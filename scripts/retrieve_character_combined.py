#!/usr/bin/env python3
"""
テキスト抽出と顔認識抽出を組み合わせてキャラクターGistを構築する。

フロー（キャラクターごとに順番に実行）:
  Phase 1: full_text にキャラクター名を含むポストを収集し Gist を作成/更新
  Phase 2: Phase 1 の結果を顔リファレンスとして使い、全ユーザーGistを顔スキャン

処理済ポストはローカルに記録し、次回はスキップする（tweet ID 単位）。
  デフォルト保存先: ~/.cache/x-post-gallery/character_scan_state.json

Usage:
    python3 scripts/retrieve_character_combined.py -c 松本麗世 姫野ひなの 菊地姫奈
    python3 scripts/retrieve_character_combined.py -c 松本麗世 -g <master_gist_id>
    python3 scripts/retrieve_character_combined.py -c 松本麗世 --threshold 0.55 --max-images 100
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import requests

# ---------------------------------------------------------------------------
# InsightFace 初期化（遅延ロード）
# ---------------------------------------------------------------------------

_face_app = None


def get_face_app():
    global _face_app
    if _face_app is None:
        from insightface.app import FaceAnalysis
        _face_app = FaceAnalysis(
            name='buffalo_l',
            providers=['CUDAExecutionProvider', 'CPUExecutionProvider'],
        )
        _face_app.prepare(ctx_id=0, det_size=(640, 640))
    return _face_app


# ---------------------------------------------------------------------------
# 状態管理（処理済 tweet ID 記録）
# ---------------------------------------------------------------------------

DEFAULT_STATE_FILE = os.path.expanduser(
    '~/.cache/x-post-gallery/character_scan_state.json'
)


def load_state(path: str) -> dict:
    """状態ファイルを読み込む。存在しない場合は空の状態を返す。"""
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    return {'text_checked': {}, 'face_checked': {}}


def save_state(state: dict, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    print(f'  💾 状態を保存しました: {path}')


def get_checked_ids(state: dict, phase: str, char_name: str) -> set[str]:
    return set(state.get(phase, {}).get(char_name, []))


def mark_checked(state: dict, phase: str, char_name: str, ids: list[str]) -> None:
    """ids を処理済として state に追加する。"""
    bucket = state.setdefault(phase, {}).setdefault(char_name, [])
    existing = set(bucket)
    new_ids = [i for i in ids if i not in existing]
    bucket.extend(new_ids)


# ---------------------------------------------------------------------------
# Gist アクセス
# ---------------------------------------------------------------------------

def fetch_gist_raw(gist_id: str) -> tuple[str, dict]:
    result = subprocess.run(
        ['gh', 'api', f'gists/{gist_id}'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f'Gist取得失敗 ({gist_id}): {result.stderr.strip()}')

    meta = json.loads(result.stdout)
    for filename in ['data.json', 'gallary_data.json']:
        file_info = meta.get('files', {}).get(filename)
        if not file_info:
            continue
        raw_url = file_info.get('raw_url')
        if not raw_url:
            continue
        resp = requests.get(raw_url, timeout=30)
        if resp.status_code == 200 and resp.text.strip():
            return filename, resp.json()
    raise RuntimeError(f'data.json が見つかりません ({gist_id})')


def get_gist_id(entry) -> str | None:
    if isinstance(entry, dict):
        return entry.get('gist_id')
    return entry if isinstance(entry, str) else None


def get_tweets(gist_data: dict, key: str) -> list[dict]:
    users = gist_data.get('users', {})
    if key in users:
        return users[key].get('tweets', [])
    return gist_data.get('tweets', [])


def create_secret_gist(data: dict, description: str) -> str:
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
        return result.stdout.strip().rstrip('/').split('/')[-1]
    finally:
        if os.path.exists(tmp_file):
            os.unlink(tmp_file)
        if os.path.isdir(tmpdir):
            os.rmdir(tmpdir)


def update_gist(gist_id: str, filename: str, data: dict) -> None:
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


# ---------------------------------------------------------------------------
# 画像取得・顔検出
# ---------------------------------------------------------------------------

def download_image(url: str):
    try:
        resp = requests.get(url, timeout=15)
        if resp.status_code != 200:
            return None
        import cv2
        arr = np.frombuffer(resp.content, np.uint8)
        return cv2.imdecode(arr, cv2.IMREAD_COLOR)
    except Exception as e:
        print(f'  [WARN] 画像DL失敗: {e}', file=sys.stderr)
        return None


def extract_face_embeddings(img) -> list[np.ndarray]:
    if img is None:
        return []
    try:
        faces = get_face_app().get(img)
        result = []
        for f in faces:
            if f.embedding is None:
                continue
            norm = np.linalg.norm(f.embedding)
            if norm > 0:
                result.append(f.embedding / norm)
        return result
    except Exception as e:
        print(f'  [WARN] 顔検出失敗: {e}', file=sys.stderr)
        return []


def max_cosine_similarity(embedding: np.ndarray,
                           ref_embeddings: list[np.ndarray]) -> float:
    if not ref_embeddings:
        return 0.0
    return float(max(np.dot(embedding, ref) for ref in ref_embeddings))


def build_ref_embeddings(tweets: list[dict], max_images: int) -> list[np.ndarray]:
    embeddings: list[np.ndarray] = []
    processed = 0
    for tweet in tweets:
        if processed >= max_images:
            break
        for url in tweet.get('media_urls', []):
            img = download_image(url)
            processed += 1
            embeddings.extend(extract_face_embeddings(img))
            if processed >= max_images:
                break
    return embeddings


# ---------------------------------------------------------------------------
# Phase 1: テキスト抽出
# ---------------------------------------------------------------------------

def phase1_text(
    char_name: str,
    master_data: dict,
    state: dict,
    state_file: str,
) -> tuple[str | None, str, list[dict]]:
    """
    full_text にキャラクター名を含むポストを収集し、キャラクターGistを作成/更新する。
    戻り値: (char_gist_id, char_filename, all_text_tweets)
             char_gist_id は作成/更新失敗時 None
    """
    print(f'\n{"="*60}')
    print(f'[Phase 1 - text] {char_name}')
    print(f'{"="*60}')

    user_gists_map = master_data.get('user_gists', {})
    character_gists_map = master_data.get('character_gists', {})

    text_checked_ids = get_checked_ids(state, 'text_checked', char_name)
    print(f'  スキップ済みID数（text）: {len(text_checked_ids)}')

    # 既存キャラクターGistを取得（あれば）
    char_entry = character_gists_map.get(char_name)
    char_gist_id = get_gist_id(char_entry) if char_entry else None
    char_filename = 'data.json'
    existing_tweets: list[dict] = []

    if char_gist_id:
        print(f'  既存キャラクターGist ({char_gist_id}) を取得中...')
        try:
            char_filename, char_gist_data = fetch_gist_raw(char_gist_id)
            existing_tweets = get_tweets(char_gist_data, char_name)
            print(f'  既存ポスト数: {len(existing_tweets)}')
        except RuntimeError as e:
            print(f'  [WARN] {e} → 新規作成します')
            char_gist_id = None

    # 既存ポストに match_source="text" をタグ付け（未設定のもの）
    existing_ids: set[str] = {t['id_str'] for t in existing_tweets if t.get('id_str')}
    tagged_existing: list[dict] = []
    for tweet in existing_tweets:
        t = dict(tweet)
        t.setdefault('match_source', 'text')
        tagged_existing.append(t)

    # 全ユーザーGistをテキストスキャン
    # gist_id 単位でキャッシュし重複フェッチを防ぐ
    unique_gist_ids = {get_gist_id(v) for v in user_gists_map.values() if get_gist_id(v)}
    gist_data_cache: dict[str, dict | None] = {}
    newly_found: list[dict] = []
    newly_checked_ids: list[str] = []
    total = len(unique_gist_ids)
    print(f'  ユーザーGist数: {total}')

    for gi, gid in enumerate(unique_gist_ids):
        print(f'  [{gi+1:3d}/{total}] {gid[:8]}...', end=' ', flush=True)

        if gid not in gist_data_cache:
            try:
                _, gd = fetch_gist_raw(gid)
                gist_data_cache[gid] = gd
                print('OK', end=' ')
            except RuntimeError as e:
                print(f'SKIP ({e})')
                gist_data_cache[gid] = None
                continue
        else:
            gd = gist_data_cache[gid]
            print('(cached)', end=' ')

        if gd is None:
            print()
            continue

        gist_found = 0
        for username, udata in gd.get('users', {}).items():
            for tweet in udata.get('tweets', []):
                tid = tweet.get('id_str')
                if not tid:
                    continue
                if tid in text_checked_ids or tid in existing_ids:
                    continue
                newly_checked_ids.append(tid)
                if char_name in tweet.get('full_text', ''):
                    t = dict(tweet)
                    t['match_source'] = 'text'
                    t.setdefault('username', username)
                    newly_found.append(t)
                    gist_found += 1

        print(f'+{gist_found}')

    print(f'\n  新規テキストマッチ: {len(newly_found)}件  (スキャン: {len(newly_checked_ids)}件)')

    # 状態を更新・保存
    mark_checked(state, 'text_checked', char_name, newly_checked_ids)
    save_state(state, state_file)

    # 既存 + 新規をマージ（id_str で重複除去）
    all_text_tweets = tagged_existing + newly_found
    seen: set[str] = set()
    deduped: list[dict] = []
    for t in all_text_tweets:
        tid = t.get('id_str')
        if tid and tid in seen:
            continue
        if tid:
            seen.add(tid)
        deduped.append(t)

    if not deduped:
        print(f'  ⚠️  ポストが0件のためGistの作成/更新をスキップします')
        return None, char_filename, []

    gist_content = {'users': {char_name: {'tweets': deduped}}}

    if char_gist_id:
        print(f'  🔄 既存Gist ({char_gist_id}) を更新中...')
        try:
            update_gist(char_gist_id, char_filename, gist_content)
            print(f'  ✅ 更新完了（計 {len(deduped)} 件）')
        except RuntimeError as e:
            print(f'  ❌ {e}')
            return None, char_filename, deduped
    else:
        print(f'  ✨ 新規 secret Gist を作成中...')
        try:
            char_gist_id = create_secret_gist(
                gist_content, f'Character Gallery: {char_name}'
            )
            master_data.setdefault('character_gists', {})[char_name] = char_gist_id
            print(f'  ✅ 作成完了 (ID: {char_gist_id}, 計 {len(deduped)} 件)')
        except RuntimeError as e:
            print(f'  ❌ {e}')
            return None, char_filename, deduped

    return char_gist_id, char_filename, deduped


# ---------------------------------------------------------------------------
# Phase 2: 顔抽出
# ---------------------------------------------------------------------------

def phase2_face(
    char_name: str,
    char_gist_id: str,
    char_filename: str,
    text_tweets: list[dict],
    master_data: dict,
    state: dict,
    state_file: str,
    threshold: float,
    max_ref_images: int,
    max_images_per_user: int,
) -> None:
    """
    text_tweets を顔リファレンスとして全ユーザーGistをスキャンし、
    face-matched ポストをキャラクターGistに追加する。
    """
    print(f'\n{"="*60}')
    print(f'[Phase 2 - face] {char_name}')
    print(f'{"="*60}')

    user_gists_map = master_data.get('user_gists', {})
    character_gists_map = master_data.get('character_gists', {})

    face_checked_ids = get_checked_ids(state, 'face_checked', char_name)
    print(f'  スキップ済みID数（face）: {len(face_checked_ids)}')

    # リファレンス embedding 構築
    print(f'  リファレンス顔特徴を抽出中（最大{max_ref_images}枚）...')
    ref_embeddings = build_ref_embeddings(text_tweets, max_ref_images)
    print(f'  取得 embedding 数: {len(ref_embeddings)}')
    if not ref_embeddings:
        print(f'  ❌ 顔 embedding が抽出できませんでした。Phase 2 をスキップします。')
        return

    # 他キャラクター除外ID セット構築
    text_ids: set[str] = {t['id_str'] for t in text_tweets if t.get('id_str')}
    excluded_ids: set[str] = set(text_ids) | face_checked_ids

    print(f'  他キャラクターの除外IDを収集中...')
    for other_char, other_entry in character_gists_map.items():
        if other_char == char_name:
            continue
        other_gist_id = get_gist_id(other_entry)
        if not other_gist_id:
            continue
        try:
            _, other_data = fetch_gist_raw(other_gist_id)
            other_tweets = get_tweets(other_data, other_char)
            ids = {t['id_str'] for t in other_tweets if t.get('id_str')}
            excluded_ids |= ids
            print(f'    {other_char}: {len(ids)} IDを除外')
        except RuntimeError as e:
            print(f'    [WARN] {other_char} の取得失敗、スキップ: {e}')

    # 同じGist IDを持つユーザーをグループ化
    gist_to_users: dict[str, list[str]] = {}
    for username, entry in user_gists_map.items():
        gid = get_gist_id(entry)
        if gid:
            gist_to_users.setdefault(gid, []).append(username)

    gist_cache: dict[str, dict | None] = {}
    face_matched: list[dict] = []
    newly_face_checked_ids: list[str] = []
    total_gists = len(gist_to_users)

    limit_str = str(max_images_per_user) if max_images_per_user > 0 else '制限なし'
    print(f'  ユーザーGist数: {total_gists}  threshold: {threshold}  max_images: {limit_str}')

    for gi, (gid, usernames_in_gist) in enumerate(gist_to_users.items()):
        label = ', '.join(usernames_in_gist[:2])
        if len(usernames_in_gist) > 2:
            label += f' +{len(usernames_in_gist) - 2}'
        print(f'  [{gi+1:3d}/{total_gists}] {gid[:8]}... ({label})', end=' ', flush=True)

        if gid not in gist_cache:
            try:
                _, gd = fetch_gist_raw(gid)
                gist_cache[gid] = gd
            except RuntimeError as e:
                print(f'SKIP ({e})')
                gist_cache[gid] = None
                continue

        gd = gist_cache[gid]
        if gd is None:
            print('SKIP')
            continue

        gist_found = 0
        for username in usernames_in_gist:
            tweets = get_tweets(gd, username)

            # 最初の1枚に顔が検出されなければアニメ/風景とみなしてスキップ
            first_url = next(
                (url for t in tweets for url in t.get('media_urls', [])),
                None,
            )
            if first_url is None:
                continue
            if not extract_face_embeddings(download_image(first_url)):
                continue

            images_since_match = 0

            for tweet in tweets:
                tid = tweet.get('id_str')
                if not tid or tid in excluded_ids:
                    continue

                if max_images_per_user > 0 and images_since_match >= max_images_per_user:
                    break

                # このツイートを処理済みとしてマーク（マッチ有無にかかわらず）
                newly_face_checked_ids.append(tid)
                excluded_ids.add(tid)  # 同一ランでの重複処理を防ぐ

                tweet_matched = False
                for url in tweet.get('media_urls', []):
                    if max_images_per_user > 0 and images_since_match >= max_images_per_user:
                        break
                    img = download_image(url)
                    images_since_match += 1

                    for emb in extract_face_embeddings(img):
                        sim = max_cosine_similarity(emb, ref_embeddings)
                        if sim >= threshold:
                            t = dict(tweet)
                            t['match_source'] = 'face'
                            t['face_similarity'] = round(sim, 3)
                            t.setdefault('username', username)
                            face_matched.append(t)
                            gist_found += 1
                            tweet_matched = True
                            images_since_match = 0  # ウィンドウをリセット
                            break

                    if tweet_matched:
                        break

        print(f'+{gist_found}')

    print(f'\n  新規 face-matched ポスト数: {len(face_matched)}')

    # 状態を更新・保存（マッチ有無にかかわらず処理済IDを記録）
    mark_checked(state, 'face_checked', char_name, newly_face_checked_ids)
    save_state(state, state_file)

    if not face_matched:
        print(f'  新規 face-matched ポストなし。Gistの更新をスキップします。')
        return

    # 現在のキャラクターGistを再取得してマージ
    try:
        _, current_char_data = fetch_gist_raw(char_gist_id)
        current_tweets = get_tweets(current_char_data, char_name)
    except RuntimeError:
        current_tweets = list(text_tweets)

    all_tweets = current_tweets + face_matched
    seen: set[str] = set()
    deduped: list[dict] = []
    for t in all_tweets:
        tid = t.get('id_str')
        if tid and tid in seen:
            continue
        if tid:
            seen.add(tid)
        deduped.append(t)

    text_count = sum(1 for t in deduped if t.get('match_source') == 'text')
    face_count = sum(1 for t in deduped if t.get('match_source') == 'face')
    print(f'  最終ポスト数: {len(deduped)}  (text: {text_count}, face: {face_count})')

    new_content = {'users': {char_name: {'tweets': deduped}}}
    try:
        update_gist(char_gist_id, char_filename, new_content)
        print(f'  ✅ Gist 更新完了 ({char_gist_id})')
    except RuntimeError as e:
        print(f'  ❌ {e}')


# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='テキスト抽出 + 顔認識抽出を組み合わせてキャラクターGistを構築する',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
例:
  python3 scripts/retrieve_character_combined.py \\
      -c 松本麗世 姫野ひなの 菊地姫奈 齋藤飛鳥 西野七瀬 志田音々 遠藤さくら
''',
    )
    parser.add_argument(
        '-c', '--chars', nargs='+', required=True, metavar='キャラクター名',
        help='対象キャラクター名（スペース区切りで複数指定可）',
    )
    parser.add_argument(
        '-g', '--gist-id', default=None,
        help='マスターGist ID（省略時は MASTER_GIST_ID 環境変数）',
    )
    parser.add_argument(
        '--character-gist-id', default=None,
        help='キャラクターGist ID（省略時は CHARACTER_GIST_ID 環境変数）',
    )
    parser.add_argument(
        '--threshold', type=float, default=0.5,
        help='顔マッチングの cosine similarity 閾値（デフォルト: 0.5）',
    )
    parser.add_argument(
        '--max-ref-images', type=int, default=100,
        help='リファレンス顔特徴の抽出に使う最大画像数（デフォルト: 100）',
    )
    parser.add_argument(
        '--max-images', type=int, default=50,
        help='スキャン時のユーザーあたり最大画像数（0=制限なし、デフォルト: 50）',
    )
    parser.add_argument(
        '--state-file', default=DEFAULT_STATE_FILE,
        help=f'処理済ID記録ファイル（デフォルト: {DEFAULT_STATE_FILE}）',
    )
    args = parser.parse_args()

    master_gist_id = args.gist_id or os.environ.get('MASTER_GIST_ID', '')
    if not master_gist_id:
        print('❌ マスターGist IDが指定されていません。-g または MASTER_GIST_ID を設定してください。')
        sys.exit(1)

    char_meta_gist_id = args.character_gist_id or os.environ.get('CHARACTER_GIST_ID', '')
    if not char_meta_gist_id:
        print('❌ キャラクターGist IDが指定されていません。--character-gist-id または CHARACTER_GIST_ID を設定してください。')
        sys.exit(1)

    print(f'🔍 マスターGist ({master_gist_id}) を取得中...')
    try:
        master_filename, master_data = fetch_gist_raw(master_gist_id)
    except RuntimeError as e:
        print(f'❌ {e}')
        sys.exit(1)

    print(f'🔍 キャラクターGist ({char_meta_gist_id}) を取得中...')
    try:
        char_meta_filename, char_meta_data = fetch_gist_raw(char_meta_gist_id)
    except RuntimeError as e:
        print(f'❌ {e}')
        sys.exit(1)

    print(f'  ユーザーGist数: {len(master_data.get("user_gists", {}))} 人')
    print(f'  キャラクターGist数: {len(char_meta_data.get("character_gists", {}))} キャラ')
    print(f'  対象キャラクター: {", ".join(args.chars)}')

    # character_gists を master_data にマージ（phase1/phase2 が参照するため）
    master_data['character_gists'] = char_meta_data.get('character_gists', {})

    state = load_state(args.state_file)
    print(f'  状態ファイル: {args.state_file}')

    for char_name in args.chars:
        # Phase 1: テキスト抽出
        char_gist_id, char_filename, text_tweets = phase1_text(
            char_name=char_name,
            master_data=master_data,
            state=state,
            state_file=args.state_file,
        )

        if not char_gist_id:
            print(f'  ⚠️  {char_name}: Phase 2 をスキップします（Gistなし）')
            continue

        # Phase 2: 顔抽出
        phase2_face(
            char_name=char_name,
            char_gist_id=char_gist_id,
            char_filename=char_filename,
            text_tweets=text_tweets,
            master_data=master_data,
            state=state,
            state_file=args.state_file,
            threshold=args.threshold,
            max_ref_images=args.max_ref_images,
            max_images_per_user=args.max_images,
        )

    # キャラクターGist を更新（character_gists に新規Gistが追加された可能性があるため）
    character_gists_map = master_data.get('character_gists', {})
    char_meta_data['character_gists'] = character_gists_map

    # 各キャラクター子Gistから代表ツイート（1件目）を収集
    print(f'\n🖼️  代表ツイートを収集中...')
    representative_tweets = []
    for char_name_key, char_gist_entry in character_gists_map.items():
        child_gist_id = get_gist_id(char_gist_entry)
        if not child_gist_id:
            continue
        try:
            _, child_data = fetch_gist_raw(child_gist_id)
            child_tweets = get_tweets(child_data, char_name_key)
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

    char_meta_data['tweets'] = representative_tweets

    print(f'\n📝 キャラクターGist ({char_meta_filename}) を更新中...')
    try:
        update_gist(char_meta_gist_id, char_meta_filename, char_meta_data)
        print(f'✅ キャラクターGist 更新完了')
    except RuntimeError as e:
        print(f'❌ {e}')
        sys.exit(1)

    print('\n🎉 すべて完了！')


if __name__ == '__main__':
    main()
