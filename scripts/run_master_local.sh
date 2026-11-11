#!/bin/bash
set -euo pipefail

# ==============================================================================
# run_master_local.sh
# run_fetch_favorites_local.sh と run_scheduled_fetch_local.sh を
# 交互に継続して繰り返し実行するマスター制御スクリプト
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# 実行インターバル（デフォルト: 10秒）
LOOP_INTERVAL="${LOOP_INTERVAL:-10}"
# レートリミット（exit 42）発生時の待機時間（秒、デフォルト: 900秒 = 15分）
RATE_LIMIT_WAIT="${RATE_LIMIT_WAIT:-900}"
# セッション切れ等の異常（exit 41など）発生時の待機時間（秒、デフォルト: 60秒）
ERROR_WAIT="${ERROR_WAIT:-60}"

# --- 二重起動防止ロック ---
LOCKFILE="/tmp/master_local.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "⚠️ [$(date '+%Y-%m-%d %H:%M:%S')] Another instance of master crawler is already running. Exiting."
  exit 0
fi

# --- 終了ハンドラ ---
cleanup() {
  echo ""
  echo "🛑 [$(date '+%Y-%m-%d %H:%M:%S')] Master crawler loop stopped."
  exit 0
}
trap cleanup INT TERM

echo "=========================================="
echo "🚀 [$(date '+%Y-%m-%d %H:%M:%S')] Master Crawler Loop Started"
echo "🔁 Priority Order: 1. App Operations Queue (Slot 1) -> 2. Favorites Crawl (Slot 0)"
echo "=========================================="

CYCLE_COUNT=0

while true; do
  CYCLE_COUNT=$((CYCLE_COUNT + 1))
  echo ""
  echo "############################################################"
  echo "🔄 [$(date '+%Y-%m-%d %H:%M:%S')] Starting Cycle #$CYCLE_COUNT"
  echo "############################################################"

  # 1. run_scheduled_fetch_local.sh --slot 1 (ユーザー操作枠: アプリ新規追加・画像取得リクエストを最優先)
  echo ""
  echo "▶️ [Priority Step 1/2] Checking & Running App Operations Queue (Slot 1)..."
  SCHED_STATUS=0
  "$SCRIPT_DIR/run_scheduled_fetch_local.sh" --slot 1 "$@" || SCHED_STATUS=$?

  if [ $SCHED_STATUS -eq 130 ] || [ $SCHED_STATUS -eq 143 ]; then
    echo "🛑 Interrupted during scheduled fetch (Slot 1). Exiting."
    exit $SCHED_STATUS
  elif [ $SCHED_STATUS -eq 42 ]; then
    echo "🚨 Rate limit detected in scheduled fetch (code 42). Sleeping for ${RATE_LIMIT_WAIT}s..."
    sleep "$RATE_LIMIT_WAIT"
  elif [ $SCHED_STATUS -eq 41 ]; then
    echo "🚨 Session error in scheduled fetch (code 41). Sleeping for ${ERROR_WAIT}s..."
    sleep "$ERROR_WAIT"
  elif [ $SCHED_STATUS -ne 0 ]; then
    echo "⚠️ run_scheduled_fetch_local.sh exited with code $SCHED_STATUS."
    sleep "$ERROR_WAIT"
  else
    echo "✅ [Priority Step 1/2] Completed App Operations Queue (Slot 1)."
    sleep "$LOOP_INTERVAL"
  fi

  # 2. run_fetch_favorites_local.sh (お気に入り同期 & Slot 0 定期巡回)
  echo ""
  echo "▶️ [Background Step 2/2] Running run_fetch_favorites_local.sh (Favorites / Slot 0)..."
  FAV_STATUS=0
  "$SCRIPT_DIR/run_fetch_favorites_local.sh" "$@" || FAV_STATUS=$?

  if [ $FAV_STATUS -eq 130 ] || [ $FAV_STATUS -eq 143 ]; then
    echo "🛑 Interrupted during run_fetch_favorites_local.sh. Exiting."
    exit $FAV_STATUS
  elif [ $FAV_STATUS -eq 42 ]; then
    echo "🚨 Rate limit detected in favorites fetch (code 42). Sleeping for ${RATE_LIMIT_WAIT}s..."
    sleep "$RATE_LIMIT_WAIT"
  elif [ $FAV_STATUS -eq 41 ]; then
    echo "🚨 Session error in favorites fetch (code 41). Sleeping for ${ERROR_WAIT}s..."
    sleep "$ERROR_WAIT"
  elif [ $FAV_STATUS -ne 0 ]; then
    echo "⚠️ run_fetch_favorites_local.sh exited with code $FAV_STATUS."
    sleep "$ERROR_WAIT"
  else
    echo "✅ [Background Step 2/2] Completed run_fetch_favorites_local.sh."
    sleep "$LOOP_INTERVAL"
  fi

  echo ""
  echo "✅ Cycle #$CYCLE_COUNT finished. Continuing to next cycle..."
done
