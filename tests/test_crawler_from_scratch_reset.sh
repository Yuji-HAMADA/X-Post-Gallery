#!/bin/bash
# test_crawler_from_scratch_reset.sh
# from_scratch=true の処理完了後に from_scratch=false にリセットされることを検証するテスト
set -euo pipefail

TMP_DIR=$(mktemp -d /tmp/test_fs_XXXXXX)
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
    {"user": "scratch_user", "count": 300, "stop_on_existing": false, "from_scratch": true, "done": false, "skip_count": 0, "skip_remaining": 0}
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
echo "CALLED append_gist.sh: \$@" >> "$APPEND_LOG"
mkdir -p "$PROJECT_DIR/data"
echo '{"user": "scratch_user", "tweets_saved": 5, "status": "ok"}' > "$PROJECT_DIR/data/.last_fetch_result.json"
exit 0
EOF
chmod +x "$PROJECT_DIR/append_gist.sh"

export PATH="$MOCK_BIN:$PATH"
export GH_TOKEN="dummy_token"
export FETCH_QUEUE_GIST_ID="dummy_slot0"

# run_scheduled_fetch_local.sh を実行（MAX_LOOPS=1）
MAX_LOOPS=1 bash "$PROJECT_DIR/scripts/run_scheduled_fetch_local.sh"

echo "--- 実行後のキュー状態 ---"
cat "$QUEUE_FILE"

# 検証 1: append_gist.sh が --from-scratch 付きで呼び出されたこと
if grep -q "\--from-scratch" "$APPEND_LOG"; then
  echo "✅ PASS: append_gist.sh was called with --from-scratch"
else
  echo "❌ FAIL: append_gist.sh was not called with --from-scratch. Log:"
  cat "$APPEND_LOG"
  exit 1
fi

# 検証 2: 処理後に from_scratch が false になっていること
FS_VAL=$(jq -r '.users[] | select(.user == "scratch_user") | .from_scratch' "$QUEUE_FILE")
if [ "$FS_VAL" = "false" ]; then
  echo "✅ PASS: from_scratch was reset to false after crawling"
else
  echo "❌ FAIL: from_scratch is '$FS_VAL', expected 'false'"
  exit 1
fi

echo "🎉 All from_scratch reset integration tests passed!"
