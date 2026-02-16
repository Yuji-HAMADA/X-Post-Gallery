import asyncio
import json
import os
import re
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
    parser.add_argument("-u", "--user", type=str, required=True, help="Target user ID")
    parser.add_argument("--mode", type=str, default="all", choices=["all", "post_only"])
    parser.add_argument("target_id", nargs="?", default=None)
    return parser.parse_args()

def build_search_url(user, mode):
    # どちらのモードでも画像付き(filter:images)を必須にする
    if mode == "post_only":
        # 本人の投稿かつ画像付き、リポストは除外
        query = f"from:{user} filter:images -filter:reposts"
    else:
        # 本人のリポストや返信も含めるが、画像付きに限定
        query = f"from:{user} filter:images"
    
    return f"https://x.com/search?q={quote(query)}&f=live"

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

    # テキストとリポスト判定
    inner_text = await article.inner_text()
    is_repost = any(w in inner_text for w in ["リポスト", "Reposted", "reposted"])
    
    tweet_text_el = await article.query_selector('[data-testid="tweetText"]')
    raw_text = await tweet_text_el.inner_text() if tweet_text_el else ""
    full_text = f"{'RT ' if is_repost else ''}@{origin_user}: {raw_text}"

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
        
        src = src.split('&name=')[0] + "&name=orig"
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
        }
    }

async def run():
    args = parse_args()
    if not os.path.exists(AUTH_PATH):
        print(f"❌ Error: {AUTH_PATH} not found."); return

    os.makedirs(DATA_DIR, exist_ok=True)
    url = build_search_url(args.user, args.mode)
    print(f"🚀 Mode: {args.mode} | Target: {args.user} | URL: {url}")

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(storage_state=AUTH_PATH)
        page = await context.new_page()
        
        await page.goto(url, wait_until="domcontentloaded")
        await page.wait_for_timeout(10000)

        new_tweets, seen_ids = [], set()
        
        while len(new_tweets) < args.num:
            articles = await page.query_selector_all('article')
            for article in articles:
                data = await extract_tweet_data(article)
                if not data: continue
                
                tid = data["tweet"]["id_str"]
                if tid in seen_ids: continue
                
                seen_ids.add(tid)
                new_tweets.append(data)
                print(f"  [{len(new_tweets)}] Saved: @{tid}")

                if args.target_id and tid == args.target_id:
                    print(f"🎯 Reached target ID: {tid}"); break
                if len(new_tweets) >= args.num: break
            
            if len(new_tweets) >= args.num: break
            await page.mouse.wheel(0, 2000)
            await asyncio.sleep(4)

        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            f.write("window.YTD.tweets.part0 = ")
            # 空リスト [] でも書き込むことで、Flutter側のエラーを防ぐ
            json.dump(new_tweets if new_tweets else [], f, ensure_ascii=False, indent=2)
        print(f"\n✅ Done: {len(new_tweets)} tweets saved.")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(run())