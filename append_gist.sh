#!/bin/bash

# --- デフォルト値の設定 ---
GIST_ID=""
USER=""
HASHTAG=""
MODE="post_only"
NUM=100
STOP_ON_EXISTING=""
FORCE_EMPTY=""
PROMOTE_GIST_ID=""

# --- 引数の解析 ---
while getopts g:u:t:m:n:sfp: OPT; do
  case $OPT in
    g) GIST_ID=$OPTARG ;;
    u) USER=$OPTARG ;;
    t) HASHTAG=$OPTARG ;;
    m) MODE=$OPTARG ;;
    n) NUM=$OPTARG ;;
    s) STOP_ON_EXISTING="-s" ;;
    f) FORCE_EMPTY="--force-empty" ;;
    p) PROMOTE_GIST_ID=$OPTARG ;;
    *) echo "Usage: $0 -g gist_id [-u user | -t hashtag] [-m all|post_only] [-n num] [-s] [-f] [-p promote_gist_id]"
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
TARGET_LABEL=""
if [ -n "$USER" ]; then
  TARGET_LABEL="@$USER"
else
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
echo "  Promote Gist     : ${PROMOTE_GIST_ID:-(none)}"
echo "=========================================="

PROMOTE_FLAG=""
if [ -n "$PROMOTE_GIST_ID" ]; then
  PROMOTE_FLAG="--promote-gist-id $PROMOTE_GIST_ID"
fi

if [ -n "$USER" ]; then
  python3 scripts/append_to_gist.py \
    -g "$GIST_ID" \
    -u "$USER" \
    -m "$MODE" \
    -n "$NUM" \
    $STOP_ON_EXISTING \
    $FORCE_EMPTY \
    $PROMOTE_FLAG
else
  python3 scripts/append_to_gist.py \
    -g "$GIST_ID" \
    --hashtag "$HASHTAG" \
    -m "$MODE" \
    -n "$NUM" \
    $STOP_ON_EXISTING \
    $FORCE_EMPTY \
    $PROMOTE_FLAG
fi
