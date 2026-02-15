#!/bin/bash

# --- デフォルト値の設定 ---
NUM=100
USER="travelbeauty8"
MODE="all"

# --- 引数の解析 (u: ユーザー名, m: モード, n: 件数) ---
while getopts u:m:n: OPT; do
  case $OPT in
    u) USER=$OPTARG ;;
    m) MODE=$OPTARG ;;
    n) NUM=$OPTARG ;;
    *) echo "Usage: $0 [-u user_id] [-m all|post_only] [-n num]"
       exit 1 ;;
  esac
done

# 1. 必要なディレクトリの強制作成
mkdir -p assets/data scripts

# 2. X（Twitter）からの抽出
echo "Step 2: Extracting $NUM items for @$USER (Mode: $MODE)..."
# 引数を Python に渡す
python3 scripts/extract_media.py -u "$USER" --mode "$MODE" -n "$NUM"

# 3. Flutter用データへの変換
echo "Step 3: Updating data format..."
python3 scripts/update_data.py

# 4. ファイルの検証
echo "Step 4: Verifying data file..."
if [ ! -f "assets/data/data.json" ]; then
    echo "❌ Error: assets/data/data.json was not generated."
    exit 1
fi

# 5. 現在時刻の取得
current_time=$(date "+%Y/%m/%d-%H:%M:%S")
# 説明文に詳細情報を盛り込む（後でGist一覧を見た時に識別しやすくなります）
description="Gallery Data ($NUM items) for @$USER ($MODE) on ${current_time}-JST"

# 6. Gistの作成（または更新）
echo "Step 5 & 6: Posting to Gist..."
gist_url=$(gh gist create assets/data/data.json -p -d "$description")

if [ $? -eq 0 ]; then
    gist_id=$(basename "$gist_url")
    echo "------------------------------------------"
    echo "✅ Success!"
    echo "Target User: @$USER"
    echo "Mode       : $MODE"
    echo "Items      : $NUM"
    echo "Gist ID    : $gist_id"
    echo "------------------------------------------"
else
    echo "❌ Error: Failed to post Gist."
    exit 1
fi