#!/bin/bash

# --- デフォルト値の設定 ---
NUM=100
GIST_ID=""

# --- 引数の解析 (n: 件数, g: Gist ID) ---
while getopts n:g: OPT; do
  case $OPT in
    n) NUM=$OPTARG ;;
    g) GIST_ID=$OPTARG ;;
    *) echo "Usage: $0 -g gist_id [-n num]"
       exit 1 ;;
  esac
done

# 必須引数のチェック
if [ -z "$GIST_ID" ]; then
    echo "❌ Error: Gist ID (-g) is required."
    echo "Usage: $0 -g gist_id [-n num]"
    exit 1
fi

echo "=========================================="
echo "Update My Gist (For You)"
echo "  Gist ID          : $GIST_ID"
echo "  Num              : $NUM"
echo "=========================================="

python3 scripts/append_to_gist.py \
  -g "$GIST_ID" \
  --foryou \
  -n "$NUM"
