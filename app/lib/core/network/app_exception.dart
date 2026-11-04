import 'package:flutter/foundation.dart';

/// Typed domain errors the UI branches on. Callers must never pattern-match
/// on a raw error message string (see `dzeroth.common.v1.ErrorReason`).
///
/// These mirror `ErrorReason` in `proto/dzeroth/common/v1/common.proto`, plus
/// a couple of transport-level cases (`network`, `unauthenticated`, `unknown`)
/// that never reach the server.
@immutable
sealed class AppException implements Exception {
  const AppException(this.message);

  /// Safe to show to the user as-is.
  final String message;

  @override
  String toString() => message;
}

/// The request body failed server-side validation.
final class ValidationException extends AppException {
  const ValidationException(super.message, {this.field});
  final String? field;
}

/// Short-window token bucket exceeded. Do not auto-retry before
/// [retryAfter] elapses.
///
/// [limitName] is the server's `metadata["limit"]` / `["limit_name"]`
/// E.g. `check_handle_daily`, `account_ops_daily`, `search_daily`; no name for
/// a per-minute bucket.
final class RateLimitedException extends AppException {
  const RateLimitedException(super.message, {this.retryAfter, this.limitName});
  final Duration? retryAfter;
  final String? limitName;

  /// A daily limit (resets at IST midnight): either named `*_daily` or with a
  /// long [retryAfter]. Never "try again in a moment".
  bool get isDaily =>
      (limitName?.endsWith('_daily') ?? false) ||
      (retryAfter != null && retryAfter! > const Duration(minutes: 5));
}

/// A per-user daily quota (posts, follows, uploads, exports...) was reached.
final class QuotaExceededException extends AppException {
  const QuotaExceededException(super.message, {this.quota, this.retryAfter});
  final String? quota;
  final Duration? retryAfter;
}

/// The platform is in degraded (readonly/no-media) mode. Show a banner, do
/// not auto-retry.
final class DegradedModeException extends AppException {
  const DegradedModeException(super.message, {this.retryAfter});
  final Duration? retryAfter;
}

/// Missing/invalid Firebase App Check token — usually a client bug or a
/// tampered build. Not user-actionable beyond "update the app".
final class AppCheckRequiredException extends AppException {
  const AppCheckRequiredException(super.message);
}

/// The caller has a Firebase account but has not called CreateProfile yet.
final class ProfileRequiredException extends AppException {
  const ProfileRequiredException(
    super.message, {
    this.fromServerReason = false,
  });

  /// True only when the server attached `ERROR_REASON_PROFILE_REQUIRED`. The
  /// code-only fallback (any FAILED_PRECONDITION without a detail) leaves it
  /// false, so callers that act on "no profile" (account deletion fallback,
  /// L-5) never trigger on an unrelated precondition failure.
  final bool fromServerReason;
}

/// Email must be verified before this action.
final class EmailNotVerifiedException extends AppException {
  const EmailNotVerifiedException(super.message);
}

/// The requested handle is taken.
final class HandleTakenException extends AppException {
  const HandleTakenException(super.message);
}

/// A fixed cap was reached (e.g. following 5,000 accounts) or a cooldown is
/// running (`ChangeHandle`: [quota] `handle_change`, [retryAfter] = time left).
final class LimitReachedException extends AppException {
  const LimitReachedException(
    super.message, {
    this.quota,
    this.retryAfter,
    this.choiceIndex,
  });

  /// The server's `metadata["quota"]`, when it names the limit.
  final String? quota;
  final Duration? retryAfter;

  /// The caller's stored 0-based poll choice from `metadata["choice"]`
  /// (`LIMIT_REACHED` with `limit=poll_vote_changes`);
  /// null otherwise.
  final int? choiceIndex;
}

/// Referenced media is not READY or not owned by the caller.
final class MediaNotReadyException extends AppException {
  const MediaNotReadyException(super.message, {this.mediaId});

  /// The server's `metadata["media_id"]` when it names the offending image.
  final String? mediaId;
}

/// Image checks are temporarily unavailable (FinalizeUpload's screening step failed with no valid assessment: an outage, a timeout).
/// Nothing was published and the upload is kept: the same FinalizeUpload for the same media id can be repeated after [retryAfter]
/// with no re-upload. Never counts against the image's attempts on the server.
final class ScreeningUnavailableException extends AppException {
  const ScreeningUnavailableException(super.message, {this.retryAfter});

  /// The server's `retry_after` (5 s); null when the answer carried none.
  final Duration? retryAfter;
}

/// The same idempotency key was reused with a different request body.
final class IdempotencyKeyReusedException extends AppException {
  const IdempotencyKeyReusedException(super.message);
}

/// The account is suspended or pending deletion.
final class AccountRestrictedException extends AppException {
  const AccountRestrictedException(super.message);
}

/// The caller blocks the target (e.g. `Follow`). Unblock first; never
/// auto-unblocked.
final class TargetBlockedException extends AppException {
  const TargetBlockedException(super.message);
}

/// The feature is not enabled for this caller (server feature flag, or not
/// built yet, e.g. follow requests). Hide the feature and refresh
/// `GetMe.enabled_features`; never retry.
///
/// [feature] is the server's `metadata["feature"]`: when set it
/// names the sub-feature (`replies`, `quotes`, `media`) and the client hides
/// only that; when null the whole service is off.
final class FeatureDisabledException extends AppException {
  const FeatureDisabledException(super.message, {this.feature});
  final String? feature;
}

/// The caller's sign-in is too old for this sensitive call (e.g.
/// `DeleteAccount`, `ERROR_REASON_REAUTH_REQUIRED`). Re-authenticate, force an
/// ID-token refresh and retry once with the same idempotency key.
final class ReauthRequiredException extends AppException {
  const ReauthRequiredException(super.message);
}

/// The reply audience policy does not let the caller reply.
///
/// The text is deliberately generic and fixed: it never says why (a block, a
/// follow rule, ...), so the UI cannot reveal who blocks whom. [policy] is the
/// server's `metadata["policy"]`, kept as an opaque string for logs and
/// analytics only; never show it to the user.
final class ReplyNotAllowedException extends AppException {
  const ReplyNotAllowedException({this.policy}) : super(userMessage);

  /// The only text ever shown for this error.
  static const userMessage = "You can't reply to this conversation.";

  final String? policy;
}

/// The target account protects its posts (FAILED_PRECONDITION + PROTECTED_ACCOUNT):
/// a Repost or Quote of its post was refused. The text is
/// fixed and generic; never show the server's.
final class ProtectedAccountException extends AppException {
  const ProtectedAccountException() : super(userMessage);

  /// The only text ever shown for this error.
  static const userMessage =
      "You can't repost or quote posts from a protected account.";
}

/// The recipient cannot be messaged (FAILED_PRECONDITION + CANNOT_MESSAGE):
/// blocked either way, not active, outside the messaging
/// rollout, or deleted. The text is fixed and generic; never show the server's.
final class CannotMessageException extends AppException {
  const CannotMessageException() : super(userMessage);

  /// The only text ever shown for this error.
  static const userMessage = "You can't message this account.";
}

/// The poll has closed (FAILED_PRECONDITION + POLL_CLOSED).
/// The caller refreshes the post and shows the final results.
final class PollClosedException extends AppException {
  const PollClosedException() : super(userMessage);

  /// The only text ever shown for this error.
  static const userMessage = 'This poll has ended.';
}

/// The vote the caller sent does not match the one the server holds
/// (FAILED_PRECONDITION + ALREADY_VOTED): a first vote that was already cast, a change sent with a stale `expected_choice`, or
/// a change sent to a server that predates changes. The server's choice is the
/// caller's own, never anyone else's.
final class AlreadyVotedException extends AppException {
  const AlreadyVotedException({this.choiceIndex}) : super(userMessage);

  /// The only text ever shown for this error.
  static const userMessage = 'You already voted in this poll.';

  /// The stored 0-based choice from `metadata["choice"]`; null when missing
  /// or not a number (the client then refreshes the post to learn it).
  final int? choiceIndex;
}

/// The resource does not exist (or is hidden from the caller, e.g. blocked).
final class NotFoundException extends AppException {
  const NotFoundException(super.message);
}

/// The caller is not signed in, or their session/App Check token is invalid.
final class UnauthenticatedException extends AppException {
  const UnauthenticatedException(super.message);
}

/// No network connectivity, or the API/Cloud Run instance is unreachable.
final class NetworkException extends AppException {
  const NetworkException(super.message);
}

/// A photo upload to storage did not complete (the signed URL expired or was
/// refused, or storage had a transient fault). Retrying re-signs the URLs
/// under the same key; it never burns upload quota. Already reported where it
/// was detected, so callers must not report it again.
final class UploadInterruptedException extends AppException {
  const UploadInterruptedException(super.message);
}

/// The API is paused: Google's front end refused the call with HTTP 403 and no
/// Connect error body (the public invoker was removed). Never a
/// permission problem of the caller. The app shows the "service paused" screen until a re-check succeeds.
final class ServicePausedException extends AppException {
  const ServicePausedException([super.message = userMessage]);

  static const userMessage =
      'The service is temporarily paused. Please try again later.';
}

/// Anything else (mapped from an unrecognized Connect `Code`).
final class UnknownApiException extends AppException {
  const UnknownApiException(super.message);
}

/// Why a role-gated community action was refused (PERMISSION_DENIED +
/// FORBIDDEN; the server's `metadata["reason"]`).
enum CommunityForbiddenReason {
  /// A BANNED user joins or posts.
  banned('banned', "You're banned from this community."),

  /// A non-member (or banned user) posts or replies.
  notMember('not_member', 'Only members of this community can do that.'),

  /// Hide, restore, ban, unban or read the moderation log without being a
  /// moderator.
  notModerator('not_moderator', 'Only moderators can do that.'),

  /// Edit the community, appoint moderators, or act on the owner or on a
  /// moderator without being the owner.
  notOwner('not_owner', 'Only the community owner can do that.'),

  /// CreateCommunity by a caller outside the creators list.
  notCreator(
    'not_creator',
    "Creating communities isn't available for your account yet.",
  ),

  /// A reason this build does not know (a newer server). Safe generic text;
  /// never "restricted".
  unknown('', "You can't do that in this community.");

  const CommunityForbiddenReason(this.wire, this.userMessage);

  /// The `metadata["reason"]` value.
  final String wire;

  /// The only text ever shown for this reason (fixed; never the server's).
  final String userMessage;

  static CommunityForbiddenReason fromWire(String? reason) {
    for (final r in values) {
      if (r != unknown && r.wire == reason) return r;
    }
    return unknown;
  }
}

/// A community action the caller's role does not allow (PERMISSION_DENIED +
/// `ERROR_REASON_FORBIDDEN`). Never an account suspension (that
/// is [AccountRestrictedException]). Do not retry; the text is fixed per
/// [reason].
final class CommunityForbiddenException extends AppException {
  CommunityForbiddenException(this.reason) : super(reason.userMessage);
  final CommunityForbiddenReason reason;
}

/// Why a community write conflicts with the community's state or a held role
/// (FAILED_PRECONDITION + COMMUNITY_STATE; `metadata["reason"]`).
enum CommunityStateReason {
  /// The owner leaves (the owner cannot leave).
  owner('owner', "The owner can't leave their community."),

  /// The owner bans a moderator (remove the role first).
  moderator('moderator', 'Remove their moderator role before banning them.'),

  /// A write to an ARCHIVED community.
  communityArchived(
    'community_archived',
    'This community is archived, so it is read-only.',
  ),

  /// A reason this build does not know. Safe generic text; never the
  /// profile-required flow.
  unknown('', "This community can't be changed right now.");

  const CommunityStateReason(this.wire, this.userMessage);

  final String wire;

  /// The only text ever shown for this reason.
  final String userMessage;

  static CommunityStateReason fromWire(String? reason) {
    for (final r in values) {
      if (r != unknown && r.wire == reason) return r;
    }
    return unknown;
  }
}

/// A write that conflicts with the community's state or a role held in it
/// (FAILED_PRECONDITION + `ERROR_REASON_COMMUNITY_STATE`). Never
/// a missing profile ([ProfileRequiredException]). Do not retry.
final class CommunityStateException extends AppException {
  CommunityStateException(this.reason) : super(reason.userMessage);
  final CommunityStateReason reason;
}
