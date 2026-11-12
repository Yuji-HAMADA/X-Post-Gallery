#!/bin/bash
# test_crawler_slot1_consume.sh
# Slot 1（手動キュー）の処理完了時のキュー削除（消化）およびバックオフバイパスの検証テスト
set -euo pipefail

TMP_DIR=$(mktemp -d /tmp/test_slot1_XXXXXX)
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# append_gist.sh をバックアップ
cp "$PROJECT_DIR/append_gist.sh" "$TMP_DIR/append_gist.sh.bak"
trap 'cp "$TMP_DIR/append_gist.sh.bak" "$PROJECT_DIR/append_gist.sh"; rm -rf "$TMP_DIR"' EXIT
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

SLOT0_FILE="$TMP_DIR/mock_slot0.json"
SLOT1_FILE="$TMP_DIR/mock_slot1.json"
APPEND_LOG="$TMP_DIR/append.log"
: > "$APPEND_LOG"

# Slot 0（お気に入り定期巡回リスト）
cat << 'EOF' > "$SLOT0_FILE"
{
  "status": "idle",
  "default_count": 500,
  "sibling_gist_id": "dummy_slot1",
  "users": [
    {"user": "fav_user1", "done": false, "skip_count": 5, "skip_remaining": 5}
  ]
}
EOF

# Slot 1（手動取得リクエスト枠）: お気に入りユーザー fav_user1 がリクエストされている
cat << 'EOF' > "$SLOT1_FILE"
{
  "status": "idle",
  "default_count": 500,
  "users": [
    {"user": "fav_user1", "count": 200, "stop_on_existing": true, "done": false, "skip_count": 5, "skip_remaining": 5}
  ]
}
EOF

# gh コマンドのモック（Gist IDに応じて Slot 0 と Slot 1 を振り分け）
cat << EOF > "$MOCK_BIN/gh"
#!/bin/bash
if [ "\$1" = "gist" ] && [ "\$2" = "view" ]; then
  GIST_ID="\$3"
  if [ "\$GIST_ID" = "dummy_slot0" ]; then
    cat "$SLOT0_FILE"
  else
    cat "$SLOT1_FILE"
  fi
elif [ "\$1" = "gist" ] && [ "\$2" = "edit" ]; then
  GIST_ID="\$3"
  if [ "\$GIST_ID" = "dummy_slot0" ]; then
    cp "\${@: -1}" "$SLOT0_FILE"
  else
    cp "\${@: -1}" "$SLOT1_FILE"
  fi
fi
EOF
chmod +x "$MOCK_BIN/gh"

# append_gist.sh のモック
cat << EOF > "$PROJECT_DIR/append_gist.sh"
#!/bin/bash
USER=""
COUNT=""
while getopts g:u:n:s OPT; do
  case \$OPT in
    u) USER=\$OPTARG ;;
    n) COUNT=\$OPTARG ;;
  esac
done

echo "APPEND user=\$USER count=\$COUNT" >> "$APPEND_LOG"
mkdir -p "$PROJECT_DIR/data"
echo "{\"user\": \"\$USER\", \"tweets_saved\": 1, \"status\": \"ok\"}" > "$PROJECT_DIR/data/.last_fetch_result.json"
exit 0
EOF
chmod +x "$PROJECT_DIR/append_gist.sh"

export PATH="$MOCK_BIN:$PATH"
export GH_TOKEN="dummy_token"
export FETCH_QUEUE_GIST_ID="dummy_slot0"
export FETCH_QUEUE_SLOT1_GIST_ID="dummy_slot1"

# Slot 1 のみ実行（run_master_local.sh の Step 1 と同等）
bash "$PROJECT_DIR/scripts/run_scheduled_fetch_local.sh" --slot 1

echo "--- 実行後の Slot 1 キュー状態 ---"
cat "$SLOT1_FILE"

# 検証 1: skip_remaining=5 にもかかわらず、Slot 1 ではスキップされずクロールが実行されたこと
if grep -q "APPEND user=fav_user1 count=200" "$APPEND_LOG"; then
  echo "✅ PASS: fav_user1 was not skipped by adaptive_skip and was crawled with count=200"
else
  echo "❌ FAIL: fav_user1 was unexpectedly skipped or crawled with wrong args. Log:"
  cat "$APPEND_LOG"
  exit 1
fi

# 検証 2: 処理完了後に Slot 1 の users から fav_user1 が完全に削除（消化）されていること
REMAINING_USERS=$(jq '.users | length' "$SLOT1_FILE")
if [ "$REMAINING_USERS" -eq 0 ]; then
  echo "✅ PASS: Slot 1 queue consumed and emptied (length=0)"
else
  echo "❌ FAIL: Slot 1 queue still contains users: $REMAINING_USERS"
  cat "$SLOT1_FILE"
  exit 1
fi

echo "=========================================="
echo "🎉 ALL SLOT 1 CONSUME TESTS PASSED!"
echo "=========================================="
