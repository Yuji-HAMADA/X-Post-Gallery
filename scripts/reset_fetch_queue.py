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


def main():
    load_env()
    gh_token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if gh_token:
        os.environ["GH_TOKEN"] = gh_token

    gist_id = os.environ.get("FETCH_QUEUE_GIST_ID")
    if not gist_id:
        print("❌ Error: FETCH_QUEUE_GIST_ID is not set in .env")
        sys.exit(1)

    print(f"🔄 Reading fetch_queue.json from Gist: {gist_id}...")
    proc = subprocess.run(
        ["gh", "gist", "view", gist_id, "-f", "fetch_queue.json"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(f"❌ Error fetching gist: {proc.stderr}")
        sys.exit(proc.returncode)

    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        print(f"❌ Error parsing JSON: {e}")
        sys.exit(1)

    old_users_count = len(data.get("users", []))
    data["users"] = []
    data["default_count"] = 500

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".json") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        tmp_path = f.name

    try:
        edit_proc = subprocess.run(
            ["gh", "gist", "edit", gist_id, "-f", "fetch_queue.json", tmp_path],
            capture_output=True,
            text=True,
        )
        if edit_proc.returncode != 0:
            print(f"❌ Error updating gist: {edit_proc.stderr}")
            sys.exit(edit_proc.returncode)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

    print(f"✅ Queue reset successful (cleared {old_users_count} users).")
    print("   Next run of scripts/run_fetch_favorites_local.sh will reload all favorites from scratch.")


if __name__ == "__main__":
    main()
