import asyncio
import json
import os
import sys
import argparse
from playwright.async_api import async_playwright

# extract_media.py から必要な関数と定数をインポート
# (同じディレクトリにあることを前提としています)
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from extract_media import extract_tweet_data, AUTH_PATH, DATA_DIR, OUTPUT_FILE

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--num", type=int, default=100, help="取得する最大件数")
    parser.add_argument("--skip-ids-file", type=str, default="", help="スキップすべきIDのリストが書かれたファイルへのパス")
    # gist-id の引数は不要になったため削除（または互換性のため残しても良いですが、ここでは新しい設計に合わせます）
    parser.add_argument("--gist-id", type=str, default=None, help="Deprecated: use --skip-ids-file instead")
    return parser.parse_args()

def load_skip_ids(skip_ids_file):
    """ファイルからスキップすべき既存IDのセットを読み込む"""
    skip_ids = set()
    if skip_ids_file and os.path.exists(skip_ids_file):
        with open(skip_ids_file, 'r', encoding='utf-8') as f:
            for line in f:
                tid = line.strip()
                if tid:
                    skip_ids.add(tid)
        print(f"✅ Loaded {len(skip_ids)} skip IDs from {skip_ids_file}")
    return skip_ids

async def run():
    args = parse_args()
    if not os.path.exists(AUTH_PATH):
        print(f"❌ Error: {AUTH_PATH} not found."); return

    os.makedirs(DATA_DIR, exist_ok=True)
    
    # 1. 既存データのIDを取得（停止条件用）
    seen_ids_in_gist = load_skip_ids(args.skip_ids_file)

    url = "https://x.com/home"
    print(f"🚀 Fetching 'For you' tweets from: {url}")

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(storage_state=AUTH_PATH)
        page = await context.new_page()
        
        await page.goto(url, wait_until="domcontentloaded")
        # タイムラインの初期ロード待機
        await page.wait_for_timeout(5000)

        new_tweets = []
        current_run_ids = set() # 今回の実行内で重複を防ぐ用
        stop_scraping = False
        no_new_data_count = 0
        
        while len(new_tweets) < args.num and not stop_scraping:
            articles = await page.query_selector_all('article')
            
            added_in_this_scroll = 0
            for article in articles:
                data = await extract_tweet_data(article)
                if not data: continue
                
                tid = data["tweet"]["id_str"]
                
                # 重複チェック: 既存リスト（Masterの代表ポストなど）にあるならスキップ
                if tid in seen_ids_in_gist:
                    continue

                # 重複チェック: 今回すでに取得済みならスキップ
                if tid in current_run_ids: continue
                
                current_run_ids.add(tid)
                new_tweets.append(data)
                added_in_this_scroll += 1
                print(f"  [{len(new_tweets)}] Saved: @{tid}")

                if len(new_tweets) >= args.num: 
                    stop_scraping = True
                    break
            
            if stop_scraping: break
            
            # スクロール
            await page.mouse.wheel(0, 2000)
            await asyncio.sleep(3)
            
            # 新しいデータが見つからない場合の無限ループ防止
            if added_in_this_scroll == 0:
                no_new_data_count += 1
                if no_new_data_count > 5:
                    print("⚠️ No new tweets found after scrolling multiple times. Stopping.")
                    break
            else:
                no_new_data_count = 0

        # 保存 (extract_media.py と同じ形式)
        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            f.write("window.YTD.tweets.part0 = ")
            json.dump(new_tweets if new_tweets else [], f, ensure_ascii=False, indent=2)
        
        print(f"\n✅ Done: {len(new_tweets)} new tweets saved locally.")
        await browser.close()

if __name__ == "__main__":
    asyncio.run(run())
