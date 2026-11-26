#!/usr/bin/env python3
"""
タイムライン上のポストからXアカウントを自動収集し、ギャラリーを拡張するスクリプト。

【仕様】
1. タイムライン（https://x.com/home）にアクセスし、10スクロールでアカウントを収集。
2. タイムライン上およびポスト内の広告（Ad）は完全に除外。
3. 10スクロールで収集した各アカウントに対して最新300ポスト分の画像収集を実行:
   - 既存アカウントの場合: --stop-on-existing で読み込み、既存ギャラリー（Favorite/User）を維持。
   - 新規アカウントの場合: --is-candidate で読み込み、「Candidate」ギャラリーに新規登録。
4. 画像収集が完了したらホーム画面をリロードし、再び10スクロールのアカウント収集へ戻ってループを継続。
"""

import re
import asyncio
import json
import os
import sys
import argparse
import subprocess
from playwright.async_api import async_playwright

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from extract_media import AUTH_PATH, DATA_DIR, dismiss_modals
from extract_instagram_media import AUTH_PATH as IG_AUTH_PATH, extract_posts_from_payload as extract_ig_posts_from_payload
from extract_tiktok_media import (
    AUTH_PATH as TIKTOK_AUTH_PATH,
    OUTPUT_FILE as TIKTOK_OUTPUT_FILE,
    USER_AGENT as TIKTOK_USER_AGENT,
    advance_tiktok_feed,
    extract_items_from_payload as extract_tt_items_from_payload,
    is_allowed_tiktok_api_url,
    enable_fast_resource_blocking as enable_tt_resource_blocking,
    to_archive_tweet_format as tt_to_archive_tweet_format,
    write_tweets_output as tt_write_tweets_output,
)

EXTRACT_ACCOUNTS_JS = """() => {
    const articles = document.querySelectorAll('article');
    const accounts = [];
    const adKeywords = ['広告', 'ad', 'sponsored', 'プロモーション', 'promoted'];

    articles.forEach(article => {
        // --- 広告（プロモーションポスト）の除外チェック ---
        // テキストによる判定: ポスト要素内のテキストに「プロモーション」または「Promoted」が含まれる場合
        // ※ [data-testid="placementTracking"] はXの動画プレイヤーラッパー要素にも付与されるため属性単体では除外しない
        const articleText = (article.innerText || '').toLowerCase();
        if (articleText.includes('プロモーション') || articleText.includes('promoted')) return;

        // バッジ、span、svg、テキストから広告判定
        const adBadges = article.querySelectorAll('[data-testid="badge"], span, svg');
        let isAd = false;
        for (const badge of adBadges) {
            const txt = (badge.innerText || badge.getAttribute('aria-label') || '').trim().toLowerCase();
            if (adKeywords.some(kw => txt === kw || txt.startsWith(kw + ' ') || txt.endsWith(' ' + kw))) {
                isAd = true;
                break;
            }
        }
        if (isAd) return;

        // 2. ユーザー名の抽出（タイムスタンプリンクを最優先）
        let username = '';
        const timeEl = article.querySelector('time');
        const timeLink = timeEl ? timeEl.closest('a') : article.querySelector('a:has(time)');
        if (timeLink) {
            const href = timeLink.getAttribute('href') || '';
            const m = href.match(/\\/([^\\/]+)\\/status\\/\\d+/);
            if (m && m[1] !== 'home' && m[1] !== 'explore' && m[1] !== 'i') {
                username = m[1];
            }
        }

        // フォールバック: statusリンク
        if (!username) {
            const statusLinks = article.querySelectorAll('a[href*="/status/"]');
            for (const link of statusLinks) {
                if (link.closest('[data-testid="quotedTweet"]')) continue;
                const href = link.getAttribute('href') || '';
                const m = href.match(/\\/([^\\/]+)\\/status\\/\\d+/);
                if (m && m[1] !== 'home' && m[1] !== 'explore' && m[1] !== 'i') {
                    username = m[1];
                    break;
                }
            }
        }

        if (username) {
            accounts.push(username);
        }
    });

    return accounts;
}"""

def load_master_gist_id():
    """環境変数または.envファイルからMASTER_GIST_IDを取得"""
    gid = os.environ.get("MASTER_GIST_ID")
    if gid:
        return gid.strip()

    env_paths = [".env", os.path.join(os.path.dirname(__file__), "..", ".env")]
    for ep in env_paths:
        if os.path.exists(ep):
            try:
                with open(ep, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("MASTER_GIST_ID="):
                            return line.split("=", 1)[1].strip().strip('"').strip("'")
            except Exception:
                pass
    return None

def fetch_master_user_gists(gist_id):
    """マスターGistから現在の全既存ユーザー一覧（user_gists/tweets/users）を取得して返す"""
    if not gist_id:
        return {}
    candidate_files = ["data.json", "gallary_data.json"]
    data = None

    # 1. GitHub API + raw_url 経由での取得（大容量JSON対応）
    try:
        res = subprocess.run(
            ["gh", "api", f"gists/{gist_id}"],
            capture_output=True, text=True, check=True
        )
        gist_meta = json.loads(res.stdout)
        files = gist_meta.get("files", {})
        for fn in candidate_files:
            if fn in files and files[fn].get("raw_url"):
                dl = subprocess.run(
                    ["curl", "-sf", "-L", files[fn]["raw_url"]],
                    capture_output=True, text=True, check=True
                )
                data = json.loads(dl.stdout.strip())
                if data:
                    break
    except Exception as e:
        # 2. フォールバック: gh gist view
        for fn in candidate_files:
            try:
                res = subprocess.run(
                    ["gh", "gist", "view", gist_id, "-f", fn],
                    capture_output=True, text=True, check=True
                )
                data = json.loads(res.stdout.strip())
                if data:
                    break
            except Exception:
                continue

    if not isinstance(data, dict):
        return {}

    user_map = {}
    if "user_gists" in data and isinstance(data["user_gists"], dict):
        user_map.update(data["user_gists"])
    if "users" in data and isinstance(data["users"], dict):
        for u in data["users"].keys():
            if u not in user_map:
                user_map[u] = {}
    if "tweets" in data and isinstance(data["tweets"], list):
        for t in data["tweets"]:
            u = t.get("username")
            if u and u not in user_map:
                user_map[u] = {}
    return user_map

def parse_args():
    parser = argparse.ArgumentParser(description="Timeline Candidate Account Collector")
    parser.add_argument("-g", "--gist-id", default=None, help="Master Gist ID (defaults to MASTER_GIST_ID env)")
    parser.add_argument("--platform", choices=["x", "instagram", "tiktok"], default=os.environ.get("PLATFORM", "x").lower(),
                        help="Platform to crawl: x, instagram, or tiktok (default: x)")
    parser.add_argument("-n", "--num", type=int, default=300, help="Number of tweets to fetch for new accounts (default: 300)")
    parser.add_argument("--num-existing", type=int, default=500, help="Number of tweets to fetch for existing accounts (default: 500)")
    parser.add_argument("--timeline-url", default=None, help="Timeline URL to scrape (defaults to x.com/home, instagram.com/, or tiktok.com/foryou)")
    parser.add_argument("--scroll-batch-size", type=int, default=10, help="Number of scrolls per collection batch (default: 10)")
    parser.add_argument("--max-cycles", type=int, default=None, help="Maximum number of reload-and-collect cycles (default: unlimited)")
    parser.add_argument("--max-total-accounts", type=int, default=None, help="Max total accounts to process")
    parser.add_argument("--rate-limit-wait", type=int, default=int(os.environ.get("RATE_LIMIT_WAIT", 900)),
                        help="Seconds to wait when rate limited (code 42, default: 900s / 15m)")
    parser.add_argument("--account-cooldown", type=int, default=3,
                        help="Cooldown seconds between processing accounts (default: 3s)")
    parser.add_argument("--no-headless", action="store_true", help="Run browser in headful mode")
    args = parser.parse_args()
    if not args.timeline_url:
        if args.platform == "instagram":
            args.timeline_url = "https://www.instagram.com/"
        elif args.platform == "tiktok":
            args.timeline_url = "https://www.tiktok.com/foryou"
        else:
            args.timeline_url = "https://x.com/home"
    return args

async def collect_batch_accounts(page, scroll_batch_size=10, excluded_accounts_lower=None):
    """10スクロール分のアカウントを広告除外しながら収集して返す"""
    excluded = excluded_accounts_lower or set()
    batch_accounts = []
    batch_set = set()

    # 初期表示のアカウント抽出
    await dismiss_modals(page)
    try:
        initial_extracted = await page.evaluate(EXTRACT_ACCOUNTS_JS)
        for acc in initial_extracted:
            acc_clean = acc.strip().lstrip("@")
            acc_lower = acc_clean.lower()
            if acc_clean and acc_lower not in excluded and acc_lower not in batch_set:
                batch_set.add(acc_lower)
                batch_accounts.append(acc_clean)
                print(f"  🎯 Found account from initial view: @{acc_clean} (Batch total: {len(batch_accounts)})")
    except Exception as e:
        print(f"⚠️ Initial extraction warning: {e}")

    for scroll_idx in range(1, scroll_batch_size + 1):
        await dismiss_modals(page)

        # スクロール実行
        prev_scroll_y = await page.evaluate("window.scrollY")
        await page.mouse.wheel(0, 2000)
        await asyncio.sleep(2.5)
        curr_scroll_y = await page.evaluate("window.scrollY")

        # 広告除外してアカウント抽出
        try:
            extracted_batch = await page.evaluate(EXTRACT_ACCOUNTS_JS)
        except Exception as e:
            print(f"⚠️ Extraction evaluate warning: {e}")
            extracted_batch = []

        new_count = 0
        for acc in extracted_batch:
            acc_clean = acc.strip().lstrip("@")
            acc_lower = acc_clean.lower()
            if acc_clean and acc_lower not in excluded and acc_lower not in batch_set:
                batch_set.add(acc_lower)
                batch_accounts.append(acc_clean)
                new_count += 1
                print(f"  🎯 Found account (scroll {scroll_idx}/{scroll_batch_size}): @{acc_clean} (Batch total: {len(batch_accounts)})")

        if curr_scroll_y == prev_scroll_y and new_count == 0:
            print(f"⏳ Cannot scroll down further at scroll {scroll_idx}/{scroll_batch_size}.")
            break

    return batch_accounts

def process_account(gist_id, username, num, is_existing, platform="x"):
    """
    既存/新規アカウントに応じて append_to_gist.py を呼び出す。
    - 既存アカウント: --stop-on-existing (既存ギャラリー所属維持)
    - 新規アカウント: --is-candidate (Candidateギャラリー登録)
    """
    python_bin = sys.executable
    append_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "append_to_gist.py")

    cmd = [python_bin, append_script, "-g", gist_id, "-u", username, "-n", str(num)]
    if platform in ("instagram", "tiktok"):
        cmd.extend(["--platform", platform])
    if is_existing:
        print(f"\n📂 Processing EXISTING account: @{username} (Stop on existing: Yes, Keep Gallery: Yes)")
        cmd.append("-s")
    else:
        print(f"\n✨ Processing NEW account: @{username} (Candidate Gallery: Yes)")
        cmd.append("--is-candidate")

    res = subprocess.run(cmd)
    return res.returncode


async def _collect_instagram_ssr_usernames(page, ig_feed_usernames):
    """初期HTML内の Relay SSR JSON からユーザー名を回収して ig_feed_usernames へ追記する"""
    try:
        ssr_texts = await page.evaluate("""() => {
            const out = [];
            for (const s of document.querySelectorAll('script[type="application/json"]')) {
                const t = s.textContent || '';
                if (t.includes('"image_versions2"') || t.includes('"carousel_media"') || t.includes('"display_uri"')) {
                    out.push(t);
                }
            }
            return out;
        }""")
        for ssr_t in ssr_texts:
            try:
                for post in extract_ig_posts_from_payload(json.loads(ssr_t), source="ssr_json"):
                    if post.get("username"):
                        ig_feed_usernames.append(post["username"])
            except Exception:
                pass
    except Exception:
        pass


async def collect_instagram_batch_accounts(page, ig_feed_usernames, scroll_batch_size=10, excluded_accounts_lower=None):
    """Instagram ホームフィードの SSR JSON + GraphQL 応答からアカウントを収集する"""
    excluded = excluded_accounts_lower or set()
    batch_accounts = []
    batch_set = set()

    def _drain():
        raw_seen = 0
        added = 0
        while ig_feed_usernames:
            raw_seen += 1
            acc = ig_feed_usernames.pop(0).strip().lstrip("@")
            acc_lower = acc.lower()
            if acc and acc_lower not in excluded and acc_lower not in batch_set:
                batch_set.add(acc_lower)
                batch_accounts.append(acc)
                added += 1
                print(f"  🎯 Found Instagram account: @{acc} (Batch total: {len(batch_accounts)})")
        return raw_seen, added

    # 初期 SSR JSON からもユーザー名を回収
    await _collect_instagram_ssr_usernames(page, ig_feed_usernames)
    init_raw, _ = _drain()

    # ホームフィードが Instagram 側の一時エラー (500 / エラー画面) で空の場合、?variant=following へ自動フォールバック
    if init_raw == 0:
        try:
            body_text = await page.inner_text("body")
        except Exception:
            body_text = ""
        has_feed_error = any(
            msg in body_text
            for msg in ("エラーが発生しました", "ページを読み込めませんでした", "Something went wrong", "Couldn't load")
        )
        if has_feed_error and "variant=following" not in page.url:
            print("⚠️ Instagram home feed returned an error page. Falling back to Following feed (?variant=following)...")
            ig_feed_usernames.clear()
            try:
                await page.goto("https://www.instagram.com/?variant=following", wait_until="domcontentloaded", timeout=45000)
                await page.wait_for_timeout(4000)
                await _collect_instagram_ssr_usernames(page, ig_feed_usernames)
                _drain()
            except Exception as e:
                print(f"⚠️ Following feed fallback warning: {e}")

    stalls = 0
    MAX_STALLS = 3
    for scroll_idx in range(1, scroll_batch_size + 1):
        prev_scroll_y = await page.evaluate("window.scrollY")
        prev_scroll_h = await page.evaluate("document.body.scrollHeight")
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await asyncio.sleep(2.5)
        curr_scroll_y = await page.evaluate("window.scrollY")
        curr_scroll_h = await page.evaluate("document.body.scrollHeight")
        raw_seen, _ = _drain()

        if curr_scroll_y == prev_scroll_y and curr_scroll_h == prev_scroll_h and raw_seen == 0:
            stalls += 1
            if stalls >= MAX_STALLS:
                print(f"⏳ Cannot scroll Instagram feed further at scroll {scroll_idx}/{scroll_batch_size} (after {MAX_STALLS} stalls).")
                break
        else:
            stalls = 0

    return batch_accounts


async def collect_tiktok_batch_posts(page, tt_feed_posts, scroll_batch_size=10, target_posts=30):
    """
    TikTok For You / Following タイムライン API (/api/recommend/item_list/) から
    動画・フォトモード投稿本体を直接一括収集する。
    ※ヘッドレス環境ではプロフィール一覧API (/api/post/item_list/) が空レスポンス(0 bytes)を返す制限があるため、
      For You ストリームで取得済みのフルメディアデータをそのまま Gist 投入する。
    """
    collected = {}

    def _drain():
        raw_seen = 0
        while tt_feed_posts:
            raw_seen += 1
            post = tt_feed_posts.pop(0)
            pid = str(post.get("id") or "")
            if pid and pid not in collected:
                collected[pid] = post
                print(
                    f"  🎯 Collected TikTok post: {pid} (@{post.get('username', '')}) "
                    f"[{len(collected)}/{target_posts}]"
                )
        return raw_seen

    _drain()

    stalls = 0
    MAX_STALLS = 6
    for scroll_idx in range(1, scroll_batch_size + 1):
        if len(collected) >= target_posts:
            break
        await advance_tiktok_feed(page, steps=5)
        await asyncio.sleep(2.0)
        raw_seen = _drain()
        if raw_seen == 0:
            stalls += 1
            if stalls >= MAX_STALLS:
                print(f"⏳ No new TikTok feed items at step {scroll_idx}/{scroll_batch_size} (after {MAX_STALLS} stalls).")
                break
        else:
            stalls = 0

    return list(collected.values())[:target_posts]


def ingest_tiktok_batch_posts(gist_id, posts):
    """収集した TikTok 投稿群を tiktok_tweets.js へ書き出し、append_to_gist.py (--skip-extract) で一括反映する"""
    archive_items = []
    for p in posts:
        item = tt_to_archive_tweet_format(p)
        if item:
            archive_items.append(item)
    if not archive_items:
        return 0

    tt_write_tweets_output(archive_items, TIKTOK_OUTPUT_FILE)
    python_bin = sys.executable
    append_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "append_to_gist.py")
    cmd = [
        python_bin, append_script,
        "--platform", "tiktok",
        "--skip-extract",
        "--is-candidate",
        "-g", gist_id,
    ]
    print(f"\n📦 Ingesting {len(archive_items)} TikTok For You posts into Gist...")
    res = subprocess.run(cmd)
    return res.returncode


async def run_expansion_loop(args, gist_id):
    platform = getattr(args, "platform", "x") or "x"
    if platform == "instagram":
        auth_path = IG_AUTH_PATH
    elif platform == "tiktok":
        auth_path = TIKTOK_AUTH_PATH
    else:
        auth_path = AUTH_PATH
    if not os.path.exists(auth_path):
        print(f"❌ Error: Auth credentials not found at {auth_path}")
        sys.exit(1)

    print(f"🚀 Launching browser for timeline candidate expansion loop (platform={platform})...")
    current_user_gists = fetch_master_user_gists(gist_id)
    existing_users_lower = {k.lower(): k for k in current_user_gists.keys()}
    candidate_users_lower = {
        k.lower() for k, v in current_user_gists.items()
        if isinstance(v, dict) and v.get("is_candidate") is True
    }
    processed_accounts_lower = set(candidate_users_lower)

    cycle = 0
    total_processed = 0

    async with async_playwright() as p:
        launch_kwargs = {"headless": not args.no_headless}
        ctx_kwargs = {
            "storage_state": auth_path,
            "viewport": {"width": 1280, "height": 900},
        }
        if platform == "tiktok":
            launch_kwargs["args"] = [
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-setuid-sandbox",
            ]
            ctx_kwargs["user_agent"] = TIKTOK_USER_AGENT
        browser = await p.chromium.launch(**launch_kwargs)
        context = await browser.new_context(**ctx_kwargs)
        if platform == "tiktok":
            await enable_tt_resource_blocking(context)
        page = await context.new_page()

        ig_feed_usernames = []
        tt_feed_posts = []
        response_handler = None
        if platform == "instagram":
            async def _on_ig_response(response):
                r_url = response.url
                if "instagram.com" not in r_url or response.status != 200:
                    return
                if not any(tok in r_url for tok in ("/api/v1/", "/graphql/query", "/api/graphql")):
                    return
                try:
                    raw = await response.text()
                except Exception:
                    return
                cleaned = re.sub(r"^\s*for\s*\(\s*;\s*;\s*\)\s*;", "", raw).strip()
                payloads = []
                try:
                    payloads.append(json.loads(cleaned))
                except Exception:
                    for line in cleaned.splitlines():
                        line = line.strip()
                        if line:
                            try:
                                payloads.append(json.loads(line))
                            except Exception:
                                pass
                for pl in payloads:
                    for post in extract_ig_posts_from_payload(pl, source="api_graphql"):
                        if post.get("username"):
                            ig_feed_usernames.append(post["username"])

            response_handler = _on_ig_response
            page.on("response", response_handler)
        elif platform == "tiktok":
            tt_mode = "following" if "/following" in args.timeline_url else "foryou"

            async def _on_tt_response(response):
                r_url = response.url
                if response.status != 200 or not is_allowed_tiktok_api_url(r_url, source_mode=tt_mode):
                    return
                try:
                    pl = await response.json()
                except Exception:
                    return
                for post in extract_tt_items_from_payload(pl, source="api_tiktok"):
                    if post.get("username"):
                        tt_feed_posts.append(post)

            response_handler = _on_tt_response
            page.on("response", response_handler)

        try:
            while True:
                cycle += 1
                print("\n==================================================")
                print(f"🔄 Starting Cycle {cycle}: Loading / Reloading Timeline ({platform})")
                print(f"  URL: {args.timeline_url}")
                print(f"  Scroll Batch Size: {args.scroll_batch_size} scrolls")
                print(f"  Total Processed so far: {total_processed}")
                print("==================================================")

                # 3. ホーム画面のリロード（初回は通常遷移）
                ig_feed_usernames.clear()
                tt_feed_posts.clear()
                try:
                    await page.goto(args.timeline_url, wait_until="domcontentloaded", timeout=45000)
                    await page.wait_for_timeout(4000)
                except Exception as e:
                    print(f"⚠️ Page load warning: {e}")

                # --- TikTok: For You タイムラインから取得済みのフル投稿を直接一括投入 ---
                if platform == "tiktok":
                    print(f"\n📜 [Cycle {cycle}] Collecting TikTok timeline posts (target={args.num}, steps={args.scroll_batch_size})...")
                    tt_posts = await collect_tiktok_batch_posts(
                        page,
                        tt_feed_posts,
                        scroll_batch_size=args.scroll_batch_size,
                        target_posts=args.num,
                    )
                    # Gist 反映中に裏側で不要な通信・route コールバックが滞留するのを防ぐためページを停止
                    try:
                        await page.goto("about:blank", wait_until="commit", timeout=5000)
                    except Exception:
                        pass
                    unique_creators = {p["username"].lower() for p in tt_posts if p.get("username")}
                    print(f"📋 [Cycle {cycle}] Collected {len(tt_posts)} TikTok posts across {len(unique_creators)} creators.")
                    if tt_posts:
                        ret_code = await asyncio.to_thread(ingest_tiktok_batch_posts, gist_id, tt_posts)
                        if ret_code == 0:
                            total_processed += len(unique_creators)
                    else:
                        print(f"ℹ️ No TikTok posts found in this {args.scroll_batch_size}-step batch.")

                    if args.max_cycles and cycle >= args.max_cycles:
                        print(f"🏁 Reached maximum requested cycles ({args.max_cycles}). Stopping loop.")
                        break
                    print(f"\n✅ [Cycle {cycle}] Completed TikTok timeline ingestion. Reloading in 3 seconds...")
                    await asyncio.sleep(3)
                    continue

                # 1. スクロールでアカウント収集（X / Instagram）
                print(f"\n📜 [Cycle {cycle}] Collecting accounts ({args.scroll_batch_size} scrolls limit)...")
                if platform == "instagram":
                    batch_accounts = await collect_instagram_batch_accounts(
                        page,
                        ig_feed_usernames,
                        scroll_batch_size=args.scroll_batch_size,
                        excluded_accounts_lower=processed_accounts_lower,
                    )
                else:
                    batch_accounts = await collect_batch_accounts(
                        page,
                        scroll_batch_size=args.scroll_batch_size,
                        excluded_accounts_lower=processed_accounts_lower,
                    )

                print(f"📋 [Cycle {cycle}] Discovered {len(batch_accounts)} new accounts in this batch.")

                # 2. 収集したアカウントの画像取得
                if batch_accounts:
                    for idx, account in enumerate(batch_accounts, start=1):
                        acc_lower = account.lower()
                        processed_accounts_lower.add(acc_lower)

                        # すでに Candidate 扱いのアカウントは取得をスキップ
                        if acc_lower in candidate_users_lower:
                            print(f"\n⏭️ Skipping @{account}: Already registered in Candidate gallery.")
                            continue

                        is_existing = acc_lower in existing_users_lower
                        fetch_num = args.num_existing if is_existing else args.num
                        print(f"\n--- [Cycle {cycle} | Account {idx}/{len(batch_accounts)}] @{account} (Existing: {is_existing}, Fetch Count: {fetch_num}) ---")
                        ret_code = await asyncio.to_thread(process_account, gist_id, account, fetch_num, is_existing, platform)

                        # レート制限 (code 42) 検知時の自動待機＆リトライ
                        if ret_code == 42:
                            wait_mins = round(args.rate_limit_wait / 60, 1)
                            print(f"\n🚨 Rate limit detected from {platform} (exit code 42) while processing @{account}.")
                            print(f"⏳ Pausing for {args.rate_limit_wait}s (~{wait_mins} min) until rate limit resets...")
                            await asyncio.sleep(args.rate_limit_wait)
                            print(f"🔄 Retrying @{account} after cooldown...")
                            ret_code = await asyncio.to_thread(process_account, gist_id, account, fetch_num, is_existing, platform)

                        if ret_code == 0:
                            total_processed += 1
                            if not is_existing:
                                existing_users_lower[acc_lower] = account
                                candidate_users_lower.add(acc_lower)

                        # 連続アクセスによるレートリミットを予防するためのクールダウン
                        if args.account_cooldown > 0:
                            await asyncio.sleep(args.account_cooldown)

                        if args.max_total_accounts and total_processed >= args.max_total_accounts:
                            print(f"🛑 Reached maximum total accounts limit ({args.max_total_accounts}).")
                            break
                else:
                    print(f"ℹ️ No new accounts found in this {args.scroll_batch_size}-scroll batch.")

                if args.max_total_accounts and total_processed >= args.max_total_accounts:
                    break

                if args.max_cycles and cycle >= args.max_cycles:
                    print(f"🏁 Reached maximum requested cycles ({args.max_cycles}). Stopping loop.")
                    break

                print(f"\n✅ [Cycle {cycle}] Completed image fetching. Reloading timeline for next cycle in 3 seconds...")
                await asyncio.sleep(3)
        finally:
            if response_handler is not None:
                try:
                    page.remove_listener("response", response_handler)
                except Exception:
                    pass
            try:
                await context.unroute_all(behavior="ignoreErrors")
            except Exception:
                pass
            for closable in (page, context, browser):
                try:
                    await closable.close()
                except Exception:
                    pass

    print("\n==================================================")
    print("Timeline Expansion Loop Finished")
    print(f"  Total Cycles Completed : {cycle}")
    print(f"  Total Accounts Handled : {total_processed}")
    print("==================================================")

def main():
    args = parse_args()
    gist_id = args.gist_id or load_master_gist_id()
    if not gist_id:
        print("❌ Error: Master Gist ID is required. Pass via -g or set MASTER_GIST_ID.")
        sys.exit(1)

    print("==================================================")
    print("Timeline Candidate Account Extractor & Expander")
    print(f"  Master Gist ID     : {gist_id}")
    print(f"  Per Account Num    : {args.num}")
    print(f"  Scroll Batch Size  : {args.scroll_batch_size}")
    print(f"  Timeline URL       : {args.timeline_url}")
    print("==================================================")

    asyncio.run(run_expansion_loop(args, gist_id))

if __name__ == "__main__":
    main()
