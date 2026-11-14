#!/bin/bash

# --- デフォルト値の設定 ---
GIST_ID=""
USER=""
MODE="post_only"
NUM=500
STOP_ON_EXISTING=""
FORCE_EMPTY=""
PROMOTE_GIST_ID=""
FROM_SCRATCH=""
IS_CANDIDATE=""

# --- 引数の解析 ---
while [ $# -gt 0 ]; do
  case "$1" in
    -g|--gist-id)
      GIST_ID="$2"
      shift 2
      ;;
    -u|--user)
      USER="$2"
      shift 2
      ;;
    -n|--num)
      NUM="$2"
      shift 2
      ;;
    -s|--stop-on-existing)
      STOP_ON_EXISTING="-s"
      shift
      ;;
    -f|--force-empty)
      FORCE_EMPTY="--force-empty"
      shift
      ;;
    -p|--promote-gist-id)
      PROMOTE_GIST_ID="$2"
      shift 2
      ;;
    -r|--from-scratch)
      FROM_SCRATCH="--from-scratch"
      shift
      ;;
    --is-candidate)
      IS_CANDIDATE="--is-candidate"
      shift
      ;;
    *)
      echo "Usage: $0 -g gist_id -u user [-n num] [-s] [-f] [-p promote_gist_id] [--from-scratch] [--is-candidate]"
      exit 1
      ;;
  esac
done

# 必須引数のチェック
if [ -z "$GIST_ID" ]; then
    echo "❌ Error: Gist ID (-g) is required."
    exit 1
fi
if [ -z "$USER" ]; then
    echo "❌ Error: User (-u) is required."
    exit 1
fi

echo "=========================================="
echo "Append to Gist"
echo "  Gist ID          : $GIST_ID"
echo "  Target           : @$USER"
echo "  Mode             : $MODE (fixed)"
echo "  Num              : $NUM"
echo "  Stop on existing : ${STOP_ON_EXISTING:-(skip mode)}"
echo "  Force empty      : ${FORCE_EMPTY:-(no)}"
echo "  From scratch     : ${FROM_SCRATCH:-(no)}"
echo "  Promote Gist     : ${PROMOTE_GIST_ID:-(none)}"
echo "=========================================="

PROMOTE_FLAG=""
if [ -n "$PROMOTE_GIST_ID" ]; then
  PROMOTE_FLAG="--promote-gist-id $PROMOTE_GIST_ID"
fi

# --- 仮想環境の有効化 ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$PROJECT_DIR/venv" ]; then
  source "$PROJECT_DIR/venv/bin/activate"
fi

python3 scripts/append_to_gist.py \
  -g "$GIST_ID" \
  -u "$USER" \
  -n "$NUM" \
  $STOP_ON_EXISTING \
  $FORCE_EMPTY \
  $FROM_SCRATCH \
  $PROMOTE_FLAG \
  $IS_CANDIDATE
