"""
指定ユーザのポストを取得し、既存Gistにアペンドする。
  - 既存IDが見つかったら取得を停止（--stop-on-existing）
  - マスターGistは master 形式:
      {user_screen_name, user_gists:{user:gist_id}, tweets:[代表1件ずつ]}
  - ユーザGist（子）は multi-user 形式:
      {users: {user: {tweets:[]}}}
"""
import json
import os
import re
import shutil
import sys
import argparse
import subprocess
import tempfile
import time
from datetime import datetime, timezone, timedelta
from urllib.parse import parse_qs, urlsplit

DATA_DIR = "data"
TWEETS_JS = os.path.join(DATA_DIR, "tweets.js")
IG_TWEETS_JS = os.path.join(DATA_DIR, "instagram_tweets.js")
TIKTOK_TWEETS_JS = os.path.join(DATA_DIR, "tiktok_tweets.js")
RESULT_FILE = os.path.join(DATA_DIR, ".last_fetch_result.json")
IG_RESULT_FILE = os.path.join(DATA_DIR, ".last_fetch_result_instagram.json")
TIKTOK_RESULT_FILE = os.path.join(DATA_DIR, ".last_fetch_result_tiktok.json")
GIST_MAX_TWEETS = 2000  # 移動先Gistの上限
IG_URL_REFRESH_BUFFER_SECONDS = 24 * 3600        # Instagram画像署名URL (寿命~4日) の事前リフレッシュ閾値（残り24時間）
IG_VIDEO_URL_REFRESH_BUFFER_SECONDS = 6 * 3600   # Instagram動画署名URL (寿命~24時間) の事前リフレッシュ閾値（残り6時間）
TIKTOK_URL_REFRESH_BUFFER_SECONDS = 12 * 3600    # TikTokサムネイル/画像URL (寿命~48時間) の事前リフレッシュ閾値（残り12時間）
TIKTOK_VIDEO_URL_REFRESH_BUFFER_SECONDS = 3 * 3600  # TikTok動画URL (寿命~6時間) の事前リフレッシュ閾値（残り3時間）
USER_PATTERN = re.compile(r"^@([^:]+):")

def get_result_file_for_platform(platform="x"):
    if platform == "instagram":
        return IG_RESULT_FILE
    if platform == "tiktok":
        return TIKTOK_RESULT_FILE
    return RESULT_FILE

def get_tweets_js_for_platform(platform="x"):
    if platform == "instagram":
        return IG_TWEETS_JS
    if platform == "tiktok":
        return TIKTOK_TWEETS_JS
    return TWEETS_JS

def write_fetch_result(user, tweets_saved, status="ok", platform=None):
    """クローラーの取得結果（保存ツイート数など）をメタデータファイルに書き出す"""
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        resolved_platform = platform or os.environ.get("PLATFORM", "x").lower()
        result_path = get_result_file_for_platform(resolved_platform)
        with open(result_path, "w", encoding="utf-8") as f:
            json.dump({
                "user": user,
                "tweets_saved": tweets_saved,
                "status": status,
                "timestamp": int(time.time()),
            }, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"⚠️ Warning: Failed to write fetch result: {e}", file=sys.stderr)

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-g", "--gist-id", required=True, help="Append対象のGist ID")
    parser.add_argument("-u", "--user", default=None, help="Target user ID")
    parser.add_argument("-m", "--mode", default="post_only", help="(deprecated, ignored: always post_only)")
    parser.add_argument("-n", "--num", type=int, default=500, help=f"最大取得件数（上限{GIST_MAX_TWEETS}）")
    parser.add_argument("-s", "--stop-on-existing", action="store_true", help="既存IDに当たったら停止")
    parser.add_argument("--is-candidate", action="store_true", help="新規ユーザーの場合Candidateとして登録")
    parser.add_argument("--from-scratch", action="store_true", help="既存データを削除して最初から取得し直す")
    parser.add_argument("--force-empty", action="store_true", help="Gistが0件でも強制続行")
    parser.add_argument("-p", "--promote-gist-id", default=None,
                        help="移動先Gist IDを手動指定")
    parser.add_argument("--platform", choices=["x", "instagram", "tiktok"], default=os.environ.get("PLATFORM", "x").lower(),
                        help="取得元プラットフォーム (x / instagram / tiktok, default: x)")
    parser.add_argument("--skip-extract", action="store_true",
                        help="抽出スクリプトの実行をスキップし、既存の tweets.js から直接 Gist へ追記する（タイムライン一括投入用）")
    parser.add_argument("--max-no-new-scrolls", type=int, default=None, help="新規未検出連続スクロール上限（未指定時はextract_media.py既定値）")
    parser.add_argument("--max-runtime", type=int, default=None, help="最大実行秒数（未指定時はextract_media.py既定値）")
    args = parser.parse_args()
    if args.num > GIST_MAX_TWEETS:
        print(f"⚠️  --num {args.num} exceeds limit. Capping at {GIST_MAX_TWEETS}.")
        args.num = GIST_MAX_TWEETS
    return args

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

def group_tweets_by_user(tweets):
    groups = {}
    for tweet in tweets:
        user = extract_username(tweet)
        groups.setdefault(user, []).append(tweet)
    return groups

def snowflake_to_jst_str(snowflake_id):
    """Snowflake ID から JST 日時文字列 (YYYY-MM-DD HH:mm:ss JST) を生成"""
    if not snowflake_id:
        return ""
    try:
        val = int(str(snowflake_id))
        if val > 100000000000:
            ms = (val >> 22) + 1288834974650
            jst = timezone(timedelta(hours=9))
            dt = datetime.fromtimestamp(ms / 1000, tz=jst)
            return dt.strftime("%Y-%m-%d %H:%M:%S JST")
    except Exception:
        pass
    return ""

def is_instagram_tweet(tweet):
    """ツイート/投稿オブジェクトが Instagram 由来かどうかを判定する"""
    if not isinstance(tweet, dict):
        return False
    post_url = str(tweet.get("post_url") or "")
    if "instagram.com/" in post_url:
        return True
    for u in tweet.get("media_urls") or []:
        if "cdninstagram.com" in str(u):
            return True
    return False

def extract_instagram_url_expiry(url):
    """Instagram 署名付き CDN URL の oe= (16進Unix秒) 有効期限を返す"""
    if not url or "cdninstagram.com" not in str(url):
        return None
    try:
        qs = parse_qs(urlsplit(str(url)).query)
        oe_hex = qs.get("oe", [None])[0]
        if oe_hex:
            return int(oe_hex, 16)
    except Exception:
        return None
    return None

def needs_instagram_url_refresh(
    tweets,
    buffer_seconds=IG_URL_REFRESH_BUFFER_SECONDS,
    video_buffer_seconds=IG_VIDEO_URL_REFRESH_BUFFER_SECONDS,
    check_limit=None,
    now=None,
):
    """
    既存投稿（check_limit 指定時は先頭 check_limit 件）内に有効期限切れ間近の Instagram CDN URL があるか判定する。
    ※画像URL（寿命~4日）と動画URL（寿命~24時間）で別々の閾値を適用し、直近取得済み動画による毎回フル再取得を防止する。
    """
    if not tweets:
        return False
    cur = time.time() if now is None else float(now)
    target_tweets = tweets[:check_limit] if check_limit and check_limit > 0 else tweets
    for t in target_tweets:
        if not isinstance(t, dict):
            continue
        for u in (t.get("media_urls") or []):
            exp = extract_instagram_url_expiry(u)
            if exp is not None and (exp - cur) <= buffer_seconds:
                return True
        v_urls = list(t.get("video_urls") or [])
        if t.get("video_url"):
            v_urls.append(t["video_url"])
        for u in v_urls:
            exp = extract_instagram_url_expiry(u)
            if exp is not None and (exp - cur) <= video_buffer_seconds:
                return True
    return False

def is_tiktok_tweet(tweet):
    """ツイート/投稿オブジェクトが TikTok 由来かどうかを判定する"""
    if not isinstance(tweet, dict):
        return False
    post_url = str(tweet.get("post_url") or "")
    if "tiktok.com/" in post_url:
        return True
    for u in list(tweet.get("media_urls") or []) + list(tweet.get("video_urls") or []):
        s = str(u)
        if "tiktokcdn.com" in s or "tiktok.com/" in s:
            return True
    return False

def is_non_x_tweet(tweet):
    return is_instagram_tweet(tweet) or is_tiktok_tweet(tweet)

def extract_tiktok_url_expiry(url):
    """TikTok 署名付き CDN URL の x-expires= / expire= (10進Unix秒) 有効期限を返す"""
    if not url:
        return None
    s = str(url)
    if "tiktokcdn.com" not in s and "tiktok.com" not in s:
        return None
    try:
        qs = parse_qs(urlsplit(s).query)
        raw = qs.get("x-expires", [None])[0] or qs.get("expire", [None])[0]
        if raw and str(raw).isdigit():
            return int(raw)
    except Exception:
        return None
    return None

def needs_tiktok_url_refresh(
    tweets,
    buffer_seconds=TIKTOK_URL_REFRESH_BUFFER_SECONDS,
    video_buffer_seconds=TIKTOK_VIDEO_URL_REFRESH_BUFFER_SECONDS,
    check_limit=None,
    now=None,
):
    """既存投稿（check_limit 指定時は先頭 check_limit 件）内に有効期限切れ間近の TikTok CDN URL があるか判定する"""
    if not tweets:
        return False
    cur = time.time() if now is None else float(now)
    target_tweets = tweets[:check_limit] if check_limit and check_limit > 0 else tweets
    for t in target_tweets:
        if not isinstance(t, dict):
            continue
        for u in (t.get("media_urls") or []):
            exp = extract_tiktok_url_expiry(u)
            if exp is not None and (exp - cur) <= buffer_seconds:
                return True
        v_urls = list(t.get("video_urls") or [])
        if t.get("video_url"):
            v_urls.append(t["video_url"])
        for u in v_urls:
            exp = extract_tiktok_url_expiry(u)
            if exp is not None and (exp - cur) <= video_buffer_seconds:
                return True
    return False

def get_tweet_sort_key(tweet):
    """ツイートの投稿時刻ソートキー（ミリ秒タイムスタンプ）を返す"""
    if not tweet or not isinstance(tweet, dict):
        return 0
    id_str = str(tweet.get("id_str") or tweet.get("id") or "")
    # Instagram / TikTok の 19桁ID は Twitter Snowflake ではないため created_at を優先する
    if not is_non_x_tweet(tweet) and id_str.isdigit():
        val = int(id_str)
        if val > 100000000000:
            return (val >> 22) + 1288834974650
    created_at = tweet.get("created_at", "")
    if created_at:
        m = re.match(r"^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+JST$", created_at)
        if m:
            try:
                dt = datetime.strptime(created_at.replace(" JST", " +0900"), "%Y-%m-%d %H:%M:%S %z")
                return int(dt.timestamp() * 1000)
            except Exception:
                pass
        try:
            dt = datetime.strptime(created_at, "%a %b %d %H:%M:%S %z %Y")
            return int(dt.timestamp() * 1000)
        except Exception:
            pass
        try:
            iso_str = created_at.replace("Z", "+00:00")
            dt = datetime.fromisoformat(iso_str)
            return int(dt.timestamp() * 1000)
        except Exception:
            pass
    return 0

def has_media(tweet):
    if not isinstance(tweet, dict):
        return False
    if tweet.get("media_urls") and len(tweet["media_urls"]) > 0:
        return True
    if tweet.get("image_url") or tweet.get("media_url") or tweet.get("video_url") or tweet.get("video_urls"):
        return True
    return False

def check_user_has_video(tweets):
    """ユーザーのツイート群に動画が含まれているか判定"""
    if not tweets:
        return False
    for t in tweets:
        if not isinstance(t, dict):
            continue
        if t.get("video_url") or t.get("video_urls"):
            return True
        media = (t.get("tweet", {}).get("extended_entities", {}).get("media") or
                 t.get("tweet", {}).get("entities", {}).get("media"))
        if isinstance(media, list):
            for m in media:
                if isinstance(m, dict) and m.get("type") in ("video", "animated_gif"):
                    return True
    return False

def select_latest_thumbnail_tweet(tweets):
    """ユーザーのツイート群からサムネイル用最新メディアツイートを選出する"""
    if not tweets:
        return {}
    media_tweets = [t for t in tweets if has_media(t)]
    candidate_list = media_tweets if media_tweets else tweets
    return max(candidate_list, key=get_tweet_sort_key)

# ---------------------------------------------------------------------------
# Gist フォーマット判定
# ---------------------------------------------------------------------------

def is_master_gist_format(data):
    return isinstance(data, dict) and "user_gists" in data

def is_multi_user_format(data):
    return isinstance(data, dict) and "users" in data

def get_gist_id_from_entry(entry):
    """user_gists の値から gist_id を取得（新形式dict・旧形式string 両対応）"""
    if isinstance(entry, dict):
        return entry.get("gist_id")
    return entry  # legacy string format

def has_user_gists_id_changed(initial_gists_map, new_user_gists):
    """
    MASTER_GIST 内の user_gists の所属 Gist ID に変更があるかを判定する。
    新規ユーザー追加または Gist ID の変更がある場合は True、変更がなければ False。
    """
    if len(initial_gists_map) != len(new_user_gists):
        return True
    for u, new_entry in new_user_gists.items():
        if u not in initial_gists_map:
            return True
        old_id = initial_gists_map[u]
        new_id = get_gist_id_from_entry(new_entry)
        if old_id != new_id:
            return True
    return False

def has_master_tweets_changed(initial_tweets, new_tweets, target_user):
    """
    MASTER_GIST 内の対象ユーザーの最新サムネイル（id_str または created_at）に変更があるかを判定する。
    """
    target_lower = target_user.lower() if target_user else ""
    old_tweet = next((t for t in initial_tweets if extract_username(t).lower() == target_lower), None)
    new_tweet = next((t for t in new_tweets if extract_username(t).lower() == target_lower), None)

    if old_tweet is None and new_tweet is not None:
        return True
    if old_tweet is not None and new_tweet is None:
        return True
    if old_tweet and new_tweet:
        if str(old_tweet.get("id_str", "")) != str(new_tweet.get("id_str", "")):
            return True
        if old_tweet.get("created_at") != new_tweet.get("created_at"):
            return True
        if old_tweet.get("media_urls") != new_tweet.get("media_urls"):
            return True
    return False

def get_user_tweets(data, user):
    """データからユーザのツイートを取得"""
    if is_master_gist_format(data):
        if not user:
            return data.get("tweets", [])
        return [t for t in data.get("tweets", []) if _tweet_belongs_to_user(t, user)]
    if is_multi_user_format(data):
        return data.get("users", {}).get(user, {}).get("tweets", [])
    # fallback
    if isinstance(data, dict) and "tweets" in data:
        return data["tweets"]
    return data if isinstance(data, list) else []

def _tweet_belongs_to_user(tweet, user):
    if tweet.get("username") == user:
        return True
    if f"x.com/{user}/status/" in tweet.get("post_url", ""):
        return True
    if tweet.get("full_text", "").startswith(f"@{user}:"):
        return True
    return False

# ---------------------------------------------------------------------------
# Gist 取得
# ---------------------------------------------------------------------------

def fetch_gist_data(gist_id):
    try:
        result = subprocess.run(
            ["gh", "api", f"gists/{gist_id}"],
            capture_output=True, text=True, check=True,
        )
        gist_meta = json.loads(result.stdout)
    except Exception as e:
        print(f"❌ Failed to fetch Gist metadata: {e}")
        sys.exit(1)
    candidate_files = ["data.json", "gallary_data.json"]
    files = gist_meta.get("files", {})
    for filename in candidate_files:
        if filename not in files:
            continue
        raw_url = files[filename].get("raw_url")
        if not raw_url:
            continue
        try:
            dl = subprocess.run(
                ["curl", "-sf", "-L", raw_url],
                capture_output=True, text=True,
            )
            if dl.returncode == 0:
                return filename, json.loads(dl.stdout)
        except Exception:
            pass
    print("❌ No valid data found in Gist.")
    sys.exit(1)

def fetch_queue_data(queue_gist_id):
    """fetch_queue.json を安全に取得してパースした dict を返す"""
    try:
        res = subprocess.run(
            ["gh", "gist", "view", queue_gist_id, "-f", "fetch_queue.json"],
            capture_output=True, text=True,
        )
        if res.returncode == 0 and res.stdout.strip():
            return json.loads(res.stdout)
    except Exception as e:
        print(f"⚠️ Warning: Could not verify queue gist {queue_gist_id}: {e}", file=sys.stderr)
    return None

def fetch_all_queue_users():
    """Slot 0 および Slot 1 (sibling_gist_id / FETCH_QUEUE_SLOT1_GIST_ID) の全キュー登録ユーザー名（小文字 set）を取得する"""
    slot0_id = os.environ.get("FETCH_QUEUE_GIST_ID")
    if not slot0_id:
        return None

    slot0_data = fetch_queue_data(slot0_id)
    if slot0_data is None:
        return None

    queue_users = {
        u.get("user", "").lower()
        for u in slot0_data.get("users", [])
        if u.get("user")
    }

    slot1_id = (
        os.environ.get("FETCH_QUEUE_SLOT1_GIST_ID")
        or slot0_data.get("sibling_gist_id")
    )
    if slot1_id and slot1_id != slot0_id:
        slot1_data = fetch_queue_data(slot1_id)
        if slot1_data:
            queue_users.update(
                u.get("user", "").lower()
                for u in slot1_data.get("users", [])
                if u.get("user")
            )

    return queue_users

def select_promote_gist_from_master(full_data):
    """user_gists に登録されているGistのうち最後に追加されたIDを返す"""
    user_gists = full_data.get("user_gists", {})
    if not user_gists:
        return None
    seen = set()
    unique_gists = []
    for entry in user_gists.values():
        gist_id = get_gist_id_from_entry(entry)
        if gist_id and gist_id not in seen:
            unique_gists.append(gist_id)
            seen.add(gist_id)
    return unique_gists[-1] if unique_gists else None

def get_existing_ids_ordered(tweets):
    ids = []
    seen = set()
    for item in tweets:
        tid = item.get("id_str") or item.get("tweet", {}).get("id_str")
        if tid and tid not in seen:
            ids.append(tid)
            seen.add(tid)
    return ids

def write_skip_ids_file(ordered_ids):
    fd, path = tempfile.mkstemp(suffix=".txt", prefix="skip_ids_")
    with os.fdopen(fd, 'w') as f:
        for tid in ordered_ids:
            f.write(tid + "\n")
    return path

def run_extraction(args, skip_ids_file):
    platform = getattr(args, "platform", "x") or "x"
    if platform == "instagram":
        extractor_script = "scripts/extract_instagram_media.py"
    elif platform == "tiktok":
        extractor_script = "scripts/extract_tiktok_media.py"
    else:
        extractor_script = "scripts/extract_media.py"
    cmd = [
        sys.executable, extractor_script,
        "--mode", "post_only",
        "-n", str(args.num),
        "--skip-ids-file", skip_ids_file,
    ]
    if platform in ("instagram", "tiktok"):
        cmd.extend([
            "--output", get_tweets_js_for_platform(platform),
            "--result-file", get_result_file_for_platform(platform),
        ])
    if args.user:
        cmd.extend(["-u", args.user])
    if args.stop_on_existing:
        cmd.append("--stop-on-existing")
    if getattr(args, "max_no_new_scrolls", None) is not None:
        cmd.extend(["--max-no-new-scrolls", str(args.max_no_new_scrolls)])
    if getattr(args, "max_runtime", None) is not None:
        cmd.extend(["--max-runtime", str(args.max_runtime)])
    print(f"🚀 Running Extraction: {' '.join(cmd)}")
    res = subprocess.run(cmd)
    if res.returncode != 0:
        print(f"❌ Extraction script failed with exit code {res.returncode}")
        sys.exit(res.returncode)

def convert_raw_tweets_to_gist_format(raw_tweets):
    """アーカイブ形式 (tweets.js) の raw_tweets リストを Gist 保存用フォーマットに変換する"""
    converted = []
    for item in raw_tweets:
        tweet = item.get('tweet', item)
        media_list = (
            tweet.get('extended_entities', {}).get('media', [])
            or tweet.get('entities', {}).get('media', [])
        )
        if not media_list:
            continue
        media_urls = [m.get('media_url_https', '') for m in media_list if m.get('media_url_https')]
        post_url = tweet.get('post_url', '') or ''
        video_urls = []
        for m in media_list:
            eu = m.get('expanded_url', '')
            if not post_url:
                if '/status/' in eu:
                    post_url = re.sub(r'/(photo|video)/\d+$', '', eu)
                elif 'instagram.com/' in eu or 'tiktok.com/' in eu:
                    post_url = eu
            if m.get('type') == 'video':
                variants = m.get('video_info', {}).get('variants', [])
                mp4_variants = [v for v in variants if v.get('content_type') == 'video/mp4' or v.get('type') == 'video/mp4']
                if mp4_variants:
                    best = max(mp4_variants, key=lambda x: int(x.get('bitrate', 0) if x.get('bitrate') is not None else 0))
                    v_url = best.get('url') or best.get('src')
                    if v_url and v_url not in video_urls:
                        video_urls.append(v_url)
        if not media_urls and not video_urls:
            continue
        tweet_obj = {
            'full_text': tweet.get('full_text', ''),
            'created_at': tweet.get('created_at', ''),
            'media_urls': media_urls,
            'id_str': tweet.get('id_str', ''),
            'post_url': post_url,
        }
        if video_urls:
            tweet_obj['video_url'] = video_urls[0]
            tweet_obj['video_urls'] = video_urls
        converted.append(tweet_obj)
    return converted

def parse_tweets_js(platform="x"):
    tweets_path = get_tweets_js_for_platform(platform)
    if not os.path.exists(tweets_path):
        return []
    with open(tweets_path, 'r', encoding='utf-8') as f:
        content = f.read()
    json_str = re.sub(r'^window\.YTD\.tweets\.part0\s*=\s*', '', content)
    raw_tweets = json.loads(json_str)
    return convert_raw_tweets_to_gist_format(raw_tweets)

def append_tweets(existing_tweets, new_tweets, refresh_urls=False):
    if not new_tweets:
        return existing_tweets
    new_by_id = {t.get("id_str"): t for t in new_tweets if t.get("id_str")}
    existing_ids = {t.get("id_str") for t in existing_tweets if t.get("id_str")}
    unique_new = [t for t in new_tweets if t.get("id_str") not in existing_ids]

    updated_existing = existing_tweets
    refreshed_count = 0
    if refresh_urls:
        updated_existing = []
        for t in existing_tweets:
            tid = t.get("id_str")
            fresh = new_by_id.get(tid) if tid else None
            if fresh:
                changed = (
                    t.get("media_urls") != fresh.get("media_urls")
                    or t.get("video_url") != fresh.get("video_url")
                    or t.get("video_urls") != fresh.get("video_urls")
                )
                if changed:
                    nt = dict(t)
                    if fresh.get("media_urls"):
                        nt["media_urls"] = fresh["media_urls"]
                    if fresh.get("video_url"):
                        nt["video_url"] = fresh["video_url"]
                    if fresh.get("video_urls"):
                        nt["video_urls"] = fresh["video_urls"]
                    if fresh.get("post_url") and not nt.get("post_url"):
                        nt["post_url"] = fresh["post_url"]
                    updated_existing.append(nt)
                    refreshed_count += 1
                    continue
            updated_existing.append(t)

    if not unique_new and refreshed_count == 0:
        return existing_tweets
    if unique_new:
        print(f"✨ Appended: {len(unique_new)} new tweets")
    if refreshed_count:
        print(f"🔄 Refreshed signed media URLs for {refreshed_count} existing posts")
    return unique_new + updated_existing

# ---------------------------------------------------------------------------
# Gist作成・移動 (インメモリ更新)
# ---------------------------------------------------------------------------

def create_gist_for_user(user, tweets):
    """新しいユーザGistを作成 (階層構造: users -> user -> tweets)"""
    data = {"users": {user: {"tweets": tweets}}}
    # tempdir 内に data.json という名前で作成（gh gist create はファイル名をそのまま使う）
    tmp_dir = tempfile.mkdtemp()
    tmp_file = os.path.join(tmp_dir, "data.json")
    try:
        with open(tmp_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        result = subprocess.run(
            ["gh", "gist", "create", tmp_file, "-d", "Gallery User Data"],
            capture_output=True, text=True,
        )
    finally:
        if os.path.exists(tmp_file):
            os.unlink(tmp_file)
        os.rmdir(tmp_dir)
    if result.returncode != 0:
        print(f"❌ Failed: {result.stderr}")
        sys.exit(1)
    return result.stdout.strip().rstrip("/").split("/")[-1]

def update_or_migrate_user_gist_in_memory(promote_gist_id, promote_data, user, merged_tweets, gist_cache):
    """ユーザGistのデータをメモリ上で更新し、必要なら新規Gistを作成してマイグレーションを行う。"""
    if not is_multi_user_format(promote_data):
        print(f"⚠️  Warning: Target Gist {promote_gist_id} is not in multi-user format. Converting...")
        promote_data = {"users": {}}

    users_data = dict(promote_data.get("users", {}))
    # 他の全ユーザの全ポスト数を合計
    current_total = sum(
        len(u.get("tweets", []))
        for u_name, u in users_data.items()
        if u_name != user
    )

    if current_total + len(merged_tweets) > GIST_MAX_TWEETS:
        merged_tweets = merged_tweets[:GIST_MAX_TWEETS]
        print(f"⚠️  Limit reached ({GIST_MAX_TWEETS}). Creating new Gist...")
        new_id = create_gist_for_user(user, merged_tweets)
        # 移行元のGistからユーザのデータを削除（メモリ上）
        if user in users_data:
            del users_data[user]
            # 移行元Gistの更新をキューに積む
            gist_cache[promote_gist_id]["data"] = {"users": users_data}
            gist_cache[promote_gist_id]["is_modified"] = True
        return new_id, {"users": {user: {"tweets": merged_tweets}}}

    # 追記保存（メモリ上）
    users_data[user] = {"tweets": merged_tweets}
    updated_data = {"users": users_data}
    return promote_gist_id, updated_data

# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def process_multi_user_append(master_data, new_tweets, promote_gist_id_override=None, from_scratch=False, is_candidate=False, refresh_urls=False):
    user_groups = group_tweets_by_user(new_tweets)
    user_gists_map = master_data.get("user_gists", {})
    master_tweets = master_data.get("tweets", [])

    # Gistの取得結果と更新状態をキャッシュして、最後に一括で書き込む
    gist_cache = {}  # { gist_id: {"filename": str, "data": dict, "is_modified": bool} }

    migrated_count = 0

    for user, tweets in user_groups.items():
        if user == "Unknown":
            if from_scratch:
                master_tweets = [t for t in master_tweets if extract_username(t) != "Unknown"]
                master_tweets = tweets + master_tweets
            else:
                master_tweets = append_tweets(master_tweets, tweets, refresh_urls=refresh_urls)
            continue

        print(f"--- @{user} ---")
        canonical_user = user
        if user not in user_gists_map:
            for k in user_gists_map.keys():
                if k.lower() == user.lower():
                    canonical_user = k
                    break

        promote_gist_id = (
            promote_gist_id_override
            or get_gist_id_from_entry(user_gists_map.get(canonical_user))
            or select_promote_gist_from_master(master_data)
        )
        if not promote_gist_id:
            promote_gist_id = create_gist_for_user(user, [])

        # キャッシュから取得、なければフェッチ
        if promote_gist_id in gist_cache:
            p_filename = gist_cache[promote_gist_id]["filename"]
            p_data = gist_cache[promote_gist_id]["data"]
        else:
            p_filename, p_data = fetch_gist_data(promote_gist_id)
            gist_cache[promote_gist_id] = {"filename": p_filename, "data": p_data, "is_modified": False}

        if from_scratch:
            # 既存データを削除して取得データで丸ごと置き換え
            merged = tweets
            migrated_count += len(merged)
            # マスターGistのツイート一覧からも当該ユーザーの過去ツイートを除外
            master_tweets = [t for t in master_tweets if extract_username(t).lower() != user.lower()]
        else:
            existing = get_user_tweets(p_data, user)
            merged = append_tweets(existing, tweets, refresh_urls=refresh_urls)
            if merged == existing:
                continue
            migrated_count += max(len(merged) - len(existing), 0)

        # メモリ上でデータを更新
        final_id, updated_data = update_or_migrate_user_gist_in_memory(
            promote_gist_id, p_data, user, merged, gist_cache,
        )

        # キャッシュを更新し、変更フラグを立てる
        if final_id not in gist_cache:
            # 新規Gistが作成された場合。作成時に書き込まれているので is_modified=False
            gist_cache[final_id] = {"filename": "data.json", "data": updated_data, "is_modified": False}
        else:
            gist_cache[final_id]["data"] = updated_data
            gist_cache[final_id]["is_modified"] = True

        existing_entry = user_gists_map.get(canonical_user)
        now_ms = int(time.time() * 1000)
        user_is_candidate = False
        if isinstance(existing_entry, dict):
            user_priority = existing_entry.get("priority_updated_at", now_ms)
            user_is_candidate = existing_entry.get("is_candidate", False)
        elif existing_entry is not None:
            user_priority = now_ms
            user_is_candidate = False
        else:
            user_priority = now_ms
            user_is_candidate = is_candidate

        old_has_video = existing_entry.get("has_video", False) if isinstance(existing_entry, dict) else False
        user_has_video = check_user_has_video(merged) or old_has_video

        entry_data = {
            "gist_id": final_id,
            "priority_updated_at": user_priority,
        }
        if user_is_candidate:
            entry_data["is_candidate"] = True
        if user_has_video:
            entry_data["has_video"] = True
        user_gists_map[canonical_user] = entry_data
        master_tweets = [t for t in master_tweets if extract_username(t).lower() != user.lower()]
        latest = select_latest_thumbnail_tweet(merged)
        master_entry = {
            "id_str": latest.get("id_str", ""),
            "username": user,
            "media_urls": latest.get("media_urls", [])[:1],
        }
        created_at = latest.get("created_at") or (
            "" if is_non_x_tweet(latest) else snowflake_to_jst_str(master_entry["id_str"])
        )
        if created_at:
            master_entry["created_at"] = created_at
        if latest.get("post_url"):
            master_entry["post_url"] = latest["post_url"]
        if latest.get("video_url"):
            master_entry["video_url"] = latest["video_url"]
        if latest.get("video_urls"):
            master_entry["video_urls"] = latest["video_urls"]
        master_tweets.insert(0, master_entry)

    print(f"📊 Total migrated to user Gists: {migrated_count} tweets")

    # ループ終了後、変更があったGistのみを一括で更新する
    for g_id, cache_info in gist_cache.items():
        if cache_info.get("is_modified"):
            print(f"☁️ Batch Updating Gist ({g_id})...")
            fd, tmp = tempfile.mkstemp(suffix=".json")
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as f:
                    json.dump(cache_info["data"], f, ensure_ascii=False, indent=2)
                subprocess.run(["gh", "gist", "edit", g_id, "-f", cache_info["filename"], tmp])
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)

    # スキーマ統一: 全ユーザーエントリに priority_updated_at を持たせる（未設定は 0）
    unified_user_gists = {}
    for u, entry in user_gists_map.items():
        if isinstance(entry, dict):
            e_dict = {
                "gist_id": entry.get("gist_id", ""),
                "priority_updated_at": int(entry.get("priority_updated_at", 0) or 0),
            }
            if entry.get("is_candidate"):
                e_dict["is_candidate"] = True
            if entry.get("has_video"):
                e_dict["has_video"] = True
            unified_user_gists[u] = e_dict
        else:
            unified_user_gists[u] = {
                "gist_id": str(entry),
                "priority_updated_at": 0,
            }

    master_data["user_gists"] = unified_user_gists
    master_data["tweets"] = master_tweets
    return master_data

def validate_master_gist_update(initial_user_gists, final_output, platform="x"):
    """
    マスターGist上書き前の安全検証:
    1. プラットフォーム不一致（X更新時に Instagram マスターデータで上書き等）を拒否
    2. 既存アカウント数が20件以上あるマスターGistでの急激な減少（50%未満）を拒否
    """
    if not isinstance(final_output, dict) or "user_gists" not in final_output:
        return False, "Invalid master Gist payload (missing user_gists)"

    screen_name = str(final_output.get("user_screen_name") or "").strip().lower()
    if platform == "x" and screen_name in ("instagram", "tiktok"):
        return False, f"Cross-platform safety block: refusing to write {screen_name} master payload into X Master Gist"
    if platform == "instagram" and screen_name == "tiktok":
        return False, "Cross-platform safety block: refusing to write tiktok master payload into Instagram Master Gist"
    if platform == "tiktok" and screen_name == "instagram":
        return False, "Cross-platform safety block: refusing to write instagram master payload into TikTok Master Gist"

    new_count = len(final_output.get("user_gists", {}))
    old_count = len(initial_user_gists or {})
    if old_count >= 20 and new_count < (old_count * 0.5):
        return False, f"Catastrophic shrink safety block: user_gists would drop from {old_count} to {new_count}"

    return True, ""


def write_master_gist_safely(gist_id, gist_filename, final_output, local_asset_path):
    """
    共有ローカルパス (assets/data/data.json) との競合を防ぐため、
    プロセス固有の一時ファイルから gh gist edit を実行し、ローカルミラーはアトミック置換する。
    """
    fd, tmp_upload = tempfile.mkstemp(suffix=".json", prefix="master_upload_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(final_output, f, ensure_ascii=False, indent=2)
        subprocess.run(["gh", "gist", "edit", gist_id, "-f", gist_filename, tmp_upload])
    finally:
        if os.path.exists(tmp_upload):
            os.unlink(tmp_upload)

    try:
        os.makedirs(os.path.dirname(local_asset_path) or ".", exist_ok=True)
        tmp_local = f"{local_asset_path}.tmp.{os.getpid()}"
        with open(tmp_local, "w", encoding="utf-8") as f:
            json.dump(final_output, f, ensure_ascii=False, indent=2)
        os.replace(tmp_local, local_asset_path)
    except Exception as e:
        print(f"⚠️ Warning: Failed to update local mirror {local_asset_path}: {e}", file=sys.stderr)


def main():
    args = parse_args()
    skip_extract = bool(getattr(args, "skip_extract", False))
    if not args.user and not skip_extract:
        print("❌ Error: Target user ID (-u/--user) is required for append_to_gist.py.")
        print("💡 Hint: To automatically discover accounts from your timeline and expand Candidate gallery, run:")
        print("   ./scripts/run_expand_timeline_local.sh")
        sys.exit(1)

    gist_filename, full_data = fetch_gist_data(args.gist_id)

    if not is_master_gist_format(full_data):
        print(f"❌ Error: {args.gist_id} is not a Master Gist.")
        sys.exit(1)

    # skip_ids 作成（Instagram / TikTok 定期URLリフレッシュ判定含む）
    refresh_urls = False
    skip_ids_file = None
    if not skip_extract:
        if args.from_scratch:
            args.stop_on_existing = False
            skip_ids_file = write_skip_ids_file([])
        elif args.user:
            ug_id = get_gist_id_from_entry(full_data.get("user_gists", {}).get(args.user))
            if ug_id:
                _, p_data = fetch_gist_data(ug_id)
                existing = get_user_tweets(p_data, args.user)
            else:
                existing = []
            if args.platform == "instagram" and needs_instagram_url_refresh(existing, check_limit=args.num):
                print(f"🔄 [Instagram] Expiring signed CDN URLs detected for @{args.user}. Refreshing URLs in-place...")
                refresh_urls = True
                args.stop_on_existing = False
                skip_ids_file = write_skip_ids_file([])
            elif args.platform == "tiktok" and needs_tiktok_url_refresh(existing, check_limit=args.num):
                print(f"🔄 [TikTok] Expiring signed CDN URLs detected for @{args.user}. Refreshing URLs in-place...")
                refresh_urls = True
                args.stop_on_existing = False
                skip_ids_file = write_skip_ids_file([])
            else:
                skip_ids_file = write_skip_ids_file(get_existing_ids_ordered(existing))
        else:
            skip_ids_file = write_skip_ids_file(
                get_existing_ids_ordered(full_data.get("tweets", []))
            )
    elif args.platform in ("instagram", "tiktok"):
        # タイムライン一括投入時は既存投稿の署名URLも最新にリフレッシュ
        refresh_urls = True

    # クロール開始前のマスターGistおよびキューの状態を記録（クロール中の削除検知用）
    user_lower = args.user.lower() if args.user else None
    initial_had_master_user = (
        any(k.lower() == user_lower for k in full_data.get("user_gists", {}).keys())
        if user_lower
        else False
    )
    initial_queue_users = fetch_all_queue_users() if user_lower else None
    initial_had_queue_user = (
        (user_lower in initial_queue_users)
        if initial_queue_users is not None
        else False
    )

    platform = getattr(args, "platform", "x")
    if platform not in ("x", "instagram", "tiktok"):
        platform = "x"
    if platform in ("instagram", "tiktok"):
        os.environ["PLATFORM"] = platform

    if not skip_extract:
        try:
            run_extraction(args, skip_ids_file)
        finally:
            if skip_ids_file and os.path.exists(skip_ids_file):
                os.unlink(skip_ids_file)

    new_tweets = parse_tweets_js(platform=platform) if platform in ("instagram", "tiktok") else parse_tweets_js()
    if not new_tweets:
        print("✅ No new tweets.")
        write_fetch_result(args.user, 0, status="no_new_tweets")
        sys.exit(0)

    # --- 防御策: 保存直前の最新マスターGist再フェッチと削除検知 ---
    # クロール中に他ユーザーの追加・削除があった場合の上書き競合を防ぐため最新マスターGistを取得
    gist_filename, fresh_master_data = fetch_gist_data(args.gist_id)
    if not is_master_gist_format(fresh_master_data):
        print(f"❌ Error: {args.gist_id} is not a Master Gist.")
        sys.exit(1)

    if user_lower:
        # 1. 抽出前にマスターGistにいたが、抽出完了時に削除されていたケースの検知
        fresh_has_master_user = any(k.lower() == user_lower for k in fresh_master_data.get("user_gists", {}).keys())
        if initial_had_master_user and not fresh_has_master_user:
            print(f"⚠️ User @{args.user} was removed from Master Gist during crawl. Aborting append to prevent zombie resurrection.")
            write_fetch_result(args.user, 0, status="cancelled_user_deleted")
            sys.exit(0)

        # 2. キューからの削除検知
        # 抽出開始時にキューに存在していたが、抽出完了時に両スロットのキューから削除されていたケース
        if initial_had_queue_user:
            fresh_queue_users = fetch_all_queue_users()
            if fresh_queue_users is not None and user_lower not in fresh_queue_users:
                print(f"⚠️ User @{args.user} was removed from Fetch Queue during crawl. Aborting append to prevent zombie resurrection.")
                write_fetch_result(args.user, 0, status="cancelled_user_deleted")
                sys.exit(0)

    # 所属 Gist ID の変化および最新サムネイルツイートの変化を検知するため更新前の状態を記録
    initial_user_gists = {
        u: get_gist_id_from_entry(e)
        for u, e in fresh_master_data.get("user_gists", {}).items()
    }
    initial_master_tweets = list(fresh_master_data.get("tweets", []))

    final_output = process_multi_user_append(
        fresh_master_data,
        new_tweets,
        args.promote_gist_id,
        from_scratch=args.from_scratch,
        is_candidate=args.is_candidate,
        refresh_urls=refresh_urls,
    )
    if platform == "instagram":
        output_file = "assets/data/data_instagram.json"
    elif platform == "tiktok":
        output_file = "assets/data/data_tiktok.json"
    else:
        output_file = "assets/data/data.json"

    # 所属 Gist ID に変更がある場合、または対象ユーザーの最新ツイート（サムネイル/日時）が更新された場合に MASTER_GIST を更新
    gists_changed = has_user_gists_id_changed(initial_user_gists, final_output.get("user_gists", {}))
    if args.user:
        tweets_changed = has_master_tweets_changed(initial_master_tweets, final_output.get("tweets", []), args.user)
    else:
        tweets_changed = (final_output.get("tweets", []) != initial_master_tweets)

    if gists_changed or tweets_changed:
        ok, err_msg = validate_master_gist_update(initial_user_gists, final_output, platform=platform)
        if not ok:
            print(f"🚨 ABORTED Master Gist update: {err_msg}", file=sys.stderr)
            sys.exit(1)
        reason = (
            "User Gist ID changed"
            if gists_changed
            else (f"Latest thumbnail updated for @{args.user}" if args.user else "Timeline batch posts updated")
        )
        write_master_gist_safely(args.gist_id, gist_filename, final_output, output_file)
        print(f"✅ Master Gist updated! ({reason})")
    else:
        print(f"ℹ️ User Gist ID and latest thumbnail unchanged. Skipped Master Gist update.")

    write_fetch_result(args.user or f"{platform}_batch", len(new_tweets), status="success")

if __name__ == "__main__":
    main()
