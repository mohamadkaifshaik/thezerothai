import '../../../core/router/app_router.dart';
import '../../beacons/domain/beacon_text_rules.dart' show isBeaconId;
import '../../messages/domain/conversation_id.dart';

/// Wire value of a follow notification's `type` (FCM data and the enum
/// `NOTIFICATION_TYPE_FOLLOW` both mean it).
const kNotificationTypeFollow = 'follow';

/// Wire values of the two protected-account types (the enums `NOTIFICATION_TYPE_FOLLOW_REQUEST` and `..._FOLLOW_ACCEPTED`).
/// Neither names
/// a post.
const kNotificationTypeFollowRequest = 'follow_request';
const kNotificationTypeFollowAccepted = 'follow_accepted';

/// Wire value of a direct-message push. It is push-only: there is
/// no notification row, and its FCM data carries `conversationId` only.
const kNotificationTypeMessage = 'message';

/// Wire values of the three plan types (`NOTIFICATION_TYPE_BEACON_REQUEST`,
/// `..._BEACON_ACCEPTED`, `..._BEACON_CANCELLED`). Each names a beacon
/// (`beaconId` in the row and in the push data), never a post.
const kNotificationTypeBeaconRequest = 'beacon_request';
const kNotificationTypeBeaconAccepted = 'beacon_accepted';
const kNotificationTypeBeaconCancelled = 'beacon_cancelled';

bool isBeaconNotificationType(String type) =>
    type == kNotificationTypeBeaconRequest ||
    type == kNotificationTypeBeaconAccepted ||
    type == kNotificationTypeBeaconCancelled;

/// The app location a notification (in-app row or tapped push) opens: the
/// actor's profile for a follow or an accepted request, the Follow requests
/// screen for a request, the conversation for a direct message, the
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
  String beaconId = '',
}) {
  if (isBeaconNotificationType(type)) {
    // A plan row or push opens the plan; a malformed id opens nothing and
    // never falls through to the post or profile cases.
    return isBeaconId(beaconId) ? AppRouter.planPath(beaconId) : null;
  }
  if (type == kNotificationTypeMessage) {
    // The raw id is checked before any path is built, so an encoded id
    // (`%61...`) is dropped, not decoded into something that matches.
    return isConversationId(conversationId)
        ? AppRouter.messagePath(conversationId)
        : null;
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
