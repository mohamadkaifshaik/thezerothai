import '../../../core/router/app_router.dart';

/// Wire value of a follow notification's `type` (FCM data and the enum
/// `NOTIFICATION_TYPE_FOLLOW` both mean it).
const kNotificationTypeFollow = 'follow';

/// Wire values of the two protected-account types (ADR-0025 D10; the enums
/// `NOTIFICATION_TYPE_FOLLOW_REQUEST` and `..._FOLLOW_ACCEPTED`). Neither names
/// a post.
const kNotificationTypeFollowRequest = 'follow_request';
const kNotificationTypeFollowAccepted = 'follow_accepted';

/// Wire value of a direct-message push (ADR-0027 D9). It is push-only: there is
/// no notification row, and its FCM data carries `conversationId` only.
const kNotificationTypeMessage = 'message';

/// The app location a notification (in-app row or tapped push) opens: the
/// actor's profile for a follow or an accepted request, the Follow requests
/// screen for a request, the conversation for a direct message (W7-19), the
/// post for everything else (a deleted post shows "this post isn't
/// available"). Null when it names neither. Ids are percent-encoded; the one
/// place both the list and the push tap use.
///
/// A message push opens `/messages/<conversationId>` only when that path is on
/// the deep-link allowlist (32 lower-case hex); any other id, or none, opens
/// nothing, and never falls through to the post or profile cases.
String? notificationLocation({
  required String type,
  required String postId,
  required String actorId,
  String conversationId = '',
}) {
  if (type == kNotificationTypeMessage) {
    final path = AppRouter.messagePath(conversationId);
    return AppRouter.deepLinkTarget(Uri(path: path)) == null ? null : path;
  }
  if (type == kNotificationTypeFollowRequest) {
    return AppRouter.followRequestsPath;
  }
  if (type != kNotificationTypeFollow &&
      type != kNotificationTypeFollowAccepted &&
      postId.isNotEmpty) {
    return AppRouter.postPath(postId);
  }
  if (actorId.isNotEmpty) return AppRouter.profileByIdPath(actorId);
  return null;
}
