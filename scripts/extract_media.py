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
    parser.add_argument("-u", "--user", type=str, default=None, help="Target user ID (--user または --hashtag のどちらか必須)")
    parser.add_argument("--hashtag", type=str, default=None, help="Target hashtag (#なし)")
    parser.add_argument("--mode", type=str, default="post_only", help="(deprecated, ignored: always post_only)")
    parser.add_argument("--skip-ids-file", type=str, default=None, help="File with IDs to skip (one per line)")
    parser.add_argument("--stop-on-existing", action="store_true", help="Stop when hitting a known ID (for user-specific append)")
    return parser.parse_args()

def build_url(user, hashtag, mode):
    if hashtag:
        # ハッシュタグは検索を使用
        query = f"#{hashtag} filter:images"
        return f"https://x.com/search?q={quote(query)}&f=live"
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
        }
    }

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
        
        await page.goto(url, wait_until="domcontentloaded")
        await page.wait_for_timeout(10000)

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
        new_tweets, seen_ids = [], set()
        stall_count = 0
        MAX_STALLS = 5
        skipped_count = 0
        hit_existing = False
        consecutive_count = 0
        last_gist_index = -1

        while len(new_tweets) < args.num and not hit_existing:
            articles = await page.query_selector_all('article')
            prev_seen = len(seen_ids)
            for article in articles:
                data = await extract_tweet_data(article)
                if not data: continue

                tid = data["tweet"]["id_str"]
                if tid in seen_ids: continue
                seen_ids.add(tid)

                if tid in skip_ids:
                    if args.stop_on_existing and gist_id_index:
                        gist_idx = gist_id_index.get(tid, -1)
                        if gist_idx >= 0 and last_gist_index >= 0 and gist_idx == last_gist_index + 1:
                            consecutive_count += 1
                        else:
                            consecutive_count = 1
                        last_gist_index = gist_idx
                        if consecutive_count >= CONSECUTIVE_STOP:
                            print(f"🛑 {CONSECUTIVE_STOP} consecutive existing IDs matched in order. Stopping.")
                            hit_existing = True
                            break
                    skipped_count += 1
                    continue

                # 新規ポスト → 連続カウントをリセット
                consecutive_count = 0
                last_gist_index = -1

                new_tweets.append(data)
                print(f"  [{len(new_tweets)}] Saved: @{tid}")

                if len(new_tweets) >= args.num:
                    break

            if len(new_tweets) >= args.num or hit_existing: break

            # スクロールしても新しいarticleが出てこなければ終端
            if len(seen_ids) > prev_seen:
                stall_count = 0
            else:
                stall_count += 1
                if stall_count >= MAX_STALLS:
                    print(f"\n⚠️ No more posts found after {MAX_STALLS} scrolls. Stopping.")
                    break

            await page.mouse.wheel(0, 2000)
            await asyncio.sleep(4)

        if skipped_count:
            print(f"⏭️ Skipped {skipped_count} already-known posts.")

        with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
            f.write("window.YTD.tweets.part0 = ")
            # 空リスト [] でも書き込むことで、Flutter側のエラーを防ぐ
            json.dump(new_tweets if new_tweets else [], f, ensure_ascii=False, indent=2)
        print(f"\n✅ Done: {len(new_tweets)} tweets saved.")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(run())