#!/bin/bash
set -euo pipefail

# ==============================================================================
# run_master_loop_local.sh
# タイムライン収集 (1巡) と 個別フェッチ (キュー処理) を連続反復する統合ループスクリプト
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

CYCLE=0

trap 'echo -e "\n🛑 Master loop stopped."; exit 0' INT TERM

while true; do
  CYCLE=$((CYCLE + 1))
  echo ""
  echo "=================================================="
  echo "🔄 [$(date '+%Y-%m-%d %H:%M:%S')] Starting Loop Cycle #$CYCLE"
  echo "=================================================="

  # 1. タイムライン収集（1巡分）の実行
  echo "▶️ [Step 1/2] Running run_expand_timeline_local.sh (--max-cycles 1)..."
  "$SCRIPT_DIR/run_expand_timeline_local.sh" --max-cycles 1 "$@" || true

  # 2. 続けてスケジュール・キューフェッチを実行
  echo "▶️ [Step 2/2] Running run_scheduled_fetch_local.sh..."
  "$SCRIPT_DIR/run_scheduled_fetch_local.sh" "$@" || true

  echo "✅ Completed Loop Cycle #$CYCLE. Repeating cycle..."
done
