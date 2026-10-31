import asyncio
import json
import os
import re
import sys
import argparse
from urllib.parse import quote
from playwright.async_api import async_playwright

# --- 設定・定数 ---
DATA_DIR = "data"
OUTPUT_FILE = os.path.join(DATA_DIR, "tweets.js")
AUTH_PATH = os.path.join(DATA_DIR, "auth.json")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--num", type=int, default=100)
    parser.add_argument("-u", "--user", type=str, default=None, help="Target user ID (--user または --hashtag のどちらか必須)")
    parser.add_argument("--hashtag", type=str, default=None, help="Target hashtag (#なし)")
    parser.add_argument("--mode", type=str, default="post_only", help="(deprecated, ignored: always post_only)")
    parser.add_argument("--skip-ids-file", type=str, default=None, help="File with IDs to skip (one per line)")
    parser.add_argument("--stop-on-existing", action="store_true", help="Stop when hitting a known ID (for user-specific append)")
    return parser.parse_args()

def build_url(user, hashtag, mode):
    if hashtag:
        # キーワード検索: Latestタブ使用（メディアはコード側でフィルタ）
        quoted = f'"{hashtag}"'
        return f"https://x.com/search?q={quote(quoted)}&f=live"
    else:
        # ユーザーはPostsタブを使用（article要素あり、画像なし・リポストはコード側でフィルター）
        return f"https://x.com/{user}"

async def extract_tweet_data(article):
    """1つのarticle要素からツイート情報を抽出するロジック"""
    # ステータスIDとユーザー名の取得
    links = await article.query_selector_all('a[href*="/status/"]')
    origin_user, origin_status_id = "unknown", ""
    for link in links:
        href = await link.get_attribute('href')
        match = re.search(r'/([^/]+)/status/(\d+)', href)
        if match:
            origin_user, origin_status_id = match.group(1), match.group(2)
            break
    
    if not origin_status_id: return None

    # テキストとリポスト判定（リポストは除外）
    inner_text = await article.inner_text()
    is_repost = any(w in inner_text for w in ["リポスト", "Reposted", "reposted"])
    if is_repost: return None

    # 固定ツイート（Pinned Tweet）判定（言語・UI構造差異に対応）
    social_context = await article.query_selector('[data-testid="socialContext"]')
    social_text = (await social_context.inner_text()).strip() if social_context else ""
    pinned_keywords = [
        "固定されたポスト", "固定されたツイート", "固定ツイート",
        "ピン留めされたポスト", "ピン留め",
        "Pinned", "Pinned Tweet", "Pinned Post", "Pinned post"
    ]
    is_pinned = (
        any(w in inner_text for w in pinned_keywords) or
        any(w in social_text for w in pinned_keywords)
    )
    if not is_pinned and social_context:
        sc_html = (await social_context.inner_html()).lower()
        if "pin" in sc_html or any(w in social_text for w in ["固定", "ピン"]):
            is_pinned = True

    tweet_text_el = await article.query_selector('[data-testid="tweetText"]')
    raw_text = await tweet_text_el.inner_text() if tweet_text_el else ""
    full_text = f"@{origin_user}: {raw_text}"

    # メディア抽出
    images = await article.query_selector_all('[data-testid="tweetPhoto"] img')
    media_urls = []
    for img in images:
        # 引用ツイート内などは除外
        is_excluded = await img.evaluate("""(node) => {
            return !!node.closest('[data-testid="quotedTweet"]') || 
                   !!node.closest('[data-testid="placementTracking"]');
        }""")
        src = await img.get_attribute('src')
        if is_excluded or not src or any(sz in src for sz in ["name=120x120", "name=240x240"]):
            continue
        
        src = src.split('&name=')[0]
        media_urls.append({
            "media_url_https": src,
            "type": "photo",
            "expanded_url": f"https://x.com/{origin_user}/status/{origin_status_id}/photo/1"
        })

    if not media_urls: return None

    # 時間
    time_el = await article.query_selector('time')
    timestamp = await time_el.get_attribute('datetime') if time_el else ""

    return {
        "tweet": {
            "id_str": origin_status_id,
            "full_text": full_text,
            "created_at": timestamp,
            "entities": {"media": media_urls},
            "extended_entities": {"media": media_urls}
        },
        "is_pinned": is_pinned
    }

async def dismiss_modals(page):
    """ログインダイアログ、センシティブ警告、シートダイアログ等を自動解除する"""
    try:
        # 1. センシティブ警告・プロファイル閲覧確認ボタンの自動クリック
        sensitive_btn_texts = ["プロフィールを表示", "表示する", "表示", "View profile", "Yes, view profile"]
        for txt in sensitive_btn_texts:
            btn = await page.query_selector(f'div[role="button"]:has-text("{txt}"), button:has-text("{txt}")')
            if btn:
                try:
                    await btn.click()
                    print(f"🔓 Dismissed profile warning banner: '{txt}'")
                    await asyncio.sleep(1)
                    break
                except Exception:
                    pass

        # 2. 閉じるボタンのクリック（ダイアログの「×」）
        close_btn = await page.query_selector('div[role="dialog"] [aria-label="閉じる"], div[role="dialog"] [aria-label="Close"], [data-testid="app-bar-close"]')
        if close_btn:
            try:
                await close_btn.click()
                print("🔓 Clicked dialog close button.")
                await asyncio.sleep(0.5)
            except Exception:
                pass

        # 3. Escape キー送信
        await page.keyboard.press("Escape")

        # 4. ログインオーバーレイ等の除去とスクロールロック解除
        await page.evaluate("""() => {
            const selectors = ['[data-testid="sheetDialog"]', '[data-testid="mask"]', 'div[role="dialog"]'];
            selectors.forEach(sel => {
                document.querySelectorAll(sel).forEach(el => {
                    const text = el.innerText || "";
                    if (text.includes("ログイン") || text.includes("Log in") || text.includes("Sign in") || text.includes("アカウントを作成")) {
                        el.remove();
                    }
                });
            });
            document.body.style.overflow = "auto";
        }""")
    except Exception:
        pass

async def diagnose_empty_state(page, seen_ids_count, skipped_count):
    """0件終了時にページ状態を解析し、明確な原因を出力する"""
    print("\n🔍 Diagnosing reason for 0 saved tweets:")
    try:
        body_text = await page.inner_text("body")
    except Exception:
        body_text = ""

    # 1. ログイン壁
    has_login_button = await page.query_selector('[data-testid="loginButton"]') is not None
    has_account_switcher = await page.query_selector('[data-testid="SideNav_AccountSwitcher_Button"]') is not None
    login_phrases = ["ログインして続行", "Log in to X", "Sign in to X", "アカウントを作成", "Create account", "いまどうしてる？"]
    if has_login_button and not has_account_switcher and any(lp in body_text for lp in login_phrases):
        print("  ❌ Cause: Login wall detected. Session in auth.json may be expired, logged out, or restricted.")
        return

    # 2. アカウント状態
    if any(m in body_text for m in ["このアカウントは存在しません", "This account doesn’t exist", "This account does not exist"]):
        print("  ❌ Cause: Account does not exist.")
        return
    if any(m in body_text for m in ["アカウントは凍結されています", "Account suspended"]):
        print("  ❌ Cause: Account is suspended.")
        return
    if any(m in body_text for m in ["ポストは非公開です", "These posts are protected"]):
        print("  ❌ Cause: Account is private / protected.")
        return
    if any(m in body_text for m in ["ブロックされています", "You are blocked"]):
        print("  ❌ Cause: Blocked by target user.")
        return

    # 3. センシティブ警告ブロック
    if any(m in body_text for m in ["センシティブな内容", "Potentially sensitive content", "プロフィールを表示"]):
        print("  ❌ Cause: Profile warning / sensitive content banner blocked timeline rendering.")
        return

    # 4. 投稿なし
    if any(m in body_text for m in ["まだポストはありません", "No posts yet", "ポストはまだありません"]):
        print("  ❌ Cause: User has no posts on this timeline.")
        return

    # 5. スキップによる0件（全て既存ID）
    if skipped_count > 0:
        print(f"  ℹ️ Cause: All {skipped_count} parsed posts were already known (in skip_ids).")
        return

    # 6. DOM / レンダリング失敗
    if seen_ids_count == 0:
        print("  ❌ Cause: Timeline articles failed to load into DOM (DOM timeout or blocked by overlay).")
    else:
        print(f"  ℹ️ Cause: Found {seen_ids_count} posts, but none contained valid media images (text-only or filtered).")

async def run():
    args = parse_args()
    if not args.user and not args.hashtag:
        print("❌ Error: --user または --hashtag のどちらかが必要です。"); return
    if not os.path.exists(AUTH_PATH):
        print(f"❌ Error: {AUTH_PATH} not found."); return

    os.makedirs(DATA_DIR, exist_ok=True)
    mode = "post_only"  # 固定
    url = build_url(args.user, args.hashtag, mode)
    target_label = f"#{args.hashtag}" if args.hashtag else f"@{args.user}"
    print(f"🚀 Mode: {mode} | Target: {target_label} | URL: {url}")

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(storage_state=AUTH_PATH)
        page = await context.new_page()

        rate_limit_hit = False

        async def handle_response(response):
            nonlocal rate_limit_hit
            if response.status == 429:
                rate_limit_hit = True

        page.on("response", handle_response)
        
        TWEET_SELECTOR = 'article, [data-testid="tweet"]'

        await page.goto(url, wait_until="domcontentloaded")
        await dismiss_modals(page)
        try:
            await page.wait_for_selector(TWEET_SELECTOR, timeout=12000)
        except Exception:
            await dismiss_modals(page)
            try:
                await page.wait_for_selector(TWEET_SELECTOR, timeout=5000)
            except Exception:
                await page.wait_for_timeout(2000)
        await asyncio.sleep(2)
        await dismiss_modals(page)

        # ページ全体のテキストからレート制限をチェック
        try:
            body_text = await page.inner_text("body")
            if any(msg in body_text for msg in ["Rate limit exceeded", "レート制限", "レート制限を超えました"]):
                rate_limit_hit = True
        except Exception:
            pass

        # 既知IDの読み込み（スキップ対象）
        skip_ids = set()
        # 順序付きID→インデックスマップ（連続一致判定用）
        gist_id_index = {}
        if args.skip_ids_file and os.path.exists(args.skip_ids_file):
            with open(args.skip_ids_file, 'r') as f:
                ordered_ids = [line.strip() for line in f if line.strip()]
            skip_ids = set(ordered_ids)
            gist_id_index = {tid: i for i, tid in enumerate(ordered_ids)}
            print(f"⏭️ Skipping {len(skip_ids)} known IDs.")

        CONSECUTIVE_STOP = 5  # 連続一致でストップする閾値
        MIN_SCROLLS_FOR_STOP = 3  # 通常ツイートを十分に確認するため停止判定前に最低限必要なスクロール回数
        new_tweets, seen_ids = [], set()
        stall_count = 0
        scroll_count = 0
        MAX_STALLS = 5
        skipped_count = 0
        hit_existing = False
        consecutive_count = 0
        last_gist_index = -1

        while len(new_tweets) < args.num and not hit_existing and not rate_limit_hit:
            articles = await page.query_selector_all('article')
            if not articles:
                articles = await page.query_selector_all('[data-testid="tweet"]')
            prev_seen = len(seen_ids)
            for article in articles:
                data = await extract_tweet_data(article)
                if not data: continue

                tid = data["tweet"]["id_str"]
                if tid in seen_ids: continue
                seen_ids.add(tid)

                is_pinned = data.get("is_pinned", False)

                # 固定ツイート（Pinned）は重複停止カウント（stop_on_existing）から明確に除外・スキップ
                if is_pinned:
                    if tid in skip_ids:
                        skipped_count += 1
                    else:
                        new_tweets.append(data)
                        print(f"  [{len(new_tweets)}] Saved (Pinned): @{tid}")
                    continue

                if tid in skip_ids:
                    # 通常ツイートの連続一致判定
                    if args.stop_on_existing and gist_id_index:
                        gist_idx = gist_id_index.get(tid, -1)
                        if gist_idx >= 0 and last_gist_index >= 0 and gist_idx == last_gist_index + 1:
                            consecutive_count += 1
                        else:
                            consecutive_count = 1
                        last_gist_index = gist_idx

                        # 固定ツイートより下の通常ツイートを確認し、数回スクロールした後に停止判定
                        if consecutive_count >= CONSECUTIVE_STOP and scroll_count >= MIN_SCROLLS_FOR_STOP:
                            print(f"🛑 {CONSECUTIVE_STOP} consecutive existing IDs matched in order (after {scroll_count} scrolls). Stopping.")
                            hit_existing = True
                            break
                    skipped_count += 1
                    continue

                # 新規通常ポスト → 連続カウントをリセット
                consecutive_count = 0
                last_gist_index = -1

                new_tweets.append(data)
                print(f"  [{len(new_tweets)}] Saved: @{tid}")

                if len(new_tweets) >= args.num:
                    break

            if consecutive_count >= CONSECUTIVE_STOP and scroll_count >= MIN_SCROLLS_FOR_STOP:
                hit_existing = True

            if len(new_tweets) >= args.num or hit_existing or rate_limit_hit: break

            # スクロールしても新しいarticleが出てこなければ終端
            if len(seen_ids) > prev_seen:
                stall_count = 0
            else:
                stall_count += 1
                if stall_count >= MAX_STALLS:
                    print(f"\n⚠️ No more posts found after {MAX_STALLS} scrolls. Stopping.")
                    break

            scroll_count += 1
            # 中央領域でマウスホイールおよびwindow.scrollByを併用して確実にスクロール
            try:
                await page.mouse.move(600, 500)
                await page.mouse.wheel(0, 2000)
                await page.evaluate("window.scrollBy(0, 2000)")
            except Exception:
                await page.mouse.wheel(0, 2000)
            await dismiss_modals(page)
            await asyncio.sleep(4)

        if skipped_count:
            print(f"⏭️ Skipped {skipped_count} already-known posts.")

        # レート制限検知時
        if rate_limit_hit:
            print("🚨 Rate limit detected from X! Exiting with code 42.")
            await browser.close()
            sys.exit(42)

        # 0件で終了した場合の原因診断とスクリーンショット保存
        if len(new_tweets) == 0:
            await diagnose_empty_state(page, len(seen_ids), skipped_count)
            debug_screen = os.path.join(DATA_DIR, "debug_screen.png")
            try:
                await page.screenshot(path=debug_screen, full_page=False)
                print(f"  📸 Debug screenshot saved to: {debug_screen}")
            except Exception:
                pass

        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            f.write("window.YTD.tweets.part0 = ")
            # 空リスト [] でも書き込むことで、Flutter側のエラーを防ぐ
            json.dump(new_tweets if new_tweets else [], f, ensure_ascii=False, indent=2)
        print(f"\n✅ Done: {len(new_tweets)} tweets saved.")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(run())