#!/usr/bin/env python3
import argparse
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


def main():
    parser = argparse.ArgumentParser(description="Reset or refresh fetch queue in Gist")
    parser.add_argument(
        "--cycle",
        action="store_true",
        help="Reset 'done' flags only for a new crawl cycle while preserving adaptive skip counters",
    )
    parser.add_argument(
        "--slot",
        type=str,
        default="all",
        choices=["0", "1", "all"],
        help="Target slot to reset (0, 1, or all. Default: all)",
    )
    args = parser.parse_args()

    load_env()
    gh_token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if gh_token:
        os.environ["GH_TOKEN"] = gh_token

    slot0_id = os.environ.get("FETCH_QUEUE_GIST_ID")
    if not slot0_id:
        print("❌ Error: FETCH_QUEUE_GIST_ID is not set in .env")
        sys.exit(1)

    # Slot 0 の読み込みと sibling_gist_id (Slot 1) の特定
    proc = subprocess.run(
        ["gh", "gist", "view", slot0_id, "-f", "fetch_queue.json"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(f"❌ Error fetching slot 0 gist: {proc.stderr}")
        sys.exit(proc.returncode)

    try:
        slot0_data = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        print(f"❌ Error parsing JSON from slot 0: {e}")
        sys.exit(1)

    slot1_id = slot0_data.get("sibling_gist_id") or os.environ.get("FETCH_QUEUE_SLOT1_GIST_ID")

    target_slots = []
    if args.slot in ("0", "all"):
        target_slots.append((0, slot0_id, slot0_data))
    if args.slot in ("1", "all") and slot1_id:
        proc1 = subprocess.run(
            ["gh", "gist", "view", slot1_id, "-f", "fetch_queue.json"],
            capture_output=True,
            text=True,
        )
        if proc1.returncode == 0:
            try:
                target_slots.append((1, slot1_id, json.loads(proc1.stdout)))
            except json.JSONDecodeError:
                print(f"⚠️ Warning: Could not parse slot 1 JSON: {slot1_id}")

    for slot_num, gid, data in target_slots:
        users = data.get("users", [])
        if args.cycle:
            for u in users:
                u["done"] = False
            action_msg = f"Slot {slot_num}: Reset cycle for {len(users)} users (preserved adaptive skip counters)."
        else:
            old_count = len(users)
            data["users"] = []
            data["default_count"] = 500
            data["status"] = "idle"
            action_msg = f"Slot {slot_num}: Cleared {old_count} queued users."

        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".json") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            tmp_path = f.name

        try:
            edit_proc = subprocess.run(
                ["gh", "gist", "edit", gid, "-f", "fetch_queue.json", tmp_path],
                capture_output=True,
                text=True,
            )
            if edit_proc.returncode != 0:
                print(f"❌ Error updating slot {slot_num} gist: {edit_proc.stderr}")
            else:
                print(f"✅ {action_msg} ({gid})")
        finally:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)


if __name__ == "__main__":
    main()
