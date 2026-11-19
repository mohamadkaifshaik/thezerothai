# Drift on Flutter Web: the two checked-in files

`app/lib/core/storage/app_database.dart` opens the local cache with `driftDatabase()`. On web, drift loads two static
files from `app/web/`, and both are **checked in** because `pubspec.lock` does not update them:

- `drift_worker.js`: drift's web worker, **built from source** for the drift in `app/pubspec.lock` (now 2.35.4) with
  `make drift-worker`. Entry point: `app/tool/drift_worker.dart` (`WasmDatabase.workerMainForOpen()`), compiled by
  `dart compile js -O4 --no-source-maps` in the `app` package, so it uses the locked `drift` and `sqlite3` sources
  from the pub cache. Nothing is downloaded. Last built with Dart 3.14.0 (bundled with Flutter 3.50.0), on Windows;
  two builds there were byte-identical. Use the `dart` that ships with the pinned Flutter (first on `PATH`): another
  SDK builds a different file, and the version file records which one built it.
- `sqlite3.wasm`: the `sqlite3.wasm` release asset of sqlite3 3.5.2 (matches `sqlite3` in `app/pubspec.lock`). Its
  SHA-256 equals the hash the locked package pins for that release in `lib/src/hook/asset_hashes.dart`;
  `make drift-worker` checks this and fails on a mismatch.
- `drift_worker.version`: written by `make drift-worker`: the drift and sqlite3 versions built against, the Dart
  version, and the SHA-256 of both files (the worker's hashed with CRLF read as LF, since git may check it out with
  CRLF on Windows). It is copied into `build/web` and served publicly, which is harmless.

`app/test/guards/drift_worker_guard_test.dart` (part of `flutter test`) fails when the version file does not match
`pubspec.lock`, when either file's hash does not match the version file, or when the worker lacks the drift 2.35.1+
protocol field `client_lock`. Android and iOS do not use these files.

Why it matters: a worker older than the app's drift once ran in production (a 2.35.0 worker under drift 2.35.4).
With `sharedIndexedDb`, the storage Chrome uses on this site (it sends no cross-origin isolation headers), that
worker flushed writes made inside a transaction to IndexedDB only at the next write outside a transaction or a clean
close, so a reload, tab close or crash lost them (drift #3864, fixed in 2.35.1).

## Refresh when `drift` or `sqlite3` changes in `pubspec.lock`

1. `cd app && flutter pub get`, then from the repo root `make drift-worker`. Commit `app/web/drift_worker.js` and
   `app/web/drift_worker.version`.
2. If `sqlite3` changed, `make drift-worker` stops because `sqlite3.wasm` no longer matches the hash the new sqlite3
   pins. Replace it with the `sqlite3.wasm` asset of the release named by `releaseTag` in the locked package's
   `lib/src/hook/asset_hashes.dart` (`https://github.com/simolus3/sqlite3.dart/releases/download/<releaseTag>/sqlite3.wasm`),
   confirm its SHA-256 equals the pinned one, and run `make drift-worker` again.
3. Run the persistence test in Chrome, in both build modes, with a ChromeDriver of Chrome's major version listening on
   a free port (see `crypto/README.md`; pick your own `MLS_VECTORS_PORT`, the driver serves the MLS vectors there):

   ```
   cd app && MLS_VECTORS_PORT=8391 flutter drive --driver=test_driver/integration_test.dart \
     --target=integration_test/drift_persistence_test.dart -d web-server --browser-name=chrome \
     --driver-port=<chromedriver port> --headless --dart-define=MLS_VECTORS_PORT=8391
   # and the same with --wasm
   ```

   It writes a row inside a transaction and, with the database still open, reads drift's IndexedDB database
   directly to check the row is there. It forces `sharedIndexedDb`, and also reports which storage the production
   options pick (`build/integration_response_data.json`): `sharedIndexedDb` in the JS build; `opfsLocks` in the wasm
   build, because Flutter's web server sends cross-origin isolation headers there and the production site does not.

A missing or mismatched file fails when the database is first opened, not at build time; check the browser console
for a worker or wasm error after sign-in.
