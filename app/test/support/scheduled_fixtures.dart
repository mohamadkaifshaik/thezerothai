import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

/// A 32-character lowercase hex scheduled id for [n].
String scheduledId(int n) => n.toRadixString(16).padLeft(32, '0');

/// The base of the scheduled fixtures: the current year, mid June, so no
/// fixed absolute date appears in a test. Use it with `.add(...)`.
DateTime scheduledBase() => DateTime(DateTime.now().year, 6, 15, 10, 0);

/// A scheduled post as the server returns it. A FAILED or terminal one has no
/// text and no media, like the real answers.
pb.ScheduledPost scheduledPost(
  int n, {
  String text = '',
  ScheduledPostStatus status =
      ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING,
  ScheduledPostFailure failure =
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_UNSPECIFIED,
  DateTime? publishAt,
  int media = 0,
  ReplyPolicy replyPolicy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
}) {
  final pending = status == ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING;
  return pb.ScheduledPost(
    scheduledId: scheduledId(n),
    text: pending ? (text.isEmpty ? 'scheduled $n' : text) : '',
    media: [
      if (pending)
        for (var i = 0; i < media; i++)
          common.MediaRef(mediaId: 'media-$n-$i', thumbUrl: 'https://t/$n/$i'),
    ],
    replyPolicy: replyPolicy,
    publishAt: Timestamp.fromDateTime(
      (publishAt ?? scheduledBase().add(Duration(hours: n))).toUtc(),
    ),
    status: status,
    failure: failure,
  );
}

/// A FAILED item.
pb.ScheduledPost failedScheduledPost(
  int n, {
  ScheduledPostFailure failure =
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_EXPIRED,
  DateTime? publishAt,
}) => scheduledPost(
  n,
  status: ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED,
  failure: failure,
  publishAt: publishAt,
);
