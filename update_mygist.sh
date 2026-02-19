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

# 1. 必要なディレクトリの強制作成
mkdir -p assets/data scripts

# 2. X（Twitter）からの抽出 (For You)
echo "Step 2: Extracting $NUM items from 'For You' timeline..."
python3 scripts/extract_foryou.py -n "$NUM" --gist-id "$GIST_ID"
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

# 5. Gist更新は merge_gist_data.py 内で実行済み
echo "------------------------------------------"
echo "✅ Success! Pipeline completed."
echo "Gist ID    : $GIST_ID"
echo "------------------------------------------"