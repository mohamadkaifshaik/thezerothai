import 'package:drift/drift.dart';

import 'memory_executor_stub.dart'
    if (dart.library.ffi) 'memory_executor_native.dart'
    if (dart.library.js_interop) 'memory_executor_web.dart'
    as impl;

/// A cache database that lives in memory only and is gone on restart: the
/// start-up fallback when the on-disk one cannot be used (see
/// `openCacheDatabase`). `NativeDatabase.memory()` on Android, iOS and
/// desktop; drift's in-memory WebAssembly storage on the web.
QueryExecutor inMemoryCacheExecutor() => impl.inMemoryCacheExecutor();
