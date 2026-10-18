import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pb.dart'
    as pb;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

/// Fixed reference time of the notification fixtures.
final DateTime kNotifBase = DateTime.utc(2026, 10, 14, 12);

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
