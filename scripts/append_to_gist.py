"""
指定ユーザ(またはハッシュタグ)のポストを取得し、既存Gistにアペンドする。
  - 既存IDが見つかったら取得を停止（--stop-on-existing）
  - Gistフォーマットは master のみ対応:
      {user_screen_name, user_gists:{user:gist_id}, tweets:[flat]}
  - master形式で対象がユーザの場合:
      - 既存ユーザ: user_gists に登録されているGistへ追記
      - 新規ユーザ: 任意の既存Gistを選択し、そこへ追記
      - 追加することで上限(GIST_MAX_TWEETS)を超える場合は、新規Gistを作成しそこへ保存する
      - マスターGistには代表1件とgist_id参照を保持する
  - ForYouタブ取得（--foryou）やハッシュタグなどで複数ユーザが混在する場合:
      - 取得したポストをユーザごとにグループ化
      - 各ユーザについて、対応するGistへ追記・移動を行う
      - マスターGistの user_gists と代表ポストを更新
"""
import json
import os
import re
import shutil
import sys
import argparse
import subprocess
import tempfile

DATA_DIR = "data"
TWEETS_JS = os.path.join(DATA_DIR, "tweets.js")
GIST_MAX_TWEETS = 1000  # 移動先Gistの上限
USER_PATTERN = re.compile(r"^@([^:]+):")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-g", "--gist-id", required=True, help="Append対象のGist ID")
    parser.add_argument("-u", "--user", default=None, help="Target user ID")
    parser.add_argument("--hashtag", type=str, default=None, help="Target hashtag (#なし)")
    parser.add_argument("--foryou", action="store_true", help="For Youタイムラインから取得")
    parser.add_argument("-m", "--mode", default="post_only", choices=["all", "post_only"])
    parser.add_argument("-n", "--num", type=int, default=100, help="最大取得件数")
    parser.add_argument("-s", "--stop-on-existing", action="store_true", help="既存IDに当たったら停止（ストップオンモード）")
    parser.add_argument("--force-empty", action="store_true", help="Gistが0件でも強制続行")
    parser.add_argument("-p", "--promote-gist-id", default=None,
                        help="移動先Gist IDを手動指定（省略時はuser_gistsから自動選択）")
    return parser.parse_args()

def extract_username(tweet):
    """ツイートからユーザ名を抽出"""
    m = USER_PATTERN.match(tweet.get("full_text", ""))
    if m:
        return m.group(1).strip()
    post_url = tweet.get("post_url", "")
    m2 = re.search(r"x\.com/([^/]+)/status/", post_url)
    if m2:
        return m2.group(1)
    return "Unknown"

def group_tweets_by_user(tweets):
    """ツイートをユーザ別にグループ化"""
    groups = {}
    for tweet in tweets:
        user = extract_username(tweet)
        groups.setdefault(user, []).append(tweet)
    return groups

# ---------------------------------------------------------------------------
# Gist フォーマット判定
# ---------------------------------------------------------------------------

def is_master_gist_format(data):
    """マスターGist形式: {user_gists:{...}, tweets:[flat]} かどうか判定"""
    return isinstance(data, dict) and "user_gists" in data

def _tweet_belongs_to_user(tweet, user):
    """ツイートが指定ユーザのものかどうか判定"""
    if f"x.com/{user}/status/" in tweet.get("post_url", ""):
        return True
    if tweet.get("full_text", "").startswith(f"@{user}:"):
        return True
    return False

def get_user_tweets(data, user):
    """データからユーザのツイートを取得（旧フォーマットからの移行対応）"""
    if is_master_gist_format(data):
        if not user:
            return data.get("tweets", [])
        return [t for t in data.get("tweets", []) if _tweet_belongs_to_user(t, user)]
    
    if isinstance(data, dict):
        if "users" in data:
            return data.get("users", {}).get(user, {}).get("tweets", [])
        return data.get("tweets", [])
    if isinstance(data, list):
        return data
    return []

# ---------------------------------------------------------------------------
# Gist 取得
# ---------------------------------------------------------------------------

def _fetch_via_git_clone(gist_id, candidate_files):
    tmpdir = tempfile.mkdtemp(prefix="gist_clone_")
    try:
        result = subprocess.run(
            ["gh", "gist", "clone", gist_id, tmpdir],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"❌ git clone失敗: {result.stderr}")
            sys.exit(1)
        for filename in candidate_files:
            filepath = os.path.join(tmpdir, filename)
            if os.path.exists(filepath):
                with open(filepath, 'r', encoding='utf-8') as f:
                    data = json.loads(f.read(), strict=False)
                return filename, data
    except json.JSONDecodeError as e:
        print(f"❌ JSON parse error after git clone: {e}")
        sys.exit(1)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    print("❌ No valid data found in Gist.")
    sys.exit(1)

def fetch_gist_data(gist_id):
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
            token = os.environ.get("GH_TOKEN", "")
            curl_cmd = ["curl", "-sf", "-L"]
            if token:
                curl_cmd += ["-H", f"Authorization: Bearer {token}"]
            curl_cmd.append(raw_url)
            dl = subprocess.run(curl_cmd, capture_output=True, text=True)
            if dl.returncode == 0:
                data = json.loads(dl.stdout)
                return filename, data
        except json.JSONDecodeError:
            pass

    print("⚠️  raw_url取得失敗 → git clone にフォールバック...")
    return _fetch_via_git_clone(gist_id, candidate_files)

# ---------------------------------------------------------------------------
# 移動先Gist選択
# ---------------------------------------------------------------------------

def select_promote_gist_from_master(full_data):
    user_gists = full_data.get("user_gists", {})
    if not user_gists:
        return None
    seen = set()
    unique_gists = []
    for gist_id in user_gists.values():
        if gist_id not in seen:
            unique_gists.append(gist_id)
            seen.add(gist_id)
    return unique_gists[-1] if unique_gists else None

# ---------------------------------------------------------------------------
# ID管理
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# スクレイピング
# ---------------------------------------------------------------------------

def run_extraction(args, skip_ids_file):
    if args.foryou:
        cmd = [
            sys.executable, "scripts/extract_foryou.py",
            "-n", str(args.num),
            "--skip-ids-file", skip_ids_file,
        ]
        print(f"🚀 Running ForYou Extraction: {' '.join(cmd)}")
    else:
        cmd = [
            sys.executable, "scripts/extract_media.py",
            "--mode", args.mode,
            "-n", str(args.num),
            "--skip-ids-file", skip_ids_file,
        ]
        if args.user:
            cmd.extend(["-u", args.user])
        elif args.hashtag:
            cmd.extend(["--hashtag", args.hashtag])
        if args.stop_on_existing:
            cmd.append("--stop-on-existing")
        print(f"🚀 Running Media Extraction: {' '.join(cmd)}")
        
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print("❌ Extraction failed.")
        sys.exit(1)

def parse_tweets_js():
    if not os.path.exists(TWEETS_JS):
        print("❌ tweets.js not found.")
        sys.exit(1)
    with open(TWEETS_JS, 'r', encoding='utf-8') as f:
        content = f.read()
    json_str = re.sub(r'^window\.YTD\.tweets\.part0\s*=\s*', '', content)
    raw_tweets = json.loads(json_str)

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

# ---------------------------------------------------------------------------
# マージ
# ---------------------------------------------------------------------------

def append_tweets(existing_tweets, new_tweets):
    if not new_tweets:
        return existing_tweets

    existing_ids = {t.get("id_str") for t in existing_tweets if t.get("id_str")}
    unique_new = [t for t in new_tweets if t.get("id_str") not in existing_ids]
    if not unique_new:
        return existing_tweets

    result = unique_new + existing_tweets
    print(f"✨ Appended: {len(unique_new)} new tweets to head")
    return result

# ---------------------------------------------------------------------------
# Gist作成・移動
# ---------------------------------------------------------------------------

def create_gist_for_user(user, tweets):
    """新しいGistを作成してユーザのツイートを格納し、Gist IDを返す"""
    data = {
        "user_screen_name": user,
        "user_gists": {},
        "tweets": tweets
    }
    fd, tmp_file = tempfile.mkstemp(suffix=".json", prefix=f"new_gist_{user}_")
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        result = subprocess.run(
            ["gh", "gist", "create", tmp_file, "-p",
             "--filename", "data.json",
             "-d", f"Gallery Data for @{user}"],
            capture_output=True, text=True,
        )
    finally:
        if os.path.exists(tmp_file):
            os.unlink(tmp_file)

    if result.returncode != 0:
        print(f"❌ 新規Gist作成失敗: {result.stderr}")
        sys.exit(1)

    gist_url = result.stdout.strip().rstrip("/")
    new_gist_id = gist_url.split("/")[-1]
    return new_gist_id

def update_or_migrate_user_gist(promote_gist_id, promote_filename, promote_data, user, merged_tweets):
    """ユーザGistを更新する。GIST_MAX_TWEETSを超える場合は新規Gistを作成し移動する。"""
    if not is_master_gist_format(promote_data):
        print(f"⚠️  警告: 移動先Gist {promote_gist_id} がMaster形式ではありません。既存データを保持しつつ変換します。")
        legacy_tweets = []
        if isinstance(promote_data, dict):
            if "users" in promote_data:
                for u_data in promote_data["users"].values():
                    legacy_tweets.extend(u_data.get("tweets", []))
            else:
                legacy_tweets.extend(promote_data.get("tweets", []))
        elif isinstance(promote_data, list):
            legacy_tweets.extend(promote_data)
        promote_data = {"user_screen_name": "", "user_gists": {}, "tweets": legacy_tweets}

    # 他ユーザのツイートも含めた合計件数を計算
    other_tweets = [t for t in promote_data.get("tweets", []) if not _tweet_belongs_to_user(t, user)]
    current_total = len(other_tweets)

    if current_total + len(merged_tweets) > GIST_MAX_TWEETS:
        print(f"⚠️  追加すると {GIST_MAX_TWEETS} 件を超えるため、新規Gistを作成します...")
        new_gist_id = create_gist_for_user(user, merged_tweets)
        print(f"🆕 新規Gist作成: {new_gist_id}  (@{user}: {len(merged_tweets)} 件)")
        
        # 古いGistからユーザデータを削除する
        updated_promote = dict(promote_data)
        updated_promote["tweets"] = other_tweets
        fd, tmp_file = tempfile.mkstemp(suffix=".json", prefix="promote_del_")
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                json.dump(updated_promote, f, ensure_ascii=False, indent=2)
            subprocess.run(["gh", "gist", "edit", promote_gist_id, "-f", promote_filename, tmp_file])
            print(f"🧹 古いGist ({promote_gist_id}) から @{user} のデータを削除しました。")
        finally:
            if os.path.exists(tmp_file):
                os.unlink(tmp_file)
        
        return new_gist_id

    # 既存の promote Gist に追加
    updated_promote = dict(promote_data)
    updated_promote["tweets"] = merged_tweets + other_tweets
    
    fd, tmp_file = tempfile.mkstemp(suffix=".json", prefix="promote_upd_")
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(updated_promote, f, ensure_ascii=False, indent=2)
        result = subprocess.run(
            ["gh", "gist", "edit", promote_gist_id, "-f", promote_filename, tmp_file],
            capture_output=True, text=True,
        )
    finally:
        if os.path.exists(tmp_file):
            os.unlink(tmp_file)

    if result.returncode != 0:
        print(f"❌ 対象ユーザGist更新失敗: {result.stderr}")
        sys.exit(1)

    after_total = current_total + len(merged_tweets)
    print(f"✅ @{user} のデータを Gist {promote_gist_id} に保存しました (合計 {after_total} 件)")
    return promote_gist_id

# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def process_multi_user_append(master_data, new_tweets, promote_gist_id_override=None):
    """
    複数ユーザが混在する new_tweets をマスターGistデータに反映する
    """
    user_groups = group_tweets_by_user(new_tweets)
    print(f"👥 Users in extracted data: {len(user_groups)}")

    user_gists_map = master_data.get("user_gists", {})
    master_tweets = master_data.get("tweets", [])
    
    migrated_count = 0

    for user, tweets in user_groups.items():
        if user == "Unknown":
            master_tweets = append_tweets(master_tweets, tweets)
            continue
            
        print(f"--- Processing @{user} ({len(tweets)} new tweets) ---")

        promote_gist_id = promote_gist_id_override
        is_existing_user = user in user_gists_map
        if not promote_gist_id:
            if is_existing_user:
                promote_gist_id = user_gists_map[user]
            else:
                promote_gist_id = select_promote_gist_from_master(master_data)

        if not promote_gist_id:
            print("⚠️ 既存のユーザGistが見つかりません。新規作成します。")
            promote_gist_id = create_gist_for_user(user, [])

        promote_filename, promote_data = fetch_gist_data(promote_gist_id)
        existing_tweets = get_user_tweets(promote_data, user)
        
        merged = append_tweets(existing_tweets, tweets)
        
        if len(merged) == len(existing_tweets):
            print(f"ℹ️ @{user}: 全て既存ポストのためスキップします。")
            continue
            
        migrated_count += (len(merged) - len(existing_tweets))
        final_user_gist_id = update_or_migrate_user_gist(promote_gist_id, promote_filename, promote_data, user, merged)

        user_gists_map[user] = final_user_gist_id
        master_tweets = [t for t in master_tweets if extract_username(t) != user]
        
        rep = dict(merged[0])
        rep["gist_id"] = final_user_gist_id
        master_tweets.insert(0, rep)

    print(f"📊 Total migrated to user Gists: {migrated_count} tweets")
    master_data["user_gists"] = user_gists_map
    master_data["tweets"] = master_tweets
    return master_data


def main():
    args = parse_args()

    if not args.user and not args.hashtag and not args.foryou:
        print("❌ Error: --user, --hashtag または --foryou のいずれかが必要です。")
        sys.exit(1)

    target_label = "ForYou" if args.foryou else (f"#{args.hashtag}" if args.hashtag else f"@{args.user}")
    print(f"🎯 Target: {target_label}")

    # 1. 既存Gistデータ取得
    gist_filename, full_data = fetch_gist_data(args.gist_id)

    # 2. フォーマット強制
    if not is_master_gist_format(full_data):
        print(f"❌ Error: Gist {args.gist_id} is not in Master format (missing 'user_gists').")
        print("Support for other formats has been removed. Please use a master Gist.")
        sys.exit(1)
    
    # 3. 既存ID抽出
    skip_ids_file = ""
    if args.user and not args.foryou:
        user_gists = full_data.get("user_gists", {})
        if args.user in user_gists:
            _, p_data = fetch_gist_data(user_gists[args.user])
            existing_tweets = get_user_tweets(p_data, args.user)
        else:
            existing_tweets = []
        skip_ids_file = write_skip_ids_file(get_existing_ids_ordered(existing_tweets))
    else:
        # 複数ユーザ（foryou/hashtag）の場合は全代表ツイートをスキップ用にする
        skip_ids_file = write_skip_ids_file(get_existing_ids_ordered(full_data.get("tweets", [])))

    # 4. 新規ポスト取得
    try:
        run_extraction(args, skip_ids_file)
    finally:
        if os.path.exists(skip_ids_file):
            os.unlink(skip_ids_file)

    new_tweets = parse_tweets_js()
    print(f"📥 New tweets extracted: {len(new_tweets)}")
    if not new_tweets:
        print("✅ 取得できた新規ツイートはありませんでした。")
        sys.exit(0)

    # 5. データマージ（常にプロセス経由）
    final_output = process_multi_user_append(full_data, new_tweets, args.promote_gist_id)

    # 6. ローカルに保存
    output_file = "assets/data/data.json"
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, ensure_ascii=False, indent=2)

    # 7. Gist更新
    print(f"☁️ Updating Gist ({args.gist_id})...")
    result = subprocess.run(
        ["gh", "gist", "edit", args.gist_id, "-f", gist_filename, output_file],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        print(f"✅ Gist updated successfully! Target: {target_label}")
    else:
        print(f"❌ Gist update failed: {result.stderr}")
        sys.exit(1)

if __name__ == "__main__":
    main()
