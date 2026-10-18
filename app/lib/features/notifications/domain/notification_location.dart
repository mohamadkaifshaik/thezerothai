import '../../../core/router/app_router.dart';

/// Wire value of a follow notification's `type` (FCM data and the enum
/// `NOTIFICATION_TYPE_FOLLOW` both mean it).
const kNotificationTypeFollow = 'follow';

/// The app location a notification (in-app row or tapped push) opens: the
/// actor's profile for a follow, the post for everything else (a deleted post
/// shows "this post isn't available"). Null when it names neither. Ids are
/// percent-encoded; the one place both the list and the push tap use.
String? notificationLocation({
  required String type,
  required String postId,
  required String actorId,
}) {
  if (type != kNotificationTypeFollow && postId.isNotEmpty) {
    return AppRouter.postPath(postId);
  }
  if (actorId.isNotEmpty) return AppRouter.profileByIdPath(actorId);
  return null;
}
