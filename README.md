# PostViewer (x_post_gallery)

A synchronized media gallery application built with Flutter, backed by GitHub Gist, paired with an automated scraping and background crawler pipeline.

---

## English

### Overview
PostViewer is a client-serverless media gallery application. It uses GitHub Gist as a lightweight, synchronized cloud backend to display image and video media collected from social platforms. The project consists of a modern Flutter frontend and a robust Python-based crawling pipeline.

### Required Setup Files
Before launching the application or running the crawler scripts, you must manually prepare the following configuration files:

1. **`.env`** (Project Root)
   Environment variables required for GitHub API access and Gist synchronization:
   - `GITHUB_TOKEN`: GitHub Personal Access Token with `gist` and `repo` permissions.
   - `GITHUB_USERNAME`: Your GitHub username.
   - `MASTER_GIST_ID`: Gist ID storing the master index of accounts and media items.
   - `FAVORITE_GIST_ID`: Gist ID storing the list of favorite accounts.
   - `FETCH_QUEUE_GIST_ID`: Gist ID used as a ring buffer for scheduled crawler jobs.

2. **`data/auth.json`**
   Playwright browser authentication session file (JSON) containing valid login cookies and local storage tokens.
   - Structure follows standard Playwright `storage_state`:
     ```json
     {
       "cookies": [
         {
           "name": "example_token",
           "value": "example_value",
           "domain": ".x.com",
           "path": "/"
         }
       ],
       "origins": []
     }
     ```

### Project Directory Structure
```
├── lib/          # Flutter application source code (UI, ViewModels, Services, L10n)
│   ├── l10n/     # Multi-language localization classes (system language auto-following)
│   ├── models/   # Data models (TweetItem, UserGistEntry)
│   ├── screens/  # Gallery, swipe viewer, and post detail screens
│   ├── services/ # GitHub API client and Gist repository services
│   └── viewmodels/ # Application state management (ChangeNotifier)
├── scripts/      # Python crawler & shell scripts (extraction, Gist sync, scheduled tasks)
├── test/         # Flutter unit and widget tests
├── tests/        # Python crawler and pipeline verification tests
├── data/         # Local session files and crawler state storage (git-ignored)
└── assets/       # Application icons and static assets
```

### Core Features & Usage
- **Synchronized Cloud Gallery**: Media metadata and image/video links are stored in GitHub Gists, enabling cross-device access without managing traditional database servers.
- **Dual-Mode Detail Viewer**:
  - **Default Layout**: Vertical image stack, inline text, interactive zoom, and video playback controls.
  - **Continuous Horizontal Viewer**: Full-screen, white-background, left-aligned continuous scroll without text or indicators. Supports vertical swipe gestures to navigate across posts and synchronizes back to the default layout upon exit.
- **Account Management & Pinning**: Toggle pin favorite accounts to the top of the gallery, organize by reverse registration order, or search users.
- **System Language Auto-Detection**: Automatically adapts UI strings and tooltips to the device system language (English and Japanese supported).
- **Automated Crawler Pipeline**: Background fetching with adaptive skip backoff to preserve bandwidth and GitHub API rate limits.

---

## 日本語 (Japanese)

### 概要
PostViewer は、GitHub Gist を同期バックエンドとして活用する Flutter 製メディアギャラリーアプリ、および自動クローラーパイプラインです。

### 必要なセットアップファイル
本プロジェクトを実行する前に、以下の設定ファイルを手動で準備する必要があります（機密情報保護のため Git 管理外となっています）：

1. **`.env`**（プロジェクトルート）
   GitHub API 連携および Gist 同期に必要な環境変数：
   - `GITHUB_TOKEN`: `gist` および `repo` 権限を持つ GitHub Personal Access Token
   - `GITHUB_USERNAME`: GitHub のユーザー名
   - `MASTER_GIST_ID`: 全体インデックスを保持するマスター Gist の ID
   - `FAVORITE_GIST_ID`: お気に入りアカウント一覧を保持する Gist の ID
   - `FETCH_QUEUE_GIST_ID`: 巡回対象キューを保持する Gist の ID（リングバッファ用）

2. **`data/auth.json`**
   Playwright 用のブラウザ認証セッションストレージファイル（有効なログイン Cookie およびローカルストレージを含む JSON）：
   - Playwright の `storage_state` 形式に準拠：
     ```json
     {
       "cookies": [
         {
           "name": "example_token",
           "value": "example_value",
           "domain": ".x.com",
           "path": "/"
         }
       ],
       "origins": []
     }
     ```

### ディレクトリ構成
```
├── lib/          # Flutter アプリケーションのソースコード (UI、ViewModel、リポジトリ、多言語化)
│   ├── l10n/     # システム言語自動追従対応の多言語化クラス
│   ├── models/   # データモデル (TweetItem、UserGistEntry)
│   ├── screens/  # ギャラリー、スワイプ画面、ポスト詳細画面
│   ├── services/ # GitHub API クライアントおよび Gist リポジトリ
│   └── viewmodels/ # アプリ状態管理 (ChangeNotifier)
├── scripts/      # Python クローラーおよび自動巡回シェルスクリプト群
├── test/         # Flutter 単体・ウィジェットテスト
├── tests/        # Python クローラー・パイプライン検証テスト
├── data/         # 認証セッションおよび巡回ステート保持ディレクトリ (.gitignore 対象)
└── assets/       # アプリアイコン等の静的リソース
```

### 主な機能と使い方
- **Gist 経由のクラウド同期ギャラリー**: メディアのメタデータや画像・動画リンクを GitHub Gist 上で分散管理し、専用サーバ不要で複数端末から同期閲覧が可能。
- **2種類の詳細ビューア**:
  - **デフォルトレイアウト**: 縦並び画像、ポスト本文表示、インタラクティブ拡大縮小、動画再生コントロール。
  - **横方向連続ビューア**: 白背景・全画面・テキスト非表示・左寄せの連続自由スクロール。上下スワイプ操作で前後のポストへシームレスに切り替わり、戻る操作で該当ポストのデフォルト表示へ同期復帰。
- **アカウント管理 & ピン留め**: お気に入り登録、最上位へのピン留め固定および解除（トグル機能）、登録順逆順（LIFO）ソート。
- **システム言語自動追従**: デバイスの言語設定に合わせて UI 表示が日本語と英語に自動で切り替わる多言語対応。
- **自動巡回パイプライン**: 更新頻度に応じたアダプティブ・スキップ機能を備え、API制限や帯域を保護しながら最新メディアを自動収集。
