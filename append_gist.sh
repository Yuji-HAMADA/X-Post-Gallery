#!/bin/bash

# --- デフォルト値の設定 ---
GIST_ID=""
USER=""
MODE="post_only"
NUM=100
STOP_ON_EXISTING=""

# --- 引数の解析 ---
while getopts g:u:m:n:s OPT; do
  case $OPT in
    g) GIST_ID=$OPTARG ;;
    u) USER=$OPTARG ;;
    m) MODE=$OPTARG ;;
    n) NUM=$OPTARG ;;
    s) STOP_ON_EXISTING="-s" ;;
    *) echo "Usage: $0 -g gist_id -u user [-m all|post_only] [-n num] [-s]"
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
echo "  User             : @$USER"
echo "  Mode             : $MODE"
echo "  Num              : $NUM"
echo "  Stop on existing : ${STOP_ON_EXISTING:-(skip mode)}"
echo "=========================================="

python3 scripts/append_to_gist.py \
  -g "$GIST_ID" \
  -u "$USER" \
  -m "$MODE" \
  -n "$NUM" \
  $STOP_ON_EXISTING
