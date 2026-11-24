import asyncio
import json
import os
import re
import sys
import time
import argparse
from datetime import datetime, timezone, timedelta
from urllib.parse import quote, urlsplit, urlunsplit, parse_qs, urlencode
from playwright.async_api import async_playwright

# --- 設定・定数 ---
DATA_DIR = "data"
OUTPUT_FILE = os.path.join(DATA_DIR, "tweets.js")
AUTH_PATH = os.path.join(DATA_DIR, "auth.json")
RESULT_FILE = os.path.join(DATA_DIR, ".last_fetch_result.json")
RESUME_DIR = os.path.join(DATA_DIR, "resume")
RESUME_TTL_SECONDS = 24 * 3600  # 再開データの有効期限（24時間）
JST = timezone(timedelta(hours=9))

def to_jst_timestamp(ts_str):
    """タイムスタンプ文字列を東京ローカルタイム（JST: YYYY-MM-DD HH:mm:ss JST）に変換"""
    if not ts_str:
        return ts_str
    try:
        cleaned = ts_str.strip()
        if cleaned.endswith("JST"):
            return cleaned
        cleaned = cleaned.replace("Z", "+00:00")
        dt = datetime.fromisoformat(cleaned)
        jst_dt = dt.astimezone(JST)
        return jst_dt.strftime("%Y-%m-%d %H:%M:%S JST")
    except Exception:
        return ts_str

def write_crawl_result(user, tweets_saved, status="ok"):
    """クローラーの取得結果（保存ツイート数など）をメタデータファイルに書き出す"""
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(RESULT_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "user": user,
                "tweets_saved": tweets_saved,
                "status": status,
                "timestamp": int(time.time()),
            }, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"⚠️ Warning: Failed to write crawl result: {e}", file=sys.stderr)

def write_tweets_output(tweets):
    """取得したツイート配列を window.YTD.tweets.part0 形式で書き出す"""
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        f.write("window.YTD.tweets.part0 = ")
        # 空リスト [] でも書き込むことで、Flutter側のエラーを防ぐ
        json.dump(tweets if tweets else [], f, ensure_ascii=False, indent=2)

# --- 再開（Resume）チェックポイント & GraphQL カーソル処理 ---

def get_resume_file_path(user):
    """ユーザーごとの再開状態ファイルパスを返す"""
    safe_user = re.sub(r'[^a-z0-9_.-]', '_', (user or "").strip().lower())
    return os.path.join(RESUME_DIR, f"{safe_user}.json")

def save_resume_state(user, tweets, seen_ids, cursor=None, target_num=None):
    """レート制限等で中断した際の取得済みデータ・カーソルをアトミックに保存する"""
    if not user:
        return
    if not tweets and not cursor:
        return
    try:
        os.makedirs(RESUME_DIR, exist_ok=True)
        path = get_resume_file_path(user)
        tmp_path = f"{path}.tmp.{os.getpid()}"
        payload = {
            "user": user,
            "target_num": target_num,
            "tweets": list(tweets),
            "seen_ids": sorted(str(x) for x in seen_ids if x),
            "cursor": cursor,
            "saved_at": int(time.time()),
        }
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp_path, path)
    except Exception as e:
        print(f"⚠️ Warning: Failed to save resume state: {e}", file=sys.stderr)

def load_resume_state(user, ttl_seconds=RESUME_TTL_SECONDS, now=None):
    """有効な再開状態ファイルが存在すれば読み込む（期限切れ・破損時は破棄して None）"""
    if not user:
        return None
    path = get_resume_file_path(user)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
        if not isinstance(state, dict):
            clear_resume_state(user)
            return None
        if str(state.get("user", "")).lower() != user.lower():
            return None
        saved_at = state.get("saved_at")
        current_time = time.time() if now is None else now
        if ttl_seconds is not None and saved_at is not None:
            if (current_time - float(saved_at)) > ttl_seconds:
                clear_resume_state(user)
                return None
        tweets = state.get("tweets")
        if not isinstance(tweets, list):
            clear_resume_state(user)
            return None
        return {
            "user": state.get("user", user),
            "target_num": state.get("target_num"),
            "tweets": tweets,
            "seen_ids": state.get("seen_ids") if isinstance(state.get("seen_ids"), list) else [],
            "cursor": state.get("cursor") if isinstance(state.get("cursor"), str) and state.get("cursor") else None,
            "saved_at": saved_at,
        }
    except Exception:
        clear_resume_state(user)
        return None

def clear_resume_state(user):
    """再開状態ファイルを削除する"""
    if not user:
        return
    path = get_resume_file_path(user)
    try:
        if os.path.exists(path):
            os.unlink(path)
    except Exception as e:
        print(f"⚠️ Warning: Failed to clear resume state: {e}", file=sys.stderr)

def apply_resume_state(resume_state, skip_ids):
    """再開状態から (restored_tweets, resumed_ids, resume_cursor) を復元する"""
    if not resume_state:
        return [], set(), None

    restored_tweets = []
    restored_tweet_ids = set()
    resumed_ids = {str(x) for x in resume_state.get("seen_ids", []) if x}

    for item in resume_state.get("tweets", []):
        if not isinstance(item, dict):
            continue
        tid = str(item.get("tweet", {}).get("id_str") or item.get("id_str") or "")
        if not tid:
            continue
        resumed_ids.add(tid)
        if tid in skip_ids or tid in restored_tweet_ids:
            continue
        restored_tweet_ids.add(tid)
        restored_tweets.append(item)

    resume_cursor = resume_state.get("cursor")
    return restored_tweets, resumed_ids, resume_cursor

def is_user_tweets_graphql_url(url):
    """X の UserTweets GraphQL エンドポイント URL かどうかを判定する"""
    if not url:
        return False
    try:
        parsed = urlsplit(url)
        path = parsed.path.rstrip("/")
        return "/i/api/graphql/" in path and path.endswith("/UserTweets")
    except Exception:
        return False

def extract_cursor_from_graphql_url(url):
    """GraphQL リクエスト URL の variables パラメータから cursor 値を抽出する"""
    try:
        qs = parse_qs(urlsplit(url).query, keep_blank_values=True)
        raw_vars = qs.get("variables", [None])[0]
        if not raw_vars:
            return None
        variables = json.loads(raw_vars)
        cursor = variables.get("cursor")
        return str(cursor) if cursor else None
    except Exception:
        return None

def inject_cursor_into_graphql_url(url, cursor):
    """初期 UserTweets GraphQL リクエスト URL の variables に再開用 cursor を注入する"""
    if not url or not cursor:
        return None
    try:
        parsed = urlsplit(url)
        qs = parse_qs(parsed.query, keep_blank_values=True)
        raw_vars = qs.get("variables", [None])[0]
        if not raw_vars:
            return None
        variables = json.loads(raw_vars)
        if not isinstance(variables, dict):
            return None
        # 既に cursor を含む後続ページリクエストは変更しない
        if variables.get("cursor"):
            return None
        variables["cursor"] = cursor
        qs["variables"] = [json.dumps(variables, separators=(",", ":"))]
        new_query = urlencode(qs, doseq=True)
        return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, new_query, parsed.fragment))
    except Exception:
        return None

def extract_user_tweets_page_info(payload):
    """UserTweets GraphQL レスポンスから (tweet_ids, bottom_cursor) を抽出する"""
    if not isinstance(payload, dict):
        return [], None

    user_result = payload.get("data", {}).get("user", {}).get("result", {})
    if not isinstance(user_result, dict):
        return [], None
    timeline_obj = (
        user_result.get("timeline_v2", {}).get("timeline")
        or user_result.get("timeline", {}).get("timeline")
        or {}
    )
    instructions = timeline_obj.get("instructions", [])
    if not isinstance(instructions, list):
        return [], None

    tweet_ids = []
    bottom_cursor = None

    for inst in instructions:
        if not isinstance(inst, dict) or inst.get("type") != "TimelineAddEntries":
            continue
        entries = inst.get("entries", [])
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            entry_id = str(entry.get("entryId", ""))
            content = entry.get("content", {})
            if not isinstance(content, dict):
                continue

            if content.get("cursorType") == "Bottom" and content.get("value"):
                bottom_cursor = str(content["value"])
                continue

            # プロモーション投稿は除外
            if entry_id.startswith("promoted-tweet-") or content.get("itemContent", {}).get("promotedMetadata"):
                continue

            if entry_id.startswith("tweet-"):
                tid = entry_id[len("tweet-"):]
                if tid.isdigit():
                    tweet_ids.append(tid)
                    continue

            tweet_res = content.get("itemContent", {}).get("tweet_results", {}).get("result", {})
            if isinstance(tweet_res, dict):
                rest_id = tweet_res.get("rest_id") or tweet_res.get("tweet", {}).get("rest_id")
                if rest_id and str(rest_id).isdigit():
                    tweet_ids.append(str(rest_id))
                    continue

            # スレッドモジュール（TimelineTimelineModule）内のツイートも収集
            items = content.get("items")
            if isinstance(items, list):
                for sub in items:
                    if not isinstance(sub, dict):
                        continue
                    sub_res = sub.get("item", {}).get("itemContent", {}).get("tweet_results", {}).get("result", {})
                    if isinstance(sub_res, dict):
                        rest_id = sub_res.get("rest_id") or sub_res.get("tweet", {}).get("rest_id")
                        if rest_id and str(rest_id).isdigit():
                            tweet_ids.append(str(rest_id))

    return tweet_ids, bottom_cursor

def select_resume_cursor(last_non_pinned_id, tweet_page_cursor, fallback_cursor=None):
    """中断直前の非固定ツイートが含まれていたページの要求カーソルを選択する（取りこぼし防止）"""
    if last_non_pinned_id and last_non_pinned_id in tweet_page_cursor:
        return tweet_page_cursor[last_non_pinned_id]
    return fallback_cursor

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--num", type=int, default=500)
    parser.add_argument("-u", "--user", type=str, required=True, help="Target user ID")
    parser.add_argument("--mode", type=str, default="post_only", help="(deprecated, ignored: always post_only)")
    parser.add_argument("--skip-ids-file", type=str, default=None, help="File with IDs to skip (one per line)")
    parser.add_argument("--stop-on-existing", action="store_true", help="Stop when hitting a known ID (for user-specific append)")
    parser.add_argument("--max-no-new-scrolls", type=int, default=40, help="Safety guard: maximum consecutive scrolls without new media (default: 40)")
    parser.add_argument("--max-runtime", type=int, default=7200, help="Safety guard: maximum execution runtime in seconds (default: 7200)")
    parser.add_argument("--no-resume", action="store_true", help="Ignore saved resume checkpoint and start from scratch")
    return parser.parse_args()

def build_url(user):
    return f"https://x.com/{user}"

def parse_syndication_video(data, origin_user, origin_status_id):
    """Syndication API のレスポンス (data) から動画メディアオブジェクトのリストを抽出する"""
    extracted = []
    
    # 1. mediaDetails (公式API同等の詳細構造: bitrate情報付き) を優先
    media_details = data.get('mediaDetails', []) if isinstance(data, dict) else []
    for md in media_details:
        if md.get('type') == 'video':
            vinfo = md.get('video_info', {})
            variants = vinfo.get('variants', [])
            mp4_variants = [v for v in variants if v.get('content_type') == 'video/mp4' or v.get('type') == 'video/mp4']
            if mp4_variants:
                best_mp4 = max(mp4_variants, key=lambda x: int(x.get('bitrate', 0) if x.get('bitrate') is not None else 0))
                best_url = best_mp4.get('url') or best_mp4.get('src')
                if best_url:
                    vid_index = len(extracted) + 1
                    extracted.append({
                        "media_url_https": md.get('media_url_https', ''),
                        "type": "video",
                        "video_info": {
                            "variants": [{"url": best_url, "content_type": "video/mp4", "bitrate": best_mp4.get('bitrate', 0)}]
                        },
                        "expanded_url": md.get('expanded_url') or f"https://x.com/{origin_user}/status/{origin_status_id}/video/{vid_index}"
                    })

    if extracted:
        return extracted

    # 2. フォールバック: data['video'] から抽出
    if isinstance(data, dict) and 'video' in data:
        video_obj = data['video']
        poster = video_obj.get('poster', '')
        variants = video_obj.get('variants', [])
        mp4_variants = [v for v in variants if v.get('type') == 'video/mp4' or v.get('content_type') == 'video/mp4']
        if mp4_variants:
            def _quality_score(v):
                bitrate = v.get('bitrate')
                if bitrate is not None:
                    return int(bitrate)
                url_str = v.get('src', '') or v.get('url', '')
                m = re.search(r'/(\d+)x(\d+)/', url_str)
                if m:
                    return int(m.group(1)) * int(m.group(2))
                return 0

            best_mp4 = max(mp4_variants, key=_quality_score)
            best_url = best_mp4.get('src') or best_mp4.get('url')
            if best_url:
                extracted.append({
                    "media_url_https": poster,
                    "type": "video",
                    "video_info": {
                        "variants": [{"url": best_url, "content_type": "video/mp4"}]
                    },
                    "expanded_url": f"https://x.com/{origin_user}/status/{origin_status_id}/video/1"
                })

    return extracted

EXTRACT_ARTICLE_JS = """(el) => {
    // --- 広告（プロモーションポスト）の除外チェック ---
    // テキストによる判定: ポスト要素内のテキストに「プロモーション」または「Promoted」が含まれる場合はスキップ
    // ※ [data-testid="placementTracking"] はXの動画プレイヤーラッパー要素にも付与されるため、動画除外バグ防止のため属性単体では除外しない
    const elText = (el.innerText || "").toLowerCase();
    if (elText.includes("プロモーション") || elText.includes("promoted")) {
        return null;
    }

    let origin_user = "unknown";
    let origin_status_id = "";

    // 1. time リンクを最優先探索
    const timeEl = el.querySelector('time');
    const timeLink = timeEl ? timeEl.closest('a') : el.querySelector('a:has(time)');
    if (timeLink) {
        const href = timeLink.getAttribute('href') || "";
        const m = href.match(/\\/([^\\/]+)\\/status\\/(\\d+)/);
        if (m) {
            origin_user = m[1];
            origin_status_id = m[2];
        }
    }

    // 2. フォールバック: time リンクがない場合は引用ツイート外のステータスリンクを探索
    if (!origin_status_id) {
        const links = el.querySelectorAll('a[href*="/status/"]');
        for (const link of links) {
            if (link.closest('[data-testid="quotedTweet"]')) continue;
            const href = link.getAttribute('href') || "";
            const m = href.match(/\\/([^\\/]+)\\/status\\/(\\d+)/);
            if (m) {
                origin_user = m[1];
                origin_status_id = m[2];
                break;
            }
        }
    }

    if (!origin_status_id) return null;

    // 3. ソーシャルコンテキスト（リポスト・固定ツイート判定）
    const scEl = el.querySelector('[data-testid="socialContext"]');
    const socialText = scEl ? (scEl.innerText || "").trim() : "";
    const isRepost = /リポスト|reposted/i.test(socialText);
    if (isRepost) return null;

    const pinnedKeywords = [
        "固定されたポスト", "固定されたツイート", "固定ツイート",
        "ピン留めされたポスト", "ピン留め",
        "Pinned", "Pinned Tweet", "Pinned Post", "Pinned post"
    ];
    let isPinned = pinnedKeywords.some(kw => socialText.includes(kw));
    if (!isPinned && scEl) {
        const scHtml = scEl.innerHTML.toLowerCase();
        if (scHtml.includes("pin") || socialText.includes("固定") || socialText.includes("ピン")) {
            isPinned = true;
        }
    }

    // 4. ツイートテキスト
    const textEl = el.querySelector('[data-testid="tweetText"]');
    const rawText = textEl ? (textEl.innerText || "") : "";

    // 5. 画像
    const imgEls = el.querySelectorAll('[data-testid="tweetPhoto"] img');
    const photoUrls = [];
    for (const img of imgEls) {
        if (img.closest('[data-testid="quotedTweet"]')) continue;
        let src = img.getAttribute('src');
        if (!src || src.includes("name=120x120") || src.includes("name=240x240")) continue;
        src = src.split('&name=')[0];
        photoUrls.push(src);
    }

    // 6. 動画要素（videoPlayer, videoComponent, または video タグ）
    const vidEls = el.querySelectorAll('[data-testid="videoPlayer"], [data-testid="videoComponent"], video');
    let hasVideo = false;
    for (const vid of vidEls) {
        if (!vid.closest('[data-testid="quotedTweet"]')) {
            hasVideo = true;
            break;
        }
    }

    // 7. タイムスタンプ
    const timestamp = timeEl ? (timeEl.getAttribute('datetime') || "") : "";

    return {
        origin_user: origin_user,
        origin_status_id: origin_status_id,
        is_pinned: isPinned,
        raw_text: rawText,
        photo_urls: photoUrls,
        has_video: hasVideo,
        timestamp: timestamp
    };
}"""

async def build_tweet_data_from_raw(page, raw_info):
    """ブラウザJS側で一括抽出された raw_info から完全なツイートデータを構築"""
    origin_user = raw_info["origin_user"]
    origin_status_id = raw_info["origin_status_id"]
    full_text = f"@{origin_user}: {raw_info['raw_text']}"

    media_urls = [
        {
            "media_url_https": src,
            "type": "photo",
            "expanded_url": f"https://x.com/{origin_user}/status/{origin_status_id}/photo/1"
        }
        for src in raw_info["photo_urls"]
    ]

    if raw_info["has_video"] and origin_status_id:
        try:
            token = await page.evaluate(f"({origin_status_id} / 1e15 * Math.PI).toString(36).replace(/(0+|\\\\.)/g, '')")
            resp = await page.context.request.get(f"https://cdn.syndication.twimg.com/tweet-result?id={origin_status_id}&token={token}")
            if resp.ok:
                data = await resp.json()
                video_items = parse_syndication_video(data, origin_user, origin_status_id)
                media_urls.extend(video_items)
        except Exception as e:
            print(f"⚠️ Failed to fetch video info for {origin_status_id}: {e}")

    if not media_urls:
        return None

    return {
        "tweet": {
            "id_str": origin_status_id,
            "full_text": full_text,
            "created_at": to_jst_timestamp(raw_info.get("timestamp", "")),
            "entities": {"media": media_urls},
            "extended_entities": {"media": media_urls}
        },
        "is_pinned": raw_info["is_pinned"]
    }

async def extract_tweet_data(page, article):
    """1つのarticle要素からツイート情報を抽出するロジック（後方互換用）"""
    try:
        raw_info = await article.evaluate(EXTRACT_ARTICLE_JS)
        if not raw_info:
            return None
        return await build_tweet_data_from_raw(page, raw_info)
    except Exception:
        return None

async def dismiss_modals(page):
    """ログインダイアログ、センシティブ警告、シートダイアログ等を自動解除する"""
    try:
        # 1. センシティブ警告・プロファイル閲覧確認ボタンの自動クリック
        sensitive_btn_texts = [
            "プロフィールを表示", "表示する", "プロフィールを見る",
            "View profile", "Yes, view profile", "Show profile", "Show warning",
        ]
        for txt in sensitive_btn_texts:
            btn = await page.query_selector(f'div[role="button"]:has-text("{txt}"), button:has-text("{txt}")')
            if btn:
                try:
                    await btn.click()
                    print(f"🔓 Dismissed profile warning banner: '{txt}'")
                    await asyncio.sleep(1)
                    break
                except Exception:
                    pass

        # "表示", "Show", "View" 単体テキストのボタン（Show more / Show this thread などの誤爆を防ぐため完全一致）
        for txt in ["表示", "Show", "View"]:
            btn = await page.query_selector(f'div[role="button"]:text-is("{txt}"), button:text-is("{txt}")')
            if btn:
                try:
                    await btn.click()
                    print(f"🔓 Dismissed profile warning banner: '{txt}'")
                    await asyncio.sleep(1)
                    break
                except Exception:
                    pass

        # 2. 閉じるボタンのクリック（ダイアログの「×」）
        close_btn = await page.query_selector('div[role="dialog"] [aria-label="閉じる"], div[role="dialog"] [aria-label="Close"], [data-testid="app-bar-close"]')
        if close_btn:
            try:
                await close_btn.click()
                print("🔓 Clicked dialog close button.")
                await asyncio.sleep(0.5)
            except Exception:
                pass

        # 3. Escape キー送信
        await page.keyboard.press("Escape")

        # 4. ログインオーバーレイ等の除去
        await page.evaluate("""() => {
            const selectors = ['[data-testid="sheetDialog"]', '[data-testid="mask"]', 'div[role="dialog"]'];
            selectors.forEach(sel => {
                document.querySelectorAll(sel).forEach(el => {
                    const text = el.innerText || "";
                    if (text.includes("ログイン") || text.includes("Log in") || text.includes("Sign in") || text.includes("アカウントを作成")) {
                        el.remove();
                    }
                });
            });
        }""")
    except Exception:
        pass

async def wait_for_timeline(page, timeout=25):
    """タイムライン（articleまたは空状態）がDOMに現れるまでモーダル解除や微小スクロールを挟みながら待機"""
    tweet_selectors = ['article', '[data-testid="tweet"]']
    empty_selectors = ['[data-testid="emptyState"]', '[data-testid="empty_timeline"]']
    empty_phrases = [
        "まだポストはありません",
        "No posts yet",
        "ポストはまだありません",
        "Nothing to see here — yet",
        "Nothing to see here",
        "posts aren't available",
    ]

    start_time = asyncio.get_event_loop().time()
    scrolled = False

    while asyncio.get_event_loop().time() - start_time < timeout:
        # 1. 記事要素の確認
        for sel in tweet_selectors:
            el = await page.query_selector(sel)
            if el:
                return "ready"

        # 2. 空タイムライン要素・文言の確認
        for sel in empty_selectors:
            el = await page.query_selector(sel)
            if el:
                return "empty"

        try:
            body_text = await page.inner_text("body")
            if any(phrase in body_text for phrase in empty_phrases):
                return "empty"
        except Exception:
            body_text = ""

        # 3. モーダル・センシティブバナーの解除
        await dismiss_modals(page)

        # 4. 数秒経過しても出ない場合、微小スクロールで動的レンダリングを促進
        elapsed = asyncio.get_event_loop().time() - start_time
        if elapsed > 4 and not scrolled:
            try:
                await page.evaluate("window.scrollBy(0, 150)")
                await asyncio.sleep(0.3)
                await page.evaluate("window.scrollBy(0, -150)")
                scrolled = True
            except Exception:
                pass

        await asyncio.sleep(1.0)

    # タイムアウト後の最終チェック
    for sel in tweet_selectors:
        if await page.query_selector(sel):
            return "ready"
    for sel in empty_selectors:
        if await page.query_selector(sel):
            return "empty"

    return "timeout"

async def check_account_status(page):
    """アカウントが存在しない、凍結、非公開、閲覧制限（年齢制限等）、認証エラー、またはサーバ障害かを早期チェック"""
    try:
        current_url = page.url
        body_text = (await page.inner_text("body")).strip()
        page_title = await page.title()
    except Exception:
        return None

    # 1. 認証エラー・セッション切れ
    if "/i/flow/login" in current_url or "login" in current_url.lower():
        return "auth_error"
    if "/account/access" in current_url:
        return "auth_error"

    has_login_button = await page.query_selector('[data-testid="loginButton"]') is not None
    has_account_switcher = await page.query_selector('[data-testid="SideNav_AccountSwitcher_Button"]') is not None
    login_phrases = ["ログインして続行", "Log in to X", "Sign in to X", "アカウントを作成", "Create account"]
    if has_login_button and not has_account_switcher and any(lp in body_text for lp in login_phrases):
        return "auth_error"

    # 2. アカウント不在・凍結・非公開・ブロック・年齢制限
    dead_phrases = [
        "このアカウントは存在しません",
        "This account doesn’t exist",
        "This account does not exist",
        "該当するアカウントは見つかりませんでした",
        "アカウントは凍結されています",
        "Account suspended",
        "ポストは非公開です",
        "These posts are protected",
        "ブロックされています",
        "You are blocked",
        # 年齢制限 / 生年月日未登録等による閲覧ブロック
        "Age-restricted account",
        "Age-restricted adult content",
        "add your birthdate",
        "年齢制限のあるアカウント",
        "年齢制限のある成人向けコンテンツ",
        "生年月日を追加",
    ]
    for phrase in dead_phrases:
        if phrase in body_text or phrase in page_title:
            return "account_dead"

    # 3. サーバ側の一時エラー
    server_error_phrases = [
        "Something went wrong",
        "問題が発生しました",
        "Cannot retrieve posts at this time",
        "ポストを読み込めません",
    ]
    for phrase in server_error_phrases:
        if phrase in body_text:
            return "server_error"

    return None

async def diagnose_empty_state(page, seen_ids_count, skipped_count, total_articles_detected):
    """0件終了時にページ状態を解析し、状態文字列を返す"""
    # 1. スキップ実績または走査実績がある場合は正常な0件終了（バーチャルスクロールによるDOM消去を考慮）
    if skipped_count > 0:
        print(f"  ℹ️ All {skipped_count} parsed posts were already known. No new tweets to save.")
        return "ok"

    if seen_ids_count > 0 or total_articles_detected > 0:
        print(f"  ℹ️ Found {seen_ids_count or total_articles_detected} posts, but none contained new valid media images.")
        return "ok"

    print("\n🔍 Diagnosing reason for 0 saved tweets:")
    current_url = page.url
    page_title = await page.title()
    print(f"  🌐 Current URL: {current_url}")
    print(f"  📄 Page Title: {page_title}")
    try:
        body_text = (await page.inner_text("body")).strip()
    except Exception:
        body_text = ""

    # ログイン画面リダイレクト
    if "/i/flow/login" in current_url or "login" in current_url.lower():
        print("  ❌ Cause: Redirected to login flow. Session in auth.json has expired or is blocked.")
        return "auth_error"

    # アカウントアクセス認証（CAPTCHA等）
    if "/account/access" in current_url:
        print("  ❌ Cause: Redirected to account access verification (CAPTCHA/Challenge).")
        return "auth_error"

    # 2. ログイン壁
    has_login_button = await page.query_selector('[data-testid="loginButton"]') is not None
    has_account_switcher = await page.query_selector('[data-testid="SideNav_AccountSwitcher_Button"]') is not None
    login_phrases = ["ログインして続行", "Log in to X", "Sign in to X", "アカウントを作成", "Create account", "いまどうしてる？"]
    if has_login_button and not has_account_switcher and any(lp in body_text for lp in login_phrases):
        print("  ❌ Cause: Login wall detected. Session in auth.json may be expired, logged out, or restricted.")
        return "auth_error"

    # 3. アカウント状態（不在・凍結・非公開・ブロック・年齢制限）
    dead_phrases = [
        "このアカウントは存在しません",
        "This account doesn’t exist",
        "This account does not exist",
        "該当するアカウントは見つかりませんでした",
        "アカウントは凍結されています",
        "Account suspended",
        "ポストは非公開です",
        "These posts are protected",
        "ブロックされています",
        "You are blocked",
        "Age-restricted account",
        "Age-restricted adult content",
        "add your birthdate",
        "年齢制限のあるアカウント",
        "年齢制限のある成人向けコンテンツ",
        "生年月日を追加",
    ]
    for m in dead_phrases:
        if m in body_text or m in page_title:
            print(f"  ❌ Cause: Account is inaccessible, suspended, non-existent, or age-restricted ({m}).")
            return "account_dead"

    # 4. センシティブ警告ブロック（ボタン解除不能な場合）
    if any(m in body_text for m in ["センシティブな内容", "Potentially sensitive content", "プロフィールを表示"]):
        print("  ❌ Cause: Profile warning / sensitive content banner blocked timeline rendering.")
        return "account_dead"

    # 5. 投稿なし
    empty_phrases = [
        "まだポストはありません",
        "No posts yet",
        "ポストはまだありません",
        "Nothing to see here — yet",
        "Nothing to see here",
        "posts aren't available",
    ]
    if any(m in body_text for m in empty_phrases):
        print("  ❌ Cause: User has no posts on this timeline.")
        return "ok"

    # 6. サーバ側エラー
    server_error_phrases = [
        "Something went wrong",
        "問題が発生しました",
        "Cannot retrieve posts at this time",
        "ポストを読み込めません",
    ]
    if any(m in body_text for m in server_error_phrases):
        print("  ❌ Cause: Server error or timeline failed to load on X side.")
        return "server_error"

    # 7. プロファイル正常表示（実在確認済み）かつエラー文言なしのフォールバック
    has_user_name = await page.query_selector('[data-testid="UserName"]') is not None
    if has_user_name:
        print("  ℹ️ User profile loaded successfully, but no posts available on this timeline.")
        return "ok"

    # 8. DOM / レンダリング失敗（スクロール全体を通して一度も記事が現れなかった場合）
    body_preview = body_text.replace('\n', ' ')[:200]
    print(f"  ❌ Cause: Timeline articles failed to load into DOM. Body snippet: {repr(body_preview)}")
    return "server_error"

async def run():
    args = parse_args()
    if not os.path.exists(AUTH_PATH):
        print(f"❌ Error: {AUTH_PATH} not found."); return

    os.makedirs(DATA_DIR, exist_ok=True)
    mode = "post_only"  # 固定
    url = build_url(args.user)
    target_label = f"@{args.user}"
    print(f"🚀 Mode: {mode} | Target: {target_label} | URL: {url}")

    # 既知IDの読み込み（スキップ対象）
    skip_ids = set()
    if args.skip_ids_file and os.path.exists(args.skip_ids_file):
        with open(args.skip_ids_file, 'r') as f:
            skip_ids = {line.strip() for line in f if line.strip()}
        print(f"⏭️ Skipping {len(skip_ids)} known IDs.")

    # 中断チェックポイントの復元（--no-resume 指定時は破棄して最初から取得）
    new_tweets = []
    resumed_ids = set()
    active_resume_cursor = None
    if args.no_resume:
        clear_resume_state(args.user)
    else:
        resume_state = load_resume_state(args.user)
        if resume_state:
            new_tweets, resumed_ids, active_resume_cursor = apply_resume_state(resume_state, skip_ids)
            print(
                f"🔄 Resuming {target_label}: {len(new_tweets)}/{args.num} tweets restored from checkpoint "
                f"(cursor={'yes' if active_resume_cursor else 'no'})."
            )
            # 復元時点で既に目標件数に達している場合はブラウザ起動せず即完了
            if len(new_tweets) >= args.num:
                final_tweets = new_tweets[:args.num]
                write_tweets_output(final_tweets)
                clear_resume_state(args.user)
                write_crawl_result(args.user, len(final_tweets), status="ok")
                print(f"\n✅ Done: {len(final_tweets)} tweets saved (completed from checkpoint).")
                return

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-setuid-sandbox",
            ]
        )
        context = await browser.new_context(
            storage_state=AUTH_PATH,
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            viewport={"width": 1280, "height": 900},
        )
        page = await context.new_page()

        # navigator.webdriver を隠蔽
        await page.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', {
                get: () => undefined
            });
        """)

        rate_limit_hit = False
        injected_resume_cursor = False
        first_user_tweets_resp_seen = False
        cursor_injection_failed = False
        tweet_page_cursor = {}

        async def handle_user_tweets_route(route):
            nonlocal injected_resume_cursor
            req_url = route.request.url
            if active_resume_cursor and not injected_resume_cursor and is_user_tweets_graphql_url(req_url):
                new_url = inject_cursor_into_graphql_url(req_url, active_resume_cursor)
                if new_url:
                    injected_resume_cursor = True
                    print("⏩ Injecting saved GraphQL cursor to resume timeline.")
                    await route.continue_(url=new_url)
                    return
            await route.continue_()

        if active_resume_cursor:
            await page.route("**/i/api/graphql/**/UserTweets*", handle_user_tweets_route)

        async def handle_response(response):
            nonlocal rate_limit_hit, first_user_tweets_resp_seen, cursor_injection_failed
            if response.status == 429:
                res_url = response.url.lower()
                # X (Twitter) の コア API エンドポイント (/i/api/ や api.x.com / api.twitter.com) の 429 のみを対象にする
                # 広告・サードパーティ・アナリティクス等の 429 は無視する
                if any(domain in res_url for domain in ["api.twitter.com", "api.x.com", "x.com/i/api/", "twitter.com/i/api/"]):
                    print(f"⚠️ X API Rate limit (429) hit on: {response.url.split('?')[0]}")
                    rate_limit_hit = True
                return

            if is_user_tweets_graphql_url(response.url):
                is_first = not first_user_tweets_resp_seen
                first_user_tweets_resp_seen = True
                if response.status >= 400:
                    if injected_resume_cursor and is_first:
                        cursor_injection_failed = True
                    return
                if response.status == 200:
                    try:
                        payload = await response.json()
                        req_cursor = extract_cursor_from_graphql_url(response.url)
                        if req_cursor is None and injected_resume_cursor and is_first:
                            req_cursor = active_resume_cursor
                        page_tids, _ = extract_user_tweets_page_info(payload)
                        for ptid in page_tids:
                            tweet_page_cursor[ptid] = req_cursor
                    except Exception:
                        pass

        page.on("response", handle_response)
        
        await page.goto(url, wait_until="domcontentloaded")
        await dismiss_modals(page)

        # ユーザー指定時、早期にアカウント存在・凍結・認証チェック
        if args.user:
            early_status = await check_account_status(page)
            if early_status == "account_dead":
                print(f"❌ Account @{args.user} is dead/suspended/inaccessible. Exiting with code 44.")
                clear_resume_state(args.user)
                await browser.close()
                sys.exit(44)
            elif early_status == "auth_error":
                print("❌ Auth session error (login required). Exiting with code 41.")
                await browser.close()
                sys.exit(41)

        # タイムラインの初期記事が現れるまで待機
        articles_ready = False
        timeline_empty = False
        status = await wait_for_timeline(page, timeout=25)
        if status == "ready":
            articles_ready = True
        elif status == "empty":
            timeline_empty = True

        # カーソル注入での再開が空/失敗した場合は先頭からの通常スクロールへフォールバック（取得済みツイートは保持）
        if injected_resume_cursor and not rate_limit_hit and (cursor_injection_failed or timeline_empty or not articles_ready):
            print("⚠️ Resuming with GraphQL cursor yielded no timeline. Falling back to top-of-timeline scroll...")
            try:
                await page.unroute("**/i/api/graphql/**/UserTweets*", handle_user_tweets_route)
            except Exception:
                pass
            active_resume_cursor = None
            injected_resume_cursor = False
            first_user_tweets_resp_seen = False
            cursor_injection_failed = False
            articles_ready = False
            timeline_empty = False
            try:
                await page.goto(url, wait_until="domcontentloaded")
                await dismiss_modals(page)
                status = await wait_for_timeline(page, timeout=25)
                if status == "ready":
                    articles_ready = True
                elif status == "empty":
                    timeline_empty = True
            except Exception as e:
                print(f"⚠️ Fallback reload failed or timed out: {e}")

        # 初期ロード時点でレート制限(429)を検知した場合はチェックポイントを保持したまま exit 42
        if rate_limit_hit:
            if new_tweets or active_resume_cursor:
                save_resume_state(args.user, new_tweets, resumed_ids, cursor=active_resume_cursor, target_num=args.num)
                print(f"💾 Preserved resume checkpoint for {target_label}: {len(new_tweets)}/{args.num} tweets.")
            write_crawl_result(args.user, len(new_tweets), status="rate_limit")
            print("🚨 Rate limit detected from X! Exiting with code 42.")
            await browser.close()
            sys.exit(42)

        # 初期タイムアウト時、アカウント状態を再確認
        if not articles_ready and not timeline_empty and args.user:
            status_check = await check_account_status(page)
            if status_check == "account_dead":
                print(f"❌ Account @{args.user} is dead/suspended/inaccessible (e.g. age-restricted). Exiting with code 44.")
                clear_resume_state(args.user)
                await browser.close()
                sys.exit(44)
            elif status_check == "auth_error":
                print("❌ Auth session error (login required). Exiting with code 41.")
                await browser.close()
                sys.exit(41)

        # 初期タイムアウト時、一度リロードして再試行
        if not articles_ready and not timeline_empty:
            print("🔄 Initial load timed out with 0 articles. Attempting page reload...")
            try:
                await page.reload(wait_until="domcontentloaded")
                await dismiss_modals(page)
                status = await wait_for_timeline(page, timeout=20)
                if status == "ready":
                    articles_ready = True
                elif status == "empty":
                    timeline_empty = True
                else:
                    print("⚠️ Page reload finished; articles still not detected in DOM.")
            except Exception as e:
                print(f"⚠️ Page reload failed or timed out: {e}")

        # 空タイムライン確定時の即時終了
        if timeline_empty:
            write_tweets_output(new_tweets)
            clear_resume_state(args.user)
            write_crawl_result(args.user, len(new_tweets), status="empty" if not new_tweets else "ok")
            print(f"\n✅ Done: {len(new_tweets)} tweets saved (empty timeline).")
            await browser.close()
            sys.exit(0)

        # リロード後も記事が検出されない場合は無駄なスクロールをスキップして即時診断・終了
        if not articles_ready:
            if rate_limit_hit:
                if new_tweets or active_resume_cursor:
                    save_resume_state(args.user, new_tweets, resumed_ids, cursor=active_resume_cursor, target_num=args.num)
                write_crawl_result(args.user, len(new_tweets), status="rate_limit")
                print("🚨 Rate limit detected from X! Exiting with code 42.")
                await browser.close()
                sys.exit(42)
            diag_status = await diagnose_empty_state(page, 0, 0, 0)
            if diag_status in ("account_dead", "auth_error", "server_error"):
                debug_screen = os.path.join(DATA_DIR, "debug_screen.png")
                try:
                    await page.screenshot(path=debug_screen, full_page=False)
                    print(f"  📸 Debug screenshot saved to: {debug_screen}")
                except Exception:
                    pass

                await browser.close()
                if diag_status == "account_dead":
                    clear_resume_state(args.user)
                    print(f"🚨 Account @{args.user} is dead/suspended/inaccessible. Exiting with code 44.")
                    sys.exit(44)
                elif diag_status == "auth_error":
                    print("🚨 Auth session error. Exiting with code 41.")
                    sys.exit(41)
                else:
                    print("🚨 Server error or timeline DOM failure. Exiting with code 43.")
                    sys.exit(43)
            elif diag_status == "ok":
                # 投稿なしなど正常な0件
                write_tweets_output(new_tweets)
                clear_resume_state(args.user)
                write_crawl_result(args.user, len(new_tweets), status="empty" if not new_tweets else "ok")
                print(f"\n✅ Done: {len(new_tweets)} tweets saved (empty timeline).")
                await browser.close()
                sys.exit(0)

        await asyncio.sleep(0.5)
        await dismiss_modals(page)

        # ページ全体のテキストからレート制限をチェック
        try:
            body_text = await page.inner_text("body")
            if any(msg in body_text for msg in ["Rate limit exceeded", "レート制限", "レート制限を超えました"]):
                rate_limit_hit = True
        except Exception:
            pass

        seen_ids = set()
        stall_count = 0
        scroll_count = 0
        total_articles_detected = 0
        MAX_STALLS = 8
        skipped_count = 0
        hit_existing = False
        no_new_scrolls = 0
        last_non_pinned_seen_id = None
        start_time = time.time()

        while len(new_tweets) < args.num and not hit_existing and not rate_limit_hit:
            prev_new_count = len(new_tweets)
            saw_resumed_in_scroll = False
            articles = await page.query_selector_all('article')
            if not articles:
                articles = await page.query_selector_all('[data-testid="tweet"]')
            if articles:
                total_articles_detected += len(articles)
            prev_seen = len(seen_ids)
            for article in articles:
                try:
                    raw_info = await article.evaluate(EXTRACT_ARTICLE_JS)
                except Exception:
                    continue
                if not raw_info: continue

                tid = raw_info["origin_status_id"]
                if tid in seen_ids: continue
                seen_ids.add(tid)

                is_pinned = raw_info.get("is_pinned", False)

                # 再開チェックポイントで既に処理済みのIDはスキップ（--stop-on-existing 誤発火防止）
                if tid in resumed_ids:
                    saw_resumed_in_scroll = True
                    if not is_pinned and injected_resume_cursor:
                        last_non_pinned_seen_id = tid
                    continue

                if not is_pinned:
                    last_non_pinned_seen_id = tid

                # 固定ツイート（Pinned）は重複停止判定から除外・スキップ
                if is_pinned:
                    if tid in skip_ids:
                        skipped_count += 1
                    else:
                        data = await build_tweet_data_from_raw(page, raw_info)
                        if data:
                            new_tweets.append(data)
                            print(f"  [{len(new_tweets)}] Saved (Pinned): @{tid}")
                    continue

                if tid in skip_ids:
                    skipped_count += 1
                    # 1個の既存IDを検出した時点で即時停止
                    if args.stop_on_existing:
                        print(f"🛑 Existing tweet ID detected (@{tid}). Stopping.")
                        hit_existing = True
                        break
                    continue

                data = await build_tweet_data_from_raw(page, raw_info)
                if not data: continue

                new_tweets.append(data)
                print(f"  [{len(new_tweets)}] Saved: @{tid}")

                if len(new_tweets) >= args.num:
                    break

            if len(new_tweets) >= args.num or hit_existing or rate_limit_hit: break

            # 新規メディア追加または再開済み範囲の通過中は no_new_scrolls をリセット
            if len(new_tweets) > prev_new_count or saw_resumed_in_scroll:
                no_new_scrolls = 0
            else:
                no_new_scrolls += 1

            # --- セーフティガード判定 ---
            # 1. 新規メディアなし連続スクロール上限
            if no_new_scrolls >= args.max_no_new_scrolls:
                print(f"\n🛡️ Safety Guard: No new media found for {no_new_scrolls} consecutive scrolls (limit: {args.max_no_new_scrolls}). Stopping.")
                break

            # 2. 最大実行時間上限
            elapsed_time = time.time() - start_time
            if elapsed_time >= args.max_runtime:
                print(f"\n🛡️ Safety Guard: Reached max runtime limit ({int(elapsed_time)}s / {args.max_runtime}s). Stopping.")
                break

            # スクロールしても新しいarticleが出てこなければ終端
            if len(seen_ids) > prev_seen:
                stall_count = 0
            else:
                stall_count += 1
                if stall_count >= MAX_STALLS:
                    print(f"\n⚠️ No more posts found after {MAX_STALLS} scrolls. Stopping.")
                    break

            scroll_count += 1
            # 1000pxずつスムーズにスクロールしてバーチャルスクロールによる取りこぼしを防止
            try:
                await page.evaluate("window.scrollBy(0, 1000)")
            except Exception:
                await page.mouse.wheel(0, 1000)

            # ストール発生時のみモーダル解除を試行
            if stall_count > 0:
                await dismiss_modals(page)

            # ローディングスピナーが表示されている場合はロード完了を少し待機
            try:
                spinner = await page.query_selector('div[role="progressbar"]')
                if spinner:
                    await asyncio.sleep(1)
            except Exception:
                pass

            await asyncio.sleep(1.2)

        if skipped_count:
            print(f"⏭️ Skipped {skipped_count} already-known posts.")

        # レート制限検知時: 取得済みデータ・カーソルをチェックポイント保存して exit 42
        if rate_limit_hit:
            checkpoint_cursor = select_resume_cursor(
                last_non_pinned_seen_id,
                tweet_page_cursor,
                fallback_cursor=active_resume_cursor,
            )
            all_seen_ids = resumed_ids | seen_ids
            if new_tweets or checkpoint_cursor:
                save_resume_state(
                    args.user,
                    new_tweets,
                    all_seen_ids,
                    cursor=checkpoint_cursor,
                    target_num=args.num,
                )
                print(
                    f"💾 Saved resume checkpoint for {target_label}: {len(new_tweets)}/{args.num} tweets "
                    f"(cursor={'yes' if checkpoint_cursor else 'no'})."
                )
            write_crawl_result(args.user, len(new_tweets), status="rate_limit")
            print("🚨 Rate limit detected from X! Exiting with code 42.")
            await browser.close()
            sys.exit(42)

        # 0件で終了した場合の原因診断とスクリーンショット保存（異常検知時のみ）
        if len(new_tweets) == 0:
            diag_status = await diagnose_empty_state(page, len(seen_ids), skipped_count, total_articles_detected)
            if diag_status in ("account_dead", "auth_error", "server_error", "error"):
                debug_screen = os.path.join(DATA_DIR, "debug_screen.png")
                try:
                    await page.screenshot(path=debug_screen, full_page=False)
                    print(f"  📸 Debug screenshot saved to: {debug_screen}")
                except Exception:
                    pass

                await browser.close()
                if diag_status == "account_dead":
                    clear_resume_state(args.user)
                    print(f"🚨 Account @{args.user} is dead/suspended/inaccessible. Exiting with code 44.")
                    sys.exit(44)
                elif diag_status == "auth_error":
                    print("🚨 Auth session error. Exiting with code 41.")
                    sys.exit(41)
                else:
                    print("🚨 Server error or timeline DOM failure. Exiting with code 43.")
                    sys.exit(43)

        write_tweets_output(new_tweets)
        clear_resume_state(args.user)
        write_crawl_result(args.user, len(new_tweets), status="ok")
        print(f"\n✅ Done: {len(new_tweets)} tweets saved.")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(run())