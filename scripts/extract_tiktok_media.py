#!/usr/bin/env python3
"""
TikTok タイムライン / ユーザープロフィールから動画・フォトモード画像・メタデータを抽出し、
既存パイプライン (append_to_gist.py) 互換の window.YTD.tweets.part0 形式で出力するクローラー。

終了コード（extract_media.py / extract_instagram_media.py と統一）:
  0  : 正常完了（空タイムライン含む）
  41 : 認証エラー / ログイン壁 / CAPTCHA・Bot検知（回避処理は行わず安全停止）
  42 : レート制限 (HTTP 429) ※チェックポイント保存あり（次回自動再開）
  43 : サーバエラー / 読み込み失敗
  44 : アカウント不在 / 非公開アカウント
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
OUTPUT_FILE = os.path.join(DATA_DIR, "tiktok_tweets.js")
AUTH_PATH = os.path.join(DATA_DIR, "tiktok_auth.json")
RESULT_FILE = os.path.join(DATA_DIR, ".last_fetch_result_tiktok.json")
RESUME_DIR = os.path.join(DATA_DIR, "resume")
RESUME_TTL_SECONDS = 24 * 3600
JST = timezone(timedelta(hours=9))
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
BLOCKED_RESOURCE_TYPES = frozenset({"image", "media", "font"})

SOURCE_MODE_API_PATTERNS = {
    "profile": ("/api/post/item_list",),
    "foryou": ("/api/recommend/item_list",),
    "following": ("/api/following/item_list", "/api/recommend/item_list"),
    "favorites": ("/api/user/collect/item_list",),
    "likes": ("/api/favorite/item_list",),
}


def parse_args():
    parser = argparse.ArgumentParser(description="TikTok media extractor (X/Instagram pipeline compatible)")
    parser.add_argument("-n", "--num", type=int, default=300, help="Target number of posts to collect")
    parser.add_argument("-u", "--user", type=str, default=None, help="Target TikTok username (required for profile/favorites/likes)")
    parser.add_argument(
        "--source-mode",
        choices=["profile", "foryou", "following", "favorites", "likes"],
        default=None,
        help="Collection source mode (default: profile if -u given, else foryou)",
    )
    parser.add_argument("--mode", type=str, default="post_only", help="(compat, ignored)")
    parser.add_argument("--skip-ids-file", type=str, default=None, help="File with known post IDs to skip")
    parser.add_argument("--stop-on-existing", action="store_true", help="Stop when hitting a known non-pinned ID")
    parser.add_argument("--max-no-new-scrolls", type=int, default=15, help="Safety guard: consecutive scrolls without new media")
    parser.add_argument("--max-runtime", type=int, default=3600, help="Safety guard: max runtime in seconds")
    parser.add_argument("--no-resume", action="store_true", help="Ignore saved resume checkpoint")
    parser.add_argument("--auth", type=str, default=None, help=f"Auth storage_state JSON (default: {AUTH_PATH})")
    parser.add_argument("--output", type=str, default=None, help=f"Output tweets.js path (default: {OUTPUT_FILE})")
    parser.add_argument("--result-file", type=str, default=None, help=f"Crawl metadata path (default: {RESULT_FILE})")
    args = parser.parse_args()
    if not args.source_mode:
        args.source_mode = "profile" if args.user else "foryou"
    return args


def to_jst_from_unix(ts):
    if not ts:
        return ""
    try:
        dt = datetime.fromtimestamp(int(ts), tz=JST)
        return dt.strftime("%Y-%m-%d %H:%M:%S JST")
    except Exception:
        return ""


async def enable_fast_resource_blocking(context):
    """帯域・CPU・RAM削減のため、画像・動画・フォント実バイナリのDLを遮断する"""
    async def _route_handler(route):
        if route.request.resource_type in BLOCKED_RESOURCE_TYPES:
            await route.abort()
        else:
            await route.continue_()

    await context.route("**/*", _route_handler)


def _select_playable_url(urls):
    """UrlList から Cookie 不要で再生可能な URL（/aweme/v1/play/）を優先選出する"""
    if not isinstance(urls, list):
        return None
    http_urls = [u for u in urls if isinstance(u, str) and u.startswith("http")]
    if not http_urls:
        return None
    # /aweme/v1/play/ は tt_chain_token Cookie 不要で Referer のみで再生可能
    for u in http_urls:
        if "/aweme/v1/play/" in u:
            return u
    for u in http_urls:
        if "webapp-prime" not in u:
            return u
    return http_urls[0]


def _pick_best_video_variant(video_obj):
    """TikTok video オブジェクトから再生互換性の高い最高ビットレート (url, bitrate) を選出する"""
    if not isinstance(video_obj, dict):
        return None, 0
    bitrates = video_obj.get("bitrateInfo")
    if isinstance(bitrates, list) and bitrates:
        candidates = []
        for b in bitrates:
            if not isinstance(b, dict):
                continue
            play_addr = b.get("PlayAddr") or {}
            urls = play_addr.get("UrlList") if isinstance(play_addr, dict) else None
            chosen_url = _select_playable_url(urls)
            if not chosen_url:
                continue
            codec = str(b.get("CodecType") or "").lower()
            is_h264 = 1 if ("h264" in codec or "avc" in codec) else 0
            is_cookieless = 1 if "/aweme/v1/play/" in chosen_url else 0
            bitrate = int(b.get("Bitrate", 0) or 0)
            candidates.append(((is_cookieless, is_h264, bitrate), chosen_url, bitrate))
        if candidates:
            candidates.sort(key=lambda item: item[0], reverse=True)
            _, best_url, best_bitrate = candidates[0]
            return best_url, best_bitrate
    for key in ("playAddr", "downloadAddr"):
        u = video_obj.get(key)
        if isinstance(u, str) and u.startswith("http"):
            return u, 0
    return None, 0


def normalize_tiktok_item(item, source="api_tiktok"):
    """TikTok API の itemList 要素を共通辞書へ正規化する（広告は除外）"""
    if not isinstance(item, dict):
        return None
    if item.get("isAd") or item.get("adAuthorization") or item.get("adLabelVersion"):
        return None

    item_id = str(item.get("id") or "")
    if not item_id:
        return None

    author = item.get("author")
    if isinstance(author, dict):
        username = str(author.get("uniqueId") or author.get("nickname") or "").lstrip("@").strip()
    elif isinstance(author, str):
        username = author.lstrip("@").strip()
    else:
        username = ""

    caption = str(item.get("desc") or "").strip()
    taken_at = to_jst_from_unix(item.get("createTime"))
    is_pinned = bool(item.get("isPinnedItem"))

    media_entries = []

    # 1. フォトモード（カルーセル画像）
    image_post = item.get("imagePost")
    if isinstance(image_post, dict) and isinstance(image_post.get("images"), list) and image_post["images"]:
        for img in image_post["images"]:
            if not isinstance(img, dict):
                continue
            url_list = (img.get("imageURL") or {}).get("urlList") or []
            for u in url_list:
                if isinstance(u, str) and u.startswith("http"):
                    media_entries.append({"type": "photo", "image_url": u, "video_url": None, "bitrate": 0})
                    break
        if not media_entries:
            cover_urls = (image_post.get("cover") or {}).get("imageURL", {}).get("urlList") or []
            for u in cover_urls:
                if isinstance(u, str) and u.startswith("http"):
                    media_entries.append({"type": "photo", "image_url": u, "video_url": None, "bitrate": 0})
                    break
        post_url = f"https://www.tiktok.com/@{username}/photo/{item_id}" if username else ""
    else:
        # 2. 通常動画投稿（動画URL + フォールバック用サムネイルURLを両方保持）
        video_obj = item.get("video") or {}
        if isinstance(video_obj, dict):
            best_vid, bitrate = _pick_best_video_variant(video_obj)
            cover_url = ""
            for cov_key in ("originCover", "cover", "dynamicCover"):
                cov = video_obj.get(cov_key)
                if isinstance(cov, str) and cov.startswith("http"):
                    cover_url = cov
                    break
            if best_vid:
                media_entries.append({
                    "type": "video",
                    "image_url": cover_url,
                    "video_url": best_vid,
                    "bitrate": bitrate,
                })
            elif cover_url:
                media_entries.append({
                    "type": "photo",
                    "image_url": cover_url,
                    "video_url": None,
                    "bitrate": 0,
                })
        post_url = f"https://www.tiktok.com/@{username}/video/{item_id}" if username else ""

    if not media_entries:
        return None

    return {
        "id": item_id,
        "username": username,
        "post_url": post_url,
        "caption": caption,
        "taken_at": taken_at,
        "media_entries": media_entries,
        "is_pinned": is_pinned,
        "source": source,
    }


def is_allowed_tiktok_api_url(url, source_mode="profile"):
    """対象 source_mode の正規 API エンドポイントのみ許可（バックグラウンド Explore 先読みを除外）"""
    if not url or "tiktok.com/api/" not in url:
        return False
    path_only = url.split("?", 1)[0]
    if "/api/prefetch/explore/" in path_only:
        return False
    patterns = SOURCE_MODE_API_PATTERNS.get(source_mode, ("/api/post/item_list",))
    return any(pat in path_only for pat in patterns)


def extract_items_from_payload(payload, source="api_tiktok"):
    """TikTok API レスポンスの itemList から投稿リストを抽出する"""
    if not isinstance(payload, dict):
        return []
    raw_list = payload.get("itemList")
    if not isinstance(raw_list, list):
        return []
    out = []
    for raw in raw_list:
        norm = normalize_tiktok_item(raw, source=source)
        if norm:
            out.append(norm)
    return out


def to_archive_tweet_format(post, fallback_user="", force_user=None):
    """正規化済み TikTok 投稿を append_to_gist.py 互換の tweets.js エントリ形式に変換する"""
    origin_user = (post.get("username") or "").lstrip("@").strip()
    if force_user:
        username = force_user.lstrip("@").strip()
    else:
        username = (origin_user or fallback_user or "Unknown").lstrip("@").strip()
    caption = post.get("caption") or ""
    full_text = f"@{username}: {caption}" if caption else f"@{username}:"
    post_url = post.get("post_url") or (
        f"https://www.tiktok.com/@{username}/video/{post['id']}" if username and post.get("id") else ""
    )

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
                        "bitrate": int(entry.get("bitrate", 0) or 0),
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
    tmp_path = f"{output_file}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write("window.YTD.tweets.part0 = ")
        json.dump(tweets if tweets else [], f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, output_file)


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

def get_resume_file_path(key):
    safe_key = re.sub(r"[^a-z0-9_.-]", "_", (key or "foryou").strip().lower())
    return os.path.join(RESUME_DIR, f"tt_{safe_key}.json")


def save_resume_state(key, tweets, seen_ids, target_num=None):
    if not key or not tweets:
        return
    try:
        os.makedirs(RESUME_DIR, exist_ok=True)
        path = get_resume_file_path(key)
        tmp_path = f"{path}.tmp.{os.getpid()}"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump({
                "key": key,
                "target_num": target_num,
                "tweets": list(tweets),
                "seen_ids": sorted(str(x) for x in seen_ids if x),
                "saved_at": int(time.time()),
            }, f, ensure_ascii=False, indent=2)
        os.replace(tmp_path, path)
    except Exception as e:
        print(f"⚠️ Warning: Failed to save TikTok resume state: {e}", file=sys.stderr)


def load_resume_state(key, ttl_seconds=RESUME_TTL_SECONDS, now=None):
    if not key:
        return None
    path = get_resume_file_path(key)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
        if not isinstance(state, dict) or str(state.get("key", "")).lower() != key.lower():
            return None
        saved_at = state.get("saved_at")
        cur = time.time() if now is None else now
        if ttl_seconds is not None and saved_at is not None and (cur - float(saved_at)) > ttl_seconds:
            clear_resume_state(key)
            return None
        tweets = state.get("tweets")
        if not isinstance(tweets, list):
            clear_resume_state(key)
            return None
        return {
            "key": state.get("key", key),
            "tweets": tweets,
            "seen_ids": state.get("seen_ids") if isinstance(state.get("seen_ids"), list) else [],
            "saved_at": saved_at,
        }
    except Exception:
        clear_resume_state(key)
        return None


def clear_resume_state(key):
    if not key:
        return
    path = get_resume_file_path(key)
    try:
        if os.path.exists(path):
            os.unlink(path)
    except Exception:
        pass


async def detect_block_status(page):
    url = page.url.lower()
    if "/login" in url:
        return "auth_error"
    try:
        has_captcha = await page.evaluate("""() => {
            const t = (document.body ? document.body.innerText : '').toLowerCase();
            return t.includes('verify to continue') || t.includes('drag the slider')
                || t.includes('認証を完了') || !!document.querySelector('[id*="captcha"], [class*="captcha-verify"]');
        }""")
        if has_captcha:
            return "auth_error"
        body_text = await page.inner_text("body")
    except Exception:
        body_text = ""

    if any(k in body_text for k in ("このアカウントは非公開です", "This account is private")):
        return "account_dead"
    if any(k in body_text for k in ("アカウントが見つかりませんでした", "Couldn't find this account")):
        return "account_dead"
    return None


async def run():
    args = parse_args()
    auth_path = args.auth or AUTH_PATH
    output_file = args.output or OUTPUT_FILE
    result_file = args.result_file or RESULT_FILE
    source_mode = args.source_mode
    target_user = (args.user or "").lstrip("@").strip()

    if source_mode in ("profile", "favorites", "likes") and not target_user:
        print(f"❌ Error: -u/--user is required for source-mode '{source_mode}'.", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(auth_path):
        print(f"❌ Error: TikTok auth session not found at {auth_path}. Exiting with code 41.")
        sys.exit(41)

    os.makedirs(DATA_DIR, exist_ok=True)
    if source_mode == "foryou":
        url = "https://www.tiktok.com/foryou"
        resume_key = "foryou"
    elif source_mode == "following":
        url = "https://www.tiktok.com/following"
        resume_key = "following"
    else:
        url = f"https://www.tiktok.com/@{target_user}"
        resume_key = f"{source_mode}_{target_user}" if source_mode != "profile" else target_user

    print(f"🚀 [TikTok] Mode: {source_mode} | Target: @{target_user or source_mode} | URL: {url}")

    skip_ids = set()
    if args.skip_ids_file and os.path.exists(args.skip_ids_file):
        with open(args.skip_ids_file, "r", encoding="utf-8") as f:
            skip_ids = {line.strip() for line in f if line.strip()}
        print(f"⏭️ Skipping {len(skip_ids)} known IDs.")

    new_tweets = []
    resumed_ids = set()
    if args.no_resume:
        clear_resume_state(resume_key)
    else:
        cp = load_resume_state(resume_key)
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
            print(f"🔄 Resuming TikTok ({resume_key}): {len(new_tweets)}/{args.num} posts restored from checkpoint.")
            if len(new_tweets) >= args.num:
                final_tweets = new_tweets[:args.num]
                write_tweets_output(final_tweets, output_file)
                clear_resume_state(resume_key)
                write_crawl_result(target_user or source_mode, len(final_tweets), status="ok", result_file=result_file)
                print(f"\n✅ Done: {len(final_tweets)} TikTok posts saved (completed from checkpoint).")
                return

    seen_ids = set()
    skipped_count = 0
    hit_existing = False
    rate_limit_hit = False
    has_more = True
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
                print(f"🛑 Existing TikTok post ID detected ({tid}). Stopping.")
                hit_existing = True
            return False

        force_u = target_user if source_mode == "profile" else None
        archive_item = to_archive_tweet_format(post, fallback_user=target_user, force_user=force_u)
        if not archive_item:
            return False

        new_tweets.append(archive_item)
        tag = " (Pinned)" if is_pinned else ""
        print(f"  [{len(new_tweets)}] Saved{tag}: {tid} (@{post.get('username', target_user)})")
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
        await enable_fast_resource_blocking(context)
        page = await context.new_page()
        await page.add_init_script("Object.defineProperty(navigator, 'webdriver', { get: () => undefined });")

        async def on_response(response):
            nonlocal rate_limit_hit, has_more
            r_url = response.url
            if "tiktok.com/api/" not in r_url:
                return
            if response.status == 429:
                print(f"⚠️ TikTok API Rate limit (429) hit on: {r_url.split('?')[0]}")
                rate_limit_hit = True
                return
            if not is_allowed_tiktok_api_url(r_url, source_mode=source_mode):
                return
            if response.status != 200:
                return
            try:
                raw_text = await response.text()
            except Exception:
                return
            if not raw_text.strip():
                if source_mode == "profile":
                    print(
                        "⚠️ TikTok /api/post/item_list/ returned empty 200 response "
                        "(headless profile API restriction; use For You / timeline ingestion instead)."
                    )
                return
            try:
                payload = json.loads(raw_text)
            except Exception:
                return
            if isinstance(payload, dict):
                if payload.get("statusCode") in (10000, 10201) or payload.get("status_code") in (10000, 10201):
                    # CAPTCHA / verify / rate-limit status code
                    rate_limit_hit = True
                    return
                if "hasMore" in payload and payload["hasMore"] is False:
                    has_more = False
            extracted = extract_items_from_payload(payload, source="api_tiktok")
            if source_mode == "profile" and target_user:
                extracted = [
                    x for x in extracted
                    if not x["username"] or x["username"].lower() == target_user.lower()
                ]
            if extracted:
                api_posts_queue.extend(extracted)

        page.on("response", on_response)

        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
        except Exception as e:
            print(f"⚠️ Navigation warning: {e}")

        await asyncio.sleep(4.0)

        block_status = await detect_block_status(page)
        if block_status == "auth_error":
            print(f"🚨 TikTok auth/CAPTCHA challenge detected ({page.url}). Exiting with code 41.")
            await browser.close()
            sys.exit(41)
        elif block_status == "account_dead":
            print(f"❌ TikTok account @{target_user} is unavailable/private. Exiting with code 44.")
            clear_resume_state(resume_key)
            await browser.close()
            sys.exit(44)

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

            if not has_more and not api_posts_queue:
                print("\nℹ️ Reached end of TikTok feed (hasMore=False). Stopping.")
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
                    print(f"\n⚠️ No more TikTok posts found after {MAX_STALLS} steps. Stopping.")
                    break

            if source_mode in ("foryou", "following"):
                for _ in range(3):
                    await page.keyboard.press("ArrowDown")
                    await asyncio.sleep(0.8)
            else:
                try:
                    await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
                except Exception:
                    await page.mouse.wheel(0, 1800)
            await asyncio.sleep(2.2)

            b_stat = await detect_block_status(page)
            if b_stat == "auth_error":
                print("🚨 TikTok auth/CAPTCHA triggered during scroll. Exiting with code 41.")
                await browser.close()
                sys.exit(41)

        if rate_limit_hit:
            if new_tweets:
                save_resume_state(resume_key, new_tweets, resumed_ids | seen_ids, target_num=args.num)
                print(f"💾 Saved TikTok resume checkpoint ({resume_key}): {len(new_tweets)}/{args.num} posts.")
            write_crawl_result(target_user or source_mode, len(new_tweets), status="rate_limit", result_file=result_file)
            print("🚨 Rate limit detected from TikTok! Exiting with code 42.")
            await browser.close()
            sys.exit(42)

        final_tweets = new_tweets[:args.num]
        write_tweets_output(final_tweets, output_file)
        clear_resume_state(resume_key)
        write_crawl_result(
            target_user or source_mode,
            len(final_tweets),
            status="ok" if final_tweets else "empty",
            result_file=result_file,
        )
        print(f"\n✅ Done: {len(final_tweets)} TikTok posts saved.")
        await browser.close()


if __name__ == "__main__":
    asyncio.run(run())
