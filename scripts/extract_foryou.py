import asyncio
import json
import os
import sys
import argparse
import subprocess
from playwright.async_api import async_playwright

# extract_media.py から必要な関数と定数をインポート
# (同じディレクトリにあることを前提としています)
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from extract_media import extract_tweet_data, AUTH_PATH, DATA_DIR, OUTPUT_FILE

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--num", type=int, default=100, help="取得する最大件数")
    parser.add_argument("--gist-id", type=str, default=None, help="既存データのGist ID (重複チェック用)")
    return parser.parse_args()

def get_existing_ids_from_gist(gist_id):
    """Gistから既存のdata.jsonを取得し、IDのセットを返す"""
    if not gist_id:
        return set()
    
    print(f"🔍 Fetching existing data from Gist: {gist_id} ...")
    
    # 読み込みを試みるファイル名の候補 (優先順)
    candidate_files = ["data.json", "gallary_data.json", "tweets.js"]
    
    for filename in candidate_files:
        try:
            # gh コマンドを使って Gist の内容を取得
            result = subprocess.run(
                ["gh", "gist", "view", gist_id, "--filename", filename, "--raw"],
                capture_output=True, text=True, check=True
            )
            
            raw_data = result.stdout.strip()
            
            # tweets.js の場合、JSの代入文を除去してJSON部分を取り出す簡易処理
            if filename == "tweets.js" and "=" in raw_data:
                parts = raw_data.split('=', 1)
                if len(parts) > 1:
                    raw_data = parts[1].strip()

            data = json.loads(raw_data)
            
            ids = set()
            # データ構造の判定
            items = []
            if isinstance(data, dict) and "tweets" in data:
                items = data["tweets"]
            elif isinstance(data, list):
                items = data
            
            for item in items:
                tid = item.get("id_str")
                if not tid and "tweet" in item:
                    tid = item["tweet"].get("id_str")
                
                if tid:
                    ids.add(tid)
            
            print(f"✅ Loaded {len(ids)} existing IDs from Gist (found '{filename}').")
            return ids

        except (subprocess.CalledProcessError, json.JSONDecodeError):
            continue

    print("⚠️ No valid data found in Gist. Proceeding as fresh run.")
    return set()

async def run():
    args = parse_args()
    if not os.path.exists(AUTH_PATH):
        print(f"❌ Error: {AUTH_PATH} not found."); return

    os.makedirs(DATA_DIR, exist_ok=True)
    
    # 1. 既存データのIDを取得（停止条件用）
    seen_ids_in_gist = get_existing_ids_from_gist(args.gist_id)

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
                
                # 重複チェック: Gistにあるデータならスキップして次へ
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
