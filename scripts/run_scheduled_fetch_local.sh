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

# --- 引数の解析 ---
TARGET_SLOT="all"
while [[ $# -gt 0 ]]; do
  case $1 in
    --slot)
      TARGET_SLOT="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

echo "=========================================="
echo "🚀 [$(date '+%Y-%m-%d %H:%M:%S')] Local Scheduled Fetch Started (Slot: $TARGET_SLOT)"
echo "=========================================="

CONSECUTIVE_ERRORS=0

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
if [ -z "$DEFAULT_COUNT" ]; then
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
    # 全エントリが処理済みの場合、アダプティブ・スキップカウンタを維持したまま done フラグをリセットして次周回に備える
    local total_users
    total_users=$(echo "$slot_json" | jq -r '(.users | length) // 0')
    if [ "$total_users" -gt 0 ]; then
      echo "🔄 [Adaptive Skip] All $total_users entries done in slot $slot_num. Resetting cycle (done=false) while keeping skip counters..."
      slot_json=$(echo "$slot_json" | jq '.users = [.users[] | .done = false]')
      local tmp_cycle
      tmp_cycle=$(mktemp /tmp/fq_cycle_reset_XXXXXX.json)
      printf '%s' "$slot_json" > "$tmp_cycle"
      gh gist edit "$slot_id" -f fetch_queue.json "$tmp_cycle"
      rm -f "$tmp_cycle"
      echo "✅ Slot $slot_num cycle reset complete."
    fi
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

  local BATCH_SKIPS_FILE
  BATCH_SKIPS_FILE=$(mktemp /tmp/fq_pending_skips_XXXXXX.json)

  flush_pending_skips() {
    if [ ! -s "$BATCH_SKIPS_FILE" ]; then
      return 0
    fi

    local pending_count
    pending_count=$(wc -l < "$BATCH_SKIPS_FILE")
    echo "💾 [Batch Update] Flushing $pending_count skipped user updates to Gist..."

    local latest_json
    latest_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
    if echo "$latest_json" | jq -e '.users' > /dev/null 2>&1; then
      latest_json=$(echo "$latest_json" | jq --slurpfile updates "$BATCH_SKIPS_FILE" '
        reduce $updates[] as $u (.;
          .users = [.users[] | if (.user | ascii_downcase) == ($u.user | ascii_downcase) then . + {"done": true, "skip_count": $u.skip_count, "skip_remaining": $u.skip_remaining} else . end]
        )
      ')
      local tmp_batch
      tmp_batch=$(mktemp /tmp/fq_batch_XXXXXX.json)
      printf '%s' "$latest_json" > "$tmp_batch"
      gh gist edit "$slot_id" -f fetch_queue.json "$tmp_batch"
      rm -f "$tmp_batch"
    fi
    : > "$BATCH_SKIPS_FILE"
  }

  for i in "${!ENTRIES[@]}"; do
    local entry="${ENTRIES[$i]}"
    local USER COUNT STOP EXIT_CODE=0

    USER=$(echo "$entry" | jq -r '.user // empty')
    COUNT=$(echo "$entry" | jq -r --arg def "$DEFAULT_COUNT" '(.count // ($def | tonumber) | tostring)')
    if [ -z "$COUNT" ]; then
      COUNT="$DEFAULT_COUNT"
    fi
    STOP=$(echo "$entry" | jq -r '(if .stop_on_existing == null then true else .stop_on_existing end | tostring)')

    if [ -z "$USER" ]; then
      echo "⚠️ Warning: Entry has no user, skipping: $entry"
      continue
    fi

    # --- アダプティブ・スキップ（バックオフ）判定 ---
    local SKIP_COUNT SKIP_REMAINING
    SKIP_COUNT=$(echo "$entry" | jq -r '.skip_count // empty')
    SKIP_REMAINING=$(echo "$entry" | jq -r '.skip_remaining // empty')

    local SHOULD_SKIP_ARGS=(should-skip -u "$USER")
    [ -n "$SKIP_COUNT" ] && SHOULD_SKIP_ARGS+=(--queue-count "$SKIP_COUNT")
    [ -n "$SKIP_REMAINING" ] && SHOULD_SKIP_ARGS+=(--queue-remaining "$SKIP_REMAINING")

    local SKIP_CHECK_OUTPUT
    if SKIP_CHECK_OUTPUT=$(python3 "$PROJECT_DIR/scripts/adaptive_skip.py" "${SHOULD_SKIP_ARGS[@]}" 2>/dev/null); then
      # exit code 0: スキップ対象（スキップ残り回数を1消費）
      local rem cnt
      rem=$(echo "$SKIP_CHECK_OUTPUT" | jq -r '.skip_remaining // 0')
      cnt=$(echo "$SKIP_CHECK_OUTPUT" | jq -r '.skip_count // 0')
      echo ""
      echo "⏩ [Adaptive Skip] Slot $slot_num [$((i+1))/$entry_count]: Skipping @$USER ($rem cycles remaining, backoff level $cnt)"

      # バッチ更新用に一時ファイルへ蓄積（Gist通信をスキップして高速化）
      printf '{"user":"%s","skip_count":%s,"skip_remaining":%s}\n' "$USER" "$cnt" "$rem" >> "$BATCH_SKIPS_FILE"

      # 25件蓄積されたら定期フラッシュ
      if [ "$(wc -l < "$BATCH_SKIPS_FILE")" -ge 25 ]; then
        flush_pending_skips
      fi

      continue
    fi

    # クロール対象の場合、保留中のスキップがあればフラッシュ
    flush_pending_skips

    # --- 防御策: クロール実行直前のキュー存在確認 ---
    # クローラー周回中にアプリからユーザーが削除された場合、即座にスキップしてゾンビ復活を防ぐ
    local fresh_queue_json
    fresh_queue_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
    if echo "$fresh_queue_json" | jq -e '.users' > /dev/null 2>&1; then
      local user_in_queue
      user_in_queue=$(echo "$fresh_queue_json" | jq -r --arg user "$USER" '[.users[] | select((.user | ascii_downcase) == ($user | ascii_downcase))] | length')
      if [ "$user_in_queue" -eq 0 ]; then
        echo ""
        echo "⚠️ [User Deleted] @$USER was removed from queue during crawl loop. Skipping."
        continue
      fi
    fi

    # --- クロール実行 ---
    echo ""
    echo "▶️ Slot $slot_num [$((i+1))/$entry_count]: @$USER (count=$COUNT, stop_on_existing=$STOP)"
    rm -f "$PROJECT_DIR/data/.last_fetch_result.json"

    if [ "$STOP" = "true" ]; then
      ./append_gist.sh -g "$MASTER_GIST_ID" -u "$USER" -n "$COUNT" -s || EXIT_CODE=$?
    else
      ./append_gist.sh -g "$MASTER_GIST_ID" -u "$USER" -n "$COUNT" || EXIT_CODE=$?
    fi

    # レートリミット (42) 検知
    if [ $EXIT_CODE -eq 42 ]; then
      echo "🚨 [$(date '+%Y-%m-%d %H:%M:%S')] Rate limit detected (exit code 42). Pausing execution."
      flush_pending_skips
      rm -f "$BATCH_SKIPS_FILE"
      reset_all_slots
      exit 42
    fi

    # セッション切れ (41) 検知
    if [ $EXIT_CODE -eq 41 ]; then
      echo "🚨 [$(date '+%Y-%m-%d %H:%M:%S')] Session expired or login required (exit code 41). Pausing execution."
      flush_pending_skips
      rm -f "$BATCH_SKIPS_FILE"
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
          flush_pending_skips
          rm -f "$BATCH_SKIPS_FILE"
          reset_all_slots
          exit 1
        fi
      fi
      sleep 2
      continue
    fi

    # 成功時はエラーカウントをリセット
    CONSECUTIVE_ERRORS=0

    # 保存されたツイート数の取得
    local SAVED_COUNT=0
    local FETCH_STATUS=""
    local RESULT_FILE="$PROJECT_DIR/data/.last_fetch_result.json"
    if [ -f "$RESULT_FILE" ]; then
      SAVED_COUNT=$(jq -r '.tweets_saved // 0' "$RESULT_FILE" 2>/dev/null || echo 0)
      FETCH_STATUS=$(jq -r '.status // empty' "$RESULT_FILE" 2>/dev/null || echo "")
    fi

    # 削除検知により追記キャンセルされた場合はキュー更新を行わず次へ進む
    if [ "$FETCH_STATUS" = "cancelled_user_deleted" ]; then
      echo "⚠️ [User Deleted] Crawl append was aborted because @$USER was deleted. Skipping queue update."
      continue
    fi

    # アダプティブ・スキップ結果の記録・更新
    local RECORD_ARGS=(record -u "$USER" -s "$SAVED_COUNT")
    [ -n "$SKIP_COUNT" ] && RECORD_ARGS+=(--queue-count "$SKIP_COUNT")

    local RECORD_OUTPUT
    RECORD_OUTPUT=$(python3 "$PROJECT_DIR/scripts/adaptive_skip.py" "${RECORD_ARGS[@]}" 2>/dev/null || echo "")
    local NEW_SKIP_COUNT=0 NEW_SKIP_REMAINING=0
    if [ -n "$RECORD_OUTPUT" ]; then
      NEW_SKIP_COUNT=$(echo "$RECORD_OUTPUT" | jq -r '.skip_count // 0')
      NEW_SKIP_REMAINING=$(echo "$RECORD_OUTPUT" | jq -r '.skip_remaining // 0')
    fi

    if [ "$SAVED_COUNT" -eq 0 ]; then
      echo "💤 [Adaptive Skip] 0 tweets saved for @$USER. Increased backoff: level $NEW_SKIP_COUNT (will skip next $NEW_SKIP_REMAINING cycles)."
    else
      echo "✨ [Adaptive Skip] $SAVED_COUNT new tweets saved for @$USER! Backoff reset to 0."
    fi

    # done: true と skip_count, skip_remaining を Gist に反映
    local latest_json
    latest_json=$(gh gist view "$slot_id" -f fetch_queue.json 2>/dev/null || echo "")
    if echo "$latest_json" | jq -e '.users' > /dev/null 2>&1; then
      latest_json=$(echo "$latest_json" | jq --arg user "$USER" --argjson sc "$NEW_SKIP_COUNT" --argjson sr "$NEW_SKIP_REMAINING" --argjson scnt "$SAVED_COUNT" \
        '.users = [.users[] | if .user == $user then . + {"done": true, "skip_count": $sc, "skip_remaining": $sr, "last_saved_count": $scnt} else . end]')
      local tmp_done
      tmp_done=$(mktemp /tmp/fq_done_XXXXXX.json)
      printf '%s' "$latest_json" > "$tmp_done"
      gh gist edit "$slot_id" -f fetch_queue.json "$tmp_done"
      rm -f "$tmp_done"
    fi

    # レート制限緩和のための待機
    sleep 5
  done

  # スロット走査終了時に未フラッシュの保留スキップを一括反映
  flush_pending_skips
  rm -f "$BATCH_SKIPS_FILE"

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

  if [ "$TARGET_SLOT" = "0" ] || [ "$TARGET_SLOT" = "all" ]; then
    process_slot "$SLOT0_ID" 0 && PROCESSED=true
  fi

  if [ "$TARGET_SLOT" = "1" ] || [ "$TARGET_SLOT" = "all" ]; then
    if [ -n "$SLOT1_ID" ]; then
      process_slot "$SLOT1_ID" 1 && PROCESSED=true
    fi
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
