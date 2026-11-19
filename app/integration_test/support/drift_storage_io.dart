import 'package:drift/drift.dart';

/// The storage a web open settled on; off the web there is none.
class OpenedStorage {
  String? implementation;
  List<String> missingFeatures = const [];
}

QueryExecutor openLikeProduction(String name, OpenedStorage report) =>
    throw UnsupportedError('drift web storage is web only');

QueryExecutor openSharedIndexedDb(String name, OpenedStorage report) =>
    throw UnsupportedError('drift web storage is web only');

Future<Uint8List?> readPersistedFile(String databaseName, String path) =>
    throw UnsupportedError('drift web storage is web only');

Future<void> deletePersisted(String databaseName) async {}

bool? get crossOriginIsolated => null;
