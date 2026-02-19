"""
ローカルの新しいデータ（ForYou等）とマスターGistの既存データをマージする。
- user_gists マッピングを保持
- マージ後、2件以上のユーザはユーザGistに移動（閾値到達時）
- マスターGistを直接更新
"""
import json
import re
import argparse
import os
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from append_to_gist import (
    fetch_gist_data,
    is_master_gist_format,
    _tweet_belongs_to_user,
    select_promote_gist_from_master,
    migrate_user_tweets,
    MIGRATE_THRESHOLD,
)

USER_PATTERN = re.compile(r"^@([^:]+):")


def extract_username(tweet):
    """ツイートからユーザ名を抽出（full_text の @user: パターン or post_url）"""
    # full_text パターン
    m = USER_PATTERN.match(tweet.get("full_text", ""))
    if m:
        return m.group(1).strip()
    # post_url パターン
    post_url = tweet.get("post_url", "")
    m2 = re.search(r"x\.com/([^/]+)/status/", post_url)
    if m2:
        return m2.group(1)
    return None


def group_tweets_by_user(tweets):
    """ツイートをユーザ別にグループ化"""
    groups = {}
    for tweet in tweets:
        user = extract_username(tweet)
        key = user if user else "_unknown"
        groups.setdefault(key, []).append(tweet)
    return groups


def merge_data(gist_id, local_file):
    if not os.path.exists(local_file):
        print(f"❌ Error: Local file {local_file} not found.")
        sys.exit(1)

    # 1. ローカルデータの読み込み (今回取得分)
    with open(local_file, 'r', encoding='utf-8') as f:
        local_data_raw = json.load(f)

    local_tweets = []
    if isinstance(local_data_raw, dict) and "tweets" in local_data_raw:
        local_tweets = local_data_raw["tweets"]
    elif isinstance(local_data_raw, list):
        local_tweets = local_data_raw

    print(f"📂 Local data (New): {len(local_tweets)} items.")

    if not gist_id:
        print("ℹ️ No Gist ID provided. Skipping merge.")
        return

    # 2. マスターGistデータの取得 (user_gists を含む完全なデータ)
    print(f"🔍 Fetching Gist data: {gist_id} ...")
    gist_filename, full_data = fetch_gist_data(gist_id)

    if full_data is None:
        print("⚠️ No existing data found in Gist. Treating as first run.")
        final_output = {"user_screen_name": "", "tweets": local_tweets}
        with open(local_file, 'w', encoding='utf-8') as f:
            json.dump(final_output, f, ensure_ascii=False, indent=2)
        print(f"✨ Saved: {len(local_tweets)} items.")
        return

    gist_tweets = full_data.get("tweets", [])
    user_gists = dict(full_data.get("user_gists", {}))
    print(f"☁️ Gist data (Old): {len(gist_tweets)} items, {len(user_gists)} user_gists ('{gist_filename}')")

    # 3. マージ処理 (New + Old, 重複排除)
    seen_ids = set()
    merged_tweets = []

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

    # 4. ユーザ別にグループ化して移動判定
    groups = group_tweets_by_user(merged_tweets)
    print(f"👥 Users in merged data: {len(groups)}")

    master_tweets = []  # マスターに残すツイート
    migrated_count = 0

    for username, tweets in groups.items():
        if username == "_unknown":
            # ユーザ不明のツイートはそのまま残す
            master_tweets.extend(tweets)
            continue

        if username in user_gists:
            # 既にユーザGistにマッピングあり → 新規ツイートをそのGistに追加
            existing_gist_id = user_gists[username]
            # マスターにある既存の代表ツイートを探す
            existing_rep = None
            new_tweets_for_user = []
            for t in tweets:
                # 既存Gistからロードしたツイートはマスターに1件だけ残っている代表
                # 新規追加分はローカルデータに含まれるもの
                if get_id(t) in {get_id(lt) for lt in local_tweets}:
                    new_tweets_for_user.append(t)
                else:
                    existing_rep = t

            if new_tweets_for_user:
                # 新規ツイートをユーザGistに追加
                print(f"📤 @{username}: {len(new_tweets_for_user)} new → Gist {existing_gist_id[:8]}...")
                migrate_user_tweets(existing_gist_id, username, new_tweets_for_user)
                migrated_count += len(new_tweets_for_user)

            # マスターには代表1件を残す（最新のものを代表に）
            representative = tweets[0]  # merged では新しいものが先頭
            representative = dict(representative)
            representative["gist_id"] = existing_gist_id
            master_tweets.append(representative)

        elif len(tweets) >= MIGRATE_THRESHOLD:
            # 閾値到達 → 移動先を自動選択して移動
            promote_gist_id = select_promote_gist_from_master(full_data)
            if promote_gist_id:
                print(f"🔄 @{username}: {len(tweets)} tweets → migrate to {promote_gist_id[:8]}...")
                actual_gist_id = migrate_user_tweets(promote_gist_id, username, tweets)
                user_gists[username] = actual_gist_id
                migrated_count += len(tweets)
                # マスターには代表1件
                representative = dict(tweets[0])
                representative["gist_id"] = actual_gist_id
                master_tweets.append(representative)
            else:
                # 移動先が見つからない → そのまま残す
                print(f"⚠️ @{username}: 移動先Gistが見つかりません。マスターに残します。")
                master_tweets.extend(tweets)
        else:
            # 1件のみ → マスターにそのまま残す
            master_tweets.extend(tweets)

    print(f"📊 Migration: {migrated_count} tweets moved to user Gists")
    print(f"📊 Master: {len(master_tweets)} tweets, {len(user_gists)} user_gists")

    # 5. マスターGist用データを構築して保存
    final_output = {
        "user_screen_name": "",
        "tweets": master_tweets,
    }
    if user_gists:
        final_output["user_gists"] = user_gists

    with open(local_file, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, ensure_ascii=False, indent=2)

    # 6. マスターGistを更新
    print(f"☁️ Updating master Gist ({gist_id})...")
    import subprocess
    result = subprocess.run(
        ["gh", "gist", "edit", gist_id, "-f", gist_filename, local_file],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        print(f"✅ Master Gist updated! {len(master_tweets)} tweets, {len(user_gists)} user_gists")
    else:
        print(f"❌ Gist update failed: {result.stderr}")
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--gist-id", required=True)
    parser.add_argument("--local-file", required=True)
    args = parser.parse_args()

    merge_data(args.gist_id, args.local_file)
