#!/usr/bin/env python3
"""
既存のキャラクターGistから顔特徴を抽出し、全ユーザーGistをスキャンして
類似顔を含むポストをキャラクターGistに追加（再構築）する。

各ポストには match_source タグを付与:
  "text" : full_text のキャラクター名マッチで既存Gistに収録済み
  "face" : 今回の顔認識で新規発見（face_similarity スコアも付与）

他のキャラクターGistに含まれるポストは除外（キャラクター排他）。

Usage:
    python3 scripts/retrieve_character_by_face.py -c キャラA
    python3 scripts/retrieve_character_by_face.py -c キャラA キャラB --threshold 0.6
    python3 scripts/retrieve_character_by_face.py -c キャラA -g <master_gist_id>
    python3 scripts/retrieve_character_by_face.py -c キャラA --max-images 0   # 制限なし
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import requests

# --- InsightFace 初期化（遅延ロード） ---
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
# 画像取得・顔検出
# ---------------------------------------------------------------------------

def download_image(url: str):
    """URL から画像を BGR numpy 配列で返す。失敗時は None。"""
    try:
        resp = requests.get(url, timeout=15)
        if resp.status_code != 200:
            return None
        import cv2
        arr = np.frombuffer(resp.content, np.uint8)
        return cv2.imdecode(arr, cv2.IMREAD_COLOR)
    except Exception as e:
        print(f"  [WARN] 画像DL失敗: {e}", file=sys.stderr)
        return None


def extract_face_embeddings(img) -> list[np.ndarray]:
    """画像から L2 正規化済み顔 embedding のリストを返す。"""
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
        print(f"  [WARN] 顔検出失敗: {e}", file=sys.stderr)
        return []


def max_cosine_similarity(embedding: np.ndarray,
                           ref_embeddings: list[np.ndarray]) -> float:
    """embedding とリファレンス全体の cosine similarity の最大値を返す。"""
    if not ref_embeddings:
        return 0.0
    return float(max(np.dot(embedding, ref) for ref in ref_embeddings))


# ---------------------------------------------------------------------------
# Gist アクセス（gh CLI + requests）
# ---------------------------------------------------------------------------

def fetch_gist_raw(gist_id: str) -> tuple[str, dict]:
    """
    gh CLI でGistメタデータを取得し、data.json の内容を返す。
    戻り値: (filename, data_dict)  失敗時は RuntimeError
    """
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


def get_tweets(gist_data: dict, key: str) -> list[dict]:
    """users.{key}.tweets を返す。フォールバックあり。"""
    users = gist_data.get('users', {})
    if key in users:
        return users[key].get('tweets', [])
    # フォールバック: 直下に tweets
    return gist_data.get('tweets', [])


def get_gist_id(entry) -> str | None:
    """user_gists / character_gists の値（dict または string）から gist_id を取得。"""
    if isinstance(entry, dict):
        return entry.get('gist_id')
    return entry if isinstance(entry, str) else None


def update_gist(gist_id: str, filename: str, data: dict) -> None:
    """既存GistのファイルをJSON dataで上書き。失敗時は RuntimeError。"""
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
# リファレンス embedding 構築
# ---------------------------------------------------------------------------

def build_ref_embeddings(tweets: list[dict], max_images: int) -> list[np.ndarray]:
    """
    キャラクターGistのツイートから顔 embedding を抽出してリファレンスを構築。
    max_images: ダウンロードする最大画像数
    """
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
# キャラクター処理メイン
# ---------------------------------------------------------------------------

def process_character(
    char_name: str,
    master_data: dict,
    threshold: float,
    max_ref_images: int,
    max_images_per_user: int,
) -> None:
    user_gists_map = master_data.get('user_gists', {})
    character_gists_map = master_data.get('character_gists', {})

    # キャラクターGist ID の確認
    char_entry = character_gists_map.get(char_name)
    char_gist_id = get_gist_id(char_entry) if char_entry else None
    if not char_gist_id:
        print(f'❌ "{char_name}" が character_gists に見つかりません。')
        print(f'   先に retrieve_character.py で Gist を作成してください。')
        return

    print(f'\n{"="*60}')
    print(f'🎭 キャラクター: {char_name}  (Gist: {char_gist_id})')
    print(f'{"="*60}')

    # ────────────────────────────────────────────
    # Step 1: 既存キャラクターGistを取得
    # ────────────────────────────────────────────
    print(f'\n[1/5] 既存キャラクターGistを取得...')
    try:
        char_filename, char_gist_data = fetch_gist_raw(char_gist_id)
    except RuntimeError as e:
        print(f'❌ {e}')
        return

    existing_tweets = get_tweets(char_gist_data, char_name)
    existing_ids = {t['id_str'] for t in existing_tweets if t.get('id_str')}
    print(f'  既存ポスト数（text-matched）: {len(existing_tweets)}')

    # 既存ツイートに match_source: "text" を付与（未設定のもののみ）
    tagged_text: list[dict] = []
    for tweet in existing_tweets:
        t = dict(tweet)
        t.setdefault('match_source', 'text')
        tagged_text.append(t)

    # ────────────────────────────────────────────
    # Step 2: リファレンス顔 embedding 構築
    # ────────────────────────────────────────────
    print(f'\n[2/5] リファレンス顔特徴を抽出中（最大{max_ref_images}枚）...')
    ref_embeddings = build_ref_embeddings(existing_tweets, max_ref_images)
    print(f'  取得 embedding 数: {len(ref_embeddings)}')
    if not ref_embeddings:
        print(f'❌ 顔 embedding が抽出できませんでした。対象Gistの画像を確認してください。')
        return

    # ────────────────────────────────────────────
    # Step 3: 他キャラクター除外ID セット構築
    # ────────────────────────────────────────────
    print(f'\n[3/5] 他キャラクターの除外IDを収集中...')
    # 自キャラ既存IDも含める（face スキャンで重複追加しないため）
    excluded_ids: set[str] = set(existing_ids)

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
            print(f'  {other_char}: {len(ids)} IDを除外')
        except RuntimeError as e:
            print(f'  [WARN] {other_char} の取得失敗、スキップ: {e}')

    print(f'  除外ID合計: {len(excluded_ids)}')

    # ────────────────────────────────────────────
    # Step 4: 全ユーザーGistをスキャン
    # ────────────────────────────────────────────
    print(f'\n[4/5] 全ユーザーGistをスキャン中...')
    print(f'  cosine similarity 閾値: {threshold}')
    limit_str = str(max_images_per_user) if max_images_per_user > 0 else '制限なし'
    print(f'  ユーザーあたり最大画像数: {limit_str}')

    # 同じGist IDを持つユーザーをグループ化（1度のフェッチで済む）
    gist_to_users: dict[str, list[str]] = {}
    for username, entry in user_gists_map.items():
        gid = get_gist_id(entry)
        if gid:
            gist_to_users.setdefault(gid, []).append(username)

    gist_cache: dict[str, dict | None] = {}
    face_matched: list[dict] = []
    total_gists = len(gist_to_users)

    for gi, (gid, usernames_in_gist) in enumerate(gist_to_users.items()):
        label = ', '.join(usernames_in_gist[:2])
        if len(usernames_in_gist) > 2:
            label += f' +{len(usernames_in_gist) - 2}'
        print(f'  [{gi+1:3d}/{total_gists}] {gid[:8]}... ({label})', end=' ', flush=True)

        # Gist データ取得（キャッシュ利用）
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
            processed_images = 0

            # 最初の1枚に顔が検出されなければアニメ/風景とみなしてスキップ
            first_url = next(
                (url for t in tweets for url in t.get('media_urls', [])),
                None,
            )
            if first_url is None:
                continue
            if not extract_face_embeddings(download_image(first_url)):
                continue

            for tweet in tweets:
                tid = tweet.get('id_str')
                if not tid or tid in excluded_ids:
                    continue

                # 画像ごとに顔マッチング
                tweet_matched = False
                for url in tweet.get('media_urls', []):
                    if max_images_per_user > 0 and processed_images >= max_images_per_user:
                        break
                    img = download_image(url)
                    processed_images += 1

                    for emb in extract_face_embeddings(img):
                        sim = max_cosine_similarity(emb, ref_embeddings)
                        if sim >= threshold:
                            t = dict(tweet)
                            t['match_source'] = 'face'
                            t['face_similarity'] = round(sim, 3)
                            t.setdefault('username', username)
                            face_matched.append(t)
                            excluded_ids.add(tid)  # 同一ポストの重複防止
                            gist_found += 1
                            tweet_matched = True
                            break  # このツイートは確定、次のツイートへ

                    if tweet_matched:
                        break  # 次の画像を見る必要なし

        print(f'+{gist_found}')

    print(f'\n  新規 face-matched ポスト数: {len(face_matched)}')

    # ────────────────────────────────────────────
    # Step 5: キャラクターGistを再構築・更新
    # ────────────────────────────────────────────
    print(f'\n[5/5] キャラクターGistを再構築中...')
    all_tweets = tagged_text + face_matched

    # id_str で重複除去（text-matched を優先）
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
    face_count  = sum(1 for t in deduped if t.get('match_source') == 'face')
    print(f'  最終ポスト数: {len(deduped)}  (text: {text_count}, face: {face_count})')

    new_content = {
        'users': {
            char_name: {
                'tweets': deduped,
            }
        }
    }

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
        description='顔認識でキャラクターGistを拡張する',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        '-c', '--chars',
        nargs='+',
        required=True,
        metavar='キャラクター名',
        help='対象キャラクター名（複数指定可、各キャラを順番に処理）',
    )
    parser.add_argument(
        '-g', '--gist-id',
        default=None,
        help='マスターGist ID（省略時は MASTER_GIST_ID 環境変数）',
    )
    parser.add_argument(
        '--threshold',
        type=float,
        default=0.5,
        help='顔マッチングの cosine similarity 閾値（0〜1、デフォルト: 0.5）',
    )
    parser.add_argument(
        '--max-ref-images',
        type=int,
        default=100,
        help='リファレンス顔特徴の抽出に使う最大画像数（デフォルト: 100）',
    )
    parser.add_argument(
        '--max-images',
        type=int,
        default=50,
        help='スキャン時のユーザーあたり最大画像数（0=制限なし、デフォルト: 50）',
    )
    args = parser.parse_args()

    # マスターGist ID の解決
    master_gist_id = args.gist_id or os.environ.get('MASTER_GIST_ID', '')
    if not master_gist_id:
        print('❌ マスターGist IDが指定されていません。-g または MASTER_GIST_ID を設定してください。')
        sys.exit(1)

    print(f'🔍 マスターGist ({master_gist_id}) を取得中...')
    try:
        _, master_data = fetch_gist_raw(master_gist_id)
    except RuntimeError as e:
        print(f'❌ {e}')
        sys.exit(1)

    print(f'  ユーザーGist数: {len(master_data.get("user_gists", {}))} 人')
    print(f'  キャラクターGist数: {len(master_data.get("character_gists", {}))} キャラ')

    for char_name in args.chars:
        process_character(
            char_name=char_name,
            master_data=master_data,
            threshold=args.threshold,
            max_ref_images=args.max_ref_images,
            max_images_per_user=args.max_images,
        )

    print('\n🎉 すべて完了！')


if __name__ == '__main__':
    main()
