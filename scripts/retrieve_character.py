"""
キャラクター名を含むポストをすべてのユーザーGistから収集し、
キャラクターGist（secret）を作成または再構築してマスターGistに登録する。

Usage:
    python3 scripts/retrieve_character.py -c キャラA キャラB キャラC
    python3 scripts/retrieve_character.py -c キャラA -g <master_gist_id>

キャラクターGistのフォーマットはユーザーGistと同じ:
    { "users": { "<キャラクター名>": { "tweets": [...] } } }

マスターGistの character_gists フィールド（user_gists と同じフォーマット）:
    { "<キャラクター名>": "<gist_id>", ... }
"""
import json
import os
import sys
import argparse
import subprocess
import tempfile


def parse_args():
    parser = argparse.ArgumentParser(
        description='キャラクター名でポストを収集し、Gistを作成/再構築する',
    )
    parser.add_argument(
        '-c', '--chars',
        nargs='+',
        required=True,
        metavar='キャラクター名',
        help='検索するキャラクター名（スペース区切りで複数指定可）',
    )
    parser.add_argument(
        '-g', '--gist-id',
        default=None,
        help='マスターGist ID（省略時は MASTER_GIST_ID 環境変数を使用）',
    )
    parser.add_argument(
        '--character-gist-id',
        default=None,
        help='キャラクターGist ID（省略時は CHARACTER_GIST_ID 環境変数を使用）',
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Gist 取得・書き込み
# ---------------------------------------------------------------------------

def fetch_gist_data(gist_id):
    """gh CLI でGistを取得し、(filename, data_dict) を返す。失敗時は RuntimeError を送出。"""
    result = subprocess.run(
        ['gh', 'api', f'gists/{gist_id}'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f'Gist取得失敗 ({gist_id}): {result.stderr.strip()}')

    gist_meta = json.loads(result.stdout)
    files = gist_meta.get('files', {})

    for filename in ['data.json', 'gallary_data.json']:
        if filename not in files:
            continue
        raw_url = files[filename].get('raw_url')
        if not raw_url:
            continue
        dl = subprocess.run(
            ['curl', '-sf', '-L', raw_url],
            capture_output=True, text=True,
        )
        if dl.returncode == 0 and dl.stdout.strip():
            return filename, json.loads(dl.stdout)

    raise RuntimeError(f'data.json が見つかりません ({gist_id})')


def create_secret_gist(data, description):
    """secret Gistを新規作成して gist_id を返す。失敗時は RuntimeError。"""
    tmpdir = tempfile.mkdtemp()
    tmp_file = os.path.join(tmpdir, 'data.json')
    try:
        with open(tmp_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        result = subprocess.run(
            ['gh', 'gist', 'create', '--desc', description, tmp_file],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f'Gist作成失敗: {result.stderr.strip()}')
        # Output例: https://gist.github.com/username/GIST_ID
        return result.stdout.strip().rstrip('/').split('/')[-1]
    finally:
        if os.path.exists(tmp_file):
            os.unlink(tmp_file)
        if os.path.isdir(tmpdir):
            os.rmdir(tmpdir)


def update_gist(gist_id, filename, data):
    """既存GistのファイルをJSON dataで上書きする。失敗時は RuntimeError。"""
    tmpdir = tempfile.mkdtemp()
    tmp_file = os.path.join(tmpdir, filename)
    try:
        with open(tmp_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        result = subprocess.run(
            ['gh', 'gist', 'edit', gist_id, '-f', filename, tmp_file],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f'Gist更新失敗 ({gist_id}): {result.stderr.strip()}')
    finally:
        if os.path.exists(tmp_file):
            os.unlink(tmp_file)
        if os.path.isdir(tmpdir):
            os.rmdir(tmpdir)


def get_gist_id_from_entry(entry):
    """user_gists / character_gists の値（dict または string）から gist_id を取得"""
    if isinstance(entry, dict):
        return entry.get('gist_id')
    return entry  # legacy string format


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    char_names = args.chars

    # マスターGist ID の解決
    master_gist_id = args.gist_id or os.environ.get('MASTER_GIST_ID', '')
    if not master_gist_id:
        print('❌ マスターGist IDが指定されていません。-g オプションまたは MASTER_GIST_ID 環境変数を設定してください。')
        sys.exit(1)

    char_meta_gist_id = args.character_gist_id or os.environ.get('CHARACTER_GIST_ID', '')
    if not char_meta_gist_id:
        print('❌ キャラクターGist IDが指定されていません。--character-gist-id または CHARACTER_GIST_ID 環境変数を設定してください。')
        sys.exit(1)

    print(f'🔍 マスターGist ({master_gist_id}) を取得中...')
    try:
        master_filename, master_data = fetch_gist_data(master_gist_id)
    except RuntimeError as e:
        print(f'❌ {e}')
        sys.exit(1)

    print(f'🔍 キャラクターGist ({char_meta_gist_id}) を取得中...')
    try:
        char_meta_filename, char_meta_data = fetch_gist_data(char_meta_gist_id)
    except RuntimeError as e:
        print(f'❌ {e}')
        sys.exit(1)

    user_gists_map = master_data.get('user_gists', {})
    character_gists_map = char_meta_data.get('character_gists', {})

    if not user_gists_map:
        print('❌ マスターGistに user_gists フィールドがありません。')
        sys.exit(1)

    unique_user_gist_ids = {get_gist_id_from_entry(v) for v in user_gists_map.values() if get_gist_id_from_entry(v)}
    print(f'👤 ユーザーGist数: {len(user_gists_map)}人 / {len(unique_user_gist_ids)}件のGist')
    print(f'🎭 対象キャラクター: {", ".join(char_names)}\n')

    # キャラクターごとの収集バッファ
    collected = {name: [] for name in char_names}

    # gist_id ごとのキャッシュ（同じGistを複数ユーザーが共有している場合に再取得しない）
    gist_data_cache = {}

    print('📥 全ユーザーGistを巡回してポストを収集します...')
    for username, entry in user_gists_map.items():
        gist_id = get_gist_id_from_entry(entry)
        if not gist_id:
            continue

        if gist_id not in gist_data_cache:
            print(f'  → Gist {gist_id} を取得中...', end=' ', flush=True)
            try:
                _, gist_data = fetch_gist_data(gist_id)
                gist_data_cache[gist_id] = gist_data
                print('OK')
            except RuntimeError as e:
                print(f'SKIP ({e})')
                gist_data_cache[gist_id] = None
                continue
        else:
            gist_data = gist_data_cache[gist_id]

        if gist_data is None:
            continue

        # users.{username}.tweets を対象にキャラクター名を検索
        users_in_gist = gist_data.get('users', {})
        user_tweets = users_in_gist.get(username, {}).get('tweets', [])

        for tweet in user_tweets:
            full_text = tweet.get('full_text', '')
            for char_name in char_names:
                if char_name in full_text:
                    # username フィールドを付与（未設定の場合）
                    tweet_with_user = dict(tweet)
                    if 'username' not in tweet_with_user:
                        tweet_with_user['username'] = username
                    collected[char_name].append(tweet_with_user)

    print()

    # キャラクターGistを作成または再構築
    for char_name in char_names:
        tweets = collected[char_name]
        print(f'🎭 {char_name}: {len(tweets)}件のポストが見つかりました')

        if not tweets:
            print(f'   ⚠️  ポストが0件のためGistの作成/更新をスキップします')
            continue

        gist_content = {
            'users': {
                char_name: {
                    'tweets': tweets,
                }
            }
        }

        existing_entry = character_gists_map.get(char_name)
        existing_gist_id = get_gist_id_from_entry(existing_entry) if existing_entry else None

        if existing_gist_id:
            # 既存Gistを再構築（上書き）
            print(f'   🔄 既存Gist ({existing_gist_id}) を再構築中...')
            try:
                update_gist(existing_gist_id, 'data.json', gist_content)
                print(f'   ✅ 完了')
            except RuntimeError as e:
                print(f'   ❌ {e}')
        else:
            # 新規 secret Gist を作成
            print(f'   ✨ 新規 secret Gist を作成中...')
            try:
                new_gist_id = create_secret_gist(gist_content, f'Character Gallery: {char_name}')
                character_gists_map[char_name] = new_gist_id
                print(f'   ✅ 作成完了 (ID: {new_gist_id})')
            except RuntimeError as e:
                print(f'   ❌ {e}')

    # 各キャラクター子Gistから代表ツイート（1件目）を収集
    print(f'\n🖼️  代表ツイートを収集中...')
    representative_tweets = []
    for char_name_key, char_gist_entry in character_gists_map.items():
        child_gist_id = get_gist_id_from_entry(char_gist_entry)
        if not child_gist_id:
            continue
        try:
            _, child_data = fetch_gist_data(child_gist_id)
            child_tweets = child_data.get('users', {}).get(char_name_key, {}).get('tweets', [])
            if child_tweets:
                first_tweet = child_tweets[0]
                media_urls = first_tweet.get('media_urls', [])
                if media_urls:
                    representative_tweets.append({
                        'id_str': first_tweet.get('id_str', ''),
                        'character': char_name_key,
                        'media_urls': [media_urls[0]],
                    })
                    print(f'  ✅ {char_name_key}')
        except RuntimeError as e:
            print(f'  ⚠️  {char_name_key}: {e}')

    # キャラクターGistの character_gists を更新
    print(f'\n📝 キャラクターGist ({char_meta_filename}) を更新中...')
    char_meta_data['character_gists'] = character_gists_map
    char_meta_data['tweets'] = representative_tweets
    try:
        update_gist(char_meta_gist_id, char_meta_filename, char_meta_data)
        print(f'✅ キャラクターGist 更新完了')
    except RuntimeError as e:
        print(f'❌ {e}')
        sys.exit(1)

    print('\n🎉 完了！')


if __name__ == '__main__':
    main()
