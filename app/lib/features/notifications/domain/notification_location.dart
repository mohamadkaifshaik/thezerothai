import '../../../core/router/app_router.dart';

/// Wire value of a follow notification's `type` (FCM data and the enum
/// `NOTIFICATION_TYPE_FOLLOW` both mean it).
const kNotificationTypeFollow = 'follow';

/// Wire values of the two protected-account types (ADR-0025 D10; the enums
/// `NOTIFICATION_TYPE_FOLLOW_REQUEST` and `..._FOLLOW_ACCEPTED`). Neither names
/// a post.
const kNotificationTypeFollowRequest = 'follow_request';
const kNotificationTypeFollowAccepted = 'follow_accepted';

/// The app location a notification (in-app row or tapped push) opens: the
/// actor's profile for a follow or an accepted request, the Follow requests
/// screen for a request, the post for everything else (a deleted post shows
/// "this post isn't available"). Null when it names neither. Ids are
/// percent-encoded; the one place both the list and the push tap use.
String? notificationLocation({
  required String type,
  required String postId,
  required String actorId,
}) {
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
