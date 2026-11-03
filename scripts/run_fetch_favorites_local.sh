#!/bin/bash
set -euo pipefail

# --- ディレクトリ移動と仮想環境の有効化 ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if [ -d "$PROJECT_DIR/venv" ]; then
  source "$PROJECT_DIR/venv/bin/activate"
else
  echo "❌ Error: Virtual environment $PROJECT_DIR/venv not found."
  exit 1
fi

# 二重起動防止ロック
LOCKFILE="/tmp/fetch_favorites_local.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "⚠️ [$(date '+%Y-%m-%d %H:%M:%S')] Another instance is already running. Exiting."
  exit 0
fi

# --- .env の読み込みと存在チェック ---
if [ -f "$PROJECT_DIR/.env" ]; then
  set -a
  source "$PROJECT_DIR/.env"
  set +a
fi

# GITHUB_TOKEN から GH_TOKEN へのフォールバック
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# 必須環境変数の検証
for var in GH_TOKEN FAVORITE_GIST_ID FETCH_QUEUE_GIST_ID; do
  if [ -z "${!var:-}" ]; then
    echo "❌ Error: Required environment variable '$var' is missing."
    exit 1
  fi
done

# 実行権限の確認
chmod +x "$PROJECT_DIR/append_gist.sh"

echo "=========================================="
echo "🚀 [$(date '+%Y-%m-%d %H:%M:%S')] Local Fetch Favorites Started"
echo "=========================================="

SLOT0_ID="$FETCH_QUEUE_GIST_ID"

# --- 1. キュー状態の確認とリロード ---
QUEUE_JSON=$(gh gist view "$SLOT0_ID" -f fetch_queue.json 2>/dev/null || echo "")
if ! echo "$QUEUE_JSON" | jq -e '.users' > /dev/null 2>&1; then
  echo "❌ Error: Failed to read fetch_queue.json from Gist: $SLOT0_ID"
  exit 1
fi

MASTER_GIST_ID=$(echo "$QUEUE_JSON" | jq -r '.master_gist_id // empty')
MASTER_GIST_ID="${MASTER_GIST_ID:-${MASTER_GIST_ID:-$SLOT0_ID}}"
DEFAULT_COUNT=$(echo "$QUEUE_JSON" | jq -r '.default_count // 500')
if [ "$DEFAULT_COUNT" = "100" ] || [ -z "$DEFAULT_COUNT" ]; then
  DEFAULT_COUNT=500
fi

UNFINISHED_COUNT=$(echo "$QUEUE_JSON" | jq -r '[.users[]? | select(.done != true)] | length')
echo "📋 Unfinished entries in queue: $UNFINISHED_COUNT"

if [ "$UNFINISHED_COUNT" -eq 0 ]; then
  echo "🔄 Reloading favorites list into queue..."
  FAV_JSON=$(gh gist view "$FAVORITE_GIST_ID" -f favorites.json 2>/dev/null || echo "")
  mapfile -t FAV_USERS < <(echo "$FAV_JSON" | jq -r '.favorite_users[]? // empty')

  if [ ${#FAV_USERS[@]} -eq 0 ]; then
    echo "⚠️ No favorite users found in $FAVORITE_GIST_ID. Exiting."
    exit 0
  fi

  echo "👥 Loaded ${#FAV_USERS[@]} favorite users. Resetting queue..."
  QUEUE_JSON=$(echo "$QUEUE_JSON" | jq '.users = [] | .default_count = 500')
  for u in "${FAV_USERS[@]}"; do
    QUEUE_JSON=$(echo "$QUEUE_JSON" | jq --arg user "$u" \
      '.users += [{"user": $user, "count": 500, "stop_on_existing": true}]')
  done

  TMP_QUEUE=$(mktemp /tmp/fq_reload_XXXXXX.json)
  printf '%s' "$QUEUE_JSON" > "$TMP_QUEUE"
  gh gist edit "$SLOT0_ID" -f fetch_queue.json "$TMP_QUEUE"
  rm -f "$TMP_QUEUE"
  echo "✅ Queue successfully initialized."
fi

# --- 2. 未処理エントリの実行ループ ---
mapfile -t ENTRIES < <(echo "$QUEUE_JSON" | jq -c '.users[] | select(.done != true)')
ENTRY_COUNT=${#ENTRIES[@]}
CONSECUTIVE_ERRORS=0

for i in "${!ENTRIES[@]}"; do
  entry="${ENTRIES[$i]}"
  USER=$(echo "$entry" | jq -r '.user // empty')
  HASHTAG=$(echo "$entry" | jq -r '.hashtag // empty')
  ENTRY_GIST_ID=$(echo "$entry" | jq -r '.gist_id // empty')
  COUNT=$(echo "$entry" | jq -r --arg def "$DEFAULT_COUNT" '(.count // ($def | tonumber) | tostring)')
  if [ -z "$COUNT" ] || [ "$COUNT" = "100" ]; then
    COUNT=500
  fi
  STOP=$(echo "$entry" | jq -r '(if .stop_on_existing == null then true else .stop_on_existing end | tostring)')

  TARGET_GIST="${ENTRY_GIST_ID:-$MASTER_GIST_ID}"
  EXIT_CODE=0

  if [ -n "$HASHTAG" ]; then
    echo ""
    echo "▶️ [$((i+1))/$ENTRY_COUNT] Fetching hashtag: #$HASHTAG (count=$COUNT)"
    if [ "$STOP" = "true" ]; then
      ./append_gist.sh -g "$TARGET_GIST" -t "$HASHTAG" -n "$COUNT" -s || EXIT_CODE=$?
    else
      ./append_gist.sh -g "$TARGET_GIST" -t "$HASHTAG" -n "$COUNT" || EXIT_CODE=$?
    fi
  elif [ -n "$USER" ]; then
    echo ""
    echo "▶️ [$((i+1))/$ENTRY_COUNT] Fetching user: @$USER (count=$COUNT)"
    if [ "$STOP" = "true" ]; then
      ./append_gist.sh -g "$TARGET_GIST" -u "$USER" -n "$COUNT" -s || EXIT_CODE=$?
    else
      ./append_gist.sh -g "$TARGET_GIST" -u "$USER" -n "$COUNT" || EXIT_CODE=$?
    fi
  else
    continue
  fi

  # レートリミット (42) 検知時は即座に中断
  if [ $EXIT_CODE -eq 42 ]; then
    echo "🚨 [$(date '+%Y-%m-%d %H:%M:%S')] Rate limit detected from X (exit code 42). Pausing queue."
    exit 42
  fi

  # セッション切れ / ログイン要求 (41) 検知時も安全のため中断（お気に入り誤削除防止）
  if [ $EXIT_CODE -eq 41 ]; then
    echo "🚨 [$(date '+%Y-%m-%d %H:%M:%S')] Session expired or login required (exit code 41). Pausing queue."
    exit 41
  fi

  if [ $EXIT_CODE -ne 0 ]; then
    if [ -n "$USER" ] && [ $EXIT_CODE -eq 44 ]; then
      echo "🗑️ Removing inaccessible/dead user @$USER from favorites.json (Gist: $FAVORITE_GIST_ID)..."

      # favorites.json から該当ユーザーを削除（case-insensitive）
      FAV_CURR=$(gh gist view "$FAVORITE_GIST_ID" -f favorites.json 2>/dev/null || echo "")
      if echo "$FAV_CURR" | jq -e '.favorite_users' >/dev/null 2>&1; then
        UPDATED_FAV=$(echo "$FAV_CURR" | jq --arg u "$USER" \
          '.favorite_users = [.favorite_users[] | select((. | ascii_downcase) != ($u | ascii_downcase))]')
        TMP_FAV=$(mktemp /tmp/fav_clean_XXXXXX.json)
        printf '%s' "$UPDATED_FAV" > "$TMP_FAV"
        gh gist edit "$FAVORITE_GIST_ID" -f favorites.json "$TMP_FAV"
        rm -f "$TMP_FAV"
        echo "✅ Removed @$USER from favorites.json."
      fi

      # fetch_queue.json でも該当ユーザーを done: true に設定して次回以降スキップ
      LATEST_JSON=$(gh gist view "$SLOT0_ID" -f fetch_queue.json 2>/dev/null || echo "")
      if echo "$LATEST_JSON" | jq -e '.users' > /dev/null 2>&1; then
        LATEST_JSON=$(echo "$LATEST_JSON" | jq --arg user "$USER" \
          '.users = [.users[] | if .user == $user then . + {"done": true} else . end]')
        TMP_DONE=$(mktemp /tmp/fq_done_XXXXXX.json)
        printf '%s' "$LATEST_JSON" > "$TMP_DONE"
        gh gist edit "$SLOT0_ID" -f fetch_queue.json "$TMP_DONE"
        rm -f "$TMP_DONE"
        echo "✅ Marked inaccessible user @$USER as done in fetch_queue.json."
      fi

      # 無効アカウントの正常スキップのため連続エラーカウントはリセット
      CONSECUTIVE_ERRORS=0
      echo "⏩ Automatically skipped inaccessible user @$USER and proceeding to next account."

    elif [ $EXIT_CODE -eq 43 ]; then
      echo "⚠️ Server-side or timeline DOM error (code 43) for target: ${USER:-#$HASHTAG}"

      # キューを done: true にして次回以降へのスタックを防止し、自動スキップ
      LATEST_JSON=$(gh gist view "$SLOT0_ID" -f fetch_queue.json 2>/dev/null || echo "")
      if echo "$LATEST_JSON" | jq -e '.users' > /dev/null 2>&1; then
        if [ -n "$HASHTAG" ]; then
          LATEST_JSON=$(echo "$LATEST_JSON" | jq --arg hashtag "$HASHTAG" \
            '.users = [.users[] | if .hashtag == $hashtag then . + {"done": true} else . end]')
        else
          LATEST_JSON=$(echo "$LATEST_JSON" | jq --arg user "$USER" \
            '.users = [.users[] | if .user == $user then . + {"done": true} else . end]')
        fi
        TMP_DONE=$(mktemp /tmp/fq_done_XXXXXX.json)
        printf '%s' "$LATEST_JSON" > "$TMP_DONE"
        gh gist edit "$SLOT0_ID" -f fetch_queue.json "$TMP_DONE"
        rm -f "$TMP_DONE"
        echo "✅ Marked target as done in current queue to skip and prevent stuck queue."
      fi

      # 一時スキップとして扱い連続エラーカウントはリセット
      CONSECUTIVE_ERRORS=0
      echo "⏩ Safely skipped target and proceeding to next account."

    else
      # その他の予期せぬスクリプトエラー
      CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
      echo "⚠️ Unexpected crawl failure (code $EXIT_CODE). Consecutive errors: $CONSECUTIVE_ERRORS/3"

      if [ -n "$USER" ]; then
        echo "⚠️ Crawl error for @$USER (code $EXIT_CODE). Leaving undone for next run."
      else
        echo "⚠️ Crawl returned code $EXIT_CODE for hashtag #$HASHTAG. Leaving undone for next run."
      fi

      if [ $CONSECUTIVE_ERRORS -ge 3 ]; then
        echo "🚨 3 consecutive crawl failures. Aborting batch run to prevent infinite loop."
        exit 1
      fi
    fi

    sleep 2
    continue
  fi

  # 成功時: done: true を Gist に反映
  CONSECUTIVE_ERRORS=0
  LATEST_JSON=$(gh gist view "$SLOT0_ID" -f fetch_queue.json 2>/dev/null || echo "")
  if echo "$LATEST_JSON" | jq -e '.users' > /dev/null 2>&1; then
    if [ -n "$HASHTAG" ]; then
      LATEST_JSON=$(echo "$LATEST_JSON" | jq --arg hashtag "$HASHTAG" \
        '.users = [.users[] | if .hashtag == $hashtag then . + {"done": true} else . end]')
    else
      LATEST_JSON=$(echo "$LATEST_JSON" | jq --arg user "$USER" \
        '.users = [.users[] | if .user == $user then . + {"done": true} else . end]')
    fi
    TMP_DONE=$(mktemp /tmp/fq_done_XXXXXX.json)
    printf '%s' "$LATEST_JSON" > "$TMP_DONE"
    gh gist edit "$SLOT0_ID" -f fetch_queue.json "$TMP_DONE"
    rm -f "$TMP_DONE"
  fi

  # 次の処理まで待機（レート制限防止）
  sleep 5
done

echo ""
echo "=========================================="
echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')] Local Fetch Favorites Completed"
echo "=========================================="
