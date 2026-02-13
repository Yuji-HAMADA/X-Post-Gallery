import asyncio
import json
import os
import re
import sys  # 引数取得用
import argparse  # 追加
from playwright.async_api import async_playwright
from urllib.parse import quote

async def run():
    # --- 引数の解析 ---
    parser = argparse.ArgumentParser()
    # -n オプション（デフォルト100）
    parser.add_argument("-n", "--num", type=int, default=100, help="取得件数")
    # ユーザー名を引数で受け取れるようにする
    parser.add_argument("-u", "--user", type=str, default="travelbeauty8", help="対象ユーザーID")
    # 取得モード（未使用だが将来の拡張用に追加）
    parser.add_argument("--mode", type=str, default="all", choices=["all", "post_only", "repost_only"], help="取得モード")
    # ターゲットID（位置引数として維持）
    parser.add_argument("target_id", nargs="?", default=None, help="到達ターゲットID")
    
    args = parser.parse_args()
    MAX_LIMIT = args.num
    target_id = args.target_id
    target_user = args.user # ターゲットユーザー

    # --- 設定 ---
    DATA_DIR = "data"
    if not os.path.exists(DATA_DIR):
        os.makedirs(DATA_DIR)

    OUTPUT_FILE = os.path.join(DATA_DIR, "tweets.js")
    AUTH_PATH = os.path.join(DATA_DIR, "auth.json")
    
    if not os.path.exists(AUTH_PATH):
        print(f"❌ Error: {AUTH_PATH} が見つかりません。")
        sys.exit(1)

    # ログ出力
    if target_id:
        print(f"ID: {target_id} に到達するまで取得します（最大{MAX_LIMIT}件）", flush=True)
    else:
        print(f"最新から最大{MAX_LIMIT}件を取得します", flush=True)

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)

        # タイムアウト対策：ネットワークが不安定な場合に備えて少し長めに
        context = await browser.new_context(
            storage_state=AUTH_PATH,
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
        )
        page = await context.new_page()

        base_query = f"from:{target_user} filter:images"

        # --- モード別のクエリ決定（すべて最新順 f=live ベース） ---
        if args.mode == "post_only":
            # 自分のポストのみ（画像あり、リポストなし）
            query = f"from:{target_user} filter:images -filter:reposts"
            print(f"🎬 モード: ポストのみ", flush=True)

        elif args.mode == "repost_only":
            # リポストのみ（後でPython側でさらに厳密にフィルタリング）
            query = f"from:{target_user} include:nativeretweets -filter:replies"
            print(f"🔄 モード: リポストのみ", flush=True)

        else:
            # 全部（ポストもリポストも画像付きで最新順）
            query = f"from:{target_user} include:nativeretweets -filter:replies"
            print(f"✨ モード: 全部", flush=True)

        # 🚀 URLの組み立て
        encoded_query = quote(query)
        url = f"https://x.com/search?q={encoded_query}&f=live"
        
        print(f"🚀 アクセスURL: {url}")

        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=60000)
        except Exception as e:
            print(f"読み込みタイムアウト(続行): {e}")

        await page.wait_for_timeout(10000)

        new_tweets = []
        seen_repost_ids = set()
        stop_scrolling = False

        while len(new_tweets) < MAX_LIMIT and not stop_scrolling:
            articles = await page.query_selector_all('article')
            
            for article in articles:
                links = await article.query_selector_all('a[href*="/status/"]')
                current_repost_id = ""
                origin_user = "unknown"
                origin_status_id = ""
                
                for link in links:
                    href = await link.get_attribute('href')
                    match = re.search(r'/([^/]+)/status/(\d+)', href)
                    if match:
                        if origin_user == "unknown":
                            origin_user = match.group(1)
                            origin_status_id = match.group(2)
                        current_repost_id = match.group(2)

                # 重複チェック
                if not current_repost_id:
                    print(f"  [SKIP] ID:{current_repost_id} - ステータスIDが取得できませんでした。")
                    continue
                if current_repost_id in seen_repost_ids:
                    continue

                # ID一致チェック（引数がある場合）
                if target_id and current_repost_id == target_id:
                    print(f"  [到達] 指定ID一致: {current_repost_id}")
                    stop_scrolling = True
                    break

                # 判定用のテキストを取得
                full_text_raw = await article.inner_text()
                
                # --- デバッグ開始 ---
                is_repost = any(word in full_text_raw for word in ["リポスト", "Reposted", "reposted"])

                # --- 修正: repost_only モードの時の最終ガード ---
                if args.mode == "repost_only" and not is_repost:
                    # リポストのみ欲しいのに、リポストじゃない場合はスキップ
                    continue 

                # --- 修正: post_only モードの時（念のため） ---
                if args.mode == "post_only" and is_repost:
                    continue

                seen_repost_ids.add(current_repost_id)
                
                # 画像要素を取得
                all_images = await article.query_selector_all('[data-testid="tweetPhoto"] img')
                
                if not all_images:
                    # 容疑者1: 画像があるはずなのに取得できていない（読み込み待ちなど）
                    print(f"  [SKIP] ID:{current_repost_id} - 画像要素が見つかりませんでした。")
                    continue

                media_urls = []
                for img in all_images:
                    # 1. DOM判定（引用ツイート内にあるか）
                    is_excluded_dom = await img.evaluate("""(node) => {
                        return !!node.closest('[data-testid="quotedTweet"]') || 
                               !!node.closest('[data-testid="placementTracking"]');
                    }""")

                    # 2. URL/サイズ判定
                    src = await img.get_attribute('src')
                    if not src:
                        print(f"  [SKIP-IMG] ID:{current_repost_id} - 画像のsrc属性が取得できませんでした。")
                        continue

                    is_thumbnail = any(sz in src for sz in ["name=120x120", "name=240x240"])

                    # 除外理由をログに出す（確認用）
                    if is_excluded_dom:
                        print(f"  [SKIP-IMG] ID:{current_repost_id} - 引用ブロック内のため除外")
                        continue
                    if is_thumbnail:
                        # ここで small が出なくなるはず
                        print(f"  [SKIP-IMG] ID:{current_repost_id} - サムネイルサイズ({src.split('name=')[-1]})のため除外")
                        continue

                    if "pbs.twimg.com/media/" in src:
                        if not any(m["media_url_https"] == src for m in media_urls):
                            media_urls.append({
                                "media_url_https": src, 
                                "type": "photo",
                                "expanded_url": f"https://x.com/{origin_user}/status/{origin_status_id}/photo/1"
                            })

                # 保存処理
                if media_urls:
                    tweet_text_el = await article.query_selector('[data-testid="tweetText"]')
                    raw_text = await tweet_text_el.inner_text() if tweet_text_el else ""
                    
                    # --- 修正: リポストかどうかで表示テキストを切り替える ---
                    if is_repost:
                        full_text = f"RT @{origin_user}: {raw_text}"
                    else:
                        full_text = f"@{origin_user}: {raw_text}"
                    
                    time_el = await article.query_selector('time')
                    timestamp = await time_el.get_attribute('datetime') if time_el else ""
                    
                    new_tweets.append({
                        "tweet": {
                            "id_str": current_repost_id,
                            "full_text": full_text,  # 切り替えたテキストを格納
                            "created_at": timestamp,
                            "entities": {
                                "user_mentions": [{ "screen_name": origin_user }],
                                "media": media_urls
                            },
                            "extended_entities": { "media": media_urls },
                            "source_status_url": f"https://x.com/{origin_user}/status/{origin_status_id}"
                        }
                    })
                    # ログもリポストかどうか分かりやすくすると便利です
                    type_label = "RT" if is_repost else "Post"
                    print(f"  [{len(new_tweets)}] {type_label}取得中: @{origin_user}", flush=True)
                else:
                    print(f"  [SKIP] ID:{current_repost_id} - 有効なメイン画像がありませんでした。")

                if len(new_tweets) >= MAX_LIMIT:
                    break

            if len(new_tweets) < MAX_LIMIT and not stop_scrolling:
                await page.mouse.wheel(0, 2000)
                await asyncio.sleep(4)

        # 保存
        if new_tweets:
            with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
                f.write("window.YTD.tweets.part0 = ")
                json.dump(new_tweets, f, ensure_ascii=False, indent=2)
            print(f"\n完了！ {len(new_tweets)} 件保存しました。", flush=True)

        await browser.close()

if __name__ == "__main__":
    asyncio.run(run())