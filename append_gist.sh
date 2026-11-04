#!/bin/bash

# --- デフォルト値の設定 ---
GIST_ID=""
USER=""
MODE="post_only"
NUM=500
STOP_ON_EXISTING=""
FORCE_EMPTY=""
PROMOTE_GIST_ID=""

# --- 引数の解析 ---
while getopts g:u:n:sfp: OPT; do
  case $OPT in
    g) GIST_ID=$OPTARG ;;
    u) USER=$OPTARG ;;
    n) NUM=$OPTARG ;;
    s) STOP_ON_EXISTING="-s" ;;
    f) FORCE_EMPTY="--force-empty" ;;
    p) PROMOTE_GIST_ID=$OPTARG ;;
    *) echo "Usage: $0 -g gist_id -u user [-n num] [-s] [-f] [-p promote_gist_id]"
       exit 1 ;;
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
echo "  Promote Gist     : ${PROMOTE_GIST_ID:-(none)}"
echo "=========================================="

PROMOTE_FLAG=""
if [ -n "$PROMOTE_GIST_ID" ]; then
  PROMOTE_FLAG="--promote-gist-id $PROMOTE_GIST_ID"
fi

python3 scripts/append_to_gist.py \
  -g "$GIST_ID" \
  -u "$USER" \
  -n "$NUM" \
  $STOP_ON_EXISTING \
  $FORCE_EMPTY \
  $PROMOTE_FLAG
