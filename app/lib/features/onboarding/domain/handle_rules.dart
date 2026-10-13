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
