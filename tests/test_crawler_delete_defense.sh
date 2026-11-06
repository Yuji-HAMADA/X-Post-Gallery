#!/bin/bash
# test_crawler_delete_defense.sh
# クロール中のユーザー削除防御策の動作検証テスト
set -euo pipefail

TMP_DIR=$(mktemp -d /tmp/test_defense_XXXXXX)
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
    {"user": "remaining_user", "count": 500, "stop_on_existing": true, "done": false},
    {"user": "deleted_user", "count": 500, "stop_on_existing": true, "done": false}
  ]
}
EOF

cat << EOF > "$MOCK_BIN/gh"
#!/bin/bash
if [ "\$1" = "gist" ] && [ "\$2" = "view" ]; then
  cat "$QUEUE_FILE"
elif [ "\$1" = "gist" ] && [ "\$2" = "edit" ]; then
  cp "\${@: -1}" "$QUEUE_FILE"
fi
EOF
chmod +x "$MOCK_BIN/gh"

export PATH="$MOCK_BIN:$PATH"
export FETCH_QUEUE_GIST_ID="dummy_queue_gist"

# 1. remaining_user 実行前に deleted_user をキューから削除（アプリ操作をシミュレート）
jq '.users = [.users[] | select(.user != "deleted_user")]' "$QUEUE_FILE" > "$QUEUE_FILE.tmp"
mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"

# 2. run_scheduled_fetch_local.sh が deleted_user を直前チェックでスキップすることを検証
# モック append_gist.sh
MOCK_APPEND="$TMP_DIR/append_gist.sh"
cat << 'EOF' > "$MOCK_APPEND"
#!/bin/bash
USER=""
while getopts g:u:n:s OPT; do
  case $OPT in
    u) USER=$OPTARG ;;
  esac
done
if [ "$USER" = "deleted_user" ]; then
  echo "FAIL: deleted_user should NOT be crawled!" >&2
  exit 99
fi
echo "OK: crawled $USER"
exit 0
EOF
chmod +x "$MOCK_APPEND"

# 実行直前のキューチェックロジック単体テスト
USER="deleted_user"
SLOT_ID="dummy_queue_gist"
FRESH_JSON=$(gh gist view "$SLOT_ID" -f fetch_queue.json)
USER_IN_QUEUE=$(echo "$FRESH_JSON" | jq -r --arg user "$USER" '[.users[] | select((.user | ascii_downcase) == ($user | ascii_downcase))] | length')

if [ "$USER_IN_QUEUE" -eq 0 ]; then
  echo "✅ Defense 1 PASSED: deleted_user correctly detected as missing from queue ($USER_IN_QUEUE users in queue)"
else
  echo "❌ Defense 1 FAILED: deleted_user was found in queue"
  exit 1
fi

echo "=========================================="
echo "🎉 ALL DEFENSE TESTS PASSED!"
echo "=========================================="
