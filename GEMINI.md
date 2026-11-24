# GEMINI.md

Project instructions for Gemini CLI / Antigravity CLI (`x_post_gallery`).

## Overview
PostViewer (`x_post_gallery`): Flutter gallery app syncing scraped X media via GitHub Gist, paired with a local crawler pipeline.

## Core Rules
1. **Token Economy (Highest Priority)**a
   - Output only essentials, diffs, and commands; omit greetings, preambles, postscripts, and fluff.
   - Prefer careful reasoning over trial-and-error turns; minimize tool calls and context bloat.
   - Use targeted reads (line ranges, grep) instead of reading whole files unnecessarily.
2. **No Hardcoding & Secrets Prohibition**
   - Avoid hardcoding magic numbers, configs, or URLs unless it clearly improves readability/maintainability.
   - **Strictly forbidden** to hardcode account/screen names, Gist IDs, tokens, or secrets in code exposed to GitHub. Load via `.env`, env vars (`resolveEnv` / `--dart-define`), or runtime config.
3. **Python Environment**
   - Always run Python scripts and tests via `./venv/bin/python` (never global `python3`).

## Commands
### Flutter (`lib/`)
```bash
flutter run
flutter analyze
flutter test
# Always run analyze & test after pub upgrade or dependency changes
```

### Crawler & Tests (`scripts/`, `tests/`)
```bash
./venv/bin/python scripts/extract_media.py -u <username> -n 100   # requires data/auth.json
./append_gist.sh -g <master_gist_id> -u <username> -n 100 -s
./scripts/run_master_local.sh
./scripts/run_scheduled_fetch_local.sh
./scripts/run_expand_timeline_local.sh

./venv/bin/python -m unittest discover tests
bash tests/test_crawler_adaptive_skip.sh
bash tests/test_crawler_delete_defense.sh
```

## Architecture
- `lib/main.dart`: Entry point (`.env`, dark theme, Provider setup).
- `lib/viewmodels/gallery_viewmodel.dart`: App state (`ChangeNotifier`: load, delete user, pin/priority, queue).
- `lib/services/gallery_repository.dart`: Gist fetch/parse, cache, `SharedPreferences` persistence.
- `lib/services/github_service.dart`: GitHub Gist API & 2-slot throttling queue.
- `lib/screens/gallery/` & `lib/screens/detail/`: Gallery/swipe view & full-screen pan/zoom viewer.
- `lib/models/tweet_item.dart`, `lib/models/user_gist_entry.dart`: Data models.
- `scripts/run_master_local.sh`: Master loop.
- `scripts/run_scheduled_fetch_local.sh` & `scripts/adaptive_skip.py`: 2-slot scheduled crawler with adaptive skip backoff.
- `scripts/run_fetch_favorites_local.sh`: Favorites crawler.
- `scripts/run_expand_timeline_local.sh`: Timeline candidate discovery & gallery expansion.
- `scripts/append_to_gist.py` / `append_gist.sh`: Append to child/master Gists (dedup, slimming, conflict/delete protection).
- `scripts/extract_media.py`: Playwright X media scraper.

## Conventions
- **i18n (`ja` & `en` required):** Never hardcode UI, dialog, button, tooltip, SnackBar, or network/API error strings. Define both `ja` and `en` in `lib/l10n/app_localizations.dart` (`AppLocalizations.of(context)` in UI; `AppLocalizations.current` in non-context layers) and add `ja`/`en` tests in `test/l10n_test.dart`.
- **Comments:** Japanese (or `[JA]` / `[EN]`).
- **Gist files & Auth:** Canonical file is `data.json` (also support legacy `gallary_data.json`). Supply GitHub token via `.env` (dev) or `--dart-define=GITHUB_TOKEN` (web build).
- **User deletion:** Remove from child Gist, master Gist, queue Gist (`fetch_queue.json`), and favorites completely.