#!/usr/bin/env python3
"""
adaptive_skip.py - アダプティブ・スキップ（バックオフ）管理スクリプト

更新がないアカウント（0 tweets saved）のクロール頻度を動的に下げる
アダプティブ・スキップ（バックオフ）機能のロジックと永続化を提供します。
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime

DATA_DIR = "data"
DEFAULT_STATE_FILE = os.path.join(DATA_DIR, "adaptive_skip_state.json")
DEFAULT_MAX_SKIP = int(os.environ.get("ADAPTIVE_SKIP_MAX", 10))


class AdaptiveSkipManager:
    """アカウントごとのバックオフ状態を管理するクラス"""

    def __init__(self, state_file=DEFAULT_STATE_FILE, max_skip=DEFAULT_MAX_SKIP):
        self.state_file = state_file
        self.max_skip = max_skip
        self.state = self._load_state()

    def _load_state(self):
        if os.path.exists(self.state_file) and os.path.getsize(self.state_file) > 0:
            try:
                with open(self.state_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, dict) and "users" in data:
                        return data
            except Exception as e:
                print(f"⚠️ Warning: Failed to load state file ({self.state_file}): {e}", file=sys.stderr)
        return {
            "version": 1,
            "updated_at": datetime.now().isoformat(),
            "max_skip_limit": self.max_skip,
            "users": {},
        }

    def save_state(self):
        os.makedirs(os.path.dirname(os.path.abspath(self.state_file)), exist_ok=True)
        self.state["updated_at"] = datetime.now().isoformat()
        self.state["max_skip_limit"] = self.max_skip
        temp_file = f"{self.state_file}.tmp.{os.getpid()}"
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(self.state, f, ensure_ascii=False, indent=2)
        os.replace(temp_file, self.state_file)

    def get_user_state(self, user):
        """指定ユーザーの現在の状態を取得（小文字で統一）"""
        key = user.lower()
        users = self.state.setdefault("users", {})
        if key not in users:
            users[key] = {
                "user": user,
                "skip_count": 0,
                "skip_remaining": 0,
                "consecutive_zeros": 0,
                "last_saved_count": None,
                "last_crawled_at": None,
            }
        return users[key]

    def should_skip(self, user, queue_skip_remaining=None, queue_skip_count=None):
        """
        クロールをスキップすべきか判定する。
        skip_remaining > 0 の場合:
            skip_remaining を 1 減らし、スキップ対象 (True) を返す。
        skip_remaining <= 0 の場合:
            クロール対象 (False) を返す。
        ※ queue_skip_remaining が与えられた場合はローカル状態と同期する。
        """
        user_state = self.get_user_state(user)

        # キュー側の値が指定されていれば同期
        if queue_skip_remaining is not None:
            user_state["skip_remaining"] = int(queue_skip_remaining)
        if queue_skip_count is not None:
            user_state["skip_count"] = int(queue_skip_count)

        remaining = user_state.get("skip_remaining", 0)
        count = user_state.get("skip_count", 0)

        if remaining > 0:
            new_remaining = remaining - 1
            user_state["skip_remaining"] = new_remaining
            self.save_state()
            return True, new_remaining, count

        return False, 0, count

    def record_result(self, user, saved_count, queue_skip_count=None):
        """
        クロール結果（tweets_saved）を記録し、バックオフカウンタを更新する。
        saved_count == 0 の場合:
            skip_count をインクリメント (上限 max_skip)
            skip_remaining を skip_count に設定
        saved_count > 0 の場合:
            skip_count = 0
            skip_remaining = 0 にリセット
        """
        user_state = self.get_user_state(user)

        if queue_skip_count is not None and queue_skip_count > user_state.get("skip_count", 0):
            user_state["skip_count"] = queue_skip_count

        current_skip_count = user_state.get("skip_count", 0)

        if saved_count == 0:
            new_skip_count = min(current_skip_count + 1, self.max_skip)
            new_skip_remaining = new_skip_count
            consecutive = user_state.get("consecutive_zeros", 0) + 1
        else:
            new_skip_count = 0
            new_skip_remaining = 0
            consecutive = 0

        user_state["skip_count"] = new_skip_count
        user_state["skip_remaining"] = new_skip_remaining
        user_state["consecutive_zeros"] = consecutive
        user_state["last_saved_count"] = saved_count
        user_state["last_crawled_at"] = datetime.now().isoformat()

        self.save_state()
        return new_skip_count, new_skip_remaining

    def update_queue_json_file(self, json_file, user, skip_count, skip_remaining, done=True, saved_count=None):
        """fetch_queue.json ファイル内の該当ユーザーのエントリを更新する"""
        if not os.path.exists(json_file):
            return False

        try:
            with open(json_file, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"❌ Error reading queue json file ({json_file}): {e}", file=sys.stderr)
            return False

        users = data.get("users", [])
        matched = False
        target_lower = user.lower()

        for entry in users:
            u = entry.get("user", "")
            if u.lower() == target_lower:
                entry["skip_count"] = skip_count
                entry["skip_remaining"] = skip_remaining
                entry["done"] = done
                if saved_count is not None:
                    entry["last_saved_count"] = saved_count
                matched = True
                break

        if not matched:
            users.append({
                "user": user,
                "count": data.get("default_count", 500),
                "stop_on_existing": True,
                "done": done,
                "skip_count": skip_count,
                "skip_remaining": skip_remaining,
            })
            data["users"] = users

        temp_path = f"{json_file}.tmp.{os.getpid()}"
        with open(temp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.replace(temp_path, json_file)
        return True

    def reset_queue_cycle(self, json_file):
        """全エントリが完了した際に done フラグのみをリセットし、スキップ状態を維持する"""
        if not os.path.exists(json_file):
            return False

        try:
            with open(json_file, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"❌ Error reading queue json file ({json_file}): {e}", file=sys.stderr)
            return False

        users = data.get("users", [])
        for entry in users:
            entry["done"] = False

        temp_path = f"{json_file}.tmp.{os.getpid()}"
        with open(temp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.replace(temp_path, json_file)
        return True

    def get_summary(self):
        """現在のバックオフ統計サマリーを返す"""
        users = self.state.get("users", {})
        total = len(users)
        skipping = sum(1 for u in users.values() if u.get("skip_remaining", 0) > 0)
        zero_backoff = sum(1 for u in users.values() if u.get("skip_count", 0) == 0)
        active_backoffs = [u.get("skip_count", 0) for u in users.values() if u.get("skip_count", 0) > 0]
        max_level = max(active_backoffs) if active_backoffs else 0

        return {
            "total_tracked_users": total,
            "currently_skipping": skipping,
            "active_crawling": total - skipping,
            "zero_backoff_users": zero_backoff,
            "max_backoff_level": max_level,
            "max_skip_limit": self.max_skip,
        }


def main():
    parser = argparse.ArgumentParser(description="Adaptive Skip Manager for Twitter Crawler")
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE, help="Path to adaptive skip state JSON file")
    parser.add_argument("--max-skip", type=int, default=DEFAULT_MAX_SKIP, help="Maximum skip count limit")

    subparsers = parser.add_subparsers(dest="command")

    # should-skip
    p_check = subparsers.add_parser("should-skip", help="Check if user should be skipped and consume 1 skip")
    p_check.add_argument("-u", "--user", required=True, help="Target username")
    p_check.add_argument("--queue-remaining", type=int, default=None, help="Skip remaining value from queue")
    p_check.add_argument("--queue-count", type=int, default=None, help="Skip count value from queue")
    p_check.add_argument("--json-file", default=None, help="Queue JSON file to update done status if skipped")

    # record
    p_record = subparsers.add_parser("record", help="Record crawl result and update skip counters")
    p_record.add_argument("-u", "--user", required=True, help="Target username")
    p_record.add_argument("-s", "--saved", type=int, required=True, help="Number of tweets saved")
    p_record.add_argument("--queue-count", type=int, default=None, help="Current skip count from queue")
    p_record.add_argument("--json-file", default=None, help="Queue JSON file to update")

    # reset-cycle
    p_reset = subparsers.add_parser("reset-cycle", help="Reset done flags for next cycle while keeping counters")
    p_reset.add_argument("--json-file", required=True, help="Queue JSON file")

    # status
    p_status = subparsers.add_parser("status", help="Show adaptive skip statistics")
    p_status.add_argument("-u", "--user", default=None, help="Filter for specific user")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    manager = AdaptiveSkipManager(state_file=args.state_file, max_skip=args.max_skip)

    if args.command == "should-skip":
        is_skip, remaining, count = manager.should_skip(
            args.user,
            queue_skip_remaining=args.queue_remaining,
            queue_skip_count=args.queue_count,
        )

        if is_skip and args.json_file:
            manager.update_queue_json_file(
                args.json_file,
                args.user,
                skip_count=count,
                skip_remaining=remaining,
                done=True,
            )

        result = {
            "user": args.user,
            "skip": is_skip,
            "skip_remaining": remaining,
            "skip_count": count,
        }
        print(json.dumps(result, ensure_ascii=False))

        # Exit code 0 if should skip, 1 if should crawl
        sys.exit(0 if is_skip else 1)

    elif args.command == "record":
        count, remaining = manager.record_result(
            args.user,
            args.saved,
            queue_skip_count=args.queue_count,
        )

        if args.json_file:
            manager.update_queue_json_file(
                args.json_file,
                args.user,
                skip_count=count,
                skip_remaining=remaining,
                done=True,
                saved_count=args.saved,
            )

        result = {
            "user": args.user,
            "saved_count": args.saved,
            "skip_count": count,
            "skip_remaining": remaining,
        }
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(0)

    elif args.command == "reset-cycle":
        success = manager.reset_queue_cycle(args.json_file)
        if success:
            print(f"✅ Reset cycle done flags in {args.json_file}")
            sys.exit(0)
        else:
            print(f"❌ Failed to reset cycle in {args.json_file}", file=sys.stderr)
            sys.exit(1)

    elif args.command == "status":
        if args.user:
            state = manager.get_user_state(args.user)
            print(json.dumps(state, ensure_ascii=False, indent=2))
        else:
            summary = manager.get_summary()
            print(json.dumps(summary, ensure_ascii=False, indent=2))
        sys.exit(0)


if __name__ == "__main__":
    main()
