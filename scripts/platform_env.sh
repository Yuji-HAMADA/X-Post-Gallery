#!/bin/bash
# ==============================================================================
# platform_env.sh
# X / Instagram 共通化用：.env 読み込みと PLATFORM=(x|instagram) の環境変数解決を行うヘルパー
# ==============================================================================

# .env の読み込み（既存の環境変数は上書きしない）
load_project_env() {
  local project_dir="$1"
  if [ -f "$project_dir/.env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [[ "$line" =~ ^# ]] && continue
      [[ "$line" != *"="* ]] && continue
      local key="${line%%=*}"
      local val="${line#*=}"
      key=$(echo "$key" | tr -d '[:space:]')
      val=$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
      if [ -n "$key" ] && [ -z "${!key+x}" ]; then
        export "$key=$val"
      fi
    done < "$project_dir/.env"
  fi
}

# PLATFORM 環境変数を正規化し、Instagram 指定時は専用 Gist ID・パスへ切り替える
resolve_platform_env() {
  local project_dir="$1"
  PLATFORM="${PLATFORM:-x}"
  PLATFORM=$(echo "$PLATFORM" | tr '[:upper:]' '[:lower:]')
  export PLATFORM

  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

  if [ "$PLATFORM" = "instagram" ]; then
    export MASTER_GIST_ID="${IG_MASTER_GIST_ID:-}"
    export FETCH_QUEUE_GIST_ID="${IG_FETCH_QUEUE_GIST_ID:-}"
    export FETCH_QUEUE_SLOT1_GIST_ID="${IG_FETCH_QUEUE_SLOT1_GIST_ID:-}"
    export FAVORITE_GIST_ID="${IG_FAVORITE_GIST_ID:-}"
    export PLATFORM_AUTH_PATH="$project_dir/data/instagram_auth.json"
    export PLATFORM_AUTH_ENV="${IG_AUTH_JSON:-}"
    export PLATFORM_RESULT_FILE="$project_dir/data/.last_fetch_result_instagram.json"
    export PLATFORM_ADAPTIVE_STATE="$project_dir/data/instagram_adaptive_skip_state.json"
    export PLATFORM_LOCK_SUFFIX="_instagram"
    export PLATFORM_LABEL="Instagram"
  elif [ "$PLATFORM" = "tiktok" ]; then
    export MASTER_GIST_ID="${TIKTOK_MASTER_GIST_ID:-}"
    export FETCH_QUEUE_GIST_ID="${TIKTOK_FETCH_QUEUE_GIST_ID:-}"
    export FETCH_QUEUE_SLOT1_GIST_ID="${TIKTOK_FETCH_QUEUE_SLOT1_GIST_ID:-}"
    export FAVORITE_GIST_ID="${TIKTOK_FAVORITE_GIST_ID:-}"
    export PLATFORM_AUTH_PATH="$project_dir/data/tiktok_auth.json"
    export PLATFORM_AUTH_ENV="${TIKTOK_AUTH_JSON:-}"
    export PLATFORM_RESULT_FILE="$project_dir/data/.last_fetch_result_tiktok.json"
    export PLATFORM_ADAPTIVE_STATE="$project_dir/data/tiktok_adaptive_skip_state.json"
    export PLATFORM_LOCK_SUFFIX="_tiktok"
    export PLATFORM_LABEL="TikTok"
  else
    export PLATFORM="x"
    export PLATFORM_AUTH_PATH="$project_dir/data/auth.json"
    export PLATFORM_AUTH_ENV="${AUTH_JSON:-}"
    export PLATFORM_RESULT_FILE="$project_dir/data/.last_fetch_result.json"
    export PLATFORM_ADAPTIVE_STATE="$project_dir/data/adaptive_skip_state.json"
    export PLATFORM_LOCK_SUFFIX=""
    export PLATFORM_LABEL="X"
  fi
}
