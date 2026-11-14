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

import asyncio
import json
import os
import sys
import argparse
import subprocess
from playwright.async_api import async_playwright

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from extract_media import AUTH_PATH, DATA_DIR, dismiss_modals

EXTRACT_ACCOUNTS_JS = """() => {
    const articles = document.querySelectorAll('article');
    const accounts = [];
    const adKeywords = ['広告', 'ad', 'sponsored', 'プロモーション'];

    articles.forEach(article => {
        // 1. 広告の除外チェック
        if (article.querySelector('[data-testid="placementTracking"]')) return;

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
    """マスターGistから現在の user_gists を取得して返す"""
    if not gist_id:
        return {}
    candidate_files = ["data.json", "gallary_data.json"]
    for fn in candidate_files:
        try:
            res = subprocess.run(
                ["gh", "gist", "view", gist_id, "-f", fn],
                capture_output=True, text=True, check=True
            )
            data = json.loads(res.stdout.strip())
            if isinstance(data, dict) and "user_gists" in data:
                return data["user_gists"]
        except Exception:
            continue
    return {}

def parse_args():
    parser = argparse.ArgumentParser(description="Timeline Candidate Account Collector")
    parser.add_argument("-g", "--gist-id", default=None, help="Master Gist ID (defaults to MASTER_GIST_ID env)")
    parser.add_argument("-n", "--num", type=int, default=300, help="Number of tweets to fetch per account (default: 300)")
    parser.add_argument("--timeline-url", default="https://x.com/home", help="Timeline URL to scrape")
    parser.add_argument("--scroll-batch-size", type=int, default=10, help="Number of scrolls per collection batch (default: 10)")
    parser.add_argument("--max-cycles", type=int, default=None, help="Maximum number of reload-and-collect cycles (default: unlimited)")
    parser.add_argument("--max-total-accounts", type=int, default=None, help="Max total accounts to process")
    parser.add_argument("--no-headless", action="store_true", help="Run browser in headful mode")
    return parser.parse_args()

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

def process_account(gist_id, username, num, is_existing):
    """
    既存/新規アカウントに応じて append_to_gist.py を呼び出す。
    - 既存アカウント: --stop-on-existing (既存ギャラリー所属維持)
    - 新規アカウント: --is-candidate (Candidateギャラリー登録)
    """
    python_bin = sys.executable
    append_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "append_to_gist.py")

    cmd = [python_bin, append_script, "-g", gist_id, "-u", username, "-n", str(num)]
    if is_existing:
        print(f"\n📂 Processing EXISTING account: @{username} (Stop on existing: Yes, Keep Gallery: Yes)")
        cmd.append("-s")
    else:
        print(f"\n✨ Processing NEW account: @{username} (Candidate Gallery: Yes)")
        cmd.append("--is-candidate")

    res = subprocess.run(cmd)
    return res.returncode == 0

async def run_expansion_loop(args, gist_id):
    if not os.path.exists(AUTH_PATH):
        print(f"❌ Error: Auth credentials not found at {AUTH_PATH}")
        sys.exit(1)

    print(f"🚀 Launching browser for timeline candidate expansion loop...")
    current_user_gists = fetch_master_user_gists(gist_id)
    existing_users_lower = {k.lower(): k for k in current_user_gists.keys()}
    processed_accounts_lower = set()

    cycle = 0
    total_processed = 0

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=not args.no_headless)
        context = await browser.new_context(
            storage_state=AUTH_PATH,
            viewport={"width": 1280, "height": 900},
        )
        page = await context.new_page()

        while True:
            cycle += 1
            print("\n==================================================")
            print(f"🔄 Starting Cycle {cycle}: Loading / Reloading Timeline")
            print(f"  URL: {args.timeline_url}")
            print(f"  Scroll Batch Size: {args.scroll_batch_size} scrolls")
            print(f"  Total Processed so far: {total_processed}")
            print("==================================================")

            # 3. ホーム画面のリロード（初回は通常遷移）
            try:
                await page.goto(args.timeline_url, wait_until="domcontentloaded", timeout=45000)
                await page.wait_for_timeout(4000)
            except Exception as e:
                print(f"⚠️ Page load warning: {e}")

            # 1. 10スクロールでアカウント収集
            print(f"\n📜 [Cycle {cycle}] Collecting accounts (10 scrolls limit)...")
            batch_accounts = await collect_batch_accounts(
                page,
                scroll_batch_size=args.scroll_batch_size,
                excluded_accounts_lower=processed_accounts_lower,
            )

            print(f"📋 [Cycle {cycle}] Discovered {len(batch_accounts)} new accounts in this batch.")

            # 2. 収集したアカウントの画像取得（最新300ポスト）
            if batch_accounts:
                for idx, account in enumerate(batch_accounts, start=1):
                    acc_lower = account.lower()
                    processed_accounts_lower.add(acc_lower)

                    is_existing = acc_lower in existing_users_lower
                    print(f"\n--- [Cycle {cycle} | Account {idx}/{len(batch_accounts)}] @{account} (Existing: {is_existing}) ---")
                    ok = process_account(gist_id, account, args.num, is_existing)
                    if ok:
                        total_processed += 1
                        if not is_existing:
                            existing_users_lower[acc_lower] = account

                    if args.max_total_accounts and total_processed >= args.max_total_accounts:
                        print(f"🛑 Reached maximum total accounts limit ({args.max_total_accounts}).")
                        break
            else:
                print("ℹ️ No new accounts found in this 10-scroll batch.")

            if args.max_total_accounts and total_processed >= args.max_total_accounts:
                break

            if args.max_cycles and cycle >= args.max_cycles:
                print(f"🏁 Reached maximum requested cycles ({args.max_cycles}). Stopping loop.")
                break

            print(f"\n✅ [Cycle {cycle}] Completed image fetching. Reloading timeline for next cycle in 3 seconds...")
            await asyncio.sleep(3)

        await browser.close()

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
