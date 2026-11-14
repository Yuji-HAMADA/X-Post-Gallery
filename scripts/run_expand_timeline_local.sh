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

# --- 2. 二重起動防止ロック ---
LOCKFILE="/tmp/expand_timeline_candidates.lock"
exec 201>"$LOCKFILE"
if ! flock -n 201; then
  echo "⚠️ [$(date '+%Y-%m-%d %H:%M:%S')] Another instance of expand_timeline is already running. Exiting."
  exit 0
fi

# --- 3. .env の読み込み（既存の環境変数は上書きしない） ---
if [ -f "$PROJECT_DIR/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" != *"="* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key=$(echo "$key" | tr -d '[:space:]')
    val=$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
    if [ -n "$key" ] && [ -z "${!key+x}" ]; then
      export "$key=$val"
    fi
  done < "$PROJECT_DIR/.env"
fi

# GITHUB_TOKEN から GH_TOKEN へのフォールバック
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# MASTER_GIST_ID の確認
if [ -z "${MASTER_GIST_ID:-}" ]; then
  echo "❌ Error: MASTER_GIST_ID is not set in .env or environment."
  exit 1
fi

# data/auth.json のチェック（未生成かつ AUTH_JSON があれば生成）
if [ ! -s "$PROJECT_DIR/data/auth.json" ] && [ -n "${AUTH_JSON:-}" ]; then
  mkdir -p "$PROJECT_DIR/data"
  printf "%s" "$AUTH_JSON" > "$PROJECT_DIR/data/auth.json"
fi

if [ ! -s "$PROJECT_DIR/data/auth.json" ]; then
  echo "❌ Error: Auth session not found at data/auth.json."
  echo "   Please place valid X session cookies in data/auth.json or set AUTH_JSON in .env."
  exit 1
fi

echo "=================================================="
echo "🚀 [$(date '+%Y-%m-%d %H:%M:%S')] Timeline Candidate Collector Started"
echo "  Master Gist ID : $MASTER_GIST_ID"
echo "=================================================="

# --- 4. タイムライン収集スクリプトの実行 ---
python3 "$PROJECT_DIR/scripts/expand_timeline_candidates.py" -g "$MASTER_GIST_ID" -n 300 "$@"
