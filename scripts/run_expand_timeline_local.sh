#!/bin/bash
# ==============================================================================
# run_expand_timeline_local.sh
# X (Twitter) タイムライン巡回・Candidateアカウント自動収集・ギャラリー拡張スクリプト
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# --- 1. 仮想環境の有効化 ---
if [ -d "$PROJECT_DIR/venv" ]; then
  source "$PROJECT_DIR/venv/bin/activate"
else
  echo "❌ Error: Virtual environment $PROJECT_DIR/venv not found."
  exit 1
fi

# --- 2. 環境変数・プラットフォーム解決 ---
source "$SCRIPT_DIR/platform_env.sh"
load_project_env "$PROJECT_DIR"
resolve_platform_env "$PROJECT_DIR"

# --- 3. 二重起動防止ロック ---
LOCKFILE="/tmp/expand_timeline_candidates${PLATFORM_LOCK_SUFFIX}.lock"
exec 201>"$LOCKFILE"
if ! flock -n 201; then
  echo "⚠️ [$(date '+%Y-%m-%d %H:%M:%S')] Another instance of expand_timeline ($PLATFORM_LABEL) is already running. Exiting."
  exit 0
fi

# MASTER_GIST_ID の確認
if [ -z "${MASTER_GIST_ID:-}" ]; then
  echo "❌ Error: MASTER_GIST_ID (or IG_MASTER_GIST_ID / TIKTOK_MASTER_GIST_ID) is not set in .env or environment."
  exit 1
fi

# 認証ファイルのチェック（未生成かつ環境変数があれば生成）
if [ ! -s "$PLATFORM_AUTH_PATH" ] && [ -n "${PLATFORM_AUTH_ENV:-}" ]; then
  mkdir -p "$PROJECT_DIR/data"
  printf "%s" "$PLATFORM_AUTH_ENV" > "$PLATFORM_AUTH_PATH"
fi

if [ ! -s "$PLATFORM_AUTH_PATH" ]; then
  echo "❌ Error: Auth session not found at $PLATFORM_AUTH_PATH."
  exit 1
fi

echo "=================================================="
echo "🚀 [$(date '+%Y-%m-%d %H:%M:%S')] Timeline Candidate Collector Started ($PLATFORM_LABEL)"
echo "  Master Gist ID : $MASTER_GIST_ID"
echo "=================================================="

# --- 4. タイムライン収集スクリプトの実行 ---
python3 "$PROJECT_DIR/scripts/expand_timeline_candidates.py" --platform "$PLATFORM" -g "$MASTER_GIST_ID" "$@"
