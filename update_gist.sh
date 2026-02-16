#!/bin/bash

# --- デフォルト値の設定 ---
NUM=18
USER=""
GIST_ID=""

# --- 引数の解析 (u: ユーザ, g: Gist ID, n: 件数) ---
while getopts u:g:n: OPT; do
  case $OPT in
    u) USER=$OPTARG ;;
    g) GIST_ID=$OPTARG ;;
    n) NUM=$OPTARG ;;
    *) echo "Usage: $0 -u user_id -g gist_id [-n num]"
       exit 1 ;;
  esac
done

# 必須引数のチェック
if [ -z "$USER" ] || [ -z "$GIST_ID" ]; then
    echo "❌ Error: User ID (-u) and Gist ID (-g) are required."
    echo "Usage: $0 -u user_id -g gist_id [-n num]"
    exit 1
fi

# 1. 必要なディレクトリの強制作成
mkdir -p assets/data data

# 2. X（Twitter）からの抽出
echo "Step 2: Extracting $NUM posts from @$USER..."
python3 scripts/extract_media.py -u "$USER" --mode post_only -n "$NUM"
if [ $? -ne 0 ]; then
    echo "❌ Error: Extraction failed."
    exit 1
fi

# 3. Flutter用データへの変換
echo "Step 3: Updating data format..."
python3 scripts/update_data.py
if [ $? -ne 0 ]; then
    echo "❌ Error: Data formatting failed."
    exit 1
fi

# 4. 既存データとのマージ
echo "Step 4: Merging with existing Gist data ($GIST_ID)..."
python3 scripts/merge_gist_data.py --gist-id "$GIST_ID" --local-file "assets/data/data.json"
if [ $? -ne 0 ]; then
    echo "❌ Error: Merge failed."
    exit 1
fi

# 5. Gistの更新
echo "Step 5: Updating Gist..."
gh gist edit "$GIST_ID" assets/data/data.json

if [ $? -eq 0 ]; then
    echo "------------------------------------------"
    echo "✅ Success! Gist Updated."
    echo "User       : @$USER"
    echo "Gist ID    : $GIST_ID"
    echo "------------------------------------------"
else
    echo "❌ Error: Failed to update Gist."
    exit 1
fi
