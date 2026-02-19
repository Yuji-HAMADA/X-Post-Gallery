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

MASTER_GIST_ID = "a1d145b2d15d227ed1c051f3824b19fc"
GITHUB_API = "https://api.github.com"
USER_PATTERN = re.compile(r"^@([^:]+):")

AVAILABLE_GIST_IDS = [
    "6f5c5d5b170b0f9b9dc43c46c5e603e0",
    "88d3d3524ab90385f63a91db71f8f4a4",
    "de8a6a65e80b67c3a01924c0b7e3fe3f",
    "385e58c079d6b8711282d22ef71c9523",
    "742acc8a510d1ec29e950b5cd5896f4f",
    "1fde5bf4acc4543533b465cea774d35b",
    "c2578a1d90f64763baa17f6da1e314ca",
    "4e1727f6c159b3741b3e45209f894e4e",
    "832456fc8aab38bfb364ccf9f60cf292",
    "fbe971d9b97aabec23237e57b5d2a005",
    "115930379e23effc9c104d7f1639f787",
    "fab96f8451366106e35a1e6f17246f03",
    "648ff206a6c6483b23f0df8ef3065e23",
    "65f0fba93f9da5622a4650809083a53e",
    "a7f49d8df444477b1049e10016eda14c",
    "b8053041ea163f3f2e9e402bcce9bd8d",
    "da5de3eae494590a2bc7fb4b9826e427",
    "3a7b87aa7584341c5039e3f6bb617743",
    "d7333a48a5e6fcfddd2815bbcf925707",
    "5596b26da8958cc9260b03aae95a7dff",
    "8bc72d67e1326d9a441673554697aa16",
    "fe5ac94a4cf988dc0596f888855a78c7",
    "b486a8e820b1277b0954c753d6b176ce",
    "062b92ee7006955494b87cc2d15a0b21",
    "ca8e7a73bf22a89f3b5b01f2cdfb53bc",
    "10b757aa930925ffcc2ebab3159dab16",
    "e44abad118600060a7b00c1fb8bd61c2",
    "5c8f403ed4d92be129e383351cf8d86a",
    "7e6332ba87d560020907019bc91c6d10",
    "355b21e10b34d955dcefd923dc18aaa0",
    "f8dbd464dccbf332d27387d1b5379f5a",
    "b9d3589a5b4ecd083e455417b0da2166",
    "88c0770cfaadda83e4d3c356f74ef6e4",
    "7965dd31ab3d88d48be1ff73f018800d",
    "205d793364ec0c52921022e054b2329f",
    "cc4aaa9385459e22a00118efaf414486",
    "59c77a96d770a9a5b742027456752077",
    "3554a84ec8d3e6e2aaf459c63c004cb4",
    "7fcb85f3470627ca20141a06422e00b0",
    "55288667f5ef6c8167a87e4cd072ba85",
    "38470aa55629c41c62e95730f7879216",
    "3704e1938b8fe4b0beb61449a6d1bba1",
    "fe96efa98710d81d68e8d3e0bf5f3940",
    "9066f5a5c1782f5506ef7f402fe04c02",
    "0b5a4418de9e6017f1b4cad8e13790c5",
    "d7c27aee7814b151b3efdbc165c5e1af",
    "106b11f828badbe85ff0860f31ead4df",
    "d4d6a828d36d4cbd6ee232fa99007280",
    "ab5de9542c5436ca77cd2134de9bc6a5",
    "d5b5dfcb7f9af2c31418f435103f035e",
    "40fb0c1ce5a1e2133f75520a995eb18f",
    "a2c321d2bf55f0b8ada52fd0266e6107",
    "0bf8dad777b9e689293cee0b585a5fbc",
    "394981cf7c6d365c740ee93c914a9e07",
    "23dca4e44a5209c07d2cdb86fbfe7b31",
    "1bcba4b0b9989df2efd3c3beb45cd27d",
    "cbc4c4c6288447e688e1d56f85e8fd32",
    "53bf1df912a4210eeaf59ab819b6d4ba",
    "348ef85f185e51577248cb714c4fef29",
]


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
    raise RuntimeError("GITHUB_TOKEN not found")


def make_headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json",
    }


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
    args = parser.parse_args()

    token = load_token()
    print(f"Token loaded (length={len(token)})")

    # マスターGistをダウンロード
    print(f"\nマスターGist ({MASTER_GIST_ID}) をダウンロード中...")
    master_fname, master_data = download_gist(MASTER_GIST_ID, token)
    if not master_data:
        print("❌ マスターGistのダウンロードに失敗")
        sys.exit(1)

    master_tweets = master_data.get("tweets", [])
    print(f"  ツイート数: {len(master_tweets)}")

    # 59個のGistをスキャン
    print(f"\n=== ユーザGist ({len(AVAILABLE_GIST_IDS)}個) をスキャン中 ===")
    user_gists = {}  # username -> gist_id
    total_user_tweets = 0
    scanned = 0
    empty = 0

    for idx, gist_id in enumerate(AVAILABLE_GIST_IDS):
        try:
            _, data = download_gist(gist_id, token)
            if data is None:
                empty += 1
                print(f"  [{idx+1}/{len(AVAILABLE_GIST_IDS)}] {gist_id[:8]}... 空")
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
                print(f"  [{idx+1}/{len(AVAILABLE_GIST_IDS)}] {gist_id[:8]}... {user_count}ユーザー, {tweet_count}件")
            else:
                # single-user or other format
                tweets = data.get("tweets", [])
                if tweets:
                    user = data.get("user_screen_name", "")
                    if user:
                        user_gists[user] = gist_id
                        total_user_tweets += len(tweets)
                        scanned += 1
                        print(f"  [{idx+1}/{len(AVAILABLE_GIST_IDS)}] {gist_id[:8]}... @{user}: {len(tweets)}件")
                    else:
                        print(f"  [{idx+1}/{len(AVAILABLE_GIST_IDS)}] {gist_id[:8]}... 不明な形式")
                else:
                    empty += 1
                    print(f"  [{idx+1}/{len(AVAILABLE_GIST_IDS)}] {gist_id[:8]}... データなし")
        except Exception as e:
            print(f"  [{idx+1}/{len(AVAILABLE_GIST_IDS)}] {gist_id[:8]}... エラー: {e}")

        if idx < len(AVAILABLE_GIST_IDS) - 1:
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
            r = requests.patch(f"{GITHUB_API}/gists/{MASTER_GIST_ID}", headers=headers, json=payload)
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
    r = requests.patch(f"{GITHUB_API}/gists/{MASTER_GIST_ID}", headers=headers, json=payload)
    if r.status_code == 200:
        print(f"✅ マスターGist更新完了!")
        print(f"   user_gists: {len(user_gists)} ユーザー")
        print(f"   tweets: {len(master_tweets)} 件")
    else:
        print(f"❌ 更新失敗: {r.status_code} {r.text[:300]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
