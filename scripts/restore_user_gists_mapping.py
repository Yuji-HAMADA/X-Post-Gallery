#!/usr/bin/env python3
"""
59個のユーザGistをスキャンして user_gists マッピングを再構築し、
マスターGistを更新するスクリプト。

使い方:
  python3 scripts/restore_user_gists_mapping.py --dry-run   # サマリーのみ
  python3 scripts/restore_user_gists_mapping.py              # 実行
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

import requests

GITHUB_API = "https://api.github.com"
USER_PATTERN = re.compile(r"^@([^:]+):")


def load_token():
    token = os.environ.get("GITHUB_TOKEN", "")
    if token:
        return token
    env_path = Path(__file__).resolve().parent.parent / ".env"
    if env_path.exists():
        text = env_path.read_text()
        m = re.search(r"^GITHUB_TOKEN=(.+)$", text, re.MULTILINE)
        if m:
            return m.group(1).strip()
    return ""


def load_master_gist_id():
    gist_id = os.environ.get("MASTER_GIST_ID", "")
    if gist_id:
        return gist_id
    env_path = Path(__file__).resolve().parent.parent / ".env"
    if env_path.exists():
        text = env_path.read_text()
        m = re.search(r"^MASTER_GIST_ID=(.+)$", text, re.MULTILINE)
        if m:
            return m.group(1).strip().strip("'\"")
    return ""


def make_headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json",
    }


def fetch_all_user_gists(token, exclude_id=None):
    """ユーザーのアカウント内の全Gist IDをAPIから自動取得する"""
    headers = make_headers(token)
    page = 1
    gist_ids = []
    while True:
        r = requests.get(f"{GITHUB_API}/gists?per_page=100&page={page}", headers=headers)
        if r.status_code != 200:
            break
        data = r.json()
        if not data:
            break
        for g in data:
            gid = g.get("id")
            if gid and gid != exclude_id:
                gist_ids.append(gid)
        page += 1
    return gist_ids


def download_gist(gist_id, token):
    headers = make_headers(token)
    r = requests.get(f"{GITHUB_API}/gists/{gist_id}", headers=headers)
    r.raise_for_status()
    meta = r.json()
    files = meta["files"]
    for fname in ["data.json", "gallary_data.json"]:
        if fname in files:
            raw_url = files[fname]["raw_url"]
            r2 = requests.get(raw_url)
            r2.raise_for_status()
            return fname, r2.json()
    return None, None


def extract_username(tweet):
    m = USER_PATTERN.match(tweet.get("full_text", ""))
    return m.group(1).strip() if m else None


def main():
    parser = argparse.ArgumentParser(description="user_gists マッピングを再構築")
    parser.add_argument("--dry-run", action="store_true", help="サマリーのみ表示")
    parser.add_argument("-g", "--master-gist-id", default=None, help="マスターGist ID (省略時は環境変数または.envから取得)")
    parser.add_argument("--gist-ids", default=None, help="対象Gist ID（カンマ区切り。省略時は全GistをAPIから自動検出）")
    args = parser.parse_args()

    token = load_token()
    if not token:
        print("❌ GITHUB_TOKEN が設定されていません")
        sys.exit(1)
    print(f"Token loaded (length={len(token)})")

    master_gist_id = args.master_gist_id or load_master_gist_id()
    if not master_gist_id:
        print("❌ MASTER_GIST_ID が指定されておらず、環境変数または.envにも見つかりません")
        sys.exit(1)

    # マスターGistをダウンロード
    print(f"\nマスターGist ({master_gist_id}) をダウンロード中...")
    master_fname, master_data = download_gist(master_gist_id, token)
    if not master_data:
        print("❌ マスターGistのダウンロードに失敗")
        sys.exit(1)

    master_tweets = master_data.get("tweets", [])
    print(f"  ツイート数: {len(master_tweets)}")

    if args.gist_ids:
        available_gist_ids = [gid.strip() for gid in args.gist_ids.split(",") if gid.strip()]
    else:
        print("\n🔍 アカウント内の全Gistを自動取得中...")
        available_gist_ids = fetch_all_user_gists(token, exclude_id=master_gist_id)

    print(f"\n=== ユーザGist ({len(available_gist_ids)}個) をスキャン中 ===")
    user_gists = {}  # username -> gist_id
    total_user_tweets = 0
    scanned = 0
    empty = 0

    for idx, gist_id in enumerate(available_gist_ids):
        try:
            _, data = download_gist(gist_id, token)
            if data is None:
                empty += 1
                print(f"  [{idx+1}/{len(available_gist_ids)}] {gist_id[:8]}... 空")
                continue

            # multi-user format: {users: {username: {tweets: [...]}}}
            users = data.get("users", {})
            if users:
                user_count = len(users)
                tweet_count = sum(len(u.get("tweets", [])) for u in users.values())
                for username in users:
                    user_gists[username] = gist_id
                total_user_tweets += tweet_count
                scanned += 1
                print(f"  [{idx+1}/{len(available_gist_ids)}] {gist_id[:8]}... {user_count}ユーザー, {tweet_count}件")
            else:
                # single-user or other format
                tweets = data.get("tweets", [])
                if tweets:
                    user = data.get("user_screen_name", "")
                    if user:
                        user_gists[user] = gist_id
                        total_user_tweets += len(tweets)
                        scanned += 1
                        print(f"  [{idx+1}/{len(available_gist_ids)}] {gist_id[:8]}... @{user}: {len(tweets)}件")
                    else:
                        print(f"  [{idx+1}/{len(available_gist_ids)}] {gist_id[:8]}... 不明な形式")
                else:
                    empty += 1
                    print(f"  [{idx+1}/{len(available_gist_ids)}] {gist_id[:8]}... データなし")
        except Exception as e:
            print(f"  [{idx+1}/{len(available_gist_ids)}] {gist_id[:8]}... エラー: {e}")

        if idx < len(available_gist_ids) - 1:
            time.sleep(0.3)  # レートリミット対策

    print(f"\n=== スキャン結果 ===")
    print(f"データ有り: {scanned} Gist")
    print(f"空: {empty} Gist")
    print(f"ユーザー数: {len(user_gists)}")
    print(f"総ツイート数: {total_user_tweets}")

    if not user_gists:
        print("\n⚠️  ユーザGistにデータが見つかりません。")
        if not args.dry_run:
            print("マスターGistの user_screen_name のみ修正します。")
            master_data["user_screen_name"] = ""
            headers = make_headers(token)
            payload = {
                "files": {
                    master_fname: {
                        "content": json.dumps(master_data, ensure_ascii=False, indent=2)
                    }
                }
            }
            r = requests.patch(f"{GITHUB_API}/gists/{master_gist_id}", headers=headers, json=payload)
            if r.status_code == 200:
                print("✅ マスターGist更新完了 (user_screen_name を空に)")
            else:
                print(f"❌ 更新失敗: {r.status_code}")
        return

    # マスターGistを更新
    print(f"\n=== マスターGist更新 ===")
    master_data["user_screen_name"] = ""
    master_data["user_gists"] = user_gists

    updated_json = json.dumps(master_data, ensure_ascii=False, indent=2)
    print(f"  user_gists: {len(user_gists)} エントリ")
    print(f"  JSONサイズ: {len(updated_json) / 1024:.0f} KB")

    if args.dry_run:
        print("\n[dry-run] 実際の更新は行いません。")
        print("\n--- user_gists マッピング (先頭20件) ---")
        for i, (user, gid) in enumerate(list(user_gists.items())[:20]):
            print(f"  @{user} → {gid[:8]}...")
        if len(user_gists) > 20:
            print(f"  ... 他 {len(user_gists) - 20} ユーザー")
        return

    headers = make_headers(token)
    payload = {
        "files": {
            master_fname: {
                "content": updated_json
            }
        }
    }
    r = requests.patch(f"{GITHUB_API}/gists/{master_gist_id}", headers=headers, json=payload)
    if r.status_code == 200:
        print(f"✅ マスターGist更新完了!")
        print(f"   user_gists: {len(user_gists)} ユーザー")
        print(f"   tweets: {len(master_tweets)} 件")
    else:
        print(f"❌ 更新失敗: {r.status_code} {r.text[:300]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
