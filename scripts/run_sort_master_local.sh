#!/bin/bash
set -euo pipefail

# ==============================================================================
# run_sort_master_local.sh
# メインギャラリーの表示順ソート実行スクリプト（RAM4GB・低スペックPC対応）
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# 仮想環境の Python を優先利用
PYTHON="$PROJECT_DIR/venv/bin/python"
if [ ! -f "$PYTHON" ]; then
  PYTHON="python3"
fi

# RAM4GB環境に配慮した並列スレッド数（デフォルト2並列）
SORT_THREADS="${SORT_THREADS:-2}"

ARGS=()
HAS_FETCH_CHILD=false

for arg in "$@"; do
  if [ "$arg" = "--fetch-child" ]; then
    HAS_FETCH_CHILD=true
  else
    ARGS+=("$arg")
  fi
done

if [ "$HAS_FETCH_CHILD" = "false" ]; then
  # 巡回直後は append_to_gist により最新ツイートがマスターGist内に反映済みのため、
  # 子Gist通信をスキップして RAM 数十MB・数秒で軽量かつ高速にソートを完了する
  ARGS+=("--no-fetch-child")
else
  ARGS+=("--threads" "$SORT_THREADS")
fi

echo "🔄 [$(date '+%Y-%m-%d %H:%M:%S')] Starting Master Gallery Sort (Memory-optimized)..."
"$PYTHON" "$SCRIPT_DIR/sort_master_gallery.py" "${ARGS[@]}"
echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')] Master Gallery Sort finished."
