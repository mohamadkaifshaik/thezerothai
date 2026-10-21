import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pb.dart'
    as pb;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

/// Reference time of the notification fixtures: the real clock, captured once
/// (UTC, truncated to the second) when the fixtures are first used.
///
/// It must not be a fixed date: the screen stamps rows against `DateTime.now()`,
/// and a fixed date ages past the 7-day relative-time cutoff, where the spoken
/// label turns into a calendar date without "ago". Every `minutesAgo` row is
/// therefore the intended number of minutes before the "now" the screen uses,
/// plus the time the test file has been running (drift). Drift only matters
/// against the cutoffs of the labels asserted: the smallest asserted row is
/// 5 minutes old, so "... ago" holds for any drift below 7 days.
final DateTime kNotifBase = _captureBase();

DateTime _captureBase() {
  final n = DateTime.now().toUtc();
  return DateTime.utc(n.year, n.month, n.day, n.hour, n.minute, n.second);
}

ts.Timestamp _stamp(DateTime t) => ts.Timestamp.fromDateTime(t);

/// A notification created [minutesAgo] minutes before [kNotifBase].
pb.Notification notif(
  String id, {
  int minutesAgo = 0,
  NotificationType type = NotificationType.NOTIFICATION_TYPE_FOLLOW,
  String actorId = 'u2',
  String handle = 'alice',
  String displayName = 'Alice',
  int actorCount = 1,
  String postId = '',
}) {
  return pb.Notification(
    id: id,
    type: type,
    actor: common.AuthorSnapshot(
      userId: actorId,
      handle: handle,
      displayName: displayName,
    ),
    actorCount: actorCount,
    postId: postId,
    createdAt: _stamp(kNotifBase.subtract(Duration(minutes: minutesAgo))),
  );
}

pb.ListNotificationsResponse listResponse(
  List<pb.Notification> items, {
  String next = '',
  String since = '',
  String gap = '',
  DateTime? seenAt,
}) {
  return pb.ListNotificationsResponse(
    notifications: items,
    nextPageToken: next,
    sinceToken: since,
    gapPageToken: gap,
    seenAt: seenAt == null ? null : _stamp(seenAt),
  );
}

/// A snapshot for UI tests that mock the repository.
NotificationsSnapshot snapshotOfNotifs(
  List<pb.Notification> items, {
  String since = '',
  String older = '',
  DateTime? seenAt,
}) {
  return NotificationsSnapshot(
    entries: [
      for (final n in items)
        NotificationEntry.notification(n.id, notificationSortKey(n), n),
    ],
    sinceToken: since,
    olderPageToken: older,
    seenAt: seenAt,
  );
}
