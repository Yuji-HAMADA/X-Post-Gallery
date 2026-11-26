#!/bin/bash
set -euo pipefail

# ==============================================================================
# run_master_loop_tiktok_local.sh
# run_master_loop_local.sh の TikTok 版ラッパー（共通スクリプトを PLATFORM=tiktok で実行）
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PLATFORM="tiktok"
exec "$SCRIPT_DIR/run_master_loop_local.sh" "$@"
