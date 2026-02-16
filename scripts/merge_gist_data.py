import json
import argparse
import subprocess
import os
import sys

def merge_data(gist_id, local_file):
    """ローカルの新しいデータとGistの古いデータをマージする"""
    if not os.path.exists(local_file):
        print(f"❌ Error: Local file {local_file} not found.")
        sys.exit(1)

    # 1. ローカルデータの読み込み (今回取得分)
    with open(local_file, 'r', encoding='utf-8') as f:
        local_data_raw = json.load(f)
    
    # データ構造の正規化 (辞書型ならリストを取り出す)
    local_tweets = []
    user_screen_name = "Unknown"
    
    if isinstance(local_data_raw, dict) and "tweets" in local_data_raw:
        local_tweets = local_data_raw["tweets"]
        user_screen_name = local_data_raw.get("user_screen_name", "Unknown")
    elif isinstance(local_data_raw, list):
        local_tweets = local_data_raw
    
    print(f"📂 Local data (New): {len(local_tweets)} items.")

    if not gist_id:
        print("ℹ️ No Gist ID provided. Skipping merge.")
        return

    # 2. Gistデータの取得 (過去分) - 複数ファイル名対応
    print(f"🔍 Fetching Gist data: {gist_id} ...")
    gist_tweets = []
    found_filename = None
    candidate_files = ["data.json", "gallary_data.json", "tweets.js"]

    for filename in candidate_files:
        try:
            result = subprocess.run(
                ["gh", "gist", "view", gist_id, "--filename", filename, "--raw"],
                capture_output=True, text=True, check=True
            )
            raw_data = result.stdout.strip()
            
            if filename == "tweets.js" and "=" in raw_data:
                parts = raw_data.split('=', 1)
                if len(parts) > 1:
                    raw_data = parts[1].strip()

            loaded_data = json.loads(raw_data)
            
            if isinstance(loaded_data, dict) and "tweets" in loaded_data:
                gist_tweets = loaded_data["tweets"]
            elif isinstance(loaded_data, list):
                gist_tweets = loaded_data
            
            print(f"☁️ Gist data (Old): {len(gist_tweets)} items (found '{filename}').")
            found_filename = filename
            break

        except (subprocess.CalledProcessError, json.JSONDecodeError):
            continue
    
    if found_filename is None:
        print(f"❌ Error: Failed to fetch Gist data. Checked: {candidate_files}")
        sys.exit(1)

    # 3. マージ処理 (New + Old)
    # 重複排除用セット
    seen_ids = set()
    merged_tweets = []
    
    # ヘルパー関数: ID取得
    def get_id(item):
        return item.get("id_str") or item.get("tweet", {}).get("id_str")

    # 新しいデータを先に追加
    for item in local_tweets:
        tid = get_id(item)
        if tid and tid not in seen_ids:
            merged_tweets.append(item)
            seen_ids.add(tid)
   # 古いデータを後ろに追加
    for item in gist_tweets:
        tid = get_id(item)
        if tid and tid not in seen_ids:
            merged_tweets.append(item)
            seen_ids.add(tid)
            
    print(f"✨ Merged Total: {len(merged_tweets)} items.")
    
    # 4. 保存 (update_data.py の形式に合わせる)
    final_output = {
        "user_screen_name": user_screen_name,
        "tweets": merged_tweets
    }
    
    with open(local_file, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, ensure_ascii=False, indent=2)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--gist-id", required=True)
    parser.add_argument("--local-file", required=True)
    args = parser.parse_args()
    
    merge_data(args.gist_id, args.local_file)
