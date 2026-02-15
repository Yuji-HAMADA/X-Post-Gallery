# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PostViewer (package name: `x_post_gallery`) is a Flutter gallery app that displays media scraped from X (Twitter). The data pipeline works as follows: Playwright scrapes X posts → Python converts to JSON → uploaded to GitHub Gist → Flutter app fetches and displays images in a grid.

## Common Commands

```bash
# Flutter
flutter run -d chrome          # Run web dev server
flutter build web               # Build for web (deployed to Firebase Hosting)
flutter analyze                  # Run Dart static analysis (uses flutter_lints)
flutter test                     # Run widget tests

# Web build with GitHub token baked in
flutter build web --dart-define=GITHUB_TOKEN=<token>

# Python scraping pipeline (requires data/auth.json with X session cookies)
python3 scripts/extract_media.py -u <username> --mode all -n 100
python3 scripts/update_data.py

# Full pipeline via shell script (requires gh CLI authenticated)
./gh_upload_gist.sh -u <username> -m all -n 100
```

## Architecture

### Flutter App (`lib/`)

- **`main.dart`** — Entry point. Loads `.env` for GitHub token, sets up Material 3 dark theme.
- **`screens/gallery/gallery_page.dart`** — Main view. 3-column image grid. Handles Gist ID input (URL param `?id=` or manual entry), triggers GitHub Actions workflows, polls workflow status.
- **`screens/detail/detail_page.dart`** + `detail_image_item.dart` — Full-screen image viewer with InteractiveViewer zoom/pan and double-tap animation.
- **`services/github_service.dart`** — GitHub API client: triggers workflow dispatch, fetches latest Gist ID by searching for `data.json` (with `gallary_data.json` fallback), checks workflow run status.
- **`services/data_service.dart`** — Fetches gallery JSON from GitHub Gist raw URL using the Gist ID as a key. Tries `data.json` first, falls back to `gallary_data.json` for backward compatibility.
- **`models/tweet_item.dart`** — Data model for tweet display.

State management uses plain `StatefulWidget` + `SharedPreferences` for persistence (Gist ID, scroll position, username). No external state management library.

### Data Pipeline (`scripts/`)

- **`extract_media.py`** — Playwright-based scraper. Loads X session from `data/auth.json`, searches for user's image posts, scrolls and collects tweet data. Outputs `data/tweets.js` in Twitter archive format.
- **`update_data.py`** — Converts `data/tweets.js` → `assets/data/data.json`. Extracts media URLs, detects username, produces `{user_screen_name, tweets[]}` structure.
- **`gh_upload_gist.sh`** — Orchestrates the full pipeline: scrape → convert → upload `data.json` as public Gist via `gh` CLI.

### CI/CD (`.github/workflows/run.yml`)

GitHub Actions workflow triggered via `workflow_dispatch` (called from the Flutter app's UI). Inputs: `target_user`, `mode` (all/post_only), `num_posts`. Requires secrets: `AUTH_JSON` (X session cookies), `GIST_TOKEN`.

## Key Conventions

- Comments and UI strings are in Japanese
- The canonical Gist filename is `data.json`. For backward compatibility, the Flutter app also reads from `gallary_data.json` (legacy misspelling) if `data.json` is not found
- GitHub token is provided either via `.env` file (dev) or `--dart-define=GITHUB_TOKEN` (web build)
- The Gist ID serves as a pseudo-password — knowing the ID grants access to the gallery data
