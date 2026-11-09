#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def load_env():
    env_file = Path(".env")
    if not env_file.exists():
        return
    with open(env_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip().strip("\"'")
            os.environ.setdefault(key, val)


def get_gist_json(gist_id, filename):
    cmd = ["gh", "gist", "view", gist_id, "-f", filename]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"❌ Failed to fetch {filename} from Gist {gist_id}: {res.stderr}", file=sys.stderr)
        return None
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError as e:
        print(f"❌ Failed to parse JSON from {filename} in Gist {gist_id}: {e}", file=sys.stderr)
        return None


def update_gist_json(gist_id, filename, data):
    fd, tmp_path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        res = subprocess.run(
            ["gh", "gist", "edit", gist_id, "-f", filename, tmp_path],
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            print(f"❌ Failed to update {filename} in Gist {gist_id}: {res.stderr}", file=sys.stderr)
            return False
        return True
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def cleanup_adaptive_skip_state(removed_users, state_path="data/adaptive_skip_state.json"):
    """除外されたユーザーのアダプティブ・スキップ状態をクリーンアップ"""
    p = Path(state_path)
    if not p.exists():
        return
    try:
        with open(p, "r", encoding="utf-8") as f:
            state = json.load(f)
        
        modified = False
        lower_removed = {u.lower() for u in removed_users}
        for u in list(state.keys()):
            if u.lower() in lower_removed:
                del state[u]
                modified = True
        
        if modified:
            with open(p, "w", encoding="utf-8") as f:
                json.dump(state, f, ensure_ascii=False, indent=2)
            print(f"🧹 Cleaned up adaptive skip state for {len(removed_users)} removed users.")
    except Exception as e:
        print(f"⚠️ Warning: Could not clean adaptive skip state: {e}", file=sys.stderr)


def sync_favorites_to_queue(fav_gist_id, queue_gist_id, slot1_gist_id=None, dry_run=False):
    """favorites.json と fetch_queue.json を同期する"""
    fav_data = get_gist_json(fav_gist_id, "favorites.json")
    if not fav_data:
        print("❌ Cannot sync: favorites.json could not be loaded.")
        return False

    fav_users = fav_data.get("favorite_users", [])
    fav_map = {u.lower(): u for u in fav_users if u}
    print(f"📋 Loaded {len(fav_map)} active favorite users from favorites.json")

    queue_data = get_gist_json(queue_gist_id, "fetch_queue.json")
    if not queue_data or "users" not in queue_data:
        print("❌ Cannot sync: fetch_queue.json could not be loaded.")
        return False

    existing_users = queue_data.get("users", [])
    default_count = queue_data.get("default_count", 500)

    # 1. お気に入りから外されたユーザーをパージ（未処理 done: false の新規リクエストは保護）
    retained_users = []
    removed_from_queue = []
    for entry in existing_users:
        u_name = entry.get("user", "")
        is_fav = u_name.lower() in fav_map
        is_pending = (entry.get("done") is False)

        if is_fav or is_pending:
            retained_users.append(entry)
        else:
            removed_from_queue.append(u_name)

    # 2. 新規お気に入りユーザーを追加（既存の skip_count や done 状態はそのまま維持）
    existing_lower_set = {entry.get("user", "").lower() for entry in retained_users}
    added_to_queue = []
    for u_lower, original_name in fav_map.items():
        if u_lower not in existing_lower_set:
            new_entry = {
                "user": original_name,
                "count": default_count,
                "stop_on_existing": True,
                "done": False,
            }
            retained_users.append(new_entry)
            added_to_queue.append(original_name)

    has_changes = (len(removed_from_queue) > 0 or len(added_to_queue) > 0)

    if removed_from_queue:
        print(f"🗑️ Removed {len(removed_from_queue)} unfavorited users from Slot 0 queue: {removed_from_queue[:5]}{'...' if len(removed_from_queue) > 5 else ''}")
    if added_to_queue:
        print(f"✨ Added {len(added_to_queue)} new favorite users to Slot 0 queue: {added_to_queue[:5]}{'...' if len(added_to_queue) > 5 else ''}")

    if not has_changes:
        print("✅ Slot 0 queue is already perfectly synchronized with favorites.json.")
    else:
        queue_data["users"] = retained_users
        if not dry_run:
            print("💾 Updating Slot 0 fetch_queue.json in Gist...")
            success = update_gist_json(queue_gist_id, "fetch_queue.json", queue_data)
            if not success:
                return False
            print("✅ Successfully updated Slot 0 fetch_queue.json.")
        else:
            print("🔍 Dry-run: skipped updating Slot 0 Gist.")

    # Slot 1 からもお気に入り解除ユーザーを除外（存在する場合）
    if slot1_gist_id and removed_from_queue:
        slot1_data = get_gist_json(slot1_gist_id, "fetch_queue.json")
        if slot1_data and "users" in slot1_data:
            s1_users = slot1_data.get("users", [])
            s1_lower_removed = {u.lower() for u in removed_from_queue}
            s1_retained = [e for e in s1_users if e.get("user", "").lower() not in s1_lower_removed]
            if len(s1_retained) != len(s1_users):
                diff = len(s1_users) - len(s1_retained)
                print(f"🗑️ Removed {diff} unfavorited users from Slot 1 queue.")
                slot1_data["users"] = s1_retained
                if not dry_run:
                    update_gist_json(slot1_gist_id, "fetch_queue.json", slot1_data)

    # アダプティブ・スキップのローカル状態からも除外
    if removed_from_queue and not dry_run:
        cleanup_adaptive_skip_state(removed_from_queue)

    return True


def main():
    load_env()
    fav_id = os.environ.get("FAVORITE_GIST_ID")
    q0_id = os.environ.get("FETCH_QUEUE_GIST_ID")
    q1_id = os.environ.get("FETCH_QUEUE_SLOT1_GIST_ID")

    dry_run = "--dry-run" in sys.argv

    if not fav_id or not q0_id:
        print("❌ Error: FAVORITE_GIST_ID and FETCH_QUEUE_GIST_ID must be set in .env")
        sys.exit(1)

    print(f"🔄 Starting favorites synchronization (dry_run={dry_run})...")
    ok = sync_favorites_to_queue(fav_id, q0_id, slot1_gist_id=q1_id, dry_run=dry_run)
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
