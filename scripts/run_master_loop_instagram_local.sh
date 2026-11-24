#!/bin/bash
set -euo pipefail

# ==============================================================================
# run_master_loop_instagram_local.sh
# run_master_loop_local.sh の Instagram 版ラッパー（共通スクリプトを PLATFORM=instagram で実行）
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PLATFORM="instagram"
exec "$SCRIPT_DIR/run_master_loop_local.sh" "$@"
