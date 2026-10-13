import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;

/// Client mirror of the handle rules in
/// `backend/internal/identity/validate.go`, shared by create-profile
/// (`OnboardingBloc`) and change-handle (`ChangeHandleCubit`). Fast feedback
/// only: `CheckHandleAvailability` / `CreateProfile` / `ChangeHandle` validate
/// again and the server is the source of truth.
///
/// Matches `^[A-Za-z0-9_]{3,15}$`; callers lowercase before validating, so the
/// charset only needs to cover lowercase here.
final kHandlePattern = RegExp(r'^[a-z0-9_]{3,15}$');

/// Mirrors `reservedHandles` (small, rarely-changed list) so the common case
/// of a reserved handle gets an instant message instead of a round trip.
const kReservedHandles = {
  'admin',
  'administrator',
  'api',
  'www',
  'root',
  'dzeroth',
  'support',
  'help',
  'about',
  'settings',
  'null',
  'undefined',
  'moderator',
  'official',
};

const kHandleFormatMessage =
    '3-15 characters: lowercase letters, numbers, underscore.';
const kHandleReservedMessage = 'That handle is reserved.';
const kHandleTakenMessage = 'That handle is taken.';

/// Maps the machine-readable `reason` from `CheckHandleAvailabilityResponse`
/// (`invalid_format`, `reserved`, or "" when merely taken) to user-facing
/// text; never show the raw code in the UI.
String handleUnavailableMessage(String reason) {
  return switch (reason) {
    'invalid_format' => kHandleFormatMessage,
    'reserved' => kHandleReservedMessage,
    _ => kHandleTakenMessage,
  };
}

/// Wait after the last keystroke before asking the server whether a handle is
/// free. One value for create-profile and change-handle: `check_handle_daily`
/// is a real per-user cap, so every probe must be debounced.
const kHandleCheckDebounce = Duration(milliseconds: 300);

/// Where a handle is in the availability check. `unknown` = the probe could
/// not answer (rate limited, offline, server error): the form stays
/// submittable because CreateProfile / ChangeHandle validate again.
enum HandleCheckStatus { idle, checking, available, unavailable, unknown }

/// Why [handle] (already trimmed and lowercased, non-empty) cannot be used
/// according to the local rules (format, then reserved), or null when it
/// passes and the server must be asked. Callers handle the empty string
/// themselves (it resets the field rather than being an error).
String? localHandleIssue(String handle) {
  if (!kHandlePattern.hasMatch(handle)) return kHandleFormatMessage;
  if (kReservedHandles.contains(handle)) return kHandleReservedMessage;
  return null;
}

/// A resolved availability check: the status plus the text to show (empty for
/// `available`).
typedef HandleCheck = ({HandleCheckStatus status, String message});

/// Maps a `CheckHandleAvailability` answer to a [HandleCheck].
HandleCheck handleCheckFromAnswer(
  identity.CheckHandleAvailabilityResponse response,
) {
  if (response.available) {
    return (status: HandleCheckStatus.available, message: '');
  }
  return (
    status: HandleCheckStatus.unavailable,
    message: handleUnavailableMessage(response.reason),
  );
}

/// Maps a failed probe to `unknown` with friendly text. The one policy for
/// every generic error: never show the exception's own message (it can be a
/// raw server string). [saveVerb] finishes "We'll confirm it when you ..."
/// ("save", "continue").
HandleCheck handleCheckFromError(
  AppException error, {
  String saveVerb = 'save',
}) {
  final message = switch (error) {
    RateLimitedException() =>
      "Couldn't check this handle right now. We'll confirm it when you "
          '$saveVerb.',
    NetworkException() =>
      "Couldn't check this handle. We'll confirm it when you $saveVerb.",
    _ => "Couldn't check this handle right now.",
  };
  return (status: HandleCheckStatus.unknown, message: message);
}
