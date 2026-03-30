#!/usr/bin/env python3
"""
Vector Gallery Gist 生成スクリプト (PoC)
- お気に入りユーザーの画像を InsightFace で顔 embedding 抽出
- ユーザー内: embedding 類似度順にソート (nearest-neighbor)
- ユーザー間: 代表 embedding (平均) の類似度順にソート
- Secret Gist にアップロード
"""

import argparse
import io
import json
import os
import random
import subprocess
import sys
import tempfile
import time

import cv2
import numpy as np
import requests
from sklearn.metrics.pairwise import cosine_similarity

# --- InsightFace 初期化 ---
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


# --- 画像ダウンロード ---
def download_image(url: str) -> tuple[np.ndarray | None, int, int]:
    """URL から画像をダウンロードして (BGR配列, width, height) を返す"""
    try:
        resp = requests.get(url, timeout=15)
        if resp.status_code != 200:
            return None, 0, 0
        arr = np.frombuffer(resp.content, np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if img is None:
            return None, 0, 0
        h, w = img.shape[:2]
        return img, w, h
    except Exception as e:
        print(f"  [WARN] download failed: {e}", file=sys.stderr)
        return None, 0, 0


# --- データ取得 ---
GIST_RAW_BASE = "https://gist.githubusercontent.com/Yuji-HAMADA"


def fetch_json(gist_id: str, filename: str = "data.json") -> dict | None:
    """Gist raw URL から JSON を取得"""
    t = int(time.time())
    url = f"{GIST_RAW_BASE}/{gist_id}/raw/{filename}?t={t}"
    resp = requests.get(url, timeout=30)
    if resp.status_code == 200:
        return resp.json()
    # フォールバック
    if filename == "data.json":
        url2 = f"{GIST_RAW_BASE}/{gist_id}/raw/gallary_data.json?t={t}"
        resp2 = requests.get(url2, timeout=30)
        if resp2.status_code == 200:
            return resp2.json()
    return None


def fetch_favorite_users(fav_gist_id: str) -> list[str]:
    """お気に入りGistからユーザーリストを取得"""
    data = fetch_json(fav_gist_id, "favorites.json")
    if data is None:
        return []
    return data.get("favorite_users", [])


def fetch_user_tweets(gist_id: str, username: str) -> list[dict]:
    """子Gistからユーザーのツイートを取得"""
    data = fetch_json(gist_id)
    if data is None:
        return []
    users = data.get("users", {})
    if username in users:
        return users[username].get("tweets", [])
    if "tweets" in data:
        return data["tweets"]
    return []


# --- 類似度ソート (nearest-neighbor TSP近似) ---
def sort_by_similarity(embeddings: list[np.ndarray], indices: list[int]) -> list[int]:
    """
    embedding の cosine similarity で nearest-neighbor 順にソート。
    indices[0] をスタートとし、未訪問の中で最も近いものを次に選ぶ。
    """
    if len(indices) <= 1:
        return indices

    emb_matrix = np.array([embeddings[i] for i in indices])
    sim_matrix = cosine_similarity(emb_matrix)
    np.fill_diagonal(sim_matrix, -1)  # 自分自身を除外

    n = len(indices)
    visited = [False] * n
    order = [0]
    visited[0] = True

    for _ in range(n - 1):
        current = order[-1]
        best = -1
        best_sim = -2
        for j in range(n):
            if not visited[j] and sim_matrix[current, j] > best_sim:
                best_sim = sim_matrix[current, j]
                best = j
        order.append(best)
        visited[best] = True

    return [indices[i] for i in order]


# --- メイン処理 ---
def process(
    master_gist_id: str,
    fav_gist_id: str,
    max_users: int = 10,
    max_images: int = 10,
) -> dict:
    """
    1. お気に入りユーザーを取得
    2. ランダムソートして順に処理
    3. 各ユーザーの画像から顔 embedding抽出。最初の画像で顔がなければ即スキップ(アニメ垢対策)
    4. 指定枚数(max_images)に達したユーザーのみを採用
    5. 採用ユーザーが max_users に達するまで繰り返す
    6. ユーザー内 / ユーザー間で類似度順ソート
    7. Gist 用 JSON を返す
    """
    # マスターGist → user_gists マッピング
    print(f"[1/5] マスターGist取得中... ({master_gist_id[:8]}...)")
    master = fetch_json(master_gist_id)
    if master is None:
        print("  ERROR: マスターGist取得失敗", file=sys.stderr)
        sys.exit(1)
    user_gists = master.get("user_gists", {})
    print(f"  全ユーザー数: {len(user_gists)}")

    # お気に入りユーザー取得
    print(f"\n[2/5] お気に入りユーザー取得中... ({fav_gist_id[:8]}...)")
    fav_users = fetch_favorite_users(fav_gist_id)
    print(f"  お気に入り数: {len(fav_users)}")

    # お気に入りかつ user_gists に存在するユーザー
    available = [u for u in fav_users if u in user_gists]
    print(f"  Gist有り: {len(available)}")

    if len(available) == 0:
        print("  ERROR: 対象ユーザーなし", file=sys.stderr)
        sys.exit(1)

    # ランダムシャッフルして順に処理（指定数に達するまで）
    random.shuffle(available)
    print(f"  シャッフル完了、最大 {max_users} ユーザー × {max_images} 画像 を抽出します")

    # embedding 抽出
    print(f"\n[3/5] 顔 embedding 抽出中...")
    user_data = []  # [{username, images: [{url, post_url, w, h, embedding}]}]

    for i, username in enumerate(available):
        if len(user_data) >= max_users:
            break

        gist_id = user_gists[username]
        print(f"\n  [{i+1}/{len(available)}] @{username} (gist: {gist_id[:8]}... | 現在 {len(user_data)}/{max_users} 完了)")

        tweets = fetch_user_tweets(gist_id, username)
        if not tweets:
            print(f"    → ツイートなし、スキップ")
            continue

        images = []
        embeddings_for_user = []
        processed = 0
        total_no_faces = 0
        skip_user = False

        for tweet in tweets:
            if processed >= max_images:
                break
            media_urls = tweet.get("media_urls", [])
            post_url = tweet.get("post_url", "")
            tweet_id = tweet.get("id_str", "")

            for img_url in media_urls:
                if processed >= max_images:
                    break

                img, w, h = download_image(img_url)
                if img is None:
                    continue

                faces = get_face_app().get(img)

                if not faces:
                    total_no_faces += 1
                    print(f"    画像 {processed+1}: 顔未検出、スキップ (累計 {total_no_faces}/10)")
                    if total_no_faces >= 10:
                        print(f"    → 顔未検出が合計10枚に達した → アニメ垢と判定しユーザースキップ")
                        skip_user = True
                        break # break out of media_urls loop
                    continue

                # 最大の顔を使用
                face = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
                emb = face.embedding / np.linalg.norm(face.embedding)

                images.append({
                    "url": img_url,
                    "post_url": post_url or f"https://x.com/{username}/status/{tweet_id}",
                    "w": w,
                    "h": h,
                })
                embeddings_for_user.append(emb)
                processed += 1
                print(f"    画像 {processed}: ✓ ({w}x{h})")

            if skip_user:
                break

        # 顔未検出合計10枚によるスキップ
        if skip_user:
            continue
        if processed == 0:
            print(f"    → 有効な画像なし、ユーザースキップ")
            continue

        # ユーザー内: 類似度順ソート
        sorted_indices = sort_by_similarity(
            embeddings_for_user, list(range(len(images)))
        )
        sorted_images = [images[i] for i in sorted_indices]
        sorted_embeddings = [embeddings_for_user[i] for i in sorted_indices]

        # 代表 embedding = 平均
        mean_emb = np.mean(sorted_embeddings, axis=0)
        mean_emb = mean_emb / np.linalg.norm(mean_emb)

        user_data.append({
            "username": username,
            "images": sorted_images,
            "mean_embedding": mean_emb,
        })

        print(f"    → {len(sorted_images)} 画像を類似度順にソート完了 (採用)")

    if not user_data:
        print("\nERROR: 有効なユーザーデータなし", file=sys.stderr)
        sys.exit(1)

    # ユーザー間: 類似度順ソート
    print(f"\n[4/5] ユーザー間類似度ソート中... ({len(user_data)} users)")
    user_embeddings = [u["mean_embedding"] for u in user_data]
    sorted_user_indices = sort_by_similarity(
        user_embeddings, list(range(len(user_data)))
    )
    user_data = [user_data[i] for i in sorted_user_indices]

    for u in user_data:
        print(f"  @{u['username']} ({len(u['images'])} images)")

    # JSON構築（embedding は含めない）
    print(f"\n[5/5] JSON生成中...")
    result = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "users": [
            {
                "username": u["username"],
                "images": u["images"],  # url, post_url, w, h のみ
            }
            for u in user_data
        ],
    }

    # mean_embedding を削除（JSON にシリアライズできない）
    return result


def upload_to_gist(data: dict) -> str | None:
    """Secret Gist にアップロードして Gist ID を返す"""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", prefix="vector_gallery_", delete=False
    ) as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        tmp_path = f.name

    try:
        current_time = time.strftime("%Y/%m/%d-%H:%M:%S")
        n_users = len(data.get("users", []))
        n_images = sum(len(u.get("images", [])) for u in data.get("users", []))
        description = f"Vector Gallery ({n_users} users, {n_images} images) {current_time}-JST"

        result = subprocess.run(
            [
                "gh", "gist", "create", tmp_path,
                "-d", description,
                # secret gist (no -p flag)
            ],
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:
            print(f"  ERROR: gh gist create failed: {result.stderr}", file=sys.stderr)
            return None

        gist_url = result.stdout.strip()
        gist_id = gist_url.split("/")[-1]
        return gist_id
    finally:
        os.unlink(tmp_path)


def main():
    parser = argparse.ArgumentParser(description="Vector Gallery Gist 生成 (PoC)")
    parser.add_argument(
        "--master-gist-id",
        default=os.environ.get("MASTER_GIST_ID", "8c6c667667a8e1c442e4fdb3939f40de"),
        help="マスターGistのID",
    )
    parser.add_argument(
        "--fav-gist-id",
        default=os.environ.get("FAVORITE_GIST_ID", "1a66322c8cd9fb65b51f75daaaead7ca"),
        help="お気に入りGistのID",
    )
    parser.add_argument("--max-users", type=int, default=10, help="処理ユーザー数上限")
    parser.add_argument("--max-images", type=int, default=10, help="ユーザーあたり画像数上限")
    parser.add_argument("--output", default=None, help="ローカル出力JSONパス（指定時はGist非作成）")
    args = parser.parse_args()

    data = process(
        master_gist_id=args.master_gist_id,
        fav_gist_id=args.fav_gist_id,
        max_users=args.max_users,
        max_images=args.max_images,
    )

    if args.output:
        with open(args.output, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f"\n✅ ローカル出力: {args.output}")
    else:
        print("\nGist にアップロード中...")
        gist_id = upload_to_gist(data)
        if gist_id:
            n_users = len(data["users"])
            n_images = sum(len(u["images"]) for u in data["users"])
            print(f"\n{'='*50}")
            print(f"✅ Secret Gist 作成成功!")
            print(f"   Gist ID : {gist_id}")
            print(f"   Users   : {n_users}")
            print(f"   Images  : {n_images}")
            print(f"{'='*50}")
            print(f"\n.env に追加してください:")
            print(f"VECTOR_GIST_ID={gist_id}")
        else:
            print("\n❌ Gist アップロード失敗", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
