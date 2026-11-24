#!/usr/bin/env python3
"""
Instagram タイムライン / ユーザープロフィールからメディア一覧を抽出する単体PoCスクリプト。

特徴:
  - 既存の X 向けパイプラインとは完全に独立
  - Playwright のブラウザ操作 + 内部 API / GraphQL レスポンスのインターセプト（主）と DOM フォールバック（副）のハイブリッド構成
  - 認証は Playwright の storage_state JSON（--save-auth で手動ログイン後に保存）に対応
  - レート制限 (429)・ログイン壁・チャレンジ (/challenge/) を検知して終了（回避・突破処理は行わない）
"""

import argparse
import asyncio
import getpass
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from playwright.async_api import async_playwright

DEFAULT_AUTH_PATH = os.path.join("data", "instagram_auth.json")
DEFAULT_OUTPUT_PATH = os.path.join("data", "poc_instagram_media.json")
JST = timezone(timedelta(hours=9))
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def parse_args():
    parser = argparse.ArgumentParser(description="Standalone PoC: Instagram media extractor")
    parser.add_argument(
        "--mode",
        choices=["profile", "feed"],
        default="profile",
        help="Target mode: 'profile' (user profile) or 'feed' (home timeline, auth required)",
    )
    parser.add_argument("-u", "--user", type=str, default=None, help="Target Instagram username (required for profile mode)")
    parser.add_argument("-n", "--num", type=int, default=20, help="Target number of posts to collect (default: 20)")
    parser.add_argument("--auth", type=str, default=DEFAULT_AUTH_PATH, help=f"Playwright storage_state JSON (default: {DEFAULT_AUTH_PATH})")
    parser.add_argument("--save-auth", action="store_true", help="Save Instagram session to storage_state JSON (GUI if $DISPLAY exists, otherwise headless CLI cookie import)")
    parser.add_argument("--import-cookies", type=str, default=None, help="Import exported cookies JSON (Cookie-Editor/EditThisCookie/Playwright) or Cookie header text file into --auth")
    parser.add_argument("--skip-verify", action="store_true", help="Skip headless browser verification when saving imported cookies")
    parser.add_argument("--output", type=str, default=DEFAULT_OUTPUT_PATH, help=f"Output JSON path (default: {DEFAULT_OUTPUT_PATH})")
    parser.add_argument("--max-scrolls", type=int, default=12, help="Maximum scroll iterations (default: 12)")
    parser.add_argument("--headful", action="store_true", help="Run Chromium in visible (non-headless) mode")
    parser.add_argument("--debug-api", action="store_true", help="Log intercepted Instagram API/GraphQL endpoints")
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


def normalize_v1_item(item, source="api_v1"):
    """Instagram v1 API / Polaris GraphQL (xdt_api__v1__*) 形式のノードを正規化"""
    if not isinstance(item, dict):
        return None
    code = item.get("code") or item.get("shortcode")
    pk = str(item.get("pk") or item.get("id") or "")
    if not code and not pk:
        return None

    user_obj = item.get("user") or item.get("owner") or {}
    username = user_obj.get("username", "") if isinstance(user_obj, dict) else ""

    caption_obj = item.get("caption")
    caption = ""
    if isinstance(caption_obj, dict):
        caption = caption_obj.get("text", "") or ""
    elif isinstance(caption_obj, str):
        caption = caption_obj

    media_urls = []
    video_urls = []

    # カルーセル（複数枚投稿）
    carousel = item.get("carousel_media")
    if isinstance(carousel, list) and carousel:
        for child in carousel:
            if not isinstance(child, dict):
                continue
            img_url = (
                _best_candidate_url(child.get("image_versions2"))
                or child.get("display_url")
                or child.get("display_uri")
            )
            if img_url and img_url not in media_urls:
                media_urls.append(img_url)
            vid_url = _best_video_url(child.get("video_versions")) or child.get("video_url")
            if vid_url and vid_url not in video_urls:
                video_urls.append(vid_url)
    else:
        img_url = (
            _best_candidate_url(item.get("image_versions2"))
            or item.get("display_url")
            or item.get("display_uri")
            or item.get("thumbnail_src")
        )
        if img_url:
            media_urls.append(img_url)
        vid_url = _best_video_url(item.get("video_versions")) or item.get("video_url")
        if vid_url:
            video_urls.append(vid_url)

    if not media_urls and not video_urls:
        return None

    post_url = f"https://www.instagram.com/p/{code}/" if code else ""
    media_type_code = item.get("media_type")
    if video_urls or media_type_code == 2 or item.get("is_video"):
        media_type = "video" if len(media_urls) <= 1 and not carousel else "carousel"
    elif carousel or media_type_code == 8:
        media_type = "carousel"
    else:
        media_type = "photo"

    return {
        "id": pk or code,
        "shortcode": code or "",
        "username": username,
        "post_url": post_url,
        "caption": caption,
        "taken_at": to_jst_from_unix(item.get("taken_at") or item.get("taken_at_timestamp")),
        "media_type": media_type,
        "media_urls": media_urls,
        "video_urls": video_urls,
        "source": source,
    }


def normalize_legacy_graph_node(node, source="graphql_legacy"):
    """web_profile_info 等の旧 GraphQL edge.node 形式を正規化"""
    if not isinstance(node, dict):
        return None
    shortcode = node.get("shortcode")
    pk = str(node.get("id") or "")
    if not shortcode and not pk:
        return None

    owner = node.get("owner") or {}
    username = owner.get("username", "") if isinstance(owner, dict) else ""

    caption = ""
    cap_edges = node.get("edge_media_to_caption", {}).get("edges", [])
    if isinstance(cap_edges, list) and cap_edges:
        caption = cap_edges[0].get("node", {}).get("text", "") or ""

    media_urls = []
    video_urls = []

    sidecar_edges = node.get("edge_sidecar_to_children", {}).get("edges", [])
    if isinstance(sidecar_edges, list) and sidecar_edges:
        for edge in sidecar_edges:
            child = edge.get("node", {})
            u = child.get("display_url") or child.get("thumbnail_src")
            if u and u not in media_urls:
                media_urls.append(u)
            v = child.get("video_url")
            if v and v not in video_urls:
                video_urls.append(v)
        media_type = "carousel"
    else:
        u = node.get("display_url") or node.get("thumbnail_src")
        if u:
            media_urls.append(u)
        v = node.get("video_url")
        if v:
            video_urls.append(v)
        media_type = "video" if (node.get("is_video") or video_urls) else "photo"

    if not media_urls and not video_urls:
        return None

    return {
        "id": pk or shortcode,
        "shortcode": shortcode or "",
        "username": username,
        "post_url": f"https://www.instagram.com/p/{shortcode}/" if shortcode else "",
        "caption": caption,
        "taken_at": to_jst_from_unix(node.get("taken_at_timestamp")),
        "media_type": media_type,
        "media_urls": media_urls,
        "video_urls": video_urls,
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

    # Polaris GraphQL / Relay SSR のメディアノード判定
    if obj.get("code") and (
        "image_versions2" in obj
        or "carousel_media" in obj
        or "display_url" in obj
        or "display_uri" in obj
        or "video_versions" in obj
    ):
        normalized = normalize_v1_item(obj, source=source)
        if normalized:
            key = normalized["shortcode"] or normalized["id"]
            if key not in seen_keys:
                seen_keys.add(key)
                posts.append(normalized)
        return

    # 旧 GraphQL (web_profile_info) ノード判定
    if obj.get("shortcode") and ("display_url" in obj or "edge_sidecar_to_children" in obj):
        normalized = normalize_legacy_graph_node(obj, source=source)
        if normalized:
            key = normalized["shortcode"] or normalized["id"]
            if key not in seen_keys:
                seen_keys.add(key)
                posts.append(normalized)
        return

    # 広告ノードはスキップ
    if obj.get("ad_id") or obj.get("injected"):
        return

    for val in obj.values():
        if isinstance(val, (dict, list)):
            _walk_extract_media_nodes(val, posts, source, seen_keys, depth + 1)


def extract_posts_from_payload(payload, source="graphql"):
    """Instagram の各種 JSON（Relay SSR / GraphQL / v1 API）から投稿リストを抽出する"""
    posts = []
    if not isinstance(payload, (dict, list)):
        return posts
    seen_keys = set()
    _walk_extract_media_nodes(payload, posts, source, seen_keys)
    return posts


EXTRACT_DOM_POSTS_JS = """() => {
    const results = [];
    const seen = new Set();
    const links = document.querySelectorAll('a[href*="/p/"], a[href*="/reel/"]');
    for (const a of links) {
        const href = a.getAttribute('href') || '';
        const m = href.match(/\\/(p|reel)\\/([A-Za-z0-9_-]+)/);
        if (!m) continue;
        const shortcode = m[2];
        if (seen.has(shortcode)) continue;
        const img = a.querySelector('img');
        if (!img) continue;
        const src = img.getAttribute('src') || '';
        if (!src || src.startsWith('data:')) continue;
        seen.add(shortcode);
        results.push({
            shortcode: shortcode,
            post_url: 'https://www.instagram.com/' + m[1] + '/' + shortcode + '/',
            media_url: src,
            alt: img.getAttribute('alt') || '',
            kind: m[1] === 'reel' ? 'video' : 'photo',
        });
    }
    return results;
}"""


def _has_gui_display():
    """GUIブラウザを起動可能なディスプレイ環境があるか判定する"""
    if sys.platform in ("win32", "darwin"):
        return True
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def _normalize_same_site(val):
    if not val:
        return "Lax"
    s = str(val).strip().lower()
    if s in ("none", "no_restriction"):
        return "None"
    if s == "strict":
        return "Strict"
    return "Lax"


def parse_cookies_input(raw_text):
    """
    Cookie-Editor / EditThisCookie / Playwright JSON、または HTTP Cookie ヘッダ文字列
    (例: 'sessionid=...; csrftoken=...; ds_user_id=...') を Playwright Cookie リストに変換する。
    """
    text = (raw_text or "").strip()
    if not text:
        return []

    # 1. JSON 形式（配列または {"cookies": [...]}）
    if text.startswith("[") or text.startswith("{"):
        try:
            obj = json.loads(text)
            raw_list = obj.get("cookies", []) if isinstance(obj, dict) else obj
            if isinstance(raw_list, list):
                cookies = []
                for c in raw_list:
                    if not isinstance(c, dict) or not c.get("name"):
                        continue
                    domain = str(c.get("domain") or ".instagram.com")
                    if "instagram.com" not in domain:
                        continue
                    exp = c.get("expires", c.get("expirationDate", -1))
                    try:
                        exp = float(exp) if exp is not None else -1
                    except Exception:
                        exp = -1
                    cookies.append({
                        "name": str(c["name"]),
                        "value": str(c.get("value", "")),
                        "domain": domain,
                        "path": str(c.get("path") or "/"),
                        "expires": exp,
                        "httpOnly": bool(c.get("httpOnly", False)),
                        "secure": bool(c.get("secure", True)),
                        "sameSite": _normalize_same_site(c.get("sameSite")),
                    })
                return cookies
        except Exception:
            pass

    # 2. HTTP Cookie ヘッダ形式 ("Cookie: a=1; b=2" または "a=1; b=2")、または sessionid 単体値
    header = re.sub(r"^\s*cookie\s*:\s*", "", text, flags=re.IGNORECASE).strip()
    pairs = []
    if "=" in header:
        for part in header.split(";"):
            part = part.strip()
            if "=" not in part:
                continue
            name, val = part.split("=", 1)
            name, val = name.strip(), val.strip()
            if name and val:
                pairs.append((name, val))
    elif header:
        # "=" を含まない場合は sessionid 単体入力として扱う
        pairs.append(("sessionid", header))

    http_only_names = {"sessionid", "rur", "datr", "shbid", "shbts"}
    return [
        {
            "name": name,
            "value": val,
            "domain": ".instagram.com",
            "path": "/",
            "expires": -1,
            "httpOnly": name.lower() in http_only_names,
            "secure": True,
            "sameSite": "Lax",
        }
        for name, val in pairs
    ]


def _write_storage_state_secure(auth_path, state_dict):
    os.makedirs(os.path.dirname(auth_path) or ".", exist_ok=True)
    with open(auth_path, "w", encoding="utf-8") as f:
        json.dump(state_dict, f, ensure_ascii=False, indent=2)
    try:
        os.chmod(auth_path, 0o600)
    except Exception:
        pass


async def save_auth_from_cookies(auth_path, cookies, verify=True):
    """インポートした Cookie から Playwright storage_state JSON を作成・検証して保存する"""
    if not cookies:
        print("❌ Error: 有効な Instagram Cookie が見つかりませんでした。", file=sys.stderr)
        sys.exit(1)

    cookie_names = {c["name"] for c in cookies}
    if "sessionid" not in cookie_names:
        print("⚠️ Warning: 'sessionid' Cookie が含まれていません（認証に失敗する可能性があります）。", file=sys.stderr)

    state = {"cookies": cookies, "origins": []}
    _write_storage_state_secure(auth_path, state)

    if not verify:
        print(f"✅ Auth state saved ({len(cookies)} cookies, verification skipped): {auth_path}")
        return

    print(f"🔍 Headless Chromium でセッション有効性を検証中 ({len(cookies)} cookies)...")
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=["--disable-blink-features=AutomationControlled", "--no-sandbox"],
        )
        context = await browser.new_context(
            storage_state=auth_path,
            user_agent=USER_AGENT,
            viewport={"width": 1280, "height": 900},
            locale="ja-JP",
        )
        page = await context.new_page()
        await page.add_init_script("Object.defineProperty(navigator, 'webdriver', { get: () => undefined });")
        try:
            await page.goto("https://www.instagram.com/", wait_until="domcontentloaded", timeout=30000)
            await asyncio.sleep(3.5)
        except Exception as e:
            print(f"⚠️ Navigation warning during verify: {e}")

        block_status = await detect_block_status(page)
        final_url = page.url
        refreshed_cookies = await context.cookies("https://www.instagram.com")
        has_ds_user = any(c.get("name") == "ds_user_id" and c.get("value") for c in refreshed_cookies)
        has_sessionid = any(c.get("name") == "sessionid" and c.get("value") for c in refreshed_cookies)

        if block_status in ("login_redirect", "challenge", "suspended"):
            await browser.close()
            print(f"❌ Session verification failed: status={block_status} (url={final_url})", file=sys.stderr)
            print("   ブラウザで最新の Cookie（sessionid を含む）を再取得してやり直してください。", file=sys.stderr)
            sys.exit(1)

        # リフレッシュされた Cookie / LocalStorage を含めて storage_state を再保存
        await context.storage_state(path=auth_path)
        try:
            os.chmod(auth_path, 0o600)
        except Exception:
            pass
        await browser.close()

    if has_sessionid and has_ds_user:
        print(f"✅ Verified & saved auth state ({len(refreshed_cookies)} cookies) -> {auth_path}")
    else:
        print(
            f"⚠️ Saved auth state to {auth_path}, but login confirmation is incomplete "
            f"(sessionid={has_sessionid}, ds_user_id={has_ds_user}, url={final_url})."
        )


async def save_auth_interactive(auth_path, verify=True):
    """GUI環境ならブラウザ手動ログイン、ヘッドレス環境ならCLIでのCookieインポートで storage_state を保存する"""
    if _has_gui_display():
        os.makedirs(os.path.dirname(auth_path) or ".", exist_ok=True)
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=False)
            context = await browser.new_context(user_agent=USER_AGENT, viewport={"width": 1280, "height": 900})
            page = await context.new_page()
            await page.goto("https://www.instagram.com/accounts/login/", wait_until="domcontentloaded")
            print("🔐 ブラウザで Instagram に手動ログインしてください。ログイン完了後に Enter を押すとセッションを保存します...")
            await asyncio.to_thread(input)
            await context.storage_state(path=auth_path)
            try:
                os.chmod(auth_path, 0o600)
            except Exception:
                pass
            print(f"✅ Auth state saved to: {auth_path}")
            await browser.close()
        return

    # ヘッドレス環境（$DISPLAY なし）: 環境変数または対話入力で Cookie を取り込む
    env_header = os.environ.get("IG_COOKIE_HEADER", "").strip()
    env_sessionid = os.environ.get("IG_SESSIONID", "").strip()
    if env_header:
        cookies = parse_cookies_input(env_header)
    elif env_sessionid:
        parts = [f"sessionid={env_sessionid}"]
        if os.environ.get("IG_CSRFTOKEN"):
            parts.append(f"csrftoken={os.environ['IG_CSRFTOKEN'].strip()}")
        if os.environ.get("IG_DS_USER_ID"):
            parts.append(f"ds_user_id={os.environ['IG_DS_USER_ID'].strip()}")
        cookies = parse_cookies_input("; ".join(parts))
    else:
        print("ℹ️ GUI ($DISPLAY) がないヘッドレス環境のため、ブラウザ起動をスキップして Cookie インポートモードで実行します。")
        print("   PCのブラウザで instagram.com にログイン後、DevTools (Network / Application > Cookies) から")
        print("   'Cookie' ヘッダ文字列（例: sessionid=...; csrftoken=...; ds_user_id=...）または sessionid 値を貼り付けてください。")
        print("   （※入力内容は画面に表示されません。ファイルから取り込む場合は --import-cookies <file> を使用してください）")
        raw_input = await asyncio.to_thread(getpass.getpass, "Cookie header or sessionid: ")
        cookies = parse_cookies_input(raw_input)

    await save_auth_from_cookies(auth_path, cookies, verify=verify)


async def detect_block_status(page):
    """ログイン要求・チャレンジ・アカウント凍結などのブロック状態を判定する"""
    url = page.url.lower()
    if "/challenge/" in url or "/checkpoint/" in url:
        return "challenge"
    if "/accounts/login" in url:
        return "login_redirect"
    if "/accounts/suspended" in url:
        return "suspended"
    try:
        body_text = await page.inner_text("body")
    except Exception:
        body_text = ""

    if any(k in body_text for k in ["Please wait a few minutes", "数分待ってからもう一度お試しください"]):
        return "rate_limit"
    if any(k in body_text for k in ["このページはご利用いただけません", "Sorry, this page isn't available"]):
        return "not_found"
    if any(k in body_text for k in ["このアカウントは非公開です", "This account is private"]):
        return "private_account"
    return None


async def run_poc(args):
    if args.import_cookies:
        if not os.path.exists(args.import_cookies):
            print(f"❌ Error: Cookie file not found: {args.import_cookies}", file=sys.stderr)
            sys.exit(1)
        with open(args.import_cookies, "r", encoding="utf-8") as f:
            cookies = parse_cookies_input(f.read())
        await save_auth_from_cookies(args.auth, cookies, verify=not args.skip_verify)
        return

    if args.save_auth:
        await save_auth_interactive(args.auth, verify=not args.skip_verify)
        return

    if args.mode == "profile" and not args.user:
        print("❌ Error: --user (-u) is required for profile mode.", file=sys.stderr)
        sys.exit(1)

    has_auth = bool(args.auth and os.path.exists(args.auth))
    if args.mode == "feed" and not has_auth:
        print(f"❌ Error: Feed mode requires auth session file ({args.auth}). Run with --save-auth first.", file=sys.stderr)
        sys.exit(1)

    target_url = (
        f"https://www.instagram.com/{args.user.lstrip('@')}/"
        if args.mode == "profile"
        else "https://www.instagram.com/"
    )
    print(f"🚀 Mode: {args.mode} | Auth: {'yes' if has_auth else 'no (anonymous)'} | URL: {target_url}")

    collected_by_key = {}  # shortcode or id -> normalized post dict
    api_events = []
    rate_limited = False
    auth_blocked_api = False

    def merge_post(post):
        key = post.get("shortcode") or post.get("id")
        if not key:
            return False
        existing = collected_by_key.get(key)
        # API 由来データがあれば DOM 由来より優先して上書き
        if existing is None:
            collected_by_key[key] = post
            return True
        if existing.get("source") == "dom_fallback" and post.get("source") != "dom_fallback":
            collected_by_key[key] = post
        return False

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=not args.headful,
            args=["--disable-blink-features=AutomationControlled", "--no-sandbox"],
        )
        ctx_kwargs = {
            "user_agent": USER_AGENT,
            "viewport": {"width": 1280, "height": 900},
            "locale": "ja-JP",
        }
        if has_auth:
            ctx_kwargs["storage_state"] = args.auth
        context = await browser.new_context(**ctx_kwargs)
        page = await context.new_page()
        await page.add_init_script("Object.defineProperty(navigator, 'webdriver', { get: () => undefined });")

        async def on_response(response):
            nonlocal rate_limited, auth_blocked_api
            url = response.url
            if "instagram.com" not in url:
                return
            is_api = any(tok in url for tok in ("/api/v1/", "/graphql/query", "/api/graphql"))
            if not is_api:
                return

            status = response.status
            if args.debug_api:
                print(f"  [API] {status} {url.split('?')[0]}")
            api_events.append({"status": status, "url": url.split("?")[0]})

            if status == 429:
                rate_limited = True
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

            # Meta /api/graphql は通常のJSONまたは改行区切りJSON (NDJSON) を返す場合がある
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
                    # GraphQL エラー（未ログイン制限 1675002 等）を検知
                    errors = payload.get("errors")
                    if isinstance(errors, list) and any(
                        isinstance(e, dict) and e.get("code") == 1675002 for e in errors
                    ):
                        auth_blocked_api = True

                extracted = extract_posts_from_payload(payload, source="api_graphql")
                for post in extracted:
                    if args.user and not post["username"]:
                        post["username"] = args.user.lstrip("@")
                    merge_post(post)

        page.on("response", on_response)

        try:
            await page.goto(target_url, wait_until="domcontentloaded", timeout=30000)
        except Exception as e:
            print(f"⚠️ Navigation warning: {e}")

        await asyncio.sleep(4.0)

        # 未ログイン時に表示される「閉じる」ダイアログのみ軽く閉じる（CAPTCHA等は操作しない）
        try:
            close_btn = await page.query_selector('div[role="dialog"] svg[aria-label="閉じる"], div[role="dialog"] svg[aria-label="Close"]')
            if close_btn:
                await close_btn.click()
                await asyncio.sleep(0.5)
        except Exception:
            pass

        block_status = await detect_block_status(page)
        if block_status:
            print(f"⚠️ Block/restriction detected: {block_status} (url={page.url})")

        # 初期HTMLに埋め込まれた Relay SSR JSON (<script type="application/json">) から投稿メタデータを抽出
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
                    for post in extract_posts_from_payload(ssr_obj, source="ssr_json"):
                        if args.user and not post["username"]:
                            post["username"] = args.user.lstrip("@")
                        merge_post(post)
                except Exception:
                    pass
        except Exception:
            pass

        stalls = 0
        for scroll_i in range(1, args.max_scrolls + 1):
            if rate_limited:
                print("🚨 Rate limit (429) detected from Instagram.")
                break

            # DOM フォールバックで初期SSR描画分も補完
            try:
                dom_items = await page.evaluate(EXTRACT_DOM_POSTS_JS)
                for d in dom_items:
                    merge_post({
                        "id": d["shortcode"],
                        "shortcode": d["shortcode"],
                        "username": args.user.lstrip("@") if args.user else "",
                        "post_url": d["post_url"],
                        "caption": d["alt"],
                        "taken_at": "",
                        "media_type": d["kind"],
                        "media_urls": [d["media_url"]],
                        "video_urls": [],
                        "source": "dom_fallback",
                    })
            except Exception:
                pass

            prev_count = len(collected_by_key)
            print(f"  [scroll {scroll_i}/{args.max_scrolls}] collected={prev_count}/{args.num}")
            if prev_count >= args.num:
                break

            # スクロール中にログイン壁モーダルが出現したか確認
            has_login_modal = False
            try:
                dlg = await page.query_selector('div[role="dialog"]')
                if dlg:
                    dlg_text = await dlg.inner_text()
                    if any(w in dlg_text for w in ("ログイン", "Log in", "Sign up", "アカウントを作成")):
                        has_login_modal = True
            except Exception:
                pass
            if has_login_modal and not has_auth:
                print("🔒 Login wall modal appeared (anonymous scroll limit reached).")
                break

            await page.evaluate("window.scrollBy(0, 1400)")
            await asyncio.sleep(2.5)

            if len(collected_by_key) == prev_count:
                stalls += 1
                if stalls >= 3:
                    print("⚠️ No new posts loaded after 3 consecutive scrolls. Stopping.")
                    break
            else:
                stalls = 0

        final_url = page.url
        await browser.close()

    posts = list(collected_by_key.values())[: args.num]
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    result = {
        "mode": args.mode,
        "target_url": target_url,
        "final_url": final_url,
        "authenticated": has_auth,
        "block_status": block_status,
        "rate_limited": rate_limited,
        "auth_blocked_api": auth_blocked_api,
        "api_event_count": len(api_events),
        "api_endpoints": sorted({f"{e['status']} {e['url']}" for e in api_events}),
        "post_count": len(posts),
        "total_media_urls": sum(len(p["media_urls"]) for p in posts),
        "sources_breakdown": {
            src: sum(1 for p in posts if p["source"] == src)
            for src in sorted({p["source"] for p in posts})
        },
        "posts": posts,
    }
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(
        f"\n✅ Finished: {result['post_count']} posts ({result['total_media_urls']} image URLs) "
        f"| sources={result['sources_breakdown']} | output={args.output}"
    )


if __name__ == "__main__":
    asyncio.run(run_poc(parse_args()))
