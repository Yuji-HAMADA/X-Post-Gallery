# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PostViewer (package name: `x_post_gallery`) is a Flutter gallery app that displays media scraped from X (Twitter). The data pipeline works as follows: Playwright scrapes X posts → Python converts to JSON → uploaded to GitHub Gist → Flutter app fetches and displays images in a grid.

## Common Commands

```bash
# Flutter
flutter run                      # Run on default device
flutter analyze                  # Run Dart static analysis (uses flutter_lints)
flutter test                     # Run widget tests
```bash
# Python scraping pipeline (requires data/auth.json with X session cookies)
python3 scripts/extract_media.py -u <username> -n 100
```
# Append via shell script (requires gh CLI authenticated)
./append_gist.sh -g <master_gist_id> -u <username> -n 100 -s
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
- **`append_to_gist.py`** — Appends scraped tweets to child Gists and updates the master Gist. Called via `append_gist.sh`.

### Local Crawler Pipeline (`scripts/`)

- **`run_master_local.sh`** — Master controller script alternating between `run_fetch_favorites_local.sh` and `run_scheduled_fetch_local.sh` continuously.
- **`run_scheduled_fetch_local.sh`** — Local scheduled fetch runner processing users in fetch queues with adaptive skip.
- **`run_fetch_favorites_local.sh`** — Local favorites crawl runner.

## Key Conventions

- Comments and UI strings are in Japanese
- The canonical Gist filename is `data.json`. For backward compatibility, the Flutter app also reads from `gallary_data.json` (legacy misspelling) if `data.json` is not found
- GitHub token is provided either via `.env` file (dev) or `--dart-define=GITHUB_TOKEN` (web build)
- The Gist ID serves as a pseudo-password — knowing the ID grants access to the gallery data
