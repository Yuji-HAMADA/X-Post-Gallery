#!/usr/bin/env python3
"""
X (Twitter) 画像URLのデッドリンク（404等）を検知し、Gist上のデータをクリーンアップするスクリプト。
アカウントごとのチェック履歴・進捗を保存し、中断時のレジューム（再開）に対応。
"""

import argparse
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import requests

GITHUB_API = "https://api.github.com"
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
DEFAULT_STATE_FILE = Path(__file__).resolve().parent.parent / "data" / "cleanup_dead_links_state.json"


def get_env_value(key: str) -> str:
    """環境変数または .env から指定キーの値を読み出す"""
    val = os.environ.get(key, "").strip()
    if val:
        return val
    env_path = Path(__file__).resolve().parent.parent / ".env"
    if env_path.exists():
        text = env_path.read_text(encoding="utf-8")
        m = re.search(rf"^{re.escape(key)}=(.*)$", text, re.MULTILINE)
        if m:
            val = m.group(1).strip()
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                val = val[1:-1]
            return val
    return ""


def get_required_env(key: str) -> str:
    """必須設定値を読み出す（未設定時はエラー終了）"""
    val = get_env_value(key)
    if not val:
        print(f"❌ エラー: {key} が環境変数または .env に設定されていません。", file=sys.stderr)
        sys.exit(1)
    return val


def load_state(path: Path) -> dict:
    """進捗ログ・状態ファイルを読み込む"""
    if path.exists():
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"⚠️ 状態ファイルの読み込みに失敗しました ({e})。新規作成します。")
    return {"checked_accounts": {}}


def save_state(path: Path, state: dict) -> None:
    """進捗ログ・状態ファイルをアトミックに保存する"""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(".tmp")
    with open(temp_path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    temp_path.replace(path)


def make_headers(token: str) -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": DEFAULT_USER_AGENT,
    }


def fetch_gist_json(gist_id: str, headers: Dict[str, str]) -> Tuple[Optional[str], Optional[dict]]:
    """Gistのファイル名とJSONデータを取得"""
    url = f"{GITHUB_API}/gists/{gist_id}"
    resp = requests.get(url, headers=headers, timeout=15)
    if resp.status_code != 200:
        return None, None

    files = resp.json().get("files", {})
    filename = next(
        (name for name in ["data.json", "gallary_data.json"] if name in files),
        next((name for name in files if name.endswith(".json")), None),
    )
    if not filename:
        return None, None

    file_info = files[filename]
    if file_info.get("truncated", False):
        raw_resp = requests.get(file_info.get("raw_url"), timeout=15)
        return (filename, raw_resp.json()) if raw_resp.status_code == 200 else (None, None)

    content = file_info.get("content")
    if content:
        try:
            return filename, json.loads(content)
        except json.JSONDecodeError:
            pass

    raw_url = file_info.get("raw_url")
    if raw_url:
        raw_resp = requests.get(raw_url, timeout=15)
        if raw_resp.status_code == 200:
            return filename, raw_resp.json()

    return None, None


def update_gist(gist_id: str, filename: str, data: dict, headers: Dict[str, str]) -> bool:
    """Gistの内容を更新"""
    url = f"{GITHUB_API}/gists/{gist_id}"
    payload = {
        "files": {
            filename: {
                "content": json.dumps(data, ensure_ascii=False, indent=2)
            }
        }
    }
    resp = requests.patch(url, headers=headers, json=payload, timeout=20)
    return resp.status_code == 200


def check_url_status(url: str, session: requests.Session, timeout: int = 5) -> Tuple[str, bool]:
    """画像URLの生存判定 (404/403/エラー時は False)"""
    try:
        r = session.head(url, timeout=timeout, allow_redirects=True)
        if r.status_code == 200:
            return url, True
        if r.status_code in (404, 403, 410):
            return url, False
        r = session.get(url, timeout=timeout, stream=True, allow_redirects=True)
        is_alive = (r.status_code == 200)
        r.close()
        return url, is_alive
    except Exception:
        return url, False


def check_urls_batch(urls: List[str], max_threads: int = 10) -> Dict[str, bool]:
    """複数URLの生存確認を並行実行"""
    unique_urls = list(set(urls))
    results = {}
    with requests.Session() as session:
        session.headers.update({"User-Agent": DEFAULT_USER_AGENT})
        with ThreadPoolExecutor(max_workers=max_threads) as executor:
            future_to_url = {
                executor.submit(check_url_status, url, session): url
                for url in unique_urls
            }
            for future in as_completed(future_to_url):
                url, is_alive = future.result()
                results[url] = is_alive
    return results


def clean_tweets(tweets: List[dict], url_status_map: Dict[str, bool]) -> Tuple[List[dict], int]:
    """デッドリンクを除去し、有効な画像が残ったツイートのみを返す"""
    cleaned_tweets = []
    removed_url_count = 0

    for tweet in tweets:
        media_urls = tweet.get("media_urls", [])
        alive_media = [u for u in media_urls if url_status_map.get(u, True)]
        removed_url_count += (len(media_urls) - len(alive_media))

        if alive_media:
            updated_tweet = dict(tweet)
            updated_tweet["media_urls"] = alive_media
            cleaned_tweets.append(updated_tweet)

    return cleaned_tweets, removed_url_count


def process_user_gist(
    username: str,
    gist_id: str,
    headers: Dict[str, str],
    dry_run: bool,
    threads: int,
) -> Optional[dict]:
    """1アカウントのGistを処理し、結果ログ情報を返す（スキップ/失敗時はNone）"""
    print(f"\n[@{username}] Gist ({gist_id}) を取得中...")
    filename, gist_data = fetch_gist_json(gist_id, headers)
    if not gist_data or not filename:
        print("  ⚠️ Gist データの取得に失敗しました。")
        return None

    is_multi_user = "users" in gist_data and username in gist_data["users"]
    tweets = (gist_data["users"][username].get("tweets", []) if is_multi_user
              else gist_data.get("tweets", []))

    now_iso = datetime.now(timezone.utc).isoformat()
    if not tweets:
        print("  ツイートデータが見つかりません。")
        return {
            "checked_at": now_iso,
            "gist_id": gist_id,
            "tweets_count": 0,
            "media_urls_count": 0,
            "dead_urls_count": 0,
            "removed_tweets_count": 0,
            "status": "empty_tweets",
        }

    all_urls = [u for t in tweets for u in t.get("media_urls", [])]
    if not all_urls:
        print("  登録画像URL: 0件")
        return {
            "checked_at": now_iso,
            "gist_id": gist_id,
            "tweets_count": len(tweets),
            "media_urls_count": 0,
            "dead_urls_count": 0,
            "removed_tweets_count": 0,
            "status": "no_media_urls",
        }

    print(f"  ツイート数: {len(tweets)}, 登録画像URL数: {len(all_urls)}")
    print(f"  URL判定中 ({threads} スレッド)...")
    url_status_map = check_urls_batch(all_urls, max_threads=threads)

    dead_count = sum(1 for is_alive in url_status_map.values() if not is_alive)
    if dead_count == 0:
        print("  ✨ デッドリンクは見つかりませんでした。")
        return {
            "checked_at": now_iso,
            "gist_id": gist_id,
            "tweets_count": len(tweets),
            "media_urls_count": len(all_urls),
            "dead_urls_count": 0,
            "removed_tweets_count": 0,
            "status": "clean",
        }

    print(f"  🚨 デッドリンク検出: {dead_count} / {len(url_status_map)} 件 (ユニークURL)")

    cleaned_tweets, removed_urls = clean_tweets(tweets, url_status_map)
    removed_tweets = len(tweets) - len(cleaned_tweets)
    print(f"  除外対象: 画像URL {removed_urls}件, 該当ツイート {removed_tweets}件")

    if is_multi_user:
        gist_data["users"][username]["tweets"] = cleaned_tweets
    else:
        gist_data["tweets"] = cleaned_tweets

    status_str = "dry_run"
    if dry_run:
        print("  [Dry-run] Gistの更新はスキップされました。")
    else:
        print(f"  Gist ({gist_id}) を更新中...")
        if update_gist(gist_id, filename, gist_data, headers):
            print("  ✅ Gistの更新が完了しました。")
            status_str = "updated"
        else:
            print("  ❌ Gistの更新に失敗しました。")
            status_str = "update_failed"

    return {
        "checked_at": now_iso,
        "gist_id": gist_id,
        "tweets_count": len(tweets),
        "media_urls_count": len(all_urls),
        "dead_urls_count": dead_count,
        "removed_tweets_count": removed_tweets,
        "status": status_str,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Twitter画像URLのデッドリンクを検知しGistをクリーンアップします（全件処理・レジューム対応）"
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="処理するアカウント数の上限（未指定時は全件処理）",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="検出のみ行いGistの更新は行わない",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="進捗ログを初期化し最初から再チェックする",
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=10,
        help="並行スレッド数 (デフォルト: 10)",
    )
    parser.add_argument(
        "--state-file",
        type=Path,
        default=DEFAULT_STATE_FILE,
        help=f"進捗ログ保存先JSONファイル (デフォルト: {DEFAULT_STATE_FILE})",
    )
    parser.add_argument(
        "--master-gist-id",
        default=None,
        help="Master Gist ID (省略時は .env または環境変数 MASTER_GIST_ID を使用)",
    )
    args = parser.parse_args()

    token = get_required_env("GITHUB_TOKEN")
    master_gist_id = args.master_gist_id or get_required_env("MASTER_GIST_ID")
    headers = make_headers(token)

    # 進捗状態のロード
    state_file: Path = args.state_file
    state = {"checked_accounts": {}} if args.reset else load_state(state_file)
    checked_accounts: dict = state.setdefault("checked_accounts", {})

    print(f"Master Gist ({master_gist_id}) を取得中...")
    _, master_data = fetch_gist_json(master_gist_id, headers)
    if not master_data or "user_gists" not in master_data:
        print("❌ Master Gistの取得に失敗しました。", file=sys.stderr)
        sys.exit(1)

    user_gists = master_data.get("user_gists", {})
    all_users = list(user_gists.keys())
    total_users = len(all_users)

    # レジューム処理: 未処理のアカウントを抽出
    pending_users = [u for u in all_users if u not in checked_accounts]
    skipped_count = total_users - len(pending_users)

    print(f"全登録アカウント数: {total_users}")
    if skipped_count > 0:
        print(f"進捗ログ確認: {skipped_count} 件チェック済み（スキップします）")

    target_users = pending_users[: args.limit] if args.limit is not None else pending_users
    print(f"今回の処理対象: {len(target_users)} 件")
    if args.dry_run:
        print("※ Dry-run モード: Gistの更新は行いません。")

    if not target_users:
        print("✨ すべてのアカウントのチェックが完了しています。")
        return

    processed_in_session = 0
    try:
        for idx, username in enumerate(target_users, 1):
            print(f"\n[{idx}/{len(target_users)}] @{username}")
            entry = user_gists[username]
            gist_id = entry.get("gist_id") if isinstance(entry, dict) else str(entry)
            if not gist_id:
                print("  ⚠️ Gist ID が見つかりません。")
                continue

            result = process_user_gist(username, gist_id, headers, args.dry_run, args.threads)
            if result:
                checked_accounts[username] = result
                save_state(state_file, state)
                processed_in_session += 1

    except KeyboardInterrupt:
        print("\n\n⚠️ 中断シグナル (Ctrl-C) を検知しました。")
        print(f"今回のセッションで完了したアカウント: {processed_in_session} 件")
        print(f"累計チェック済み: {len(checked_accounts)} / {total_users} 件")
        print(f"進捗ログ ({state_file}) を保存しました。次回実行時にここから自動再開します。")
        sys.exit(0)

    print(f"\n🎉 処理が完了しました。 (今回の処理: {processed_in_session} 件 / 累計: {len(checked_accounts)} 件)")


if __name__ == "__main__":
    main()
