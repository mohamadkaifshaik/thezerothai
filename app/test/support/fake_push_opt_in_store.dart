import 'package:dzeroth/features/notifications/data/push_opt_in_store.dart';

/// An in-memory [PushOptInStore]; `failReads` / `failWrites` script a broken
/// disk.
class FakePushOptInStore implements PushOptInStore {
  FakePushOptInStore({Map<String, DateTime>? records})
    : records = records ?? {};

  final Map<String, DateTime> records;
  bool failReads = false;
  bool failWrites = false;
  int reads = 0;
  int writes = 0;

  @override
  Future<DateTime?> readNotNow(String uid) async {
    reads++;
    if (failReads) throw StateError('disk read failed');
    return records[uid];
  }

  @override
  Future<void> writeNotNow(String uid, DateTime at) async {
    writes++;
    if (failWrites) throw StateError('disk write failed');
    records[uid] = at;
  }

  /// The uids [forget] was called with, in order.
  final List<String> forgotten = [];
  bool failForget = false;

  @override
  Future<void> forget(String uid) async {
    forgotten.add(uid);
    if (failForget) throw StateError('disk delete failed');
    records.remove(uid);
  }
}
