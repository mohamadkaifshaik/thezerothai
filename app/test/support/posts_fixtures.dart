import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// A zero-padded 19-digit Snowflake-shaped post id for [n].
String postId(int n) => n.toString().padLeft(19, '0');

pb.PostView postView(int n, {String authorId = 'u1', String text = ''}) {
  return pb.PostView(
    post: pb.Post(
      postId: postId(n),
      text: text.isEmpty ? 'post $n' : text,
      author: common.AuthorSnapshot(userId: authorId, handle: 'h$authorId'),
    ),
  );
}

/// A server error carrying `ErrorDetail(reason, metadata)`.
connect.ConnectException serverError(
  connect.Code code,
  common.ErrorReason reason, {
  Map<String, String> metadata = const {},
}) {
  return connect.ConnectException(
    code,
    'server says no',
    details: [
      connect.ErrorDetail(
        'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
        common.ErrorDetail(
          reason: reason,
          message: 'server says no',
          metadata: metadata.entries,
        ).writeToBuffer(),
      ),
    ],
  );
}

connect.ConnectException rejectedToken(String field) => serverError(
  connect.Code.invalidArgument,
  common.ErrorReason.ERROR_REASON_VALIDATION,
  metadata: {'field': field},
);
