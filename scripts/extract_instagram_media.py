#!/usr/bin/env python3
"""
Instagram ユーザープロフィールからメディア（画像・カルーセル・動画）を抽出し、
既存の X パイプライン (append_to_gist.py) 互換の window.YTD.tweets.part0 形式で出力するクローラー。

終了コード（extract_media.py と統一）:
  0  : 正常完了（空タイムライン含む）
  41 : 認証エラー / ログイン壁 / チャレンジ (/challenge/)
  42 : レート制限 (HTTP 429) ※チェックポイント保存あり（次回自動再開）
  43 : サーバエラー / タイムライン読み込み失敗
  44 : アカウント不在 / 凍結 / 非公開アカウント
"""

import argparse
import asyncio
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from playwright.async_api import async_playwright

DATA_DIR = "data"
OUTPUT_FILE = os.path.join(DATA_DIR, "instagram_tweets.js")
AUTH_PATH = os.path.join(DATA_DIR, "instagram_auth.json")
RESULT_FILE = os.path.join(DATA_DIR, ".last_fetch_result_instagram.json")
RESUME_DIR = os.path.join(DATA_DIR, "resume")
RESUME_TTL_SECONDS = 24 * 3600
JST = timezone(timedelta(hours=9))
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def parse_args():
    parser = argparse.ArgumentParser(description="Instagram profile media extractor (X-pipeline compatible)")
    parser.add_argument("-n", "--num", type=int, default=300, help="Target number of posts to collect")
    parser.add_argument("-u", "--user", type=str, required=True, help="Target Instagram username")
    parser.add_argument("--mode", type=str, default="post_only", help="(compat, ignored)")
    parser.add_argument("--skip-ids-file", type=str, default=None, help="File with known post IDs to skip")
    parser.add_argument("--stop-on-existing", action="store_true", help="Stop when hitting a known non-pinned ID")
    parser.add_argument("--max-no-new-scrolls", type=int, default=15, help="Safety guard: consecutive scrolls without new media")
    parser.add_argument("--max-runtime", type=int, default=3600, help="Safety guard: max runtime in seconds")
    parser.add_argument("--no-resume", action="store_true", help="Ignore saved resume checkpoint")
    parser.add_argument("--auth", type=str, default=None, help=f"Auth storage_state JSON (default: {AUTH_PATH})")
    parser.add_argument("--output", type=str, default=None, help=f"Output tweets.js path (default: {OUTPUT_FILE})")
    parser.add_argument("--result-file", type=str, default=None, help=f"Crawl metadata path (default: {RESULT_FILE})")
    return parser.parse_args()


def to_jst_from_unix(ts):
    if not ts:
        return ""
    try:
        dt = datetime.fromtimestamp(int(ts), tz=JST)
        return dt.strftime("%Y-%m-%d %H:%M:%S JST")
    except Exception:
        return ""


def _best_candidate_url(image_versions2):
    if not isinstance(image_versions2, dict):
        return None
    candidates = image_versions2.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        return None
    best = max(
        candidates,
        key=lambda c: int(c.get("width", 0) or 0) * int(c.get("height", 0) or 0),
    )
    return best.get("url")


def _best_video_url(video_versions):
    if not isinstance(video_versions, list) or not video_versions:
        return None
    best = max(
        video_versions,
        key=lambda v: int(v.get("width", 0) or 0) * int(v.get("height", 0) or 0),
    )
    return best.get("url")


def normalize_instagram_node(item, source="api_graphql"):
    """Instagram GraphQL / SSR / v1 API の投稿ノードを共通辞書へ正規化する"""
    if not isinstance(item, dict):
        return None
    code = item.get("code") or item.get("shortcode")
    pk = str(item.get("pk") or item.get("id") or "")
    if pk and "_" in pk:
        pk = pk.split("_", 1)[0]
    if not code and not pk:
        return None

    user_obj = item.get("user") or item.get("owner") or {}
    username = user_obj.get("username", "") if isinstance(user_obj, dict) else ""

    caption = ""
    caption_obj = item.get("caption")
    if isinstance(caption_obj, dict):
        caption = caption_obj.get("text", "") or ""
    elif isinstance(caption_obj, str):
        caption = caption_obj
    else:
        cap_edges = item.get("edge_media_to_caption", {}).get("edges", [])
        if isinstance(cap_edges, list) and cap_edges:
            caption = cap_edges[0].get("node", {}).get("text", "") or ""

    media_entries = []  # list of {"type": "photo"|"video", "image_url": str, "video_url": str|None}

    carousel = item.get("carousel_media")
    sidecar_edges = item.get("edge_sidecar_to_children", {}).get("edges", [])
    if isinstance(carousel, list) and carousel:
        for child in carousel:
            if not isinstance(child, dict):
                continue
            img_url = (
                _best_candidate_url(child.get("image_versions2"))
                or child.get("display_url")
                or child.get("display_uri")
            )
            vid_url = _best_video_url(child.get("video_versions")) or child.get("video_url")
            if vid_url:
                media_entries.append({"type": "video", "image_url": img_url or "", "video_url": vid_url})
            elif img_url:
                media_entries.append({"type": "photo", "image_url": img_url, "video_url": None})
    elif isinstance(sidecar_edges, list) and sidecar_edges:
        for edge in sidecar_edges:
            child = edge.get("node", {}) if isinstance(edge, dict) else {}
            img_url = child.get("display_url") or child.get("thumbnail_src") or ""
            vid_url = child.get("video_url")
            if vid_url:
                media_entries.append({"type": "video", "image_url": img_url, "video_url": vid_url})
            elif img_url:
                media_entries.append({"type": "photo", "image_url": img_url, "video_url": None})
    else:
        img_url = (
            _best_candidate_url(item.get("image_versions2"))
            or item.get("display_url")
            or item.get("display_uri")
            or item.get("thumbnail_src")
            or ""
        )
        vid_url = _best_video_url(item.get("video_versions")) or item.get("video_url")
        if vid_url:
            media_entries.append({"type": "video", "image_url": img_url, "video_url": vid_url})
        elif img_url:
            media_entries.append({"type": "photo", "image_url": img_url, "video_url": None})

    if not media_entries:
        return None

    is_reel = (item.get("product_type") == "clips") or (
        len(media_entries) == 1 and media_entries[0]["type"] == "video"
    )
    post_url = f"https://www.instagram.com/{'reel' if is_reel else 'p'}/{code}/" if code else ""
    pinned_ids = item.get("timeline_pinned_user_ids")
    is_pinned = bool(isinstance(pinned_ids, list) and len(pinned_ids) > 0)

    return {
        "id": pk or code,
        "shortcode": code or "",
        "username": username,
        "post_url": post_url,
        "caption": caption,
        "taken_at": to_jst_from_unix(item.get("taken_at") or item.get("taken_at_timestamp")),
        "media_entries": media_entries,
        "is_pinned": is_pinned,
        "source": source,
    }


def _walk_extract_media_nodes(obj, posts, source, seen_keys, depth=0):
    """Relay SSR JSON や GraphQL レスポンス内を再帰走査し、投稿メディアノードを抽出する"""
    if depth > 25:
        return
    if isinstance(obj, list):
        for elem in obj:
            _walk_extract_media_nodes(elem, posts, source, seen_keys, depth + 1)
        return
    if not isinstance(obj, dict):
        return

    # 広告ノード除外
    if obj.get("ad_id") or obj.get("injected"):
        return

    if (obj.get("code") or obj.get("shortcode")) and (
        "image_versions2" in obj
        or "carousel_media" in obj
        or "display_url" in obj
        or "display_uri" in obj
        or "video_versions" in obj
        or "edge_sidecar_to_children" in obj
    ):
        normalized = normalize_instagram_node(obj, source=source)
        if normalized:
            key = normalized["id"] or normalized["shortcode"]
            if key not in seen_keys:
                seen_keys.add(key)
                posts.append(normalized)
        return

    for val in obj.values():
        if isinstance(val, (dict, list)):
            _walk_extract_media_nodes(val, posts, source, seen_keys, depth + 1)


def extract_posts_from_payload(payload, source="api_graphql", profile_only=False):
    """
    Instagram の各種 JSON（Relay SSR / GraphQL / v1 API）から投稿リストを抽出する。
    profile_only=True の場合はプロフィールタイムライン由来ノードのみを対象とし、
    バックグラウンドで先読みされるホームフィード (xdt_api__v1__feed__timeline__connection) の混入を防ぐ。
    """
    posts = []
    if not isinstance(payload, (dict, list)):
        return posts
    seen_keys = set()

    if profile_only:
        target = _extract_profile_timeline_root(payload)
        if target is None:
            return posts
        _walk_extract_media_nodes(target, posts, source, seen_keys)
        return posts

    _walk_extract_media_nodes(payload, posts, source, seen_keys)
    return posts


def _extract_profile_timeline_root(payload):
    """プロフィール投稿一覧に該当するサブツリーのみを抽出する（ホームフィード先読みを除外）"""
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, dict):
            # 1. Polaris プロフィール投稿 GraphQL
            if "xdt_api__v1__feed__user_timeline_graphql_connection" in data:
                return data["xdt_api__v1__feed__user_timeline_graphql_connection"]
            # 2. 旧 web_profile_info 形式
            user_obj = data.get("user")
            if isinstance(user_obj, dict) and "edge_owner_to_timeline_media" in user_obj:
                return user_obj["edge_owner_to_timeline_media"]
            # ホームフィード先読み等、その他の GraphQL レスポンスは無視
            return None
        # 3. REST /api/v1/feed/user/ レスポンス
        if isinstance(payload.get("items"), list) and "feed_items" not in payload:
            return payload["items"]
    # 4. SSR JSON (Relay 入れ子構造): プロフィール接続キー配下のみ再帰探索
    found = []
    _find_profile_connection_nodes(payload, found)
    return found if found else None


def _find_profile_connection_nodes(obj, found, depth=0):
    if depth > 25:
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            if "user_timeline_graphql_connection" in k or k == "edge_owner_to_timeline_media":
                found.append(v)
            elif "timeline__connection" in k:
                # ホームフィード接続は明示的にスキップ
                continue
            elif isinstance(v, (dict, list)):
                _find_profile_connection_nodes(v, found, depth + 1)
    elif isinstance(obj, list):
        for elem in obj:
            if isinstance(elem, (dict, list)):
                _find_profile_connection_nodes(elem, found, depth + 1)


def extract_profile_has_next_page(payload):
    """プロフィール GraphQL レスポンスから page_info.has_next_page を取得する（不明時は None）"""
    if not isinstance(payload, dict):
        return None
    data = payload.get("data")
    if not isinstance(data, dict):
        return None
    conn = data.get("xdt_api__v1__feed__user_timeline_graphql_connection")
    if isinstance(conn, dict):
        pi = conn.get("page_info")
        if isinstance(pi, dict) and "has_next_page" in pi:
            return bool(pi["has_next_page"])
    return None


def to_archive_tweet_format(post, fallback_user="", force_user=None):
    """
    正規化済み Instagram 投稿を append_to_gist.py 互換の tweets.js エントリ形式に変換する。
    force_user を指定した場合（プロフィール収集時）、コラボ投稿で元 author が別アカウントであっても
    対象プロフィールユーザー配下として保存されるよう @<force_user>: を先頭に付与する。
    """
    origin_user = (post.get("username") or "").lstrip("@")
    if force_user:
        username = force_user.lstrip("@")
    else:
        username = (origin_user or fallback_user or "Unknown").lstrip("@")
    caption = post.get("caption") or ""
    if force_user and origin_user and origin_user.lower() != username.lower():
        caption = f"[collab @{origin_user}] {caption}".strip()
    full_text = f"@{username}: {caption}" if caption else f"@{username}:"
    post_url = post.get("post_url") or ""

    media_list = []
    for entry in post.get("media_entries", []):
        if entry["type"] == "video" and entry.get("video_url"):
            media_list.append({
                "media_url_https": entry.get("image_url") or "",
                "type": "video",
                "video_info": {
                    "variants": [{
                        "url": entry["video_url"],
                        "content_type": "video/mp4",
                        "bitrate": 0,
                    }]
                },
                "expanded_url": post_url,
            })
        elif entry.get("image_url"):
            media_list.append({
                "media_url_https": entry["image_url"],
                "type": "photo",
                "expanded_url": post_url,
            })

    if not media_list:
        return None

    return {
        "tweet": {
            "id_str": str(post["id"]),
            "full_text": full_text,
            "created_at": post.get("taken_at") or "",
            "post_url": post_url,
            "entities": {"media": media_list},
            "extended_entities": {"media": media_list},
        },
        "is_pinned": bool(post.get("is_pinned", False)),
    }


def write_tweets_output(tweets, output_file):
    os.makedirs(os.path.dirname(output_file) or ".", exist_ok=True)
    with open(output_file, "w", encoding="utf-8") as f:
        f.write("window.YTD.tweets.part0 = ")
        json.dump(tweets if tweets else [], f, ensure_ascii=False, indent=2)


def write_crawl_result(user, tweets_saved, status="ok", result_file=RESULT_FILE):
    try:
        os.makedirs(os.path.dirname(result_file) or ".", exist_ok=True)
        with open(result_file, "w", encoding="utf-8") as f:
            json.dump({
                "user": user,
                "tweets_saved": tweets_saved,
                "status": status,
                "timestamp": int(time.time()),
            }, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"⚠️ Warning: Failed to write crawl result: {e}", file=sys.stderr)


# --- チェックポイント保存・復元（レート制限 exit 42 対策） ---

def get_resume_file_path(user):
    safe_user = re.sub(r"[^a-z0-9_.-]", "_", (user or "").strip().lower())
    return os.path.join(RESUME_DIR, f"ig_{safe_user}.json")


def save_resume_state(user, tweets, seen_ids, target_num=None):
    if not user or not tweets:
        return
    try:
        os.makedirs(RESUME_DIR, exist_ok=True)
        path = get_resume_file_path(user)
        tmp_path = f"{path}.tmp.{os.getpid()}"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump({
                "user": user,
                "target_num": target_num,
                "tweets": list(tweets),
                "seen_ids": sorted(str(x) for x in seen_ids if x),
                "saved_at": int(time.time()),
            }, f, ensure_ascii=False, indent=2)
        os.replace(tmp_path, path)
    except Exception as e:
        print(f"⚠️ Warning: Failed to save Instagram resume state: {e}", file=sys.stderr)


def load_resume_state(user, ttl_seconds=RESUME_TTL_SECONDS, now=None):
    if not user:
        return None
    path = get_resume_file_path(user)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
        if not isinstance(state, dict) or str(state.get("user", "")).lower() != user.lower():
            return None
        saved_at = state.get("saved_at")
        cur = time.time() if now is None else now
        if ttl_seconds is not None and saved_at is not None and (cur - float(saved_at)) > ttl_seconds:
            clear_resume_state(user)
            return None
        tweets = state.get("tweets")
        if not isinstance(tweets, list):
            clear_resume_state(user)
            return None
        return {
            "user": state.get("user", user),
            "tweets": tweets,
            "seen_ids": state.get("seen_ids") if isinstance(state.get("seen_ids"), list) else [],
            "saved_at": saved_at,
        }
    except Exception:
        clear_resume_state(user)
        return None


def clear_resume_state(user):
    if not user:
        return
    path = get_resume_file_path(user)
    try:
        if os.path.exists(path):
            os.unlink(path)
    except Exception:
        pass


async def detect_block_status(page):
    url = page.url.lower()
    if "/challenge/" in url or "/checkpoint/" in url:
        return "auth_error"
    if "/accounts/login" in url:
        return "auth_error"
    if "/accounts/suspended" in url:
        return "account_dead"
    try:
        body_text = await page.inner_text("body")
    except Exception:
        body_text = ""

    if any(k in body_text for k in ("Please wait a few minutes", "数分待ってからもう一度お試しください")):
        return "rate_limit"
    if any(k in body_text for k in ("このページはご利用いただけません", "Sorry, this page isn't available")):
        return "account_dead"
    if any(k in body_text for k in ("このアカウントは非公開です", "This account is private")):
        return "account_dead"
    return None


async def run():
    args = parse_args()
    auth_path = args.auth or AUTH_PATH
    output_file = args.output or OUTPUT_FILE
    result_file = args.result_file or RESULT_FILE
    target_user = args.user.lstrip("@").strip()

    if not os.path.exists(auth_path):
        print(f"❌ Error: Instagram auth session not found at {auth_path}. Exiting with code 41.")
        sys.exit(41)

    os.makedirs(DATA_DIR, exist_ok=True)
    url = f"https://www.instagram.com/{target_user}/"
    print(f"🚀 [Instagram] Target: @{target_user} | URL: {url}")

    skip_ids = set()
    if args.skip_ids_file and os.path.exists(args.skip_ids_file):
        with open(args.skip_ids_file, "r", encoding="utf-8") as f:
            skip_ids = {line.strip() for line in f if line.strip()}
        print(f"⏭️ Skipping {len(skip_ids)} known IDs.")

    new_tweets = []
    resumed_ids = set()
    if args.no_resume:
        clear_resume_state(target_user)
    else:
        cp = load_resume_state(target_user)
        if cp:
            seen_restored = set()
            resumed_ids = {str(x) for x in cp.get("seen_ids", []) if x}
            for item in cp.get("tweets", []):
                tid = str(item.get("tweet", {}).get("id_str") or "")
                if not tid:
                    continue
                resumed_ids.add(tid)
                if tid in skip_ids or tid in seen_restored:
                    continue
                seen_restored.add(tid)
                new_tweets.append(item)
            print(f"🔄 Resuming @{target_user}: {len(new_tweets)}/{args.num} posts restored from checkpoint.")
            if len(new_tweets) >= args.num:
                final_tweets = new_tweets[:args.num]
                write_tweets_output(final_tweets, output_file)
                clear_resume_state(target_user)
                write_crawl_result(target_user, len(final_tweets), status="ok", result_file=result_file)
                print(f"\n✅ Done: {len(final_tweets)} Instagram posts saved (completed from checkpoint).")
                return

    seen_ids = set()
    skipped_count = 0
    hit_existing = False
    rate_limit_hit = False
    auth_blocked_api = False
    has_next_page = True
    api_posts_queue = []

    def process_incoming_post(post):
        nonlocal skipped_count, hit_existing
        if len(new_tweets) >= args.num or hit_existing:
            return False
        tid = str(post.get("id") or "")
        if not tid or tid in seen_ids:
            return False
        seen_ids.add(tid)

        if tid in resumed_ids:
            return False

        is_pinned = bool(post.get("is_pinned", False))
        if tid in skip_ids:
            skipped_count += 1
            if args.stop_on_existing and not is_pinned:
                print(f"🛑 Existing Instagram post ID detected ({tid}). Stopping.")
                hit_existing = True
            return False

        archive_item = to_archive_tweet_format(post, fallback_user=target_user, force_user=target_user)
        if not archive_item:
            return False

        new_tweets.append(archive_item)
        tag = " (Pinned)" if is_pinned else ""
        print(f"  [{len(new_tweets)}] Saved{tag}: {tid} ({post.get('shortcode', '')})")
        return True

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=["--disable-blink-features=AutomationControlled", "--no-sandbox", "--disable-setuid-sandbox"],
        )
        context = await browser.new_context(
            storage_state=auth_path,
            user_agent=USER_AGENT,
            viewport={"width": 1280, "height": 900},
            locale="ja-JP",
        )
        page = await context.new_page()
        await page.add_init_script("Object.defineProperty(navigator, 'webdriver', { get: () => undefined });")

        async def on_response(response):
            nonlocal rate_limit_hit, auth_blocked_api, has_next_page
            r_url = response.url
            if "instagram.com" not in r_url:
                return
            if not any(tok in r_url for tok in ("/api/v1/", "/graphql/query", "/api/graphql")):
                return

            status = response.status
            if status == 429:
                print(f"⚠️ Instagram API Rate limit (429) hit on: {r_url.split('?')[0]}")
                rate_limit_hit = True
                return
            if status in (401, 403):
                auth_blocked_api = True
                return
            if status != 200:
                return

            ctype = (response.headers.get("content-type") or "").lower()
            if "json" not in ctype and "javascript" not in ctype and "text/plain" not in ctype:
                return
            try:
                raw_text = await response.text()
            except Exception:
                return

            cleaned = re.sub(r"^\s*for\s*\(\s*;\s*;\s*\)\s*;", "", raw_text).strip()
            payloads = []
            try:
                payloads.append(json.loads(cleaned))
            except Exception:
                for line in cleaned.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payloads.append(json.loads(line))
                    except Exception:
                        pass

            for payload in payloads:
                if isinstance(payload, dict):
                    if payload.get("require_login"):
                        auth_blocked_api = True
                    errs = payload.get("errors")
                    if isinstance(errs, list) and any(
                        isinstance(e, dict) and e.get("code") == 1675002 for e in errs
                    ):
                        auth_blocked_api = True
                extracted = extract_posts_from_payload(payload, source="api_graphql", profile_only=True)
                if extracted:
                    api_posts_queue.extend(extracted)
                next_flag = extract_profile_has_next_page(payload)
                if next_flag is not None:
                    has_next_page = next_flag

        page.on("response", on_response)

        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
        except Exception as e:
            print(f"⚠️ Navigation warning: {e}")

        await asyncio.sleep(4.0)

        block_status = await detect_block_status(page)
        if block_status == "auth_error":
            print(f"🚨 Instagram auth/challenge error ({page.url}). Exiting with code 41.")
            await browser.close()
            sys.exit(41)
        elif block_status == "account_dead":
            print(f"❌ Instagram account @{target_user} is unavailable/private/suspended. Exiting with code 44.")
            clear_resume_state(target_user)
            await browser.close()
            sys.exit(44)
        elif block_status == "rate_limit":
            rate_limit_hit = True

        # 初期HTML内 Relay SSR JSON を回収
        try:
            ssr_texts = await page.evaluate("""() => {
                const out = [];
                for (const s of document.querySelectorAll('script[type="application/json"]')) {
                    const t = s.textContent || '';
                    if (t.includes('"image_versions2"') || t.includes('"carousel_media"') || t.includes('"display_url"') || t.includes('"display_uri"')) {
                        out.push(t);
                    }
                }
                return out;
            }""")
            for ssr_t in ssr_texts:
                try:
                    ssr_obj = json.loads(ssr_t)
                    for post in extract_posts_from_payload(ssr_obj, source="ssr_json", profile_only=True):
                        api_posts_queue.append(post)
                except Exception:
                    pass
        except Exception:
            pass

        no_new_scrolls = 0
        stall_count = 0
        MAX_STALLS = 4
        start_time = time.time()

        while len(new_tweets) < args.num and not hit_existing and not rate_limit_hit:
            prev_new = len(new_tweets)
            prev_seen = len(seen_ids)
            saw_resumed = False

            while api_posts_queue and len(new_tweets) < args.num and not hit_existing:
                post = api_posts_queue.pop(0)
                if str(post.get("id") or "") in resumed_ids:
                    saw_resumed = True
                process_incoming_post(post)

            if len(new_tweets) >= args.num or hit_existing or rate_limit_hit:
                break

            if not has_next_page and not api_posts_queue:
                print("\nℹ️ Reached end of Instagram profile (has_next_page=False). Stopping.")
                break

            if len(new_tweets) > prev_new or saw_resumed:
                no_new_scrolls = 0
            else:
                no_new_scrolls += 1

            if no_new_scrolls >= args.max_no_new_scrolls:
                print(f"\n🛡️ Safety Guard: No new media for {no_new_scrolls} scrolls. Stopping.")
                break
            if (time.time() - start_time) >= args.max_runtime:
                print(f"\n🛡️ Safety Guard: Reached max runtime ({args.max_runtime}s). Stopping.")
                break

            if len(seen_ids) > prev_seen:
                stall_count = 0
            else:
                stall_count += 1
                if stall_count >= MAX_STALLS:
                    print(f"\n⚠️ No more Instagram posts found after {MAX_STALLS} scrolls. Stopping.")
                    break

            try:
                await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            except Exception:
                await page.mouse.wheel(0, 1600)
            await asyncio.sleep(2.5)

            # スクロール後のブロック再確認
            b_stat = await detect_block_status(page)
            if b_stat == "rate_limit":
                rate_limit_hit = True
            elif b_stat == "auth_error":
                print("🚨 Instagram auth/challenge triggered during scroll. Exiting with code 41.")
                await browser.close()
                sys.exit(41)

        if rate_limit_hit:
            if new_tweets:
                save_resume_state(target_user, new_tweets, resumed_ids | seen_ids, target_num=args.num)
                print(f"💾 Saved Instagram resume checkpoint for @{target_user}: {len(new_tweets)}/{args.num} posts.")
            write_crawl_result(target_user, len(new_tweets), status="rate_limit", result_file=result_file)
            print("🚨 Rate limit detected from Instagram! Exiting with code 42.")
            await browser.close()
            sys.exit(42)

        if len(new_tweets) == 0 and skipped_count == 0 and len(seen_ids) == 0:
            if auth_blocked_api:
                print("🚨 Instagram API requires login (session expired). Exiting with code 41.")
                await browser.close()
                sys.exit(41)

        final_tweets = new_tweets[:args.num]
        write_tweets_output(final_tweets, output_file)
        clear_resume_state(target_user)
        write_crawl_result(target_user, len(final_tweets), status="ok" if final_tweets else "empty", result_file=result_file)
        print(f"\n✅ Done: {len(final_tweets)} Instagram posts saved.")
        await browser.close()


if __name__ == "__main__":
    asyncio.run(run())
