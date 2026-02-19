#!/bin/bash

# --- デフォルト値の設定 ---
GIST_ID=""
USER=""
HASHTAG=""
MODE="post_only"
NUM=100
STOP_ON_EXISTING=""
FORCE_EMPTY=""

# --- 引数の解析 ---
while getopts g:u:t:m:n:sf OPT; do
  case $OPT in
    g) GIST_ID=$OPTARG ;;
    u) USER=$OPTARG ;;
    t) HASHTAG=$OPTARG ;;
    m) MODE=$OPTARG ;;
    n) NUM=$OPTARG ;;
    s) STOP_ON_EXISTING="-s" ;;
    f) FORCE_EMPTY="--force-empty" ;;
    *) echo "Usage: $0 -g gist_id [-u user | -t hashtag] [-m all|post_only] [-n num] [-s] [-f]"
       exit 1 ;;
  esac
done

# 必須引数のチェック
if [ -z "$GIST_ID" ]; then
    echo "❌ Error: Gist ID (-g) is required."
    exit 1
fi
if [ -z "$USER" ] && [ -z "$HASHTAG" ]; then
    echo "❌ Error: User (-u) または Hashtag (-t) のどちらかが必要です。"
    exit 1
fi

# ターゲット引数の構築
TARGET_ARG=""
TARGET_LABEL=""
if [ -n "$USER" ]; then
  TARGET_ARG="-u \"$USER\""
  TARGET_LABEL="@$USER"
else
  TARGET_ARG="--hashtag \"$HASHTAG\""
  TARGET_LABEL="#$HASHTAG"
fi

echo "=========================================="
echo "Append to Gist"
echo "  Gist ID          : $GIST_ID"
echo "  Target           : $TARGET_LABEL"
echo "  Mode             : $MODE"
echo "  Num              : $NUM"
echo "  Stop on existing : ${STOP_ON_EXISTING:-(skip mode)}"
echo "  Force empty      : ${FORCE_EMPTY:-(no)}"
echo "=========================================="

if [ -n "$USER" ]; then
  python3 scripts/append_to_gist.py \
    -g "$GIST_ID" \
    -u "$USER" \
    -m "$MODE" \
    -n "$NUM" \
    $STOP_ON_EXISTING \
    $FORCE_EMPTY
else
  python3 scripts/append_to_gist.py \
    -g "$GIST_ID" \
    --hashtag "$HASHTAG" \
    -m "$MODE" \
    -n "$NUM" \
    $STOP_ON_EXISTING \
    $FORCE_EMPTY
fi
