#!/usr/bin/env python3
"""
顔クラスタリング PoC
- ユーザー別Gistから画像を取得
- InsightFace で顔検出 + embedding 抽出（顔なし＝アニメ→スキップ）
- full_text からキーワードを抽出して事前ヒントに利用
- DBSCAN でクラスタリング → character_groups.json 出力
"""

import argparse
import io
import json
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import requests
from sklearn.cluster import DBSCAN
from sklearn.metrics.pairwise import cosine_distances

# --- InsightFace 初期化 ---
_face_app = None

def get_face_app():
    global _face_app
    if _face_app is None:
        from insightface.app import FaceAnalysis
        _face_app = FaceAnalysis(name='buffalo_l',
                                  providers=['CPUExecutionProvider'])
        _face_app.prepare(ctx_id=-1, det_size=(640, 640))
    return _face_app


# --- 画像取得 ---
def download_image(url: str) -> np.ndarray | None:
    """URL から画像をダウンロードして BGR numpy 配列で返す"""
    try:
        resp = requests.get(url, timeout=15)
        if resp.status_code != 200:
            return None
        import cv2
        arr = np.frombuffer(resp.content, np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        return img
    except Exception as e:
        print(f"  [WARN] download failed: {e}", file=sys.stderr)
        return None


# --- 顔検出 + embedding ---
def detect_faces(img: np.ndarray) -> list:
    """画像から顔を検出。各要素に .embedding (512d) がある"""
    app = get_face_app()
    return app.get(img)


def is_real_photo_user(first_image_url: str) -> bool:
    """1枚目の画像で顔検出 → 検出されれば実写と判定"""
    img = download_image(first_image_url)
    if img is None:
        return False
    faces = detect_faces(img)
    return len(faces) > 0


# --- full_text からキーワード抽出 ---
STOP_WORDS = {
    # 英語系
    'AI', 'SFW', 'NSFW', 'digitalart', 'AIart', 'AIArt', 'aiart',
    'sfw', 'nsfw', 'art', 'photo', 'Nikon', 'Canon', 'Sony',
    'AIgravure', 'RT',
    # 日本語: ジャンル・形容詞・一般語
    'AI美女', 'AI写真', 'AIグラビア', 'AI画像', 'AI美少女', 'AIイラスト',
    'グラビア', '美少女', '美女', '透明感', 'セクシー', 'ビキニ', '水着',
    'ポートレート', '撮影会', '撮影', 'イラスト',
    'かわいい', '可愛い', '可愛', 'おはよう', 'おやすみ', 'おはようございます',
    'ショート', 'ロング', 'ショートカット', 'ポニテ',
    'フォロー', 'リツイート', 'いいね', 'ランダム', '修正',
    'ブログ', '公開', 'サブ', '今日', '今週', '明日', '一日',
    '笑顔', 'スタイル', 'リアル', 'メリークリス', 'マス', 'ゴメン',
    '制服女子', '女子', '画像', '画像探', '魅力的', '手間',
    # 服装・撮影関連
    'パーカー', 'シャツ', 'タンクトップ', 'ジャケット', 'レオタード',
    'デニムショー', 'コーデ', 'ショット', 'アングル', 'モデル',
    # 行動・一般語
    '投稿', '日目', '仕事', '午後', '気合', 'ステキ', '頑張',
    '綺麗', '彼女', '誤字脱字', '公演', 'プロンプト',
    # ゲーム・その他
    'デレステ', 'ブルアカ', 'ミリシタ', '原神', '生誕祭',
    'Fictional',
    # 機材・技術
    'hakushiMix', 'momiziNoob',
}

# ストップワードの部分一致パターン（正規表現）
STOP_PATTERNS = re.compile(
    r'^(hakushiMix|momiziNoob|AniKawa|hassaku|tanemomix|paperMoon|botan_|'
    r'AI美女|v\d+|_v\d+|XL_|マス・)'
)


def looks_like_person_name(word: str) -> bool:
    """日本人名っぽいかを簡易判定する"""
    # 漢字2-4文字（姓）＋ひらがな/カタカナ/漢字（名）のフルネームパターン
    # 例: 菊地姫奈, 武田玲奈, 沢口愛華, 松本麗世, 西野七瀬
    if re.fullmatch(r'[\u4e00-\u9fff]{2,4}[\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff]{1,4}', word):
        if len(word) >= 3:
            return True
    # カタカナ名（えなこ等は短いが、フルカタカナ名もある）
    if re.fullmatch(r'[\u30a0-\u30ff]{3,8}', word):
        return True
    # ひらがな名
    if re.fullmatch(r'[\u3040-\u309f]{3,8}', word):
        return True
    return False


def extract_keywords(full_texts: list[str]) -> list[str]:
    """
    full_text のリストからキャラ名候補を抽出する。
    - ハッシュタグ（#付き → #を外して取得）
    - 本文中の日本語名パターン（漢字/カタカナ 2-6文字の連続）
    - 繰り返し出現するものを人名候補とする
    """
    all_keywords = []

    for text in full_texts:
        # @username: を除去
        body = re.sub(r'^@\S+:\s*', '', text)

        # ハッシュタグ抽出（#を外す）
        hashtags = re.findall(r'#([^\s#]+)', body)
        all_keywords.extend(hashtags)

        # 本文中の日本語名候補（漢字2-6文字 or カタカナ2-6文字）
        names = re.findall(r'[\u4e00-\u9fff]{2,6}|[\u30a0-\u30ff]{2,6}', body)
        all_keywords.extend(names)

    # ストップワード除外
    all_keywords = [k for k in all_keywords
                    if k not in STOP_WORDS and not STOP_PATTERNS.match(k)]

    # 頻度カウントして、3回以上出現するものを返す（名前は繰り返される）
    counter = Counter(all_keywords)
    return [kw for kw, cnt in counter.most_common(20) if cnt >= 3]


def pick_best_label(keywords: list[str], cluster_id: int) -> str:
    """キーワードリストから最も人名らしいものをラベルとして選ぶ"""
    if not keywords:
        return f"character_{cluster_id}"

    counter = Counter(keywords)

    # 人名っぽいキーワードを優先
    name_candidates = [(kw, cnt) for kw, cnt in counter.most_common()
                       if looks_like_person_name(kw)]
    if name_candidates:
        return name_candidates[0][0]

    # 人名が見つからなければ最頻出キーワード
    return counter.most_common(1)[0][0]


# --- データ取得 ---
GIST_RAW_BASE = "https://gist.githubusercontent.com/Yuji-HAMADA"

def fetch_master_data(master_gist_id: str) -> dict:
    """マスターGistからユーザー一覧と user_gists を取得"""
    url = f"{GIST_RAW_BASE}/{master_gist_id}/raw/data.json"
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()
    return resp.json()


def fetch_user_tweets(gist_id: str, username: str) -> list[dict]:
    """子Gistからユーザーのツイートを取得"""
    t = int(time.time())
    url = f"{GIST_RAW_BASE}/{gist_id}/raw/data.json?t={t}"
    resp = requests.get(url, timeout=30)
    if resp.status_code == 404:
        url = f"{GIST_RAW_BASE}/{gist_id}/raw/gallary_data.json?t={t}"
        resp = requests.get(url, timeout=30)
    if resp.status_code != 200:
        return []
    data = resp.json()

    # 子Gist形式: users -> username -> tweets
    users = data.get('users', {})
    if username in users:
        return users[username].get('tweets', [])
    # フォールバック: 直下に tweets
    if 'tweets' in data:
        return data['tweets']
    return []


# --- メイン処理 ---
def process_users(master_gist_id: str, max_users: int = 10,
                  max_images_per_user: int = 20,
                  priority_users: list[str] | None = None):
    """
    1. マスターGistからユーザー一覧取得
    2. 各ユーザーの1枚目で実写判定
    3. 実写ユーザーの画像から顔embedding抽出
    4. full_text キーワード抽出
    5. クラスタリング
    """
    print(f"[1/5] マスターGist取得中... ({master_gist_id})")
    master = fetch_master_data(master_gist_id)
    user_gists = master.get('user_gists', {})
    print(f"  ユーザー数: {len(user_gists)}")

    # ユーザーごとの処理
    face_records = []  # [{username, tweet_id, embedding, image_url, tweet_kw}]
    user_keywords = {}  # {username: [keywords]}
    real_users = []
    skip_count = 0

    # 優先ユーザーを先頭に、残りを後続に
    all_keys = list(user_gists.keys())
    ordered = []
    if priority_users:
        for pu in priority_users:
            if pu in user_gists:
                ordered.append(pu)
            else:
                print(f"  [WARN] 優先ユーザー '{pu}' がマスターに見つかりません")
    for k in all_keys:
        if k not in ordered:
            ordered.append(k)
    usernames = ordered[:max_users]

    print(f"\n[2/5] 実写判定 + embedding抽出 ({len(usernames)} users)...")
    for i, username in enumerate(usernames):
        gist_id = user_gists[username]
        print(f"\n  [{i+1}/{len(usernames)}] @{username} (gist: {gist_id[:8]}...)")

        # 子Gistからツイート取得
        tweets = fetch_user_tweets(gist_id, username)
        if not tweets:
            print(f"    → ツイートなし、スキップ")
            skip_count += 1
            continue

        # media_urls がある最初のツイートで実写判定
        first_url = None
        for t in tweets:
            urls = t.get('media_urls', [])
            if urls:
                first_url = urls[0]
                break

        if not first_url:
            print(f"    → 画像なし、スキップ")
            skip_count += 1
            continue

        if not is_real_photo_user(first_url):
            print(f"    → 顔未検出（アニメ）、スキップ")
            skip_count += 1
            continue

        print(f"    → 実写ユーザー ✓ ({len(tweets)} tweets)")
        real_users.append(username)

        # full_text からキーワード抽出
        full_texts = [t.get('full_text', '') for t in tweets if t.get('full_text')]
        kws = extract_keywords(full_texts)
        if kws:
            user_keywords[username] = kws
            print(f"    keywords: {kws[:5]}")

        # ツイート単位のキーワード抽出用マップ
        tweet_kw_map = {}
        for t in tweets:
            ft = t.get('full_text', '')
            body = re.sub(r'^@\S+:\s*', '', ft)
            tags = re.findall(r'#([^\s#]+)', body)
            names = re.findall(r'[\u4e00-\u9fff]{2,6}|[\u30a0-\u30ff]{2,6}', body)
            candidates = [k for k in tags + names if k not in STOP_WORDS]
            # ユーザー全体で頻出のキーワードのみ残す（ノイズ除去）
            candidates = [k for k in candidates if k in kws]
            tweet_kw_map[t.get('id_str', '')] = candidates

        # 各画像から顔embedding抽出
        processed = 0
        for t in tweets[:max_images_per_user]:
            tid = t.get('id_str', '')
            for img_url in t.get('media_urls', []):
                img = download_image(img_url)
                if img is None:
                    continue
                faces = detect_faces(img)
                for face in faces:
                    face_records.append({
                        'username': username,
                        'tweet_id': tid,
                        'embedding': face.embedding,
                        'image_url': img_url,
                        'tweet_kw': tweet_kw_map.get(tid, []),
                    })
                processed += 1
            if processed >= max_images_per_user:
                break

        print(f"    顔検出: {len([r for r in face_records if r['username'] == username])} faces from {processed} images")

    print(f"\n[3/5] 結果サマリー")
    print(f"  実写ユーザー: {len(real_users)}")
    print(f"  スキップ: {skip_count}")
    print(f"  顔レコード総数: {len(face_records)}")

    if len(face_records) < 2:
        print("\n顔レコードが不足しています。ユーザー数を増やしてください。")
        return []

    # --- クラスタリング ---
    print(f"\n[4/5] クラスタリング...")
    embeddings = np.array([r['embedding'] for r in face_records])
    # L2正規化してcosine距離をユークリッドで近似
    norms = np.linalg.norm(embeddings, axis=1, keepdims=True)
    embeddings_normed = embeddings / norms

    # キーワードによるヒント行列: 同じキーワードを共有するペアは距離を縮める
    # ツイート単位のキーワードで比較（boobs_japanese のように1ユーザーが複数人を投稿する場合に対応）
    n = len(face_records)
    keyword_bonus = np.zeros((n, n))
    for i in range(n):
        kws_i = set(face_records[i].get('tweet_kw', []))
        if not kws_i:
            continue
        for j in range(i + 1, n):
            kws_j = set(face_records[j].get('tweet_kw', []))
            if kws_i & kws_j:  # 共通キーワードあり
                keyword_bonus[i, j] = 0.1  # 距離を0.1縮める
                keyword_bonus[j, i] = 0.1

    # cosine距離行列を計算し、キーワードボーナスを適用
    dist_matrix = cosine_distances(embeddings_normed)
    dist_matrix = np.maximum(dist_matrix - keyword_bonus, 0)

    # DBSCAN (eps=0.5 はcosine距離での典型的な閾値、要調整)
    clustering = DBSCAN(eps=0.5, min_samples=2, metric='precomputed')
    labels = clustering.fit_predict(dist_matrix)

    n_clusters = len(set(labels) - {-1})
    n_noise = (labels == -1).sum()
    print(f"  クラスタ数: {n_clusters}")
    print(f"  未分類（ノイズ）: {n_noise}")

    # --- 結果整理 ---
    print(f"\n[5/5] 結果出力...")
    clusters = defaultdict(list)
    for idx, label in enumerate(labels):
        if label == -1:
            continue
        clusters[label].append(face_records[idx])

    characters = []
    for cluster_id, records in sorted(clusters.items()):
        usernames_in_cluster = list(set(r['username'] for r in records))
        tweet_ids = list(set(r['tweet_id'] for r in records))
        image_urls = list(set(r['image_url'] for r in records))

        # ラベル: クラスタ内ツイートのキーワードから人名を優先選定
        all_kws = []
        for r in records:
            all_kws.extend(r.get('tweet_kw', []))
        label = pick_best_label(all_kws, cluster_id)

        char_info = {
            'label': label,
            'cluster_id': int(cluster_id),
            'usernames': usernames_in_cluster,
            'source_tags': list(set(all_kws)),
            'representative_image': records[0]['image_url'],
            'tweet_ids': tweet_ids[:50],  # 上限
            'image_urls': image_urls[:50],
            'face_count': len(records),
        }
        characters.append(char_info)

        print(f"  Cluster {cluster_id}: \"{label}\" "
              f"({len(records)} faces, {len(usernames_in_cluster)} users: "
              f"{', '.join(usernames_in_cluster[:3])})")

    return characters


def main():
    parser = argparse.ArgumentParser(description='顔クラスタリング PoC')
    parser.add_argument('--master-gist-id', required=True,
                        help='マスターGistのID')
    parser.add_argument('--max-users', type=int, default=10,
                        help='処理するユーザー数の上限')
    parser.add_argument('--max-images', type=int, default=20,
                        help='ユーザーあたりの処理画像数の上限')
    parser.add_argument('--priority-users', nargs='*', default=[],
                        help='優先処理するユーザー名（先頭に配置）')
    parser.add_argument('--output', default='character_groups.json',
                        help='出力JSONファイルパス')
    args = parser.parse_args()

    characters = process_users(
        args.master_gist_id,
        max_users=args.max_users,
        max_images_per_user=args.max_images,
        priority_users=args.priority_users or None,
    )

    output_path = Path(args.output)
    output_data = {
        'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'characters': characters,
    }
    output_path.write_text(json.dumps(output_data, ensure_ascii=False, indent=2))
    print(f"\n出力: {output_path} ({len(characters)} characters)")


if __name__ == '__main__':
    main()
