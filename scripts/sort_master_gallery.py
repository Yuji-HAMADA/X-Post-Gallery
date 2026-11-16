#!/usr/bin/env python3
"""
メインギャラリーの表示順を並び替えるスクリプト。
- ピン留めされているグループ（priority_updated_at > 0）、されていないグループ（priority_updated_at == 0）の
  それぞれにおいて、「ポストされた時刻の新しい順」に並び替える。
- メインギャラリーのサムネイルは各Xアカウントの最新メディア付きツイートを使用する。
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

USER_PATTERN = re.compile(r"^@([^:]+):")


def load_token():
    """環境変数または.envファイルからGITHUB_TOKENを取得"""
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        return token.strip()
    env_paths = [".env", os.path.join(os.path.dirname(__file__), "..", ".env")]
    for ep in env_paths:
        if os.path.exists(ep):
            try:
                with open(ep, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("GITHUB_TOKEN="):
                            return line.split("=", 1)[1].strip().strip('"').strip("'")
            except Exception:
                pass
    return None


def load_master_gist_id():
    """環境変数または.envファイルからMASTER_GIST_IDを取得"""
    gid = os.environ.get("MASTER_GIST_ID")
    if gid:
        return gid.strip()
    env_paths = [".env", os.path.join(os.path.dirname(__file__), "..", ".env")]
    for ep in env_paths:
        if os.path.exists(ep):
            try:
                with open(ep, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("MASTER_GIST_ID="):
                            return line.split("=", 1)[1].strip().strip('"').strip("'")
            except Exception:
                pass
    return None


def fetch_gist_json(gist_id):
    """gh api を用いて Gist の JSON データを取得"""
    try:
        res = subprocess.run(
            ["gh", "api", f"gists/{gist_id}"],
            capture_output=True,
            text=True,
            check=True,
        )
        meta = json.loads(res.stdout)
    except Exception as e:
        print(f"❌ Failed to fetch metadata for Gist ({gist_id}): {e}")
        return None, None

    files = meta.get("files", {})
    candidate_names = ["data.json", "gallary_data.json"]
    target_name = None
    for name in candidate_names:
        if name in files:
            target_name = name
            break
    if not target_name:
        for name in files:
            if name.endswith(".json"):
                target_name = name
                break
    if not target_name:
        return None, None

    file_info = files[target_name]
    raw_url = file_info.get("raw_url")
    if not raw_url:
        return target_name, None

    try:
        dl = subprocess.run(
            ["curl", "-sf", "-L", raw_url],
            capture_output=True,
            text=True,
            check=True,
        )
        return target_name, json.loads(dl.stdout)
    except Exception as e:
        print(f"❌ Failed to download raw content from Gist ({gist_id}): {e}")
        return target_name, None


def extract_username(tweet):
    if tweet.get("username"):
        return tweet["username"]
    m = USER_PATTERN.match(tweet.get("full_text", ""))
    if m:
        return m.group(1).strip()
    post_url = tweet.get("post_url", "")
    m2 = re.search(r"x\.com/([^/]+)/status/", post_url)
    if m2:
        return m2.group(1)
    return "Unknown"


def get_tweet_sort_key(tweet):
    """ツイートの投稿時刻ソートキー（ミリ秒タイムスタンプ）を算出"""
    if not tweet or not isinstance(tweet, dict):
        return 0
    id_str = str(tweet.get("id_str") or tweet.get("id") or "")
    if id_str.isdigit():
        val = int(id_str)
        # Snowflake ID のタイムスタンプ部分を抽出 (41 bits)
        if val > 100000000000:
            return (val >> 22) + 1288834974650
    created_at = tweet.get("created_at", "")
    if created_at:
        # 1. "YYYY-MM-DD HH:mm:ss JST"
        m = re.match(r"^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+JST$", created_at)
        if m:
            try:
                dt = datetime.strptime(created_at.replace(" JST", " +0900"), "%Y-%m-%d %H:%M:%S %z")
                return int(dt.timestamp() * 1000)
            except Exception:
                pass
        # 2. "Wed Oct 10 20:19:24 +0000 2018"
        try:
            dt = datetime.strptime(created_at, "%a %b %d %H:%M:%S %z %Y")
            return int(dt.timestamp() * 1000)
        except Exception:
            pass
        # 3. ISO-8601 (例: "2026-11-15T21:40:33.000Z")
        try:
            iso_str = created_at.replace("Z", "+00:00")
            dt = datetime.fromisoformat(iso_str)
            return int(dt.timestamp() * 1000)
        except Exception:
            pass
    return 0


def has_media(tweet):
    if not isinstance(tweet, dict):
        return False
    if tweet.get("media_urls") and len(tweet["media_urls"]) > 0:
        return True
    if tweet.get("image_url") or tweet.get("media_url") or tweet.get("video_url") or tweet.get("video_urls"):
        return True
    return False


def select_latest_thumbnail_tweet(tweets):
    """ユーザーの全ツイート群からサムネイル用最新メディアツイートを選出"""
    if not tweets:
        return {}
    media_tweets = [t for t in tweets if has_media(t)]
    candidate_list = media_tweets if media_tweets else tweets
    return max(candidate_list, key=get_tweet_sort_key)


def get_gist_id_from_entry(entry):
    if isinstance(entry, dict):
        return entry.get("gist_id")
    return entry


def fetch_child_user_tweets(username, gist_id):
    """子Gistから当該ユーザーの全ツイートを取得"""
    if not gist_id:
        return []
    _, child_data = fetch_gist_json(gist_id)
    if not child_data:
        return []
    users = child_data.get("users", {})
    if isinstance(users, dict) and username in users:
        return users[username].get("tweets", [])
    # 大文字小文字不問フォールバック
    u_lower = username.lower()
    for k, v in users.items():
        if k.lower() == u_lower and isinstance(v, dict):
            return v.get("tweets", [])
    if "tweets" in child_data and isinstance(child_data["tweets"], list):
        return [t for t in child_data["tweets"] if extract_username(t).lower() == u_lower]
    return []


def sort_master_gallery(master_data, fetch_child=True, max_threads=2):
    """
    マスターGistデータをピン留めグループ/非ピン留めグループそれぞれ
    「ポスト時刻の新しい順」にソートし、最新サムネイルを指定して返す。
    """
    user_gists = master_data.get("user_gists", {})
    master_tweets = master_data.get("tweets", [])

    # マスターGist内の既存ツイートをユーザーごとにマッピング
    existing_user_tweets = {}
    for t in master_tweets:
        u = extract_username(t)
        if u and u != "Unknown":
            existing_user_tweets.setdefault(u, []).append(t)

    # 各ユーザーの最新ツイートとソートキーを特定
    latest_tweet_map = {}  # username -> Tweet
    sort_key_map = {}      # username -> int (timestamp ms)

    if fetch_child:
        print(f"🔍 子Gistから最新ツイートとサムネイル画像を取得中 ({len(user_gists)} アカウント, 並列数: {max_threads})...")
        user_child_map = {}
        for u, entry in user_gists.items():
            gid = get_gist_id_from_entry(entry)
            if gid:
                user_child_map[u] = gid

        with ThreadPoolExecutor(max_workers=max_threads) as executor:
            future_to_user = {
                executor.submit(fetch_child_user_tweets, u, gid): u
                for u, gid in user_child_map.items()
            }
            completed_count = 0
            for future in as_completed(future_to_user):
                u = future_to_user[future]
                completed_count += 1
                try:
                    tweets = future.result()
                except Exception as e:
                    print(f"  ⚠️ Error fetching child for @{u}: {e}")
                    tweets = []

                # 子Gist取得失敗時は既存マスターツイートをフォールバックとして使用
                all_candidate_tweets = tweets if tweets else existing_user_tweets.get(u, [])
                best_tweet = select_latest_thumbnail_tweet(all_candidate_tweets)
                if best_tweet:
                    latest_tweet_map[u] = best_tweet
                    sort_key_map[u] = get_tweet_sort_key(best_tweet)
                else:
                    sort_key_map[u] = 0

                if completed_count % 20 == 0 or completed_count == len(user_child_map):
                    print(f"  [{completed_count}/{len(user_child_map)}] 取得完了...")
    else:
        print(f"ℹ️ 子Gistフェッチをスキップし、マスターGist内の既存ツイートからソートキーを算出します。")
        for u in user_gists.keys():
            tweets = existing_user_tweets.get(u, [])
            best_tweet = select_latest_thumbnail_tweet(tweets)
            if best_tweet:
                latest_tweet_map[u] = best_tweet
                sort_key_map[u] = get_tweet_sort_key(best_tweet)
            else:
                sort_key_map[u] = 0

    # ユーザーを「ピン留めグループ」と「非ピン留めグループ」に分類
    pinned_users = []
    unpinned_users = []

    for u, entry in user_gists.items():
        priority = 0
        if isinstance(entry, dict):
            priority = int(entry.get("priority_updated_at", 0) or 0)
        if priority > 0:
            pinned_users.append(u)
        else:
            unpinned_users.append(u)

    # 各グループ内を「ポストされた時刻の新しい順（降順）」でソート
    pinned_users.sort(key=lambda u: sort_key_map.get(u, 0), reverse=True)
    unpinned_users.sort(key=lambda u: sort_key_map.get(u, 0), reverse=True)

    sorted_all_users = pinned_users + unpinned_users

    # 新しい user_gists を構築
    # ピン留めアカウントはソート順を保持するため最新ポスト時刻を priority_updated_at に反映
    new_user_gists = {}
    for u in sorted_all_users:
        old_entry = user_gists[u]
        is_pinned = u in pinned_users
        if isinstance(old_entry, dict):
            entry_dict = dict(old_entry)
            if is_pinned:
                # ピン留め順序を最新ポスト順に整合（0より大きい値）
                entry_dict["priority_updated_at"] = max(1, sort_key_map.get(u, 1))
            else:
                entry_dict["priority_updated_at"] = 0
            new_user_gists[u] = entry_dict
        else:
            new_user_gists[u] = {
                "gist_id": str(old_entry),
                "priority_updated_at": max(1, sort_key_map.get(u, 1)) if is_pinned else 0,
            }

    # 新しい tweets（各ユーザーの最新サムネイル用ツイート）を構築
    new_tweets = []
    for u in sorted_all_users:
        latest = latest_tweet_map.get(u) or select_latest_thumbnail_tweet(existing_user_tweets.get(u, []))
        if latest:
            master_entry = {
                "id_str": latest.get("id_str") or latest.get("id", ""),
                "username": u,
                "media_urls": latest.get("media_urls", [])[:1],
            }
            if latest.get("created_at"):
                master_entry["created_at"] = latest["created_at"]
            if latest.get("video_url"):
                master_entry["video_url"] = latest["video_url"]
            if latest.get("video_urls"):
                master_entry["video_urls"] = latest["video_urls"]
            new_tweets.append(master_entry)

    master_data["user_gists"] = new_user_gists
    master_data["tweets"] = new_tweets

    return master_data, pinned_users, unpinned_users, sort_key_map


def format_ts(ts):
    if not ts:
        return "Unknown"
    return datetime.fromtimestamp(ts / 1000).strftime("%Y-%m-%d %H:%M:%S")


def main():
    parser = argparse.ArgumentParser(
        description="Sort Master Gallery items by latest post timestamp (pinned and unpinned groups)"
    )
    parser.add_argument("-g", "--master-gist-id", default=None, help="Master Gist ID")
    parser.add_argument("--dry-run", action="store_true", help="Print sorted preview without editing Gist")
    parser.add_argument("--no-fetch-child", action="store_true", help="Skip fetching child Gists, sort by existing master tweets")
    parser.add_argument("--threads", type=int, default=2, help="Threads for child Gist fetching (default: 2)")
    args = parser.parse_args()

    gist_id = args.master_gist_id or load_master_gist_id()
    if not gist_id:
        print("❌ Error: Master Gist ID is required. Pass via -g or set MASTER_GIST_ID in .env.")
        sys.exit(1)

    print("==================================================")
    print("🚀 Master Gallery Sorter Started")
    print(f"📋 Master Gist ID : {gist_id}")
    print(f"🔧 Dry-run Mode    : {'Yes' if args.dry_run else 'No'}")
    print(f"🌐 Fetch Child     : {'No' if args.no_fetch_child else 'Yes'}")
    print("==================================================")

    filename, master_data = fetch_gist_json(gist_id)
    if not master_data or "user_gists" not in master_data:
        print(f"❌ Error: Failed to fetch valid master data from Gist ({gist_id}).")
        sys.exit(1)

    sorted_data, pinned, unpinned, sort_keys = sort_master_gallery(
        master_data,
        fetch_child=not args.no_fetch_child,
        max_threads=args.threads,
    )

    print("\n--- 📌 ピン留めグループ (ソート後) ---")
    for i, u in enumerate(pinned, 1):
        print(f"  {i}. @{u:<20} [最新ポスト: {format_ts(sort_keys.get(u, 0))}]")
    if not pinned:
        print("  (ピン留めアカウントなし)")

    print("\n--- 👥 通常グループ (ソート後) ---")
    for i, u in enumerate(unpinned[:20], 1):
        print(f"  {i}. @{u:<20} [最新ポスト: {format_ts(sort_keys.get(u, 0))}]")
    if len(unpinned) > 20:
        print(f"  ... 他 {len(unpinned) - 20} アカウント")

    if args.dry_run:
        print("\n✨ Dry-run completed. No changes written to Gist.")
        return

    print(f"\n☁️ Master Gist ({gist_id}) を更新中 ({filename})...")
    fd, tmp_file = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(sorted_data, f, ensure_ascii=False, indent=2)
        res = subprocess.run(
            ["gh", "gist", "edit", gist_id, "-f", filename, tmp_file],
            capture_output=True,
            text=True,
        )
        if res.returncode == 0:
            print("✅ Master Gist のソートおよび最新サムネイル更新が正常に完了しました！")
        else:
            print(f"❌ Failed to update Master Gist: {res.stderr}")
            sys.exit(1)
    finally:
        if os.path.exists(tmp_file):
            os.unlink(tmp_file)


if __name__ == "__main__":
    main()
