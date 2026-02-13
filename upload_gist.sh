#!/bin/bash

# --- デフォルト値の設定 ---
NUM=100
USER="Yuji20359094"
MODE="all"

# --- 引数の解析 (u: ユーザー名, m: モード, n: 件数) ---
while getopts u:m:n: OPT; do
  case $OPT in
    u) USER=$OPTARG ;;
    m) MODE=$OPTARG ;;
    n) NUM=$OPTARG ;;
    *) echo "Usage: $0 [-u user_id] [-m all|post_only|repost_only] [-n num]"
       exit 1 ;;
  esac
done

# 1. Python仮想環境の有効化
if [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
else
    echo "Error: venv not found."
    exit 1
fi

# 2. X（Twitter）からの抽出
echo "Step 2: Extracting $NUM items for @$USER (Mode: $MODE)..."
# --- Pythonにすべての引数を渡す ---
python3 scripts/extract_media.py -u "$USER" --mode "$MODE" -n "$NUM"

# 3. Flutter用データへの変換
echo "Step 3: Updating data format..."
python3 scripts/update_data.py

# 4. ファイルのリネーム
echo "Step 4: Renaming data file..."
mv assets/data/data.json assets/data/gallary_data.json

# 5. 現在時刻の取得
current_time=$(date "+%Y/%m/%d-%H:%M:%S")
description="Gallery Data ($NUM items) for @$USER ($MODE) on ${current_time}-JST"

# 6. Gist作成とIDの表示
echo "Step 5 & 6: Creating Secret Gist..."
gist_url=$(gh gist create assets/data/gallary_data.json -p -d "$description")

if [ $? -eq 0 ]; then
    gist_id=$(basename "$gist_url")
    echo "------------------------------------------"
    echo "✅ Success!"
    echo "Target User: @$USER"
    echo "Mode       : $MODE"
    echo "Gist URL   : $gist_url"
    echo "Your Gist ID: $gist_id"
    echo "------------------------------------------"
else
    echo "❌ Error: Failed to create Gist."
    exit 1
fi