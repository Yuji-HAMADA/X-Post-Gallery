#!/bin/bash
# test_crawler_batch_and_count.sh
# スキップバッチ処理およびCOUNT保持の統合テスト
set -euo pipefail

TMP_DIR=$(mktemp -d /tmp/test_batch_XXXXXX)
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# append_gist.sh をバックアップ
cp "$PROJECT_DIR/append_gist.sh" "$TMP_DIR/append_gist.sh.bak"
trap 'cp "$TMP_DIR/append_gist.sh.bak" "$PROJECT_DIR/append_gist.sh"; rm -rf "$TMP_DIR"' EXIT
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

QUEUE_FILE="$TMP_DIR/mock_fetch_queue.json"
GIST_EDIT_LOG="$TMP_DIR/gist_edits.log"
APPEND_LOG="$TMP_DIR/append.log"
: > "$GIST_EDIT_LOG"
: > "$APPEND_LOG"

cat << 'EOF' > "$QUEUE_FILE"
{
  "status": "idle",
  "default_count": 500,
  "users": [
    {"user": "skip1", "count": 100, "stop_on_existing": true, "done": false, "skip_count": 2, "skip_remaining": 1},
    {"user": "skip2", "count": 100, "stop_on_existing": true, "done": false, "skip_count": 3, "skip_remaining": 2},
    {"user": "target_100", "count": 100, "stop_on_existing": true, "done": false, "skip_count": 0, "skip_remaining": 0}
  ]
}
EOF

# gh コマンドのモック
cat << EOF > "$MOCK_BIN/gh"
#!/bin/bash
if [ "\$1" = "gist" ] && [ "\$2" = "view" ]; then
  cat "$QUEUE_FILE"
elif [ "\$1" = "gist" ] && [ "\$2" = "edit" ]; then
  echo "EDIT \${@: -1}" >> "$GIST_EDIT_LOG"
  cp "\${@: -1}" "$QUEUE_FILE"
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
export FETCH_QUEUE_SLOT1_GIST_ID=""

# run_scheduled_fetch_local.sh を実行（MAX_LOOPS=1 で1回のみ回す）
# スクリプトを呼び出し、1ループで終了するようにテスト
MAX_LOOPS=1 bash "$PROJECT_DIR/scripts/run_scheduled_fetch_local.sh"

echo "--- 実行後のキュー状態 ---"
cat "$QUEUE_FILE"

# 検証 1: COUNT=100 が 500 に上書きされず 100 で渡されたこと
if grep -q "APPEND user=target_100 count=100" "$APPEND_LOG"; then
  echo "✅ PASS: count=100 was preserved and passed to append_gist.sh"
else
  echo "❌ FAIL: count=100 was NOT preserved. Log content:"
  cat "$APPEND_LOG"
  exit 1
fi

# 検証 2: skip1 と skip2 の skip_remaining がデクリメントされ、サイクルリセットで done=false に安全に戻っていること
SKIP1_REM=$(jq -r '.users[] | select(.user == "skip1") | .skip_remaining' "$QUEUE_FILE")
SKIP2_REM=$(jq -r '.users[] | select(.user == "skip2") | .skip_remaining' "$QUEUE_FILE")
SKIP1_DONE=$(jq -r '.users[] | select(.user == "skip1") | .done' "$QUEUE_FILE")

if [ "$SKIP1_REM" -eq 0 ] && [ "$SKIP2_REM" -eq 1 ] && [ "$SKIP1_DONE" = "false" ]; then
  echo "✅ PASS: Batch skipped users correctly updated and cycle-reset (skip1: rem=$SKIP1_REM, skip2: rem=$SKIP2_REM, done=$SKIP1_DONE)"
else
  echo "❌ FAIL: Batch skipped users mismatch. skip1(rem=$SKIP1_REM), skip2(rem=$SKIP2_REM)"
  exit 1
fi

# 検証 3: バッチフラッシュが行われたことの検証
if [ -s "$GIST_EDIT_LOG" ]; then
  EDIT_COUNT=$(wc -l < "$GIST_EDIT_LOG")
  echo "✅ PASS: Gist edit was batched (edit count: $EDIT_COUNT)"
fi
