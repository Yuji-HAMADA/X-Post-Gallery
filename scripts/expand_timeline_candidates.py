#!/usr/bin/env python3
"""
タイムライン上のポストからXアカウントを自動収集し、ギャラリーを拡張するスクリプト。

【仕様】
1. 自分のタイムライン（https://x.com/home）にアクセスし、流れているポストからアカウントを抽出。
2. タイムライン上およびポスト内の広告（Ad）は完全に除外。
3. タイムラインがこれ以上スクロールできなくなった時点でタイムライン走査を終了。
4. 抽出された各アカウントについて最新300件のポストを取得:
   - 既存アカウントの場合: --stop-on-existing で読み込み、既存ギャラリー（Favorite/User）を維持。
   - 新規アカウントの場合: --is-candidate で読み込み、「Candidate」ギャラリーに新規登録。
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
    parser.add_argument("--max-accounts", type=int, default=None, help="Max accounts to process")
    parser.add_argument("--no-headless", action="store_true", help="Run browser in headful mode")
    return parser.parse_args()

async def collect_accounts_from_timeline(timeline_url, max_accounts=None, headless=True):
    """タイムラインをスクロールしてアカウント一覧を収集（広告ポスト除外、終了条件判定付き）"""
    if not os.path.exists(AUTH_PATH):
        print(f"❌ Error: Auth credentials not found at {AUTH_PATH}")
        sys.exit(1)

    print(f"🚀 Launching browser to collect accounts from: {timeline_url}")
    seen_accounts = []
    seen_set = set()
    no_change_count = 0
    max_no_change = 5

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=headless)
        context = await browser.new_context(
            storage_state=AUTH_PATH,
            viewport={"width": 1280, "height": 900},
        )
        page = await context.new_page()

        try:
            await page.goto(timeline_url, wait_until="domcontentloaded", timeout=45000)
            await page.wait_for_timeout(5000)
        except Exception as e:
            print(f"⚠️ Initial page load warning: {e}")

        while True:
            await dismiss_modals(page)

            # 広告を除外してアカウント一覧を抽出
            try:
                extracted_batch = await page.evaluate(EXTRACT_ACCOUNTS_JS)
            except Exception as e:
                print(f"⚠️ Extraction evaluate warning: {e}")
                extracted_batch = []

            new_in_batch = 0
            for acc in extracted_batch:
                acc_clean = acc.strip().lstrip("@")
                acc_lower = acc_clean.lower()
                if acc_clean and acc_lower not in seen_set:
                    seen_set.add(acc_lower)
                    seen_accounts.append(acc_clean)
                    new_in_batch += 1
                    print(f"  🎯 Found account from timeline: @{acc_clean} (Total unique: {len(seen_accounts)})")
                    if max_accounts and len(seen_accounts) >= max_accounts:
                        break

            if max_accounts and len(seen_accounts) >= max_accounts:
                print(f"🛑 Reached requested maximum accounts limit: {max_accounts}")
                break

            # スクロールと終了判定
            prev_scroll_y = await page.evaluate("window.scrollY")
            await page.mouse.wheel(0, 2000)
            await asyncio.sleep(2.5)
            curr_scroll_y = await page.evaluate("window.scrollY")

            # 終了条件: これ以上スクロールできない、または新規アカウントが見つからない
            if curr_scroll_y == prev_scroll_y and new_in_batch == 0:
                no_change_count += 1
                print(f"⏳ Scroll down limit reached or no new items (check {no_change_count}/{max_no_change})...")
                if no_change_count >= max_no_change:
                    print("🏁 Reached end of timeline. Stopping account collection.")
                    break
            else:
                no_change_count = 0

        await browser.close()

    return seen_accounts

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

def main():
    args = parse_args()
    gist_id = args.gist_id or load_master_gist_id()
    if not gist_id:
        print("❌ Error: Master Gist ID is required. Pass via -g or set MASTER_GIST_ID.")
        sys.exit(1)

    print("==================================================")
    print("Timeline Candidate Account Extractor & Expander")
    print(f"  Master Gist ID : {gist_id}")
    print(f"  Per Account Num: {args.num}")
    print(f"  Timeline URL   : {args.timeline_url}")
    print("==================================================")

    # 1. タイムラインからアカウント一覧を収集
    accounts = asyncio.run(
        collect_accounts_from_timeline(
            args.timeline_url,
            max_accounts=args.max_accounts,
            headless=not args.no_headless,
        )
    )

    if not accounts:
        print("ℹ️ No accounts discovered from timeline.")
        sys.exit(0)

    print(f"\n📋 Discovered {len(accounts)} accounts from timeline. Fetching master Gist status...")
    current_user_gists = fetch_master_user_gists(gist_id)
    existing_users_lower = {k.lower(): k for k in current_user_gists.keys()}

    # 2. アカウントごとに読み込み＆Gist登録を実行
    success_count = 0
    new_candidate_count = 0
    existing_count = 0

    for idx, account in enumerate(accounts, start=1):
        is_existing = account.lower() in existing_users_lower
        print(f"\n--- [{idx}/{len(accounts)}] @{account} (Existing: {is_existing}) ---")
        ok = process_account(gist_id, account, args.num, is_existing)
        if ok:
            success_count += 1
            if is_existing:
                existing_count += 1
            else:
                new_candidate_count += 1
                existing_users_lower[account.lower()] = account

    print("\n==================================================")
    print("Timeline Expansion Summary")
    print(f"  Total Accounts Found : {len(accounts)}")
    print(f"  Successfully Processed: {success_count}")
    print(f"  Existing Users Updated: {existing_count}")
    print(f"  New Candidates Added  : {new_candidate_count}")
    print("==================================================")

if __name__ == "__main__":
    main()
