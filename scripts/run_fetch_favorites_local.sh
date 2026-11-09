#!/bin/bash
# ==============================================================================
# run_fetch_favorites_local.sh
# X (Twitter) お気に入り巡回スクリプト（favorites同期 ＆ Slot 0 巡回）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

if [ -d "$PROJECT_DIR/venv" ]; then
  source "$PROJECT_DIR/venv/bin/activate"
fi

echo "=========================================="
echo "🌟 [$(date '+%Y-%m-%d %H:%M:%S')] Favorites Sync & Crawl Started"
echo "=========================================="

# 1. お気に入りリスト (favorites.json) と Slot 0 キュー (fetch_queue.json) を同期
#    お気に入り解除されたアカウントを除外し、新規お気に入りを追加
python3 "$PROJECT_DIR/scripts/sync_favorites.py"

# 2. Slot 0 (お気に入り巡回枠) のクローリング実行
exec "$SCRIPT_DIR/run_scheduled_fetch_local.sh" --slot 0 "$@"
