#!/bin/bash
set -euo pipefail

# ==============================================================================
# run_master_loop_local.sh
# タイムライン収集 (1巡) と 個別フェッチ (キュー処理) を連続反復する統合ループスクリプト
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

show_usage() {
  cat <<'EOF'
Usage: run_master_loop_local.sh [OPTIONS] [EXPAND_TIMELINE_OPTIONS...]
       run_master_loop_instagram_local.sh [OPTIONS] [EXPAND_TIMELINE_OPTIONS...]
       run_master_loop_tiktok_local.sh [OPTIONS] [EXPAND_TIMELINE_OPTIONS...]

Master Loop Options:
  -h, --help                Show this help message and exit
  --platform <x|instagram|tiktok>
                            Target platform (default: $PLATFORM or x)
  --max-cycles <N>          Stop master loop after N full cycles (0 = unlimited)

All other options (e.g., -n, --num-existing, --scroll-batch-size, --rate-limit-wait,
--slot, --no-headless) are forwarded to run_expand_timeline_local.sh / run_scheduled_fetch_local.sh.
EOF
  if [ -x "$PROJECT_DIR/venv/bin/python" ] && [ -f "$PROJECT_DIR/scripts/expand_timeline_candidates.py" ]; then
    echo ""
    echo "--- expand_timeline_candidates.py options ---"
    "$PROJECT_DIR/venv/bin/python" "$PROJECT_DIR/scripts/expand_timeline_candidates.py" --help
  fi
}

# --platform / --max-cycles / --help 引数を解析し、残りを子スクリプトへ引き継ぐ
PASS_ARGS=()
MAX_CYCLES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_usage
      exit 0
      ;;
    --platform)
      export PLATFORM="$2"
      shift 2
      ;;
    --platform=*)
      export PLATFORM="${1#*=}"
      shift
      ;;
    --max-cycles)
      if [[ $# -lt 2 ]]; then
        echo "❌ Error: --max-cycles requires a numeric argument." >&2
        exit 1
      fi
      MAX_CYCLES="$2"
      shift 2
      ;;
    --max-cycles=*)
      MAX_CYCLES="${1#*=}"
      shift
      ;;
    *)
      PASS_ARGS+=("$1")
      shift
      ;;
  esac
done

if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: --max-cycles must be a non-negative integer (got: '$MAX_CYCLES')." >&2
  exit 1
fi

source "$SCRIPT_DIR/platform_env.sh"
load_project_env "$PROJECT_DIR"
resolve_platform_env "$PROJECT_DIR"

CYCLE=0

trap 'echo -e "\n🛑 Master loop stopped."; exit 0' INT TERM

while true; do
  CYCLE=$((CYCLE + 1))
  echo ""
  echo "=================================================="
  if [[ "$MAX_CYCLES" -gt 0 ]]; then
    echo "🔄 [$(date '+%Y-%m-%d %H:%M:%S')] Starting Loop Cycle #$CYCLE/$MAX_CYCLES (Platform: $PLATFORM_LABEL)"
  else
    echo "🔄 [$(date '+%Y-%m-%d %H:%M:%S')] Starting Loop Cycle #$CYCLE (Platform: $PLATFORM_LABEL)"
  fi
  echo "=================================================="

  # 1. タイムライン収集（1巡分）の実行
  echo "▶️ [Step 1/3] Running run_expand_timeline_local.sh (--max-cycles 1)..."
  set +e
  "$SCRIPT_DIR/run_expand_timeline_local.sh" --max-cycles 1 "${PASS_ARGS[@]}"
  STEP1_RC=$?
  set -e
  if [[ "$STEP1_RC" -eq 41 ]]; then
    echo "🚨 [$(date '+%Y-%m-%d %H:%M:%S')] Auth session expired for $PLATFORM_LABEL (exit 41). Stopping master loop immediately." >&2
    exit 41
  fi

  # 2. 続けてスケジュール・キューフェッチを実行
  echo "▶️ [Step 2/3] Running run_scheduled_fetch_local.sh..."
  set +e
  "$SCRIPT_DIR/run_scheduled_fetch_local.sh" "${PASS_ARGS[@]}"
  STEP2_RC=$?
  set -e
  if [[ "$STEP2_RC" -eq 41 ]]; then
    echo "🚨 [$(date '+%Y-%m-%d %H:%M:%S')] Auth session expired for $PLATFORM_LABEL (exit 41). Stopping master loop immediately." >&2
    exit 41
  fi

  # 3. タイムライン収集および詳細取得完了後のギャラリーソート実行
  echo "▶️ [Step 3/3] Running run_sort_master_local.sh (Sorting Master Gallery)..."
  "$SCRIPT_DIR/run_sort_master_local.sh" || echo "⚠️ Warning: Master gallery sort encountered an error."

  if [[ "$MAX_CYCLES" -gt 0 && "$CYCLE" -ge "$MAX_CYCLES" ]]; then
    echo "🏁 Completed Loop Cycle #$CYCLE/$MAX_CYCLES (Platform: $PLATFORM_LABEL). Stopping master loop."
    break
  fi

  echo "✅ Completed Loop Cycle #$CYCLE (Platform: $PLATFORM_LABEL). Repeating cycle..."
done
