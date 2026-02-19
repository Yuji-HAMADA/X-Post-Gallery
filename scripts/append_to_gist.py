"""
指定ユーザ(またはハッシュタグ)のポストを取得し、既存Gistにアペンドする。
  - 先頭1件はGistの先頭に挿入、残りは末尾に追加
  - 既存IDが見つかったら取得を停止（--stop-on-existing）
"""
import json
import os
import re
import sys
import argparse
import subprocess
import tempfile

DATA_DIR = "data"
TWEETS_JS = os.path.join(DATA_DIR, "tweets.js")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-g", "--gist-id", required=True, help="Append対象のGist ID")
    parser.add_argument("-u", "--user", default=None, help="Target user ID (--user または --hashtag のどちらか必須)")
    parser.add_argument("--hashtag", type=str, default=None, help="Target hashtag (#なし)")
    parser.add_argument("-m", "--mode", default="post_only", choices=["all", "post_only"])
    parser.add_argument("-n", "--num", type=int, default=100, help="最大取得件数")
    parser.add_argument("-s", "--stop-on-existing", action="store_true", help="既存IDに当たったら停止（ストップオンモード）")
    parser.add_argument("--force-empty", action="store_true", help="Gistが0件でも強制続行（通常は安全のため中断）")
    return parser.parse_args()

def fetch_gist_data(gist_id):
    """GistからJSON取得。ファイル名と既存tweetsリストを返す。
    大きなファイルは gh gist view で切り詰められるため、API経由でraw_urlを取得しcurlで落とす。
    """
    try:
        result = subprocess.run(
            ["gh", "api", f"gists/{gist_id}"],
            capture_output=True, text=True, check=True,
        )
        gist_meta = json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
        print(f"❌ Failed to fetch Gist metadata: {e}")
        sys.exit(1)

    candidate_files = ["data.json", "gallary_data.json"]
    files = gist_meta.get("files", {})
    for filename in candidate_files:
        if filename not in files:
            continue
        raw_url = files[filename].get("raw_url")
        if not raw_url:
            continue
        try:
            dl = subprocess.run(
                ["curl", "-sL", raw_url],
                capture_output=True, text=True, check=True,
            )
            data = json.loads(dl.stdout)
            tweets = data.get("tweets", []) if isinstance(data, dict) else data
            user_screen_name = data.get("user_screen_name", "Unknown") if isinstance(data, dict) else "Unknown"
            print(f"☁️ Gist: {len(tweets)} items ('{filename}')")
            return filename, user_screen_name, tweets
        except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
            print(f"⚠️ Failed to parse '{filename}': {e}")
            continue
    print("❌ No valid data found in Gist.")
    sys.exit(1)

def get_existing_ids_ordered(tweets):
    """既存tweetsから順序付きIDリストを構築（連続一致判定用）"""
    ids = []
    seen = set()
    for item in tweets:
        tid = item.get("id_str") or item.get("tweet", {}).get("id_str")
        if tid and tid not in seen:
            ids.append(tid)
            seen.add(tid)
    return ids

def write_skip_ids_file(ordered_ids):
    """一時ファイルに既存IDを順序付きで書き出す（連続一致判定用）"""
    fd, path = tempfile.mkstemp(suffix=".txt", prefix="skip_ids_")
    with os.fdopen(fd, 'w') as f:
        for tid in ordered_ids:
            f.write(tid + "\n")
    return path

def run_extraction(user, hashtag, mode, num, skip_ids_file, stop_on_existing=True):
    """extract_media.py を呼び出してポストを取得"""
    cmd = [
        sys.executable, "scripts/extract_media.py",
        "--mode", mode,
        "-n", str(num),
        "--skip-ids-file", skip_ids_file,
    ]
    if user:
        cmd.extend(["-u", user])
    elif hashtag:
        cmd.extend(["--hashtag", hashtag])
    if stop_on_existing:
        cmd.append("--stop-on-existing")
    print(f"🚀 Running: {' '.join(cmd)}")
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print("❌ Extraction failed.")
        sys.exit(1)

def parse_tweets_js():
    """extract_media.py が出力した tweets.js を読む"""
    if not os.path.exists(TWEETS_JS):
        print("❌ tweets.js not found.")
        sys.exit(1)
    with open(TWEETS_JS, 'r', encoding='utf-8') as f:
        content = f.read()
    json_str = re.sub(r'^window\.YTD\.tweets\.part0\s*=\s*', '', content)
    raw_tweets = json.loads(json_str)

    # update_data.py と同じ変換ロジック
    converted = []
    for item in raw_tweets:
        tweet = item.get('tweet', {})
        full_text = tweet.get('full_text', '')
        media_list = tweet.get('extended_entities', {}).get('media', [])
        if not media_list:
            media_list = tweet.get('entities', {}).get('media', [])
        if not media_list:
            continue
        media_urls = [m.get('media_url_https', '') for m in media_list if m.get('media_url_https')]
        if not media_urls:
            continue

        post_url = ''
        for m in media_list:
            eu = m.get('expanded_url', '')
            if '/status/' in eu:
                post_url = re.sub(r'/photo/\d+$', '', eu)
                break

        entry = {
            'full_text': full_text,
            'created_at': tweet.get('created_at', ''),
            'media_urls': media_urls,
            'id_str': tweet.get('id_str', ''),
        }
        if post_url:
            entry['post_url'] = post_url
        converted.append(entry)

    return converted

def append_tweets(existing_tweets, new_tweets):
    """新規tweetsを既存に挿入: 先頭1件→先頭、残り→末尾"""
    if not new_tweets:
        print("ℹ️ No new tweets to append.")
        return existing_tweets

    # 重複チェック用
    existing_ids = {t.get("id_str") for t in existing_tweets if t.get("id_str")}

    unique_new = [t for t in new_tweets if t.get("id_str") not in existing_ids]
    if not unique_new:
        print("ℹ️ All tweets already exist. Nothing to append.")
        return existing_tweets

    first = unique_new[0]
    rest = unique_new[1:]

    # 先頭1件をGistの先頭に、残りを末尾に
    result = [first] + existing_tweets + rest
    print(f"✨ Appended: 1 to head + {len(rest)} to tail = {len(unique_new)} new tweets")
    return result

def main():
    args = parse_args()

    if not args.user and not args.hashtag:
        print("❌ Error: --user または --hashtag のどちらかが必要です。")
        sys.exit(1)

    target_label = f"#{args.hashtag}" if args.hashtag else f"@{args.user}"
    print(f"🎯 Target: {target_label}")

    # 1. 既存Gistデータ取得
    gist_filename, user_screen_name, existing_tweets = fetch_gist_data(args.gist_id)
    existing_ids_ordered = get_existing_ids_ordered(existing_tweets)
    print(f"📋 Existing IDs: {len(existing_ids_ordered)}")

    # 安全チェック: Appendなのに0件は異常。上書き事故を防ぐため中断する
    if len(existing_tweets) == 0 and not args.force_empty:
        print("⚠️  警告: GistのTweet数が0件です。")
        print("   Appendモードなのに既存データが空なのは異常な状態の可能性があります。")
        print("   意図的に空のGistへAppendしたい場合は --force-empty を付けて再実行してください。")
        sys.exit(1)

    # 2. 既存IDファイルを作成（順序付き：連続一致判定用）
    skip_ids_file = write_skip_ids_file(existing_ids_ordered)

    try:
        # 3. 新規ポスト取得
        run_extraction(args.user, args.hashtag, args.mode, args.num, skip_ids_file, args.stop_on_existing)
    finally:
        os.unlink(skip_ids_file)

    # 4. 取得結果をパース
    new_tweets = parse_tweets_js()
    print(f"📥 New tweets extracted: {len(new_tweets)}")

    # 5. アペンド
    merged = append_tweets(existing_tweets, new_tweets)

    # 6. ローカルに保存
    output_file = "assets/data/data.json"
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    final_output = {
        "user_screen_name": user_screen_name,
        "tweets": merged,
    }
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, ensure_ascii=False, indent=2)
    print(f"💾 Saved: {len(merged)} tweets to {output_file}")

    # 7. Gist更新
    print(f"☁️ Updating Gist ({args.gist_id})...")
    # gh gist edit は -f <filename> <local_file> の形式
    result = subprocess.run(
        ["gh", "gist", "edit", args.gist_id, "-f", gist_filename, output_file],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        print(f"✅ Gist updated successfully! Total: {len(merged)} tweets")
    else:
        print(f"❌ Gist update failed: {result.stderr}")
        sys.exit(1)

if __name__ == "__main__":
    main()
