// The entry point of app/web/drift_worker.js, drift's web worker (shared and
// dedicated). Compiled with dart2js against the drift and sqlite3 versions in
// pubspec.lock by `make drift-worker` (tool/build_drift_worker.dart); not an
// app entry point and not something to `dart run`. See web/DRIFT_WEB_SETUP.md.
import 'package:drift/wasm.dart';

void main() => WasmDatabase.workerMainForOpen();
