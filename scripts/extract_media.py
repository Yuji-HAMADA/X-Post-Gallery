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
    parser.add_argument("-n", "--num", type=int, default=500)
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
    # ステータスIDとユーザー名の取得（投稿自身のタイムスタンプリンクを最優先）
    origin_user, origin_status_id = "unknown", ""
    time_link = await article.query_selector('a:has(time)')
    if time_link:
        href = await time_link.get_attribute('href')
        if href:
            match = re.search(r'/([^/]+)/status/(\d+)', href)
            if match:
                origin_user, origin_status_id = match.group(1), match.group(2)

    # フォールバック: timeリンクがない場合は引用ツイート外のステータスリンクを探索
    if not origin_status_id:
        links = await article.query_selector_all('a[href*="/status/"]')
        for link in links:
            is_quoted = await link.evaluate("""(node) => {
                return !!node.closest('[data-testid="quotedTweet"]');
            }""")
            if is_quoted: continue
            href = await link.get_attribute('href')
            if not href: continue
            match = re.search(r'/([^/]+)/status/(\d+)', href)
            if match:
                origin_user, origin_status_id = match.group(1), match.group(2)
                break

    if not origin_status_id: return None

    # ソーシャルコンテキストの取得（リポスト判定・固定ツイート判定用）
    social_context = await article.query_selector('[data-testid="socialContext"]')
    social_text = (await social_context.inner_text()).strip() if social_context else ""

    # リポスト判定（本文の「リポスト」表記による誤爆を防ぐため socialContext のみで判定）
    is_repost = any(w in social_text for w in ["リポスト", "Reposted", "reposted"])
    if is_repost: return None

    # 固定ツイート（Pinned Tweet）判定（言語・UI構造差異に対応）
    pinned_keywords = [
        "固定されたポスト", "固定されたツイート", "固定ツイート",
        "ピン留めされたポスト", "ピン留め",
        "Pinned", "Pinned Tweet", "Pinned Post", "Pinned post"
    ]
    is_pinned = any(w in social_text for w in pinned_keywords)
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

        # 4. ログインオーバーレイ等の除去
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
        }""")
    except Exception:
        pass

async def check_account_status(page):
    """アカウントが存在しない、または凍結されているか、認証エラーかを早期チェック"""
    try:
        current_url = page.url
        body_text = (await page.inner_text("body")).strip()
        page_title = await page.title()
    except Exception:
        return None

    # 1. 認証エラー・セッション切れ
    if "/i/flow/login" in current_url or "login" in current_url.lower():
        return "auth_error"
    if "/account/access" in current_url:
        return "auth_error"

    has_login_button = await page.query_selector('[data-testid="loginButton"]') is not None
    has_account_switcher = await page.query_selector('[data-testid="SideNav_AccountSwitcher_Button"]') is not None
    login_phrases = ["ログインして続行", "Log in to X", "Sign in to X", "アカウントを作成", "Create account"]
    if has_login_button and not has_account_switcher and any(lp in body_text for lp in login_phrases):
        return "auth_error"

    # 2. アカウント不在・凍結
    dead_phrases = [
        "このアカウントは存在しません",
        "This account doesn’t exist",
        "This account does not exist",
        "該当するアカウントは見つかりませんでした",
        "アカウントは凍結されています",
        "Account suspended",
    ]
    for phrase in dead_phrases:
        if phrase in body_text or phrase in page_title:
            return "account_dead"

    return None

async def diagnose_empty_state(page, seen_ids_count, skipped_count, total_articles_detected):
    """0件終了時にページ状態を解析し、状態文字列を返す"""
    # 1. スキップ実績または走査実績がある場合は正常な0件終了（バーチャルスクロールによるDOM消去を考慮）
    if skipped_count > 0:
        print(f"  ℹ️ All {skipped_count} parsed posts were already known. No new tweets to save.")
        return "ok"

    if seen_ids_count > 0 or total_articles_detected > 0:
        print(f"  ℹ️ Found {seen_ids_count or total_articles_detected} posts, but none contained new valid media images.")
        return "ok"

    print("\n🔍 Diagnosing reason for 0 saved tweets:")
    current_url = page.url
    page_title = await page.title()
    print(f"  🌐 Current URL: {current_url}")
    print(f"  📄 Page Title: {page_title}")
    try:
        body_text = (await page.inner_text("body")).strip()
    except Exception:
        body_text = ""

    # ログイン画面リダイレクト
    if "/i/flow/login" in current_url or "login" in current_url.lower():
        print("  ❌ Cause: Redirected to login flow. Session in auth.json has expired or is blocked.")
        return "auth_error"

    # アカウントアクセス認証（CAPTCHA等）
    if "/account/access" in current_url:
        print("  ❌ Cause: Redirected to account access verification (CAPTCHA/Challenge).")
        return "auth_error"

    # 2. ログイン壁
    has_login_button = await page.query_selector('[data-testid="loginButton"]') is not None
    has_account_switcher = await page.query_selector('[data-testid="SideNav_AccountSwitcher_Button"]') is not None
    login_phrases = ["ログインして続行", "Log in to X", "Sign in to X", "アカウントを作成", "Create account", "いまどうしてる？"]
    if has_login_button and not has_account_switcher and any(lp in body_text for lp in login_phrases):
        print("  ❌ Cause: Login wall detected. Session in auth.json may be expired, logged out, or restricted.")
        return "auth_error"

    # 3. アカウント状態
    dead_phrases = [
        "このアカウントは存在しません",
        "This account doesn’t exist",
        "This account does not exist",
        "該当するアカウントは見つかりませんでした",
        "アカウントは凍結されています",
        "Account suspended",
    ]
    for m in dead_phrases:
        if m in body_text or m in page_title:
            print(f"  ❌ Cause: Account does not exist or is suspended ({m}).")
            return "account_dead"

    if any(m in body_text for m in ["ポストは非公開です", "These posts are protected"]):
        print("  ❌ Cause: Account is private / protected.")
        return "account_dead"
    if any(m in body_text for m in ["ブロックされています", "You are blocked"]):
        print("  ❌ Cause: Blocked by target user.")
        return "account_dead"

    # 4. センシティブ警告ブロック
    if any(m in body_text for m in ["センシティブな内容", "Potentially sensitive content", "プロフィールを表示"]):
        print("  ❌ Cause: Profile warning / sensitive content banner blocked timeline rendering.")
        return "error"

    # 5. 投稿なし
    if any(m in body_text for m in ["まだポストはありません", "No posts yet", "ポストはまだありません"]):
        print("  ❌ Cause: User has no posts on this timeline.")
        return "ok"

    # 6. DOM / レンダリング失敗（スクロール全体を通して一度も記事が現れなかった場合のみ）
    body_preview = body_text.replace('\n', ' ')[:200]
    print(f"  ❌ Cause: Timeline articles failed to load into DOM. Body snippet: {repr(body_preview)}")
    return "error"

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
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-setuid-sandbox",
            ]
        )
        context = await browser.new_context(
            storage_state=AUTH_PATH,
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            viewport={"width": 1280, "height": 900},
        )
        page = await context.new_page()

        # navigator.webdriver を隠蔽
        await page.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', {
                get: () => undefined
            });
        """)

        rate_limit_hit = False

        async def handle_response(response):
            nonlocal rate_limit_hit
            if response.status == 429:
                rate_limit_hit = True

        page.on("response", handle_response)
        
        TWEET_SELECTOR = 'article, [data-testid="tweet"]'

        await page.goto(url, wait_until="domcontentloaded")
        await dismiss_modals(page)

        # ユーザー指定時、早期にアカウント存在・凍結・認証チェック
        if args.user:
            early_status = await check_account_status(page)
            if early_status == "account_dead":
                print(f"❌ Account @{args.user} does not exist or is suspended. Exiting with code 44.")
                await browser.close()
                sys.exit(44)
            elif early_status == "auth_error":
                print("❌ Auth session error (login required). Exiting with code 41.")
                await browser.close()
                sys.exit(41)

        # タイムラインの初期記事が現れるまで待機
        articles_ready = False
        try:
            await page.wait_for_selector(TWEET_SELECTOR, timeout=15000)
            articles_ready = True
        except Exception:
            await dismiss_modals(page)
            try:
                await page.wait_for_selector(TWEET_SELECTOR, timeout=8000)
                articles_ready = True
            except Exception:
                pass

        # 初期タイムアウト時、アカウント状態を再確認
        if not articles_ready and args.user:
            status_check = await check_account_status(page)
            if status_check == "account_dead":
                print(f"❌ Account @{args.user} does not exist or is suspended. Exiting with code 44.")
                await browser.close()
                sys.exit(44)
            elif status_check == "auth_error":
                print("❌ Auth session error (login required). Exiting with code 41.")
                await browser.close()
                sys.exit(41)

        # 初期タイムアウト時、一度リロードして再試行
        if not articles_ready:
            print("🔄 Initial load timed out with 0 articles. Attempting page reload...")
            try:
                await page.reload(wait_until="domcontentloaded")
                await dismiss_modals(page)
                await page.wait_for_selector(TWEET_SELECTOR, timeout=15000)
                articles_ready = True
            except Exception:
                print("⚠️ Page reload finished; proceeding to timeline scanning.")

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
        total_articles_detected = 0
        MAX_STALLS = 8
        skipped_count = 0
        hit_existing = False
        consecutive_count = 0
        last_gist_index = -1

        while len(new_tweets) < args.num and not hit_existing and not rate_limit_hit:
            articles = await page.query_selector_all('article')
            if not articles:
                articles = await page.query_selector_all('[data-testid="tweet"]')
            if articles:
                total_articles_detected += len(articles)
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
            # 1000pxずつスムーズにスクロールしてバーチャルスクロールによる取りこぼしを防止
            try:
                await page.evaluate("window.scrollBy(0, 1000)")
            except Exception:
                await page.mouse.wheel(0, 1000)
            await dismiss_modals(page)

            # ローディングスピナーが表示されている場合はロード完了を少し待機
            try:
                spinner = await page.query_selector('div[role="progressbar"]')
                if spinner:
                    await asyncio.sleep(2)
            except Exception:
                pass

            await asyncio.sleep(2.5)

        if skipped_count:
            print(f"⏭️ Skipped {skipped_count} already-known posts.")

        # レート制限検知時
        if rate_limit_hit:
            print("🚨 Rate limit detected from X! Exiting with code 42.")
            await browser.close()
            sys.exit(42)

        # 0件で終了した場合の原因診断とスクリーンショット保存（異常検知時のみ）
        if len(new_tweets) == 0:
            diag_status = await diagnose_empty_state(page, len(seen_ids), skipped_count, total_articles_detected)
            if diag_status in ("account_dead", "auth_error", "error"):
                debug_screen = os.path.join(DATA_DIR, "debug_screen.png")
                try:
                    await page.screenshot(path=debug_screen, full_page=False)
                    print(f"  📸 Debug screenshot saved to: {debug_screen}")
                except Exception:
                    pass

                await browser.close()
                if diag_status == "account_dead":
                    print(f"🚨 Account @{args.user} is dead/suspended. Exiting with code 44.")
                    sys.exit(44)
                elif diag_status == "auth_error":
                    print("🚨 Auth session error. Exiting with code 41.")
                    sys.exit(41)
                else:
                    print("🚨 Extraction failed. Exiting with code 1.")
                    sys.exit(1)

        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            f.write("window.YTD.tweets.part0 = ")
            # 空リスト [] でも書き込むことで、Flutter側のエラーを防ぐ
            json.dump(new_tweets if new_tweets else [], f, ensure_ascii=False, indent=2)
        print(f"\n✅ Done: {len(new_tweets)} tweets saved.")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(run())