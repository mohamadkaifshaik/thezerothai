import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// An sqlite3 database in memory, on the calling isolate. Touches no file.
QueryExecutor inMemoryCacheExecutor() => NativeDatabase.memory();
