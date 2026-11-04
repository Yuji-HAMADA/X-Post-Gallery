#!/bin/bash
set -euo pipefail

# ==============================================================================
# run_scheduled_fetch_local.sh
# GitHub Actions の scheduled_fetch.yml をローカル(Ubuntu)環境で実行するためのラッパー
# ==============================================================================

# --- 1. ディレクトリ移動と仮想環境の有効化 ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if [ -d "$PROJECT_DIR/venv" ]; then
  source "$PROJECT_DIR/venv/bin/activate"
else
  echo "❌ Error: Virtual environment $PROJECT_DIR/venv not found."
  exit 1
fi

# --- 2. 二重起動防止ロック ---
LOCKFILE="/tmp/scheduled_fetch_local.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "⚠️ [$(date '+%Y-%m-%d %H:%M:%S')] Another instance of scheduled fetch is already running. Exiting."
  exit 0
fi

# --- 3. .env の読み込みと環境変数の検証 ---
if [ -f "$PROJECT_DIR/.env" ]; then
  set -a
  source "$PROJECT_DIR/.env"
  set +a
fi

# GITHUB_TOKEN から GH_TOKEN へのフォールバック
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

for var in GH_TOKEN FETCH_QUEUE_GIST_ID; do
  if [ -z "${!var:-}" ]; then
    echo "❌ Error: Required environment variable '$var' is missing in .env or environment."
    exit 1
  fi
done

# data/auth.json のチェック（未生成かつ AUTH_JSON があれば生成）
if [ ! -s "$PROJECT_DIR/data/auth.json" ] && [ -n "${AUTH_JSON:-}" ]; then
  mkdir -p "$PROJECT_DIR/data"
  printf "%s" "$AUTH_JSON" > "$PROJECT_DIR/data/auth.json"
fi

if [ ! -s "$PROJECT_DIR/data/auth.json" ]; then
  echo "❌ Error: $PROJECT_DIR/data/auth.json is missing or empty."
  exit 1
fi

# 実行権限の確認
chmod +x "$PROJECT_DIR/append_gist.sh"

echo "=========================================="
echo "🚀 [$(date '+%Y-%m-%d %H:%M:%S')] Local Scheduled Fetch Started"
echo "=========================================="

START_TIME=$(date +%s)
CONSECUTIVE_ERRORS=0
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-18000}" # デフォルト5時間

# --- 4. スロット設定の取得 ---
SLOT0_ID="$FETCH_QUEUE_GIST_ID"
SLOT0_JSON=$(gh gist view "$SLOT0_ID" -f fetch_queue.json 2>/dev/null || echo "")
if ! echo "$SLOT0_JSON" | jq -e '.users' > /dev/null 2>&1; then
  echo "❌ Error: Failed to read fetch_queue.json from Gist: $SLOT0_ID"
  exit 1
fi

SLOT1_ID=$(echo "$SLOT0_JSON" | jq -r '.sibling_gist_id // empty')
if [ -z "$SLOT1_ID" ]; then
  echo "ℹ️ sibling_gist_id not found in slot 0. Running in single-slot mode."
fi

MASTER_GIST_ID=$(echo "$SLOT0_JSON" | jq -r '.master_gist_id // empty')
MASTER_GIST_ID="${MASTER_GIST_ID:-$SLOT0_ID}"
DEFAULT_COUNT=$(echo "$SLOT0_JSON" | jq -r '.default_count // 500')
if [ "$DEFAULT_COUNT" = "100" ] || [ -z "$DEFAULT_COUNT" ]; then
  DEFAULT_COUNT=500
fi

echo "📋 Master Gist  : $MASTER_GIST_ID"
echo "📋 Default count: $DEFAULT_COUNT"
echo "📋 Slot 0 Gist  : $SLOT0_ID"
[ -n "$SLOT1_ID" ] && echo "📋 Slot 1 Gist  : $SLOT1_ID"

# --- 5. ステータスリセット関数 ---
reset_status() {
  local gist_id="$1"
  local json
  json=$(gh gist view "$gist_id" -f fetch_queue.json 2>/dev/null || echo "")
  if ! echo "$json" | jq -e '.' > /dev/null 2>&1; then
    echo "⚠️ Warning: fetch_queue.json read failed for $gist_id, skipping reset."
    return 0
  fi
  local current_status
  current_status=$(echo "$json" | jq -r '.status // "idle"')
  if [ "$current_status" != "idle" ]; then
    echo "🔄 Resetting slot status to idle: $gist_id"
    json=$(echo "$json" | jq '.status = "idle"')
    if [ -z "$json" ] || [ "$json" = "null" ]; then
      echo "⚠️ Warning: jq produced empty output for reset, skipping."
      return 0
    fi
    local tmp_file
    tmp_file=$(mktemp /tmp/fq_reset_XXXXXX.json)
    printf '%s' "$json" > "$tmp_file"
    gh gist edit "$gist_id" -f fetch_queue.json "$tmp_file"
    rm -f "$tmp_file"
  fi
}

reset_all_slots() {
  reset_status "$SLOT0_ID"
  if [ -n "$SLOT1_ID" ]; then
    reset_status "$SLOT1_ID"
  fi
}

# 中断シグナル受信時の安全停止ハンドラ
trap 'echo ""; echo "🛑 [$(date "+%Y-%m-%d %H:%M:%S")] Process interrupted by signal. Resetting status..."; reset_all_slots; exit 130' INT TERM

# 開始時にステータスを idle にリセット（前回異常終了対策）
reset_all_slots

# --- 6. 1スロット処理関数 ---
process_slot() {
  local slot_id="$1"
  local slot_num="$2"

  echo ""
  echo "=========================================="
  echo "🔍 Checking slot $slot_num ($slot_id)"
  echo "=========================================="

  local slot_json
  slot_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
  if ! echo "$slot_json" | jq -e '.users' > /dev/null 2>&1; then
    echo "⚠️ Warning: fetch_queue.json read failed for slot $slot_num, skipping."
    return 1
  fi

  # 未処理エントリを取得
  mapfile -t ENTRIES < <(echo "$slot_json" | jq -c '.users[] | select(.done != true)')
  local entry_count=${#ENTRIES[@]}
  echo "📋 Unprocessed entries in slot $slot_num: $entry_count"

  if [ "$entry_count" -eq 0 ]; then
    return 1 # 未処理なし
  fi

  # status を "processing" に更新
  slot_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
  if echo "$slot_json" | jq -e '.' > /dev/null 2>&1; then
    slot_json=$(echo "$slot_json" | jq '.status = "processing"')
    local tmp_file
    tmp_file=$(mktemp /tmp/fq_status_XXXXXX.json)
    printf '%s' "$slot_json" > "$tmp_file"
    gh gist edit "$slot_id" -f fetch_queue.json "$tmp_file"
    rm -f "$tmp_file"
  fi

  for i in "${!ENTRIES[@]}"; do
    local entry="${ENTRIES[$i]}"
    local USER COUNT STOP EXIT_CODE=0

    USER=$(echo "$entry" | jq -r '.user // empty')
    COUNT=$(echo "$entry" | jq -r --arg def "$DEFAULT_COUNT" '(.count // ($def | tonumber) | tostring)')
    if [ -z "$COUNT" ] || [ "$COUNT" = "100" ]; then
      COUNT=500
    fi
    STOP=$(echo "$entry" | jq -r '(if .stop_on_existing == null then true else .stop_on_existing end | tostring)')

    if [ -n "$USER" ]; then
      echo ""
      echo "▶️ Slot $slot_num [$((i+1))/$entry_count]: @$USER (count=$COUNT, stop_on_existing=$STOP)"
      if [ "$STOP" = "true" ]; then
        ./append_gist.sh -g "$MASTER_GIST_ID" -u "$USER" -n "$COUNT" -s || EXIT_CODE=$?
      else
        ./append_gist.sh -g "$MASTER_GIST_ID" -u "$USER" -n "$COUNT" || EXIT_CODE=$?
      fi
    else
      echo "⚠️ Warning: Entry has no user, skipping: $entry"
      continue
    fi

    # レートリミット (42) 検知
    if [ $EXIT_CODE -eq 42 ]; then
      echo "🚨 [$(date '+%Y-%m-%d %H:%M:%S')] Rate limit detected (exit code 42). Pausing execution."
      reset_all_slots
      exit 42
    fi

    # セッション切れ (41) 検知
    if [ $EXIT_CODE -eq 41 ]; then
      echo "🚨 [$(date '+%Y-%m-%d %H:%M:%S')] Session expired or login required (exit code 41). Pausing execution."
      reset_all_slots
      exit 41
    fi

    # エラー時のハンドリング
    if [ $EXIT_CODE -ne 0 ]; then
      if [ $EXIT_CODE -eq 44 ]; then
        echo "🗑️ Inaccessible or dead user @$USER (code 44). Marking as done to safely skip."
        local latest_json
        latest_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
        if echo "$latest_json" | jq -e '.users' > /dev/null 2>&1; then
          latest_json=$(echo "$latest_json" | jq --arg user "$USER" \
            '.users = [.users[] | if .user == $user then . + {"done": true} else . end]')
          local tmp_done
          tmp_done=$(mktemp /tmp/scheduled_fq_done_XXXXXX.json)
          printf '%s' "$latest_json" > "$tmp_done"
          gh gist edit "$slot_id" -f fetch_queue.json "$tmp_done"
          rm -f "$tmp_done"
        fi
        CONSECUTIVE_ERRORS=0
        echo "⏩ Skipped inaccessible user @$USER and proceeding to next entry."

      elif [ $EXIT_CODE -eq 43 ]; then
        echo "⚠️ Server-side or timeline DOM error (code 43) for target: @$USER"
        local latest_json
        latest_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
        if echo "$latest_json" | jq -e '.users' > /dev/null 2>&1; then
          latest_json=$(echo "$latest_json" | jq --arg user "$USER" \
            '.users = [.users[] | if .user == $user then . + {"done": true} else . end]')
          local tmp_done
          tmp_done=$(mktemp /tmp/scheduled_fq_done_XXXXXX.json)
          printf '%s' "$latest_json" > "$tmp_done"
          gh gist edit "$slot_id" -f fetch_queue.json "$tmp_done"
          rm -f "$tmp_done"
        fi
        CONSECUTIVE_ERRORS=0
        echo "⏩ Safely skipped target in current queue and proceeding to next entry."

      else
        CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
        echo "⚠️ Crawl failed for this entry (code $EXIT_CODE). Consecutive errors: $CONSECUTIVE_ERRORS/3"

        if [ $CONSECUTIVE_ERRORS -ge 3 ]; then
          echo "🚨 3 consecutive crawl errors encountered. Aborting to protect accounts and prevent stack."
          reset_all_slots
          exit 1
        fi
      fi
      sleep 2
      continue
    fi

    # 成功時はエラーカウントをリセット
    CONSECUTIVE_ERRORS=0

    # done: true を Gist に反映
    local latest_json
    latest_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
    if echo "$latest_json" | jq -e '.users' > /dev/null 2>&1; then
      latest_json=$(echo "$latest_json" | jq --arg user "$USER" \
        '.users = [.users[] | if .user == $user then . + {"done": true} else . end]')
      local tmp_done
      tmp_done=$(mktemp /tmp/fq_done_XXXXXX.json)
      printf '%s' "$latest_json" > "$tmp_done"
      gh gist edit "$slot_id" -f fetch_queue.json "$tmp_done"
      rm -f "$tmp_done"
    fi

    # タイムアウト判定
    local current_time elapsed
    current_time=$(date +%s)
    elapsed=$((current_time - START_TIME))
    if [ "$elapsed" -ge "$TIMEOUT_SECONDS" ]; then
      echo "⏱️ [$(date '+%Y-%m-%d %H:%M:%S')] Time limit reached ($elapsed seconds). Preserving status and exiting."
      reset_all_slots
      exit 0
    fi

    # レート制限緩和のための待機
    sleep 5
  done

  # スロット終了時に status を idle に戻す
  local final_json
  final_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
  if echo "$final_json" | jq -e '.' > /dev/null 2>&1; then
    final_json=$(echo "$final_json" | jq '.status = "idle"')
    local tmp_idle
    tmp_idle=$(mktemp /tmp/fq_idle_XXXXXX.json)
    printf '%s' "$final_json" > "$tmp_idle"
    gh gist edit "$slot_id" -f fetch_queue.json "$tmp_idle"
    rm -f "$tmp_idle"
  fi

  return 0
}

# --- 7. メインループ（未処理がなくなるまで最大10回実行） ---
LOOP_COUNT=0
MAX_LOOPS=10

while [ $LOOP_COUNT -lt $MAX_LOOPS ]; do
  LOOP_COUNT=$((LOOP_COUNT + 1))
  echo ""
  echo "🔁 [Loop iteration $LOOP_COUNT/$MAX_LOOPS]"
  PROCESSED=false

  process_slot "$SLOT0_ID" 0 && PROCESSED=true

  if [ -n "$SLOT1_ID" ]; then
    process_slot "$SLOT1_ID" 1 && PROCESSED=true
  fi

  if [ "$PROCESSED" = false ]; then
    echo "✅ No unprocessed entries in any slot. All done."
    break
  fi

  echo "🔄 Entries processed in this round. Re-checking slots..."
done

if [ $LOOP_COUNT -ge $MAX_LOOPS ]; then
  echo "⚠️ Warning: Reached max loop count ($MAX_LOOPS). Exiting."
fi

reset_all_slots

echo ""
echo "=========================================="
echo "🎉 [$(date '+%Y-%m-%d %H:%M:%S')] Local Scheduled Fetch Completed"
echo "=========================================="
