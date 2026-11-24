#!/bin/bash
set -euo pipefail

# ==============================================================================
# run_master_loop_local.sh
# タイムライン収集 (1巡) と 個別フェッチ (キュー処理) を連続反復する統合ループスクリプト
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# --platform 引数があれば PLATFORM 環境変数に反映
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      export PLATFORM="$2"
      shift 2
      ;;
    *)
      PASS_ARGS+=("$1")
      shift
      ;;
  esac
done

source "$SCRIPT_DIR/platform_env.sh"
load_project_env "$PROJECT_DIR"
resolve_platform_env "$PROJECT_DIR"

CYCLE=0

trap 'echo -e "\n🛑 Master loop stopped."; exit 0' INT TERM

while true; do
  CYCLE=$((CYCLE + 1))
  echo ""
  echo "=================================================="
  echo "🔄 [$(date '+%Y-%m-%d %H:%M:%S')] Starting Loop Cycle #$CYCLE (Platform: $PLATFORM_LABEL)"
  echo "=================================================="

  # 1. タイムライン収集（1巡分）の実行
  echo "▶️ [Step 1/3] Running run_expand_timeline_local.sh (--max-cycles 1)..."
  "$SCRIPT_DIR/run_expand_timeline_local.sh" --max-cycles 1 "${PASS_ARGS[@]}" || true

  # 2. 続けてスケジュール・キューフェッチを実行
  echo "▶️ [Step 2/3] Running run_scheduled_fetch_local.sh..."
  "$SCRIPT_DIR/run_scheduled_fetch_local.sh" "${PASS_ARGS[@]}" || true

  # 3. タイムライン収集および詳細取得完了後のギャラリーソート実行
  echo "▶️ [Step 3/3] Running run_sort_master_local.sh (Sorting Master Gallery)..."
  "$SCRIPT_DIR/run_sort_master_local.sh" || echo "⚠️ Warning: Master gallery sort encountered an error."

  echo "✅ Completed Loop Cycle #$CYCLE (Platform: $PLATFORM_LABEL). Repeating cycle..."
done
