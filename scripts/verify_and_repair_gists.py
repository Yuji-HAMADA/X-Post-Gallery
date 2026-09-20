#!/usr/bin/env python3
"""
Gist構成の不整合を検証し、修復（不要なマッピングとタイムラインツイートの削除）を行うスクリプト。

使い方:
  python3 scripts/verify_and_repair_gists.py             # 検証のみ (Dry-run)
  python3 scripts/verify_and_repair_gists.py --repair    # 実際にマスターGistを修正
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import requests

MASTER_GIST_ID = "8c6c667667a8e1c442e4fdb3939f40de"
GITHUB_API = "https://api.github.com"

# ---------------------------------------------------------------------------
# Token & API Helpers
# ---------------------------------------------------------------------------
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
    raise RuntimeError("GITHUB_TOKEN not found in environment or .env file")

def make_headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json",
    }

def get_ratelimit_info(headers):
    try:
        r = requests.get(f"{GITHUB_API}/rate_limit", headers=headers, timeout=5)
        if r.status_code == 200:
            limit = r.json().get("resources", {}).get("core", {})
            return limit.get("limit"), limit.get("remaining"), limit.get("reset")
    except Exception:
        pass
    return None, None, None

def get_gist_id_from_entry(entry):
    if isinstance(entry, dict):
        return entry.get("gist_id")
    return entry

# ---------------------------------------------------------------------------
# Gist Fetcher with Retries
# ---------------------------------------------------------------------------
def fetch_gist_meta_with_retry(gist_id, headers, retries=3):
    url = f"{GITHUB_API}/gists/{gist_id}"
    for attempt in range(retries):
        try:
            r = requests.get(url, headers=headers, timeout=10)
            if r.status_code == 404:
                return 404, None
            r.raise_for_status()
            return 200, r.json()
        except requests.exceptions.RequestException as e:
            if attempt == retries - 1:
                status_code = getattr(e.response, "status_code", 500) if getattr(e, "response", None) else 500
                return status_code, None
            time.sleep(1 + attempt)
    return 500, None

def download_raw_json(raw_url, retries=3):
    for attempt in range(retries):
        try:
            r = requests.get(raw_url, timeout=10)
            r.raise_for_status()
            return r.json()
        except Exception:
            if attempt == retries - 1:
                return None
            time.sleep(1 + attempt)
    return None

def download_gist_content(gist_id, headers):
    status, meta = fetch_gist_meta_with_retry(gist_id, headers)
    if status == 404:
        return 404, None, "Gist not found"
    if status != 200 or not meta:
        return status, None, f"API error (status: {status})"

    files = meta.get("files", {})
    target_file = None
    for fname in ["data.json", "gallary_data.json"]:
        if fname in files:
            target_file = files[fname]
            break

    if not target_file:
        return 200, None, "No data.json or gallary_data.json in Gist"

    raw_url = target_file.get("raw_url")
    if not raw_url:
        return 200, None, "No raw_url for data file"

    data = download_raw_json(raw_url)
    if data is None:
        return 200, None, "Failed to download raw JSON content"

    return 200, data, "OK"

# ---------------------------------------------------------------------------
# Worker Function
# ---------------------------------------------------------------------------
def verify_single_gist(gist_id, mapped_users, headers):
    """
    1つのGist IDを検証し、そこに紐づいているユーザーたちが正しくデータとして存在するか調べる。
    """
    status, data, msg = download_gist_content(gist_id, headers)
    
    # Gist自体が404
    if status == 404:
        return {
            "gist_id": gist_id,
            "status": "404_NOT_FOUND",
            "results": {user: (False, "Gist deleted (404)") for user in mapped_users}
        }
    
    # その他の通信エラー/ファイル欠損
    if status != 200 or data is None:
        return {
            "gist_id": gist_id,
            "status": "ERROR",
            "results": {user: (False, f"Gist unreachable or invalid: {msg}") for user in mapped_users}
        }

    # データの形式判定
    users_dict = data.get("users", {})
    user_screen_name = data.get("user_screen_name", "")
    tweets = data.get("tweets", [])

    results = {}
    for user in mapped_users:
        if users_dict:
            # マルチユーザー形式
            if user in users_dict:
                user_tweets = users_dict[user].get("tweets", [])
                if user_tweets:
                    results[user] = (True, "Valid (multi-user)")
                else:
                    results[user] = (False, "No tweets in multi-user data")
            else:
                # 大文字小文字違いも探してみる
                matched_case = None
                for k in users_dict.keys():
                    if k.lower() == user.lower():
                        matched_case = k
                        break
                if matched_case:
                    user_tweets = users_dict[matched_case].get("tweets", [])
                    if user_tweets:
                        results[user] = (False, f"Username case mismatch: mapped as '{user}' but exists as '{matched_case}'")
                    else:
                        results[user] = (False, f"Username case mismatch and 0 tweets: '{matched_case}'")
                else:
                    results[user] = (False, "User not found in multi-user Gist")
        elif user_screen_name:
            # シングルユーザー形式
            if user.lower() == user_screen_name.lower():
                if tweets:
                    if user != user_screen_name:
                        results[user] = (False, f"Username case mismatch: mapped as '{user}' but Gist is '{user_screen_name}'")
                    else:
                        results[user] = (True, "Valid (single-user)")
                else:
                    results[user] = (False, f"Single-user '{user_screen_name}' has 0 tweets")
            else:
                results[user] = (False, f"User mismatch in single-user Gist (Gist owner: '{user_screen_name}')")
        else:
            # fallback: tweets のみ
            if tweets:
                # tweets の中にそのユーザーが投稿したツイートがあるか確認
                has_tweet = any(t.get("username", "").lower() == user.lower() for t in tweets)
                if has_tweet:
                    results[user] = (True, "Valid (tweets list search)")
                else:
                    results[user] = (False, "Gist format unknown and user has no tweets in list")
            else:
                results[user] = (False, "Gist contains no structured user or tweet data")

    return {
        "gist_id": gist_id,
        "status": "OK",
        "results": results
    }

# ---------------------------------------------------------------------------
# Main Routine
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Gist構成の不整合を検証し、必要に応じて修復する")
    parser.add_argument("--repair", action="store_true", help="実際にマスターGistの不要マッピングと不整合ツイートを削除")
    parser.add_argument("--threads", type=int, default=15, help="並列検証のスレッド数 (デフォルト: 15)")
    args = parser.parse_args()

    token = load_token()
    headers = make_headers(token)
    
    limit, remaining, reset = get_ratelimit_info(headers)
    print("=== GitHub API Rate Limit ===")
    if limit is not None:
        print(f"Limit: {limit}, Remaining: {remaining}")
    else:
        print("Could not retrieve rate limit info.")
    print("=============================\n")

    # 1. マスターGistをダウンロード
    print(f"マスターGist ({MASTER_GIST_ID}) をダウンロード中...")
    status, master_data, msg = download_gist_content(MASTER_GIST_ID, headers)
    if status != 200 or not master_data:
        print(f"❌ マスターGistのダウンロードに失敗: {msg}")
        sys.exit(1)

    master_tweets = master_data.get("tweets", [])
    user_gists = master_data.get("user_gists", {})
    print(f"  マスターGist内の登録ユーザー数: {len(user_gists)}")
    print(f"  マスターGist内のタイムラインツイート数: {len(master_tweets)}")

    # 2. Gist ID ごとにユーザーをグループ化
    gist_to_users = {}
    invalid_format_users = []
    
    for user, entry in user_gists.items():
        gid = get_gist_id_from_entry(entry)
        if gid:
            gist_to_users.setdefault(gid, []).append(user)
        else:
            invalid_format_users.append((user, entry))

    unique_gists = list(gist_to_users.keys())
    print(f"  検証が必要なユニークGist ID数: {len(unique_gists)}")
    if invalid_format_users:
        print(f"  ⚠️ 形式が不正なマッピング: {len(invalid_format_users)}件")
        for u, ent in invalid_format_users:
            print(f"    @{u} -> {ent}")

    # 3. 並列検証実行
    print(f"\n=== {len(unique_gists)}個のGistを並列スキャン中 ({args.threads}スレッド) ===")
    
    verified_statuses = {}  # user -> (is_valid, reason)
    completed_gists = 0
    total_gists = len(unique_gists)

    with ThreadPoolExecutor(max_workers=args.threads) as executor:
        futures = {
            executor.submit(verify_single_gist, gid, gist_to_users[gid], headers): gid
            for gid in unique_gists
        }

        for future in as_completed(futures):
            res = future.result()
            gid = res["gist_id"]
            results = res["results"]
            
            for user, (is_valid, reason) in results.items():
                verified_statuses[user] = (is_valid, reason)

            completed_gists += 1
            if completed_gists % 50 == 0 or completed_gists == total_gists:
                print(f"  進捗: [{completed_gists}/{total_gists}] ({completed_gists/total_gists*100:.1f}%) のGist検証完了")

    # 4. 検証結果の集計
    valid_users = []
    invalid_users = []  # list of (username, reason, gist_id)

    for user, entry in user_gists.items():
        gid = get_gist_id_from_entry(entry)
        if not gid:
            invalid_users.append((user, "Invalid map format (missing gist_id)", ""))
            continue
        
        is_valid, reason = verified_statuses.get(user, (False, "Verification skipped/failed"))
        if is_valid:
            valid_users.append(user)
        else:
            invalid_users.append((user, reason, gid))

    print("\n=== 検証サマリー ===")
    print(f"正常なユーザー数: {len(valid_users)}")
    print(f"不整合のあるユーザー数: {len(invalid_users)}")

    if invalid_users:
        print("\n--- 不整合ユーザー一覧 (先頭50件を表示) ---")
        for i, (user, reason, gid) in enumerate(invalid_users[:50]):
            print(f"  {i+1:2d}. @{user} (Gist: {gid[:8]}...) -> {reason}")
        if len(invalid_users) > 50:
            print(f"  ... 他 {len(invalid_users) - 50} ユーザー")

    # 5. 修復処理
    if invalid_users:
        invalid_usernames = set(u[0] for u in invalid_users)
        
        # タイムライン(tweets)内での不整合チェック
        timeline_tweets_to_remove = [t for t in master_tweets if t.get("username") in invalid_usernames]
        print(f"\nマスタータイムライン内の影響:")
        print(f"  不整合ユーザーによるツイート数: {len(timeline_tweets_to_remove)} / {len(master_tweets)} 件")

        if not args.repair:
            print("\n💡 [DRY-RUN] 修復を行うには --repair オプションを指定して実行してください。")
            print("   例: python3 scripts/verify_and_repair_gists.py --repair")
            print("   (Gist自体の削除は行わず、マスターGistのマッピングと不要ツイートのみを安全に削除します)")
        else:
            print("\n=== 修復の実行 ===")
            print(f"1. user_gists マッピングから {len(invalid_usernames)} ユーザーを削除中...")
            new_user_gists = {k: v for k, v in user_gists.items() if k not in invalid_usernames}
            
            print(f"2. マスタータイムラインから不整合なツイート {len(timeline_tweets_to_remove)} 件を削除中...")
            new_tweets = [t for t in master_tweets if t.get("username") not in invalid_usernames]
            
            master_data["user_gists"] = new_user_gists
            master_data["tweets"] = new_tweets
            
            updated_json = json.dumps(master_data, ensure_ascii=False, indent=2)
            
            # 安全確認: ファイル名を取得
            master_fname = "data.json"
            # 念のため元のマスターGistファイル名を確認
            meta_status, master_meta = fetch_gist_meta_with_retry(MASTER_GIST_ID, headers)
            if meta_status == 200 and master_meta:
                files = master_meta.get("files", {})
                for fname in ["data.json", "gallary_data.json"]:
                    if fname in files:
                        master_fname = fname
                        break

            payload = {
                "files": {
                    master_fname: {
                        "content": updated_json
                    }
                }
            }
            
            print(f"3. マスターGist ({MASTER_GIST_ID}) を更新中 ({master_fname})...")
            r = requests.patch(f"{GITHUB_API}/gists/{MASTER_GIST_ID}", headers=headers, json=payload)
            if r.status_code == 200:
                print("✅ マスターGistの修復が正常に完了しました！")
                print(f"   登録ユーザー数: {len(user_gists)} -> {len(new_user_gists)}")
                print(f"   タイムラインツイート数: {len(master_tweets)} -> {len(new_tweets)}")
            else:
                print(f"❌ 更新に失敗しました: HTTP {r.status_code}")
                print(r.text[:500])
                sys.exit(1)
    else:
        print("\n✨ 不整合は見つかりませんでした！Gist構成は完全に健全です。")

    # APIリミットの最終確認
    limit, remaining, reset = get_ratelimit_info(headers)
    if limit is not None:
        print(f"\n=== 最終 API Rate Limit: {remaining} / {limit} ===")

if __name__ == "__main__":
    main()
