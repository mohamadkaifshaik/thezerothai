import 'package:drift/drift.dart';

/// Fallback for platforms that are neither `dart:ffi` nor web. Never selected
/// in practice; present so the conditional import always resolves.
QueryExecutor inMemoryCacheExecutor() {
  throw UnsupportedError(
    'No in-memory database for this platform. '
    'Expected dart:ffi or dart:js_interop (web) to be available.',
  );
}
