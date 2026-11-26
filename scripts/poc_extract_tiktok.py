#!/usr/bin/env python3
"""
TikTok タイムライン (For You / Profile / Favorites / Likes) から動画・フォトモード画像・メタデータを抽出する単体PoCスクリプト。

特徴:
  - 既存の X / Instagram パイプラインとは完全に独立
  - Playwright + 内部 API (/api/recommend/item_list/, /api/post/item_list/ 等) のインターセプト＋SSR JSON 抽出
  - バックグラウンド先読み (/api/prefetch/explore/item_list/) と広告 (isAd) を除外
  - 認証は Playwright storage_state JSON (data/tiktok_auth.json) を利用し、ヘッドレス環境でも CLI Cookie インポートに対応
  - レート制限 (429)・CAPTCHA/チャレンジ検知時は回避せず安全停止
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

DEFAULT_AUTH_PATH = os.path.join("data", "tiktok_auth.json")
DEFAULT_OUTPUT_PATH = os.path.join("data", "poc_tiktok_media.json")
JST = timezone(timedelta(hours=9))
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
BLOCKED_RESOURCE_TYPES = frozenset({"image", "media", "font"})

MODE_API_PATTERNS = {
    "foryou": ("/api/recommend/item_list",),
    "following": ("/api/following/item_list", "/api/recommend/item_list"),
    "profile": ("/api/post/item_list",),
    "favorites": ("/api/user/collect/item_list",),
    "likes": ("/api/favorite/item_list",),
}


def parse_args():
    parser = argparse.ArgumentParser(description="Standalone PoC: TikTok media extractor")
    parser.add_argument(
        "--mode",
        choices=["foryou", "following", "profile", "favorites", "likes"],
        default="foryou",
        help="Target mode: foryou (default), following, profile, favorites, likes",
    )
    parser.add_argument("-u", "--user", type=str, default=None, help="Target TikTok username (required for profile/favorites/likes)")
    parser.add_argument("-n", "--num", type=int, default=20, help="Target number of posts to collect (default: 20)")
    parser.add_argument("--auth", type=str, default=DEFAULT_AUTH_PATH, help=f"Playwright storage_state JSON (default: {DEFAULT_AUTH_PATH})")
    parser.add_argument("--save-auth", action="store_true", help="Save TikTok session to storage_state JSON (GUI if $DISPLAY exists, otherwise headless CLI cookie import)")
    parser.add_argument("--import-cookies", type=str, default=None, help="Import exported cookies JSON (Cookie-Editor/Playwright) or Cookie header text file into --auth")
    parser.add_argument("--skip-verify", action="store_true", help="Skip headless verification when saving cookies")
    parser.add_argument("--output", type=str, default=DEFAULT_OUTPUT_PATH, help=f"Output JSON path (default: {DEFAULT_OUTPUT_PATH})")
    parser.add_argument("--max-scrolls", type=int, default=10, help="Maximum scroll/next iterations (default: 10)")
    parser.add_argument("--headful", action="store_true", help="Run Chromium in visible mode")
    parser.add_argument("--debug-api", action="store_true", help="Log intercepted TikTok API endpoints")
    return parser.parse_args()


def to_jst_from_unix(ts):
    if not ts:
        return ""
    try:
        dt = datetime.fromtimestamp(int(ts), tz=JST)
        return dt.strftime("%Y-%m-%d %H:%M:%S JST")
    except Exception:
        return ""


def _pick_best_video_url(video_obj):
    if not isinstance(video_obj, dict):
        return None
    # 1. bitrateInfo から Cookie 不要の /aweme/v1/play/ かつ H.264 最高ビットレートを優先
    bitrates = video_obj.get("bitrateInfo")
    if isinstance(bitrates, list) and bitrates:
        candidates = []
        for b in bitrates:
            if not isinstance(b, dict):
                continue
            play_addr = b.get("PlayAddr") or {}
            urls = play_addr.get("UrlList") if isinstance(play_addr, dict) else None
            http_urls = [u for u in (urls or []) if isinstance(u, str) and u.startswith("http")]
            if not http_urls:
                continue
            chosen = next((u for u in http_urls if "/aweme/v1/play/" in u), http_urls[0])
            codec = str(b.get("CodecType") or "").lower()
            is_h264 = 1 if ("h264" in codec or "avc" in codec) else 0
            is_cookieless = 1 if "/aweme/v1/play/" in chosen else 0
            bitrate = int(b.get("Bitrate", 0) or 0)
            candidates.append(((is_cookieless, is_h264, bitrate), chosen))
        if candidates:
            candidates.sort(key=lambda item: item[0], reverse=True)
            return candidates[0][1]
    # 2. フォールバック: playAddr / downloadAddr
    for key in ("playAddr", "downloadAddr"):
        u = video_obj.get(key)
        if isinstance(u, str) and u.startswith("http"):
            return u
    return None


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

    media_urls = []
    video_urls = []

    # 1. フォトモード（カルーセル画像）
    image_post = item.get("imagePost")
    if isinstance(image_post, dict) and isinstance(image_post.get("images"), list) and image_post["images"]:
        for img in image_post["images"]:
            if not isinstance(img, dict):
                continue
            url_list = (img.get("imageURL") or {}).get("urlList") or []
            for u in url_list:
                if isinstance(u, str) and u.startswith("http"):
                    if u not in media_urls:
                        media_urls.append(u)
                    break
        # カバー画像フォールバック
        if not media_urls:
            cover_urls = (image_post.get("cover") or {}).get("imageURL", {}).get("urlList") or []
            for u in cover_urls:
                if isinstance(u, str) and u.startswith("http"):
                    media_urls.append(u)
                    break
        media_type = "photo_mode"
        post_url = f"https://www.tiktok.com/@{username}/photo/{item_id}" if username else ""
    else:
        # 2. 通常動画投稿（動画URL + フォールバック用サムネイルURL）
        video_obj = item.get("video") or {}
        if isinstance(video_obj, dict):
            best_vid = _pick_best_video_url(video_obj)
            if best_vid:
                video_urls.append(best_vid)
            for cov_key in ("originCover", "cover", "dynamicCover"):
                cov = video_obj.get(cov_key)
                if isinstance(cov, str) and cov.startswith("http"):
                    media_urls.append(cov)
                    break
        media_type = "video"
        post_url = f"https://www.tiktok.com/@{username}/video/{item_id}" if username else ""

    if not media_urls and not video_urls:
        return None

    return {
        "id": item_id,
        "username": username,
        "post_url": post_url,
        "caption": caption,
        "taken_at": taken_at,
        "media_type": media_type,
        "media_urls": media_urls,
        "video_urls": video_urls,
        "source": source,
    }


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


# --- ヘッドレス対応 Cookie 認証保存 ---

def _has_gui_display():
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
    """Cookie-Editor/Playwright JSON または HTTP Cookie ヘッダ文字列を TikTok Playwright Cookie 配列へ変換"""
    text = (raw_text or "").strip()
    if not text:
        return []

    if text.startswith("[") or text.startswith("{"):
        try:
            obj = json.loads(text)
            raw_list = obj.get("cookies", []) if isinstance(obj, dict) else obj
            if isinstance(raw_list, list):
                cookies = []
                for c in raw_list:
                    if not isinstance(c, dict) or not c.get("name"):
                        continue
                    domain = str(c.get("domain") or ".tiktok.com")
                    if "tiktok.com" not in domain:
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
        pairs.append(("sessionid", header))

    http_only_names = {"sessionid", "sessionid_ss", "sid_tt", "sid_guard", "uid_tt", "uid_tt_ss"}
    return [
        {
            "name": name,
            "value": val,
            "domain": ".tiktok.com",
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
    tmp_path = f"{auth_path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state_dict, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, auth_path)
    try:
        os.chmod(auth_path, 0o600)
    except Exception:
        pass


async def detect_block_status(page):
    url = page.url.lower()
    if "/login" in url:
        return "login_redirect"
    try:
        has_captcha = await page.evaluate("""() => {
            const t = (document.body ? document.body.innerText : '').toLowerCase();
            return t.includes('verify to continue') || t.includes('drag the slider')
                || t.includes('認証を完了') || !!document.querySelector('[id*="captcha"], [class*="captcha-verify"]');
        }""")
        if has_captcha:
            return "captcha"
        body_text = await page.inner_text("body")
    except Exception:
        body_text = ""

    if any(k in body_text for k in ("このアカウントは非公開です", "This account is private")):
        return "private_account"
    if any(k in body_text for k in ("アカウントが見つかりませんでした", "Couldn't find this account")):
        return "not_found"
    return None


async def save_auth_from_cookies(auth_path, cookies, verify=True):
    if not cookies:
        print("❌ Error: 有効な TikTok Cookie が見つかりませんでした。", file=sys.stderr)
        sys.exit(1)

    names = {c["name"] for c in cookies}
    if not (names & {"sessionid", "sessionid_ss", "sid_tt"}):
        print("⚠️ Warning: sessionid / sessionid_ss / sid_tt が含まれていません。", file=sys.stderr)

    _write_storage_state_secure(auth_path, {"cookies": cookies, "origins": []})
    if not verify:
        print(f"✅ Auth state saved ({len(cookies)} cookies, verification skipped): {auth_path}")
        return

    print(f"🔍 Headless Chromium で TikTok セッション有効性を検証中 ({len(cookies)} cookies)...")
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
            await page.goto("https://www.tiktok.com/foryou", wait_until="domcontentloaded", timeout=30000)
            await asyncio.sleep(3.5)
        except Exception as e:
            print(f"⚠️ Navigation warning during verify: {e}")

        block = await detect_block_status(page)
        if block in ("login_redirect", "captcha"):
            await browser.close()
            print(f"❌ Session verification blocked: status={block} (url={page.url})", file=sys.stderr)
            sys.exit(1)

        await context.storage_state(path=auth_path)
        try:
            os.chmod(auth_path, 0o600)
        except Exception:
            pass
        refreshed = await context.cookies("https://www.tiktok.com")
        await browser.close()

    print(f"✅ Verified & saved TikTok auth state ({len(refreshed)} cookies) -> {auth_path}")


async def save_auth_interactive(auth_path, verify=True):
    if _has_gui_display():
        os.makedirs(os.path.dirname(auth_path) or ".", exist_ok=True)
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=False)
            context = await browser.new_context(user_agent=USER_AGENT, viewport={"width": 1280, "height": 900})
            page = await context.new_page()
            await page.goto("https://www.tiktok.com/login", wait_until="domcontentloaded")
            print("🔐 ブラウザで TikTok に手動ログイン後、Enter を押すとセッションを保存します...")
            await asyncio.to_thread(input)
            await context.storage_state(path=auth_path)
            try:
                os.chmod(auth_path, 0o600)
            except Exception:
                pass
            print(f"✅ Auth state saved to: {auth_path}")
            await browser.close()
        return

    env_header = os.environ.get("TT_COOKIE_HEADER", "").strip()
    env_sid = os.environ.get("TT_SESSIONID", "").strip()
    if env_header:
        cookies = parse_cookies_input(env_header)
    elif env_sid:
        cookies = parse_cookies_input(f"sessionid={env_sid}; sessionid_ss={env_sid}")
    else:
        print("ℹ️ ヘッドレス環境 ($DISPLAY なし) のため CLI Cookie インポートモードで実行します。")
        print("   PCブラウザで tiktok.com にログイン後、DevTools の Cookie ヘッダ文字列または sessionid を貼り付けてください。")
        print("   （※入力は画面に表示されません。ファイルから取り込む場合は --import-cookies <file> を使用）")
        raw = await asyncio.to_thread(getpass.getpass, "TikTok Cookie header or sessionid: ")
        cookies = parse_cookies_input(raw)

    await save_auth_from_cookies(auth_path, cookies, verify=verify)


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

    if args.mode in ("profile", "favorites", "likes") and not args.user:
        print(f"❌ Error: --user (-u) is required for {args.mode} mode.", file=sys.stderr)
        sys.exit(1)

    has_auth = bool(args.auth and os.path.exists(args.auth))
    if args.mode in ("foryou", "following", "favorites", "likes") and not has_auth:
        print(f"⚠️ Running {args.mode} without auth ({args.auth} not found); personalized feed/bookmarks require --save-auth.")

    target_user = args.user.lstrip("@").strip() if args.user else ""
    if args.mode == "foryou":
        target_url = "https://www.tiktok.com/foryou"
    elif args.mode == "following":
        target_url = "https://www.tiktok.com/following"
    else:
        target_url = f"https://www.tiktok.com/@{target_user}"

    allowed_patterns = MODE_API_PATTERNS[args.mode]
    print(f"🚀 [TikTok PoC] Mode: {args.mode} | Auth: {'yes' if has_auth else 'no (anonymous)'} | URL: {target_url}")

    collected = {}
    api_events = []
    rate_limited = False

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
        await context.route(
            "**/*",
            lambda r: r.abort() if r.request.resource_type in BLOCKED_RESOURCE_TYPES else r.continue_(),
        )
        page = await context.new_page()
        await page.add_init_script("Object.defineProperty(navigator, 'webdriver', { get: () => undefined });")

        async def on_response(response):
            nonlocal rate_limited
            u = response.url
            if "tiktok.com/api/" not in u:
                return
            path_only = u.split("?")[0]
            if response.status == 429:
                rate_limited = True
                api_events.append({"status": 429, "url": path_only})
                return
            if not any(pat in path_only for pat in allowed_patterns):
                return
            if args.debug_api:
                print(f"  [API] {response.status} {path_only}")
            api_events.append({"status": response.status, "url": path_only})
            if response.status != 200:
                return
            try:
                payload = await response.json()
            except Exception:
                return
            for post in extract_items_from_payload(payload, source="api_tiktok"):
                if args.mode == "profile" and target_user:
                    if post["username"] and post["username"].lower() != target_user.lower():
                        continue
                collected.setdefault(post["id"], post)

        page.on("response", on_response)

        try:
            await page.goto(target_url, wait_until="domcontentloaded", timeout=30000)
        except Exception as e:
            print(f"⚠️ Navigation warning: {e}")

        await asyncio.sleep(4.0)
        block_status = await detect_block_status(page)
        if block_status:
            print(f"⚠️ Block/restriction detected: {block_status} (url={page.url})")

        stalls = 0
        for idx in range(1, args.max_scrolls + 1):
            if rate_limited or block_status == "captcha":
                break
            prev = len(collected)
            print(f"  [step {idx}/{args.max_scrolls}] collected={prev}/{args.num}")
            if prev >= args.num:
                break
            if args.mode in ("foryou", "following"):
                for _ in range(3):
                    await page.keyboard.press("ArrowDown")
                    await asyncio.sleep(0.8)
            else:
                await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            await asyncio.sleep(2.0)

            block_status = await detect_block_status(page)
            if block_status == "captcha":
                print("🚨 CAPTCHA/anti-bot verification detected. Stopping safely.")
                break

            if len(collected) == prev:
                stalls += 1
                if stalls >= 3:
                    print("⚠️ No new TikTok items loaded after 3 consecutive steps. Stopping.")
                    break
            else:
                stalls = 0

        final_url = page.url
        await browser.close()

    posts = list(collected.values())[: args.num]
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    result = {
        "mode": args.mode,
        "target_url": target_url,
        "final_url": final_url,
        "authenticated": has_auth,
        "block_status": block_status,
        "rate_limited": rate_limited,
        "api_endpoints": sorted({f"{e['status']} {e['url']}" for e in api_events}),
        "post_count": len(posts),
        "video_posts": sum(1 for p in posts if p["video_urls"]),
        "photo_mode_posts": sum(1 for p in posts if p["media_type"] == "photo_mode"),
        "posts": posts,
    }
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(
        f"\n✅ Finished: {result['post_count']} posts "
        f"(videos={result['video_posts']}, photo_mode={result['photo_mode_posts']}) -> {args.output}"
    )


if __name__ == "__main__":
    asyncio.run(run_poc(parse_args()))
