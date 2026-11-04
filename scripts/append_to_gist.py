"""
指定ユーザのポストを取得し、既存Gistにアペンドする。
  - 既存IDが見つかったら取得を停止（--stop-on-existing）
  - マスターGistは master 形式:
      {user_screen_name, user_gists:{user:gist_id}, tweets:[代表1件ずつ]}
  - ユーザGist（子）は multi-user 形式:
      {users: {user: {tweets:[]}}}
"""
import json
import os
import re
import shutil
import sys
import argparse
import subprocess
import tempfile
import time

DATA_DIR = "data"
TWEETS_JS = os.path.join(DATA_DIR, "tweets.js")
RESULT_FILE = os.path.join(DATA_DIR, ".last_fetch_result.json")
GIST_MAX_TWEETS = 2000  # 移動先Gistの上限
USER_PATTERN = re.compile(r"^@([^:]+):")

def write_fetch_result(user, tweets_saved, status="ok"):
    """クローラーの取得結果（保存ツイート数など）をメタデータファイルに書き出す"""
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(RESULT_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "user": user,
                "tweets_saved": tweets_saved,
                "status": status,
                "timestamp": int(time.time()),
            }, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"⚠️ Warning: Failed to write fetch result: {e}", file=sys.stderr)

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-g", "--gist-id", required=True, help="Append対象のGist ID")
    parser.add_argument("-u", "--user", default=None, help="Target user ID")
    parser.add_argument("-m", "--mode", default="post_only", help="(deprecated, ignored: always post_only)")
    parser.add_argument("-n", "--num", type=int, default=500, help=f"最大取得件数（上限{GIST_MAX_TWEETS}）")
    parser.add_argument("-s", "--stop-on-existing", action="store_true", help="既存IDに当たったら停止")
    parser.add_argument("--force-empty", action="store_true", help="Gistが0件でも強制続行")
    parser.add_argument("-p", "--promote-gist-id", default=None,
                        help="移動先Gist IDを手動指定")
    args = parser.parse_args()
    if args.num > GIST_MAX_TWEETS:
        print(f"⚠️  --num {args.num} exceeds limit. Capping at {GIST_MAX_TWEETS}.")
        args.num = GIST_MAX_TWEETS
    return args

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

def group_tweets_by_user(tweets):
    groups = {}
    for tweet in tweets:
        user = extract_username(tweet)
        groups.setdefault(user, []).append(tweet)
    return groups

# ---------------------------------------------------------------------------
# Gist フォーマット判定
# ---------------------------------------------------------------------------

def is_master_gist_format(data):
    return isinstance(data, dict) and "user_gists" in data

def is_multi_user_format(data):
    return isinstance(data, dict) and "users" in data

def get_gist_id_from_entry(entry):
    """user_gists の値から gist_id を取得（新形式dict・旧形式string 両対応）"""
    if isinstance(entry, dict):
        return entry.get("gist_id")
    return entry  # legacy string format

def get_user_tweets(data, user):
    """データからユーザのツイートを取得"""
    if is_master_gist_format(data):
        if not user:
            return data.get("tweets", [])
        return [t for t in data.get("tweets", []) if _tweet_belongs_to_user(t, user)]
    if is_multi_user_format(data):
        return data.get("users", {}).get(user, {}).get("tweets", [])
    # fallback
    if isinstance(data, dict) and "tweets" in data:
        return data["tweets"]
    return data if isinstance(data, list) else []

def _tweet_belongs_to_user(tweet, user):
    if tweet.get("username") == user:
        return True
    if f"x.com/{user}/status/" in tweet.get("post_url", ""):
        return True
    if tweet.get("full_text", "").startswith(f"@{user}:"):
        return True
    return False

# ---------------------------------------------------------------------------
# Gist 取得
# ---------------------------------------------------------------------------

def fetch_gist_data(gist_id):
    try:
        result = subprocess.run(
            ["gh", "api", f"gists/{gist_id}"],
            capture_output=True, text=True, check=True,
        )
        gist_meta = json.loads(result.stdout)
    except Exception as e:
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
                ["curl", "-sf", "-L", raw_url],
                capture_output=True, text=True,
            )
            if dl.returncode == 0:
                return filename, json.loads(dl.stdout)
        except Exception:
            pass
    print("❌ No valid data found in Gist.")
    sys.exit(1)

def select_promote_gist_from_master(full_data):
    """user_gists に登録されているGistのうち最後に追加されたIDを返す"""
    user_gists = full_data.get("user_gists", {})
    if not user_gists:
        return None
    seen = set()
    unique_gists = []
    for entry in user_gists.values():
        gist_id = get_gist_id_from_entry(entry)
        if gist_id and gist_id not in seen:
            unique_gists.append(gist_id)
            seen.add(gist_id)
    return unique_gists[-1] if unique_gists else None

def get_existing_ids_ordered(tweets):
    ids = []
    seen = set()
    for item in tweets:
        tid = item.get("id_str") or item.get("tweet", {}).get("id_str")
        if tid and tid not in seen:
            ids.append(tid)
            seen.add(tid)
    return ids

def write_skip_ids_file(ordered_ids):
    fd, path = tempfile.mkstemp(suffix=".txt", prefix="skip_ids_")
    with os.fdopen(fd, 'w') as f:
        for tid in ordered_ids:
            f.write(tid + "\n")
    return path

def run_extraction(args, skip_ids_file):
    cmd = [
        sys.executable, "scripts/extract_media.py",
        "--mode", "post_only",
        "-n", str(args.num),
        "--skip-ids-file", skip_ids_file,
    ]
    if args.user:
        cmd.extend(["-u", args.user])
    if args.stop_on_existing:
        cmd.append("--stop-on-existing")
    print(f"🚀 Running Extraction: {' '.join(cmd)}")
    res = subprocess.run(cmd)
    if res.returncode != 0:
        print(f"❌ Extraction script failed with exit code {res.returncode}")
        sys.exit(res.returncode)

def parse_tweets_js():
    if not os.path.exists(TWEETS_JS):
        return []
    with open(TWEETS_JS, 'r', encoding='utf-8') as f:
        content = f.read()
    json_str = re.sub(r'^window\.YTD\.tweets\.part0\s*=\s*', '', content)
    raw_tweets = json.loads(json_str)
    converted = []
    for item in raw_tweets:
        tweet = item.get('tweet', {})
        media_list = (
            tweet.get('extended_entities', {}).get('media', [])
            or tweet.get('entities', {}).get('media', [])
        )
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
        converted.append({
            'full_text': tweet.get('full_text', ''),
            'created_at': tweet.get('created_at', ''),
            'media_urls': media_urls,
            'id_str': tweet.get('id_str', ''),
            'post_url': post_url,
        })
    return converted

def append_tweets(existing_tweets, new_tweets):
    if not new_tweets:
        return existing_tweets
    existing_ids = {t.get("id_str") for t in existing_tweets if t.get("id_str")}
    unique_new = [t for t in new_tweets if t.get("id_str") not in existing_ids]
    if not unique_new:
        return existing_tweets
    print(f"✨ Appended: {len(unique_new)} new tweets")
    return unique_new + existing_tweets

# ---------------------------------------------------------------------------
# Gist作成・移動 (インメモリ更新)
# ---------------------------------------------------------------------------

def create_gist_for_user(user, tweets):
    """新しいユーザGistを作成 (階層構造: users -> user -> tweets)"""
    data = {"users": {user: {"tweets": tweets}}}
    # tempdir 内に data.json という名前で作成（gh gist create はファイル名をそのまま使う）
    tmp_dir = tempfile.mkdtemp()
    tmp_file = os.path.join(tmp_dir, "data.json")
    try:
        with open(tmp_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        result = subprocess.run(
            ["gh", "gist", "create", tmp_file, "-d", "Gallery User Data"],
            capture_output=True, text=True,
        )
    finally:
        if os.path.exists(tmp_file):
            os.unlink(tmp_file)
        os.rmdir(tmp_dir)
    if result.returncode != 0:
        print(f"❌ Failed: {result.stderr}")
        sys.exit(1)
    return result.stdout.strip().rstrip("/").split("/")[-1]

def update_or_migrate_user_gist_in_memory(promote_gist_id, promote_data, user, merged_tweets, gist_cache):
    """ユーザGistのデータをメモリ上で更新し、必要なら新規Gistを作成してマイグレーションを行う。"""
    if not is_multi_user_format(promote_data):
        print(f"⚠️  Warning: Target Gist {promote_gist_id} is not in multi-user format. Converting...")
        promote_data = {"users": {}}

    users_data = dict(promote_data.get("users", {}))
    # 他の全ユーザの全ポスト数を合計
    current_total = sum(
        len(u.get("tweets", []))
        for u_name, u in users_data.items()
        if u_name != user
    )

    if current_total + len(merged_tweets) > GIST_MAX_TWEETS:
        merged_tweets = merged_tweets[:GIST_MAX_TWEETS]
        print(f"⚠️  Limit reached ({GIST_MAX_TWEETS}). Creating new Gist...")
        new_id = create_gist_for_user(user, merged_tweets)
        # 移行元のGistからユーザのデータを削除（メモリ上）
        if user in users_data:
            del users_data[user]
            # 移行元Gistの更新をキューに積む
            gist_cache[promote_gist_id]["data"] = {"users": users_data}
            gist_cache[promote_gist_id]["is_modified"] = True
        return new_id, {"users": {user: {"tweets": merged_tweets}}}

    # 追記保存（メモリ上）
    users_data[user] = {"tweets": merged_tweets}
    updated_data = {"users": users_data}
    return promote_gist_id, updated_data

# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def process_multi_user_append(master_data, new_tweets, promote_gist_id_override=None):
    user_groups = group_tweets_by_user(new_tweets)
    user_gists_map = master_data.get("user_gists", {})
    master_tweets = master_data.get("tweets", [])

    # Gistの取得結果と更新状態をキャッシュして、最後に一括で書き込む
    gist_cache = {}  # { gist_id: {"filename": str, "data": dict, "is_modified": bool} }

    migrated_count = 0

    for user, tweets in user_groups.items():
        if user == "Unknown":
            master_tweets = append_tweets(master_tweets, tweets)
            continue

        print(f"--- @{user} ---")
        promote_gist_id = (
            promote_gist_id_override
            or get_gist_id_from_entry(user_gists_map.get(user))
            or select_promote_gist_from_master(master_data)
        )
        if not promote_gist_id:
            promote_gist_id = create_gist_for_user(user, [])

        # キャッシュから取得、なければフェッチ
        if promote_gist_id in gist_cache:
            p_filename = gist_cache[promote_gist_id]["filename"]
            p_data = gist_cache[promote_gist_id]["data"]
        else:
            p_filename, p_data = fetch_gist_data(promote_gist_id)
            gist_cache[promote_gist_id] = {"filename": p_filename, "data": p_data, "is_modified": False}

        existing = get_user_tweets(p_data, user)
        merged = append_tweets(existing, tweets)

        if len(merged) == len(existing):
            continue

        migrated_count += len(merged) - len(existing)

        # メモリ上でデータを更新
        final_id, updated_data = update_or_migrate_user_gist_in_memory(
            promote_gist_id, p_data, user, merged, gist_cache,
        )

        # キャッシュを更新し、変更フラグを立てる
        if final_id not in gist_cache:
            # 新規Gistが作成された場合。作成時に書き込まれているので is_modified=False
            gist_cache[final_id] = {"filename": "data.json", "data": updated_data, "is_modified": False}
        else:
            gist_cache[final_id]["data"] = updated_data
            gist_cache[final_id]["is_modified"] = True

        existing_entry = user_gists_map.get(user)
        now_ms = int(time.time() * 1000)
        if isinstance(existing_entry, dict):
            user_priority = existing_entry.get("priority_updated_at", now_ms)
        elif existing_entry is not None:
            user_priority = now_ms
        else:
            user_priority = now_ms

        user_gists_map[user] = {
            "gist_id": final_id,
            "priority_updated_at": user_priority,
        }
        master_tweets = [t for t in master_tweets if extract_username(t) != user]
        latest = merged[0]
        master_tweets.insert(0, {
            "id_str": latest.get("id_str", ""),
            "username": user,
            "media_urls": latest.get("media_urls", [])[:1],
        })

    print(f"📊 Total migrated to user Gists: {migrated_count} tweets")

    # ループ終了後、変更があったGistのみを一括で更新する
    for g_id, cache_info in gist_cache.items():
        if cache_info.get("is_modified"):
            print(f"☁️ Batch Updating Gist ({g_id})...")
            fd, tmp = tempfile.mkstemp(suffix=".json")
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as f:
                    json.dump(cache_info["data"], f, ensure_ascii=False, indent=2)
                subprocess.run(["gh", "gist", "edit", g_id, "-f", cache_info["filename"], tmp])
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)

    # スキーマ統一: 全ユーザーエントリに priority_updated_at を持たせる（未設定は 0）
    unified_user_gists = {}
    for u, entry in user_gists_map.items():
        if isinstance(entry, dict):
            unified_user_gists[u] = {
                "gist_id": entry.get("gist_id", ""),
                "priority_updated_at": int(entry.get("priority_updated_at", 0) or 0),
            }
        else:
            unified_user_gists[u] = {
                "gist_id": str(entry),
                "priority_updated_at": 0,
            }

    master_data["user_gists"] = unified_user_gists
    master_data["tweets"] = master_tweets
    return master_data

def main():
    args = parse_args()
    gist_filename, full_data = fetch_gist_data(args.gist_id)

    if not is_master_gist_format(full_data):
        print(f"❌ Error: {args.gist_id} is not a Master Gist.")
        sys.exit(1)

    # skip_ids 作成
    if args.user:
        ug_id = get_gist_id_from_entry(full_data.get("user_gists", {}).get(args.user))
        if ug_id:
            _, p_data = fetch_gist_data(ug_id)
            existing = get_user_tweets(p_data, args.user)
        else:
            existing = []
        skip_ids_file = write_skip_ids_file(get_existing_ids_ordered(existing))
    else:
        skip_ids_file = write_skip_ids_file(
            get_existing_ids_ordered(full_data.get("tweets", []))
        )

    try:
        run_extraction(args, skip_ids_file)
    finally:
        os.unlink(skip_ids_file)

    new_tweets = parse_tweets_js()
    if not new_tweets:
        print("✅ No new tweets.")
        write_fetch_result(args.user, 0, status="no_new_tweets")
        sys.exit(0)

    final_output = process_multi_user_append(full_data, new_tweets, args.promote_gist_id)
    output_file = "assets/data/data.json"
    os.makedirs("assets/data", exist_ok=True)
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, ensure_ascii=False, indent=2)
    subprocess.run(["gh", "gist", "edit", args.gist_id, "-f", gist_filename, output_file])
    write_fetch_result(args.user, len(new_tweets), status="success")
    print(f"✅ Master Gist updated!")

if __name__ == "__main__":
    main()
