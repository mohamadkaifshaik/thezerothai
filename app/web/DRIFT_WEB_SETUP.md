# Drift on Flutter Web: the two checked-in files

`app/lib/core/storage/app_database.dart` opens the local cache with `driftDatabase()`. On web, drift loads two static
files from `app/web/`, and both are **checked in**:

- `sqlite3.wasm`: sqlite3 3.5.2 (matches `sqlite3` in `app/pubspec.lock`).
- `drift_worker.js`: downloaded for drift 2.35.0. `pubspec.lock` now has drift 2.35.2, a patch difference that has not been
  refreshed or tested.

Android and iOS do not use them.

## Refresh when `drift` or `sqlite3` changes in `pubspec.lock`
Download the assets for the locked versions and overwrite the files in `app/web/`:

- `https://github.com/simolus3/drift/releases/download/drift-<version>/drift_worker.js`
- `https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-<version>/sqlite3.wasm`

Then run `flutter build web` and open the app in Chrome. A missing or mismatched file fails when the database is first
opened, not at build time, so check the browser console for a worker or wasm error after sign-in. If the release assets do
not exist for a version, build the worker from source as described at https://drift.simonbinder.eu/platforms/web/.
