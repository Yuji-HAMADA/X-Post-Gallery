# GEMINI.md

This file provides project-level instructions, conventions, and guidelines for Gemini CLI.

## Project Overview

PostViewer (package name: `x_post_gallery`) は、X（旧Twitter）からスクレイピングしたメディアをGitHub Gist経由で同期・表示するFlutter製ギャラリーアプリ、およびローカル常駐クローラーパイプラインです。

## Core Mandates & Rules

### 1. 【トークン節約の方針】（最優先）
- **出力の最小化:** 挨拶、前置き、後置き、過剰な解説・お世辞は一切排除し、要点・差分・実行コマンドのみを極力簡潔に出力すること。
- **思考・検証プロセスの重視:** トークン節約のためであれば、処理やコード生成に時間がかかることは許容される。試行錯誤による手戻りターンを減らし、最小限のツール呼び出しと的確なコンテキスト操作で確実に完遂すること。
- **コンテキスト効率:** ファイル全体を不用意に読み込まず、`grep_search` や行番号範囲指定の `read_file` を活用してトークン消費を抑制すること。

### 2. 【ハードコード原則禁止のルール】
- **原則禁止:** マジックナンバーや設定値・URLなどのハードコードは原則禁止とする。ただし、ハードコードした方がコード全体が直感的かつシンプルになり、可読性・保守性が向上する場合に限り、例外的に許容する。
- **【厳禁事項】固有情報・機密情報のハードコード絶対禁止:**
  - X（旧Twitter）のアカウント名/スクリーンネーム、Gist ID、アクセストークン等の固有情報・機密情報を、**GitHub等に露出する形でコード内に絶対にハードコードしてはならない**。
  - 必ず `.env` ファイル、環境変数（`resolveEnv` / `--dart-define`）、または動的設定ファイルから安全に取得・注入すること。

### 3. 【Python実行環境（venv利用必須）】
- **仮想環境の利用:** Pythonスクリプトやテストの実行時は、Playwright等の依存ライブラリが整備されているプロジェクト直下の仮想環境（`./venv/bin/python`）を必ず使用すること。グローバルの `python3` を直接実行してはならない。

## Common Commands & Workflows

### Flutter App (`lib/`)
```bash
flutter run                      # デフォルトデバイスで実行
flutter analyze                  # Dart静的解析 (flutter_lints)
flutter test                     # 単体テスト・ウィジェットテスト実行
# pub upgrade や依存更新後は必ず analyze と test を通して健全性を確認すること
```

### Scraping & Crawler Pipeline (`scripts/`)
```bash
# Python 単体抽出 (data/auth.json のクッキーが必要、必ず venv の python を使用)
./venv/bin/python scripts/extract_media.py -u <username> -n 100

# Gist へのアペンド実行
./append_gist.sh -g <master_gist_id> -u <username> -n 100 -s

# ローカル常駐マスターループ (お気に入り巡回とキュー巡回を交互実行)
./scripts/run_master_local.sh

# スケジュール巡回単体実行 (アダプティブ・スキップ対応)
./scripts/run_scheduled_fetch_local.sh

# テスト実行
./venv/bin/python -m unittest discover tests
bash tests/test_crawler_adaptive_skip.sh
bash tests/test_crawler_delete_defense.sh
```

## Architecture

### Flutter App (`lib/`)
- **`main.dart`**: エントリポイント。`.env` のロード、ダークテーマ設定、Provider の初期化。
- **`viewmodels/gallery_viewmodel.dart`**: アプリ状態管理（`ChangeNotifier`）。ギャラリーのロード、ユーザー削除、優先度更新（ピン留め）、キュー追加等を統括。
- **`services/gallery_repository.dart`**: Gist データの取得・パース、キャッシュ管理、SharedPreferences によるローカル永続化。
- **`services/github_service.dart`**: GitHub API クライアント。Gist ファイル更新、キュー（2スロットリングバッファ）操作。
- **`screens/gallery/`**: メインギャラリー画面（お気に入り・ユーザー一覧、スワイプビュー）。
- **`screens/detail/`**: フルスクリーン画像ビューア（拡大・縮小、パン操作）。
- **`models/tweet_item.dart`**, **`models/user_gist_entry.dart`**: データモデル。

### Local Crawler Pipeline (`scripts/`)
- **`run_master_local.sh`**: 常駐マスターループ。
- **`run_scheduled_fetch_local.sh`**: 2スロットリングバッファ対応の巡回クローラー（アダプティブ・スキップバックオフ機能付き）。
- **`run_fetch_favorites_local.sh`**: お気に入り巡回スクリプト。
- **`append_to_gist.py` / `append_gist.sh`**: 抽出したツイートを子GistおよびマスターGistへアペンド（重複除外、スリム化、上書き競合・削除防御付き）。
- **`extract_media.py`**: Playwright による X メディア抽出。
- **`adaptive_skip.py`**: 更新がないアカウントの巡回頻度を段階的に抑制するアダプティブ・スキップ管理。

## Key Conventions & Standards
- コメントおよびUI文字列は日本語を使用する。
- Gist の正準ファイル名は `data.json`（後方互換用 `gallary_data.json` も考慮）。
- GitHub トークンは `.env`（開発時）または `--dart-define=GITHUB_TOKEN`（Webビルド時）から供給。
- ユーザー削除処理では、子Gist、マスターGist、キューGist（`fetch_queue.json`）、お気に入りリストから漏れなく完全に除外すること。
