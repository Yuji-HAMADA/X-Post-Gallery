#!/bin/bash
# test_crawler_adaptive_skip.sh
# ローカルクローラーのアダプティブ・スキップ動作検証スクリプト
set -euo pipefail

TMP_DIR=$(mktemp -d /tmp/test_crawler_XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# モック用 gh コマンドを作成
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

QUEUE_FILE="$TMP_DIR/mock_fetch_queue.json"
cat << 'EOF' > "$QUEUE_FILE"
{
  "status": "idle",
  "default_count": 500,
  "users": [
    {"user": "zero_user", "count": 500, "stop_on_existing": true, "done": false, "skip_count": 0, "skip_remaining": 0},
    {"user": "skip_user", "count": 500, "stop_on_existing": true, "done": false, "skip_count": 2, "skip_remaining": 1},
    {"user": "active_user", "count": 500, "stop_on_existing": true, "done": false, "skip_count": 3, "skip_remaining": 0}
  ]
}
EOF

# gh モック
cat << EOF > "$MOCK_BIN/gh"
#!/bin/bash
if [ "\$1" = "gist" ] && [ "\$2" = "view" ]; then
  cat "$QUEUE_FILE"
elif [ "\$1" = "gist" ] && [ "\$2" = "edit" ]; then
  # 引数末尾のファイルをQUEUE_FILEにコピー
  cp "\${@: -1}" "$QUEUE_FILE"
fi
EOF
chmod +x "$MOCK_BIN/gh"

# append_gist.sh モック
MOCK_APPEND="$TMP_DIR/append_gist.sh"
cat << EOF > "$MOCK_APPEND"
#!/bin/bash
USER=""
while getopts g:u:n:s OPT; do
  case \$OPT in
    u) USER=\$OPTARG ;;
  esac
done

mkdir -p "$PROJECT_DIR/data"
RESULT_FILE="$PROJECT_DIR/data/.last_fetch_result.json"

if [ "\$USER" = "zero_user" ]; then
  echo '{"user": "zero_user", "tweets_saved": 0, "status": "empty"}' > "\$RESULT_FILE"
  echo "✅ Done: 0 tweets saved (empty timeline)."
elif [ "\$USER" = "active_user" ]; then
  echo '{"user": "active_user", "tweets_saved": 5, "status": "ok"}' > "\$RESULT_FILE"
  echo "✅ Done: 5 tweets saved."
fi
exit 0
EOF
chmod +x "$MOCK_APPEND"

export PATH="$MOCK_BIN:$PATH"
export GH_TOKEN="dummy_token"
export FETCH_QUEUE_GIST_ID="dummy_gist"
export TIMEOUT_SECONDS=60

echo "--- テスト前のキュー状態 ---"
jq '.users[] | {user, done, skip_count, skip_remaining}' "$QUEUE_FILE"

# 1. skip_user に対するスキップ判定のテスト
SKIP_CHECK=$(python3 "$PROJECT_DIR/scripts/adaptive_skip.py" should-skip -u "skip_user" --queue-remaining 1 --queue-count 2)
IS_SKIP=$?
if [ $IS_SKIP -ne 0 ]; then
  echo "❌ Error: skip_user should be skipped"
  exit 1
fi
echo "✅ skip_user correctly identified as skip target: $SKIP_CHECK"

# 2. zero_user のクロール結果記録テスト (0件)
RECORD_ZERO=$(python3 "$PROJECT_DIR/scripts/adaptive_skip.py" record -u "zero_user" -s 0 --queue-count 0)
SC_ZERO=$(echo "$RECORD_ZERO" | jq -r '.skip_count')
SR_ZERO=$(echo "$RECORD_ZERO" | jq -r '.skip_remaining')
if [ "$SC_ZERO" -ne 1 ] || [ "$SR_ZERO" -ne 1 ]; then
  echo "❌ Error: zero_user should have skip_count=1, skip_remaining=1. Got sc=$SC_ZERO, sr=$SR_ZERO"
  exit 1
fi
echo "✅ zero_user correctly backed off to level 1: $RECORD_ZERO"

# 3. active_user のクロール結果記録テスト (>0件)
RECORD_ACTIVE=$(python3 "$PROJECT_DIR/scripts/adaptive_skip.py" record -u "active_user" -s 5 --queue-count 3)
SC_ACTIVE=$(echo "$RECORD_ACTIVE" | jq -r '.skip_count')
SR_ACTIVE=$(echo "$RECORD_ACTIVE" | jq -r '.skip_remaining')
if [ "$SC_ACTIVE" -ne 0 ] || [ "$SR_ACTIVE" -ne 0 ]; then
  echo "❌ Error: active_user should have skip_count=0, skip_remaining=0. Got sc=$SC_ACTIVE, sr=$SR_ACTIVE"
  exit 1
fi
echo "✅ active_user correctly reset to 0: $RECORD_ACTIVE"

# 4. 全件 done 後のサイクルリセットテスト
cat << 'EOF' > "$QUEUE_FILE"
{
  "status": "idle",
  "users": [
    {"user": "u1", "done": true, "skip_count": 2, "skip_remaining": 1},
    {"user": "u2", "done": true, "skip_count": 0, "skip_remaining": 0}
  ]
}
EOF

python3 "$PROJECT_DIR/scripts/adaptive_skip.py" reset-cycle --json-file "$QUEUE_FILE"
RESET_DONE_COUNT=$(jq '[.users[] | select(.done == true)] | length' "$QUEUE_FILE")
RESET_SC_U1=$(jq -r '.users[] | select(.user == "u1") | .skip_count' "$QUEUE_FILE")
RESET_SR_U1=$(jq -r '.users[] | select(.user == "u1") | .skip_remaining' "$QUEUE_FILE")

if [ "$RESET_DONE_COUNT" -ne 0 ]; then
  echo "❌ Error: done count should be 0 after reset"
  exit 1
fi
if [ "$RESET_SC_U1" -ne 2 ] || [ "$RESET_SR_U1" -ne 1 ]; then
  echo "❌ Error: u1 skip_count/remaining not preserved after reset"
  exit 1
fi
echo "✅ Cycle reset successfully preserved skip_count=2, skip_remaining=1 while setting done=false!"

echo "=========================================="
echo "🎉 ALL INTEGRATION TESTS PASSED!"
echo "=========================================="
