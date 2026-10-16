import 'package:drift/drift.dart';

import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/notifications/v1/notifications.pb.dart' as pb;

/// Notifications kept before the list is trimmed back (at a page boundary).
const kNotificationsRetention = 100;

/// Past this many cached rows the list is cut back to
/// [kNotificationsRetention] (6 notifications per DAU is the planning mean,
/// so this is rarely reached).
const kNotificationsHardCap = 150;

/// One row of the cached list: a notification or a refresh-gap marker.
class NotificationEntry {
  const NotificationEntry.notification(this.itemKey, this.sortKey, this.value)
    : gapToken = null;
  const NotificationEntry.gap(this.itemKey, this.sortKey, String this.gapToken)
    : value = null;

  final String itemKey;
  final String sortKey;
  final pb.Notification? value;
  final String? gapToken;

  bool get isGap => gapToken != null;
}

/// What the screen renders from disk, with no network call.
class NotificationsSnapshot {
  const NotificationsSnapshot({
    this.entries = const [],
    this.sinceToken = '',
    this.olderPageToken = '',
    this.seenAt,
  });

  /// Newest first; notifications and gap markers interleaved.
  final List<NotificationEntry> entries;
  final String sinceToken;
  final String olderPageToken;

  /// The caller's `seen_at`; null when never marked seen.
  final DateTime? seenAt;

  bool get hasMore => olderPageToken.isNotEmpty;

  bool get hasNotifications => entries.any((e) => !e.isGap);
}

/// Sort key of a notification: zero-padded `created_at` microseconds, then
/// the id (a total order, newest first when sorted descending).
String notificationSortKey(pb.Notification n) {
  final micros = n.hasCreatedAt()
      ? n.createdAt.toDateTime().microsecondsSinceEpoch
      : 0;
  return '${micros.toString().padLeft(20, '0')}|${n.id}';
}

/// A key that sorts directly below every row of [sortKey]'s timestamp.
String _sortKeyBelow(String sortKey) {
  final bar = sortKey.indexOf('|');
  return bar < 0 ? sortKey : sortKey.substring(0, bar + 1);
}

/// A key that sorts directly above every row of [sortKey]'s timestamp
/// (`~` is above every id character).
String _sortKeyAbove(String sortKey) {
  final bar = sortKey.indexOf('|');
  final stamp = bar < 0 ? sortKey : sortKey.substring(0, bar);
  return '$stamp|~';
}

/// Persists the notification list in drift and implements every merge rule
/// in one place (one transaction per method, so a crash never leaves a
/// half-merged list). Mirrors `TimelineStore`: every write takes the session
/// it started under and is dropped when the epoch ended since, so an
/// in-flight request of a signed-out user never lands in the next user's
/// cache (CLAUDE.md privacy rule 10).
class NotificationsStore {
  NotificationsStore(this._db);

  static const _stateKey = 'main';

  final AppDatabase _db;

  int get session => _db.sessionEpoch.value;

  Future<void> _tx(int session, Future<void> Function() body) {
    return _db.transaction(() async {
      if (!_db.sessionEpoch.allows(session)) return;
      await body();
    });
  }

  Future<NotificationsSnapshot> read() async {
    final rows = await (_db.select(
      _db.notificationEntries,
    )..orderBy([(t) => OrderingTerm.desc(t.sortKey)])).get();
    final entries = <NotificationEntry>[];
    final undecodable = <String>[];
    for (final row in rows) {
      final payload = row.payload;
      if (payload != null) {
        try {
          entries.add(
            NotificationEntry.notification(
              row.itemKey,
              row.sortKey,
              pb.Notification.fromBuffer(payload),
            ),
          );
        } catch (_) {
          undecodable.add(row.itemKey);
        }
      } else if (row.gapToken != null) {
        entries.add(
          NotificationEntry.gap(row.itemKey, row.sortKey, row.gapToken!),
        );
      }
    }
    if (undecodable.isNotEmpty) {
      await (_db.delete(
        _db.notificationEntries,
      )..where((t) => t.itemKey.isIn(undecodable))).go();
    }
    final state = await _state();
    final micros = state?.seenAtMicros;
    return NotificationsSnapshot(
      entries: entries,
      sinceToken: state?.sinceToken ?? '',
      olderPageToken: state?.olderPageToken ?? '',
      seenAt: micros == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true),
    );
  }

  /// Replaces the list with a cold-open page (no tokens sent).
  Future<void> applyColdOpen({
    required List<pb.Notification> items,
    required String sinceToken,
    required String nextPageToken,
    required DateTime? seenAt,
    required int session,
  }) {
    return _tx(session, () async {
      await _db.delete(_db.notificationEntries).go();
      final valid = _valid(items);
      await _upsert(valid);
      if (valid.isNotEmpty && nextPageToken.isNotEmpty) {
        await _setPageToken(valid, nextPageToken);
      }
      await _saveState(
        sinceToken: sinceToken,
        olderPageToken: nextPageToken,
        seenAt: seenAt,
      );
    });
  }

  /// Merges a `since_token` refresh. Rows are replaced by id (a collapsed
  /// like moves to the top); a non-empty [gapPageToken] persists a gap row
  /// directly below the oldest returned row.
  Future<void> applyRefresh({
    required List<pb.Notification> items,
    required String sinceToken,
    required String gapPageToken,
    required DateTime? seenAt,
    required int session,
  }) {
    return _tx(session, () async {
      final valid = _valid(items);
      await _upsert(valid);
      if (gapPageToken.isNotEmpty && valid.isNotEmpty) {
        await _putGap(
          _sortKeyBelow(notificationSortKey(valid.last)),
          gapPageToken,
        );
      } else if (gapPageToken.isNotEmpty) {
        // Every new row was filtered out but the server says more exist
        // below them: keep the gap directly above the newest cached row so
        // "Show more" is still offered (never infer the end from empty).
        final newest =
            await (_db.select(_db.notificationEntries)
                  ..where((t) => t.payload.isNotNull())
                  ..orderBy([(t) => OrderingTerm.desc(t.sortKey)])
                  ..limit(1))
                .getSingleOrNull();
        if (newest != null) {
          await _putGap(_sortKeyAbove(newest.sortKey), gapPageToken);
        }
      }
      await _saveState(sinceToken: sinceToken, seenAt: seenAt);
      await _prune();
    });
  }

  /// Merges a scroll-down page into the tail.
  Future<void> applyOlderPage({
    required List<pb.Notification> items,
    required String nextPageToken,
    required int session,
  }) {
    return _tx(session, () async {
      final valid = _valid(items);
      await _upsert(valid);
      if (valid.isNotEmpty && nextPageToken.isNotEmpty) {
        await _setPageToken(valid, nextPageToken);
      }
      await _saveState(olderPageToken: nextPageToken, replaceOlder: true);
    });
  }

  /// Merges one page that fills the gap row [gapItemKey]; the gap moves below
  /// the page with the new token, or is removed when the token is empty.
  Future<void> applyGapPage(
    String gapItemKey, {
    required List<pb.Notification> items,
    required String nextPageToken,
    required int session,
  }) {
    return _tx(session, () async {
      final gap = await (_db.select(
        _db.notificationEntries,
      )..where((t) => t.itemKey.equals(gapItemKey))).getSingleOrNull();
      final valid = _valid(items);
      await _upsert(valid);
      if (gap != null) {
        await (_db.delete(
          _db.notificationEntries,
        )..where((t) => t.itemKey.equals(gapItemKey))).go();
      }
      if (nextPageToken.isNotEmpty) {
        final key = valid.isNotEmpty
            ? _sortKeyBelow(notificationSortKey(valid.last))
            : gap?.sortKey;
        if (key != null) await _putGap(key, nextPageToken);
      }
    });
  }

  /// Stores the `seen_at` the server confirmed.
  Future<void> setSeenAt(DateTime seenAt, {required int session}) =>
      _tx(session, () => _saveState(seenAt: seenAt));

  /// Drops the stored `since_token` (the server rejected it).
  Future<void> clearSince({required int session}) =>
      _tx(session, () => _saveState(sinceToken: '', replaceSince: true));

  /// This installation's device id, generated by [generate] on first use
  /// and kept until sign-out wipes the cache.
  Future<String> deviceId(String Function() generate) async {
    final existing = (await _state())?.deviceId ?? '';
    if (existing.isNotEmpty) return existing;
    final id = generate();
    final session = this.session;
    await _tx(session, () => _saveState(deviceId: id));
    return id;
  }

  /// This installation's stored device id, or '' when none was generated.
  /// Read-only: never creates one (sign-out must not mint an id to remove).
  Future<String> existingDeviceId() async => (await _state())?.deviceId ?? '';

  // --- internals -----------------------------------------------------------

  List<pb.Notification> _valid(List<pb.Notification> items) => [
    for (final n in items)
      if (n.id.isNotEmpty) n,
  ];

  Future<CachedNotificationState?> _state() {
    return (_db.select(
      _db.notificationStateEntries,
    )..where((t) => t.stateKey.equals(_stateKey))).getSingleOrNull();
  }

  /// A null/empty token leaves the stored one alone unless the matching
  /// `replace*` flag is set (a response without a `since_token` must not
  /// erase the old one).
  Future<void> _saveState({
    String? sinceToken,
    String? olderPageToken,
    DateTime? seenAt,
    String? deviceId,
    bool replaceSince = false,
    bool replaceOlder = false,
  }) async {
    final old = await _state();
    final since =
        (sinceToken != null && (sinceToken.isNotEmpty || replaceSince))
        ? sinceToken
        : old?.sinceToken ?? '';
    final older =
        (olderPageToken != null && (olderPageToken.isNotEmpty || replaceOlder))
        ? olderPageToken
        : old?.olderPageToken ?? '';
    final seenMicros = seenAt?.microsecondsSinceEpoch ?? old?.seenAtMicros;
    await _db
        .into(_db.notificationStateEntries)
        .insertOnConflictUpdate(
          NotificationStateEntriesCompanion.insert(
            stateKey: _stateKey,
            sinceToken: Value(since),
            olderPageToken: Value(older),
            seenAtMicros: Value(seenMicros),
            deviceId: Value(deviceId ?? old?.deviceId ?? ''),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _upsert(List<pb.Notification> items) async {
    for (final n in items) {
      await _db
          .into(_db.notificationEntries)
          .insertOnConflictUpdate(
            NotificationEntriesCompanion.insert(
              itemKey: n.id,
              sortKey: notificationSortKey(n),
              payload: Value(n.writeToBuffer()),
            ),
          );
    }
  }

  Future<void> _putGap(String sortKey, String token) {
    final key = 'gap:$sortKey';
    return _db
        .into(_db.notificationEntries)
        .insertOnConflictUpdate(
          NotificationEntriesCompanion.insert(
            itemKey: key,
            sortKey: sortKey,
            gapToken: Value(token),
          ),
        );
  }

  Future<void> _setPageToken(List<pb.Notification> page, String token) {
    return (_db.update(_db.notificationEntries)
          ..where((t) => t.itemKey.equals(page.last.id)))
        .write(NotificationEntriesCompanion(pageToken: Value(token)));
  }

  /// Trims to [kNotificationsRetention] rows at a page boundary once the list
  /// exceeds [kNotificationsHardCap]; the boundary page's token becomes the
  /// scroll token. No boundary, no trim.
  Future<void> _prune() async {
    final rows = await (_db.select(
      _db.notificationEntries,
    )..orderBy([(t) => OrderingTerm.desc(t.sortKey)])).get();
    if (rows.length <= kNotificationsHardCap) return;
    for (var i = kNotificationsRetention - 1; i < rows.length; i++) {
      final token = rows[i].pageToken;
      if (token == null || token.isEmpty) continue;
      final below = [for (final r in rows.skip(i + 1)) r.itemKey];
      if (below.isNotEmpty) {
        await (_db.delete(
          _db.notificationEntries,
        )..where((t) => t.itemKey.isIn(below))).go();
      }
      await _saveState(olderPageToken: token, replaceOlder: true);
      return;
    }
  }
}
