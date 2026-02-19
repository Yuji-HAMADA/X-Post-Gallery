"""
指定ユーザ(またはハッシュタグ)のポストを取得し、既存Gistにアペンドする。
  - 先頭1件はGistの先頭に挿入、残りは末尾に追加
  - 既存IDが見つかったら取得を停止（--stop-on-existing）
  - 3種類のGistフォーマットに対応:
      master : {user_screen_name, user_gists:{user:gist_id}, tweets:[flat]}
      multi  : {users:{user:{tweets:[]}}}
      single : {user_screen_name, tweets:[]}
  - master形式でuser_gistsが存在する場合: 閾値到達で自動的に移動先Gistを選択し移動
    マスターGistには代表1件（gist_idフィールド付き）を残す
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
MIGRATE_THRESHOLD = 2   # この件数以上になったら移動
GIST_MAX_TWEETS = 1000  # 移動先Gistの上限

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-g", "--gist-id", required=True, help="Append対象のGist ID")
    parser.add_argument("-u", "--user", default=None, help="Target user ID (--user または --hashtag のどちらか必須)")
    parser.add_argument("--hashtag", type=str, default=None, help="Target hashtag (#なし)")
    parser.add_argument("-m", "--mode", default="post_only", choices=["all", "post_only"])
    parser.add_argument("-n", "--num", type=int, default=100, help="最大取得件数")
    parser.add_argument("-s", "--stop-on-existing", action="store_true", help="既存IDに当たったら停止（ストップオンモード）")
    parser.add_argument("--force-empty", action="store_true", help="Gistが0件でも強制続行（通常は安全のため中断）")
    parser.add_argument("-p", "--promote-gist-id", default=None,
                        help="移動先Gist IDを手動指定（省略時はuser_gistsから自動選択）")
    return parser.parse_args()

# ---------------------------------------------------------------------------
# Gist フォーマット判定
# ---------------------------------------------------------------------------

def is_master_gist_format(data):
    """マスターGist形式: {user_gists:{...}, tweets:[flat]} かどうか判定"""
    return isinstance(data, dict) and "user_gists" in data

def is_multi_user_format(data):
    """マルチユーザ形式: {users:{username:{tweets:[]}}} かどうか判定"""
    return isinstance(data, dict) and "users" in data and not is_master_gist_format(data)

def _tweet_belongs_to_user(tweet, user):
    """ツイートが指定ユーザのものかどうか判定"""
    if f"x.com/{user}/status/" in tweet.get("post_url", ""):
        return True
    if tweet.get("full_text", "").startswith(f"@{user}:"):
        return True
    return False

def get_user_tweets(data, user):
    """データからユーザのツイートを取得（フォーマット自動判定）"""
    if is_master_gist_format(data):
        # flat tweetsから対象ユーザのもののみ抽出
        if not user:
            return data.get("tweets", [])
        return [t for t in data.get("tweets", []) if _tweet_belongs_to_user(t, user)]
    if is_multi_user_format(data):
        return data.get("users", {}).get(user, {}).get("tweets", [])
    # single-user形式
    return data.get("tweets", []) if isinstance(data, dict) else (data if isinstance(data, list) else [])

# ---------------------------------------------------------------------------
# Gist 取得
# ---------------------------------------------------------------------------

def _fetch_via_git_clone(gist_id, candidate_files):
    """raw_url失敗時のフォールバック: git clone でGistを取得"""
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
    """GistからJSON取得。(filename, full_data) を返す。
    curlが失敗した場合は git clone にフォールバック。
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
            token = os.environ.get("GH_TOKEN", "")
            curl_cmd = ["curl", "-sf", "-L"]  # -f: HTTPエラー時に失敗扱い
            if token:
                curl_cmd += ["-H", f"Authorization: Bearer {token}"]
            curl_cmd.append(raw_url)
            dl = subprocess.run(curl_cmd, capture_output=True, text=True)
            if dl.returncode == 0:
                data = json.loads(dl.stdout)
                return filename, data
        except json.JSONDecodeError:
            pass

    # Fallback: git clone
    print("⚠️  raw_url取得失敗 → git clone にフォールバック...")
    return _fetch_via_git_clone(gist_id, candidate_files)

# ---------------------------------------------------------------------------
# 移動先Gist選択
# ---------------------------------------------------------------------------

def select_promote_gist_from_master(full_data):
    """user_gists の末尾（最近追加）の一意なGist IDを自動選択して返す"""
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

# ---------------------------------------------------------------------------
# スクレイピング
# ---------------------------------------------------------------------------

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
    """新規tweetsを既存に挿入: 先頭1件→先頭、残り→末尾"""
    if not new_tweets:
        print("ℹ️ No new tweets to append.")
        return existing_tweets

    existing_ids = {t.get("id_str") for t in existing_tweets if t.get("id_str")}
    unique_new = [t for t in new_tweets if t.get("id_str") not in existing_ids]
    if not unique_new:
        print("ℹ️ All tweets already exist. Nothing to append.")
        return existing_tweets

    first = unique_new[0]
    rest = unique_new[1:]
    result = [first] + existing_tweets + rest
    print(f"✨ Appended: 1 to head + {len(rest)} to tail = {len(unique_new)} new tweets")
    return result

# ---------------------------------------------------------------------------
# 出力データ構築
# ---------------------------------------------------------------------------

def build_output(full_data, user, merged_tweets, user_gist_id=None):
    """最終出力データを構築。各フォーマットを保持する。
    user_gist_id が指定された場合（移動後）:
      - master: flatリストから該当ユーザを除き、代表1件（gist_idフィールド付き）を先頭に追加
      - multi : users[user] = {gist_id, tweets:[代表1件]}
    """
    if is_master_gist_format(full_data) and user:
        updated = dict(full_data)
        # 他ユーザのツイートはそのまま保持
        other_tweets = [t for t in updated.get("tweets", []) if not _tweet_belongs_to_user(t, user)]
        if user_gist_id:
            # 代表1件にgist_idを付与してflatリストの先頭へ
            representative = dict(merged_tweets[0])
            representative["gist_id"] = user_gist_id
            updated["tweets"] = [representative] + other_tweets
            # user_gists マッピングにも追加
            user_gists = dict(updated.get("user_gists", {}))
            user_gists[user] = user_gist_id
            updated["user_gists"] = user_gists
        else:
            updated["tweets"] = merged_tweets + other_tweets
        return updated

    if is_multi_user_format(full_data) and user:
        updated = dict(full_data)
        users = dict(updated.get("users", {}))
        if user_gist_id:
            users[user] = {
                "gist_id": user_gist_id,
                "tweets": [merged_tweets[0]],
            }
            if "user_gists" in updated:
                user_gists = dict(updated["user_gists"])
                user_gists[user] = user_gist_id
                updated["user_gists"] = user_gists
        else:
            users[user] = {"tweets": merged_tweets}
        updated["users"] = users
        return updated

    # single-user形式
    user_screen_name = full_data.get("user_screen_name", user or "Unknown") if isinstance(full_data, dict) else (user or "Unknown")
    return {
        "user_screen_name": user or user_screen_name,
        "tweets": merged_tweets,
    }

# ---------------------------------------------------------------------------
# Gist作成・移動
# ---------------------------------------------------------------------------

def create_gist_for_user(user, tweets):
    """新しいGistを作成してユーザのツイートを格納し、Gist IDを返す"""
    data = {"users": {user: {"tweets": tweets}}}
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

def migrate_user_tweets(promote_gist_id, user, tweets):
    """ユーザのツイートを promote Gist（または新規Gist）に移動し、移動先Gist IDを返す"""
    promote_filename, promote_data = fetch_gist_data(promote_gist_id)

    if is_multi_user_format(promote_data):
        current_total = sum(
            len(u.get("tweets", [])) for u in promote_data.get("users", {}).values()
        )
    elif isinstance(promote_data, dict):
        current_total = len(promote_data.get("tweets", []))
    else:
        current_total = len(promote_data) if isinstance(promote_data, list) else 0

    print(f"📊 移動先Gist ({promote_gist_id[:8]}...): 現在 {current_total} 件")

    if current_total + len(tweets) > GIST_MAX_TWEETS:
        print(f"⚠️  追加すると {GIST_MAX_TWEETS} 件を超えるため、新規Gistを作成します...")
        new_gist_id = create_gist_for_user(user, tweets)
        print(f"🆕 新規Gist作成: {new_gist_id}  (@{user}: {len(tweets)} 件)")
        return new_gist_id

    # 既存の promote Gist に追加
    if is_multi_user_format(promote_data):
        updated_promote = dict(promote_data)
        users = dict(updated_promote.get("users", {}))
        users[user] = {"tweets": tweets}
        updated_promote["users"] = users
    else:
        updated_promote = {"users": {user: {"tweets": tweets}}}

    fd, tmp_file = tempfile.mkstemp(suffix=".json", prefix="promote_")
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
        print(f"❌ 移動先Gist更新失敗: {result.stderr}")
        sys.exit(1)

    after_total = current_total + len(tweets)
    print(f"✅ @{user} を Gist {promote_gist_id} に追加 ({len(tweets)} 件 → 合計 {after_total} 件)")
    return promote_gist_id

# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    if not args.user and not args.hashtag:
        print("❌ Error: --user または --hashtag のどちらかが必要です。")
        sys.exit(1)

    target_label = f"#{args.hashtag}" if args.hashtag else f"@{args.user}"
    print(f"🎯 Target: {target_label}")

    # 1. 既存Gistデータ取得
    gist_filename, full_data = fetch_gist_data(args.gist_id)

    # 2. フォーマット判定とユーザのツイート取得
    master = is_master_gist_format(full_data)
    multi_user = is_multi_user_format(full_data)
    existing_tweets = get_user_tweets(full_data, args.user)

    if master:
        total_items = len(full_data.get("tweets", []))
        fmt_label = "master"
    elif multi_user:
        total_items = sum(len(u.get("tweets", [])) for u in full_data.get("users", {}).values())
        fmt_label = "multi-user"
    else:
        total_items = len(existing_tweets)
        fmt_label = "single-user"

    print(f"☁️ Gist: {total_items} items total, {len(existing_tweets)} for {target_label} ({fmt_label}, '{gist_filename}')")

    existing_ids_ordered = get_existing_ids_ordered(existing_tweets)
    print(f"📋 Existing IDs: {len(existing_ids_ordered)}")

    # 新規ユーザ判定（安全チェック用）
    if master:
        is_new_user = not any(_tweet_belongs_to_user(t, args.user) for t in full_data.get("tweets", [])) if args.user else False
    elif multi_user:
        is_new_user = args.user not in full_data.get("users", {})
    else:
        is_new_user = False

    # 安全チェック: 0件は異常（新規ユーザの場合は除く）
    if len(existing_tweets) == 0 and not args.force_empty and not is_new_user:
        print("⚠️  警告: GistのTweet数が0件です。")
        print("   Appendモードなのに既存データが空なのは異常な状態の可能性があります。")
        print("   意図的に空のGistへAppendしたい場合は --force-empty を付けて再実行してください。")
        sys.exit(1)

    # 3. 既存IDファイルを作成（順序付き：連続一致判定用）
    skip_ids_file = write_skip_ids_file(existing_ids_ordered)

    try:
        # 4. 新規ポスト取得
        run_extraction(args.user, args.hashtag, args.mode, args.num, skip_ids_file, args.stop_on_existing)
    finally:
        os.unlink(skip_ids_file)

    # 5. 取得結果をパース
    new_tweets = parse_tweets_js()
    print(f"📥 New tweets extracted: {len(new_tweets)}")

    # 6. アペンド
    merged = append_tweets(existing_tweets, new_tweets)

    # 7. 移動先Gistの決定
    #    -p 手動指定 > user_gists からの自動選択 > 移動なし
    promote_gist_id = args.promote_gist_id
    if not promote_gist_id and args.user and "user_gists" in full_data:
        promote_gist_id = select_promote_gist_from_master(full_data)
        if promote_gist_id:
            print(f"🔍 移動先Gistを自動選択: {promote_gist_id}")

    # 8. 移動判定（閾値到達かつ移動先が決定している場合）
    user_gist_id = None
    if promote_gist_id and args.user and len(merged) >= MIGRATE_THRESHOLD:
        print(f"🔄 @{args.user} が {len(merged)} 件に達しました（閾値: {MIGRATE_THRESHOLD}）→ 移動処理を開始します")
        user_gist_id = migrate_user_tweets(promote_gist_id, args.user, merged)
        print(f"📌 移動先Gist: {user_gist_id}")
        print(f"   マスターGistには代表1件 + gist_id参照を保持します")

    # 9. ローカルに保存
    output_file = "assets/data/data.json"
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    final_output = build_output(full_data, args.user, merged, user_gist_id=user_gist_id)
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, ensure_ascii=False, indent=2)

    if user_gist_id:
        print(f"💾 Saved: マスターGist用 (代表1件 + gist_id) to {output_file}")
    else:
        print(f"💾 Saved: {len(merged)} tweets for {target_label} to {output_file}")

    # 10. ソースGist更新
    print(f"☁️ Updating Gist ({args.gist_id})...")
    result = subprocess.run(
        ["gh", "gist", "edit", args.gist_id, "-f", gist_filename, output_file],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        if user_gist_id:
            print(f"✅ Gist updated! @{args.user} → {user_gist_id}")
        else:
            print(f"✅ Gist updated successfully! Total for {target_label}: {len(merged)} tweets")
    else:
        print(f"❌ Gist update failed: {result.stderr}")
        sys.exit(1)

if __name__ == "__main__":
    main()
