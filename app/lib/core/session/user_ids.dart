import '../../features/onboarding/presentation/bloc/onboarding_state.dart';

/// The id the server sends for an account that has no public id (erased, or
/// mid-deletion): `u` + 26 `z`. Several unavailable accounts share it. A real
/// public id can never equal it (its first body character is always 0-7).
const kUnavailableUserId = 'uzzzzzzzzzzzzzzzzzzzzzzzzzz';

/// What an unavailable account is called where it has no name of its own (the
/// moderation log and a deleted peer in Messages say the same).
const kUnavailableAccountName = 'Deleted account';

/// Whether [userId] names an account that is gone (the tombstone id). Such an
/// id is never navigable, never actionable and never "me".
bool isUnavailableUserId(String? userId) => userId == kUnavailableUserId;

/// A user id is an opaque string issued by the server: the Firebase uid while
/// `public_ids` is off for the caller, the public id once it is on. The app
/// never derives one from the signed-in Firebase user. The only "my id in API
/// terms" is [myUserId].
extension MyUserId on OnboardingState {
  /// The caller's own user id exactly as the last `GetMe` sent it, or null
  /// when it is not known (fail safe: "is me" is then false everywhere):
  /// - no profile yet, or only the cached profile of a warm start is showing
  ///   ([OnboardingState.flagsPending]: it may be of the other id kind);
  /// - the id is empty or the tombstone.
  /// Never falls back to the Firebase uid.
  String? get myUserId {
    final id = profile?.userId;
    if (id == null || id.isEmpty || flagsPending || isUnavailableUserId(id)) {
      return null;
    }
    return id;
  }
}
