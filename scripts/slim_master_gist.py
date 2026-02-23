"""
マスターGistのtweetsをスリム形式に移行する一回限りスクリプト。
{full_text, created_at, post_url} を削除し、{username, id_str, media_urls[0:1]} のみ残す。
"""
import json
import os
import re
import subprocess
import sys
import tempfile

USER_PATTERN = re.compile(r"^@([^:]+):")

def extract_username(tweet):
    if tweet.get("username"):
        return tweet["username"]
    m = USER_PATTERN.match(tweet.get("full_text", ""))
    if m:
        return m.group(1).strip()
    post_url = tweet.get("post_url", "")
    m2 = re.search(r"x\.com/([^/]+)/status/", post_url)
    if m2:
        return m2.group(1)
    return "Unknown"

def fetch_gist(gist_id):
    result = subprocess.run(
        ["gh", "api", f"gists/{gist_id}"],
        capture_output=True, text=True, check=True,
    )
    meta = json.loads(result.stdout)
    files = meta.get("files", {})
    for fname in ["data.json", "gallary_data.json"]:
        if fname in files:
            raw_url = files[fname]["raw_url"]
            dl = subprocess.run(["curl", "-sf", "-L", raw_url], capture_output=True, text=True)
            if dl.returncode == 0:
                return fname, json.loads(dl.stdout)
    print("❌ data.json not found")
    sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 slim_master_gist.py <master_gist_id>")
        sys.exit(1)

    gist_id = sys.argv[1]
    print(f"Fetching master Gist {gist_id}...")
    filename, data = fetch_gist(gist_id)

    tweets = data.get("tweets", [])
    print(f"tweets count: {len(tweets)}")

    already_slim = sum(1 for t in tweets if "username" in t and "full_text" not in t)
    print(f"already slim: {already_slim}")

    slimmed = []
    for t in tweets:
        username = extract_username(t)
        slimmed.append({
            "id_str": t.get("id_str", ""),
            "username": username,
            "media_urls": t.get("media_urls", [])[:1],
        })

    data["tweets"] = slimmed

    fd, tmp = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f"Updating Gist {gist_id}...")
        result = subprocess.run(
            ["gh", "gist", "edit", gist_id, "-f", filename, tmp],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"❌ Failed: {result.stderr}")
            sys.exit(1)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print(f"✅ Done. {len(slimmed)} tweets slimmed.")

if __name__ == "__main__":
    main()
