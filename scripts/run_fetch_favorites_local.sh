#!/bin/bash
# ==============================================================================
# run_fetch_favorites_local.sh
# X (Twitter) ローカルクローラー実行スクリプト（アダプティブ・スキップ対応）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run_scheduled_fetch_local.sh" "$@"
