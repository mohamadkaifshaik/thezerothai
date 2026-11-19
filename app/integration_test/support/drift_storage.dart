// The platform-specific parts of integration_test/drift_persistence_test.dart:
// opening the cache database the way the web build does and reading back what
// drift persisted to IndexedDB. Web only; elsewhere every function throws.
export 'drift_storage_io.dart'
    if (dart.library.js_interop) 'drift_storage_web.dart';
