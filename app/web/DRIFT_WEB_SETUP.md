# Drift (local cache) on Flutter Web — one-time manual step

> **Status (2026-09-27): done.** `sqlite3.wasm` (sqlite3 3.5.2) and `drift_worker.js` (drift 2.35.0) are checked in,
> downloaded from the upstream GitHub releases. Re-download both whenever `drift` or `sqlite3` changes in `pubspec.lock`:
> `https://github.com/simolus3/drift/releases/download/drift-<ver>/drift_worker.js` and
> `https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-<ver>/sqlite3.wasm`.

`app/lib/core/storage/app_database.dart` opens the local profile cache with
`drift_flutter`'s `driftDatabase()`. On native platforms (Android/iOS/desktop)
this works out of the box. On **web**, drift needs two static files that are
not Dart packages and can't be `pub get`'d, so they are **not** included in
this commit:

1. `sqlite3.wasm` — the compiled sqlite3 WebAssembly module.
2. `drift_worker.js` — a small worker script that runs the database off the
   main thread.

## Steps

1. Download the `sqlite3.wasm` build that matches the `sqlite3` package
   version pinned in `app/pubspec.lock` from the
   [sqlite3.dart releases page](https://github.com/simolus3/sqlite3.dart/releases)
   (asset name `sqlite3.wasm`) and place it at `app/web/sqlite3.wasm`.
2. Build the drift worker: add a dev dependency on `build_web_compilers`,
   create `app/web/worker.dart` containing:
   ```dart
   import 'package:drift/wasm.dart';
   void main() => WasmDatabase.workerMainForOpen();
   ```
   then run `dart run build_runner build -o web:build/web_worker` (or the
   current drift-recommended command — see
   https://drift.simonbinder.eu/platforms/web/ for the exact, version-matched
   instructions) and copy the compiled `worker.dart.js` to
   `app/web/drift_worker.js`.
3. Re-run `flutter build web` / `flutter run -d chrome`.

Until this is done, `flutter run -d chrome` still **compiles and boots**;
`AppDatabase._openConnection()` will only fail at runtime when the cache is
first touched, in which case wrap reads in a try/catch and fall back to
"cache miss" (already the default behavior of `IdentityRepository`, which
treats a missing cache row as "no cached profile yet" rather than crashing).

Native builds (Android, iOS, macOS, Windows, Linux) do not need this file.
