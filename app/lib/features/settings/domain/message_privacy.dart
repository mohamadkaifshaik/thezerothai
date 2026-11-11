/// The server flag (wire name) of the "Read receipts" setting (F3,
/// `FEATURE_READ_RECEIPTS`). Turning receipts ON needs it for the caller;
/// turning them OFF never does (the undo rule).
const kFeatureReadReceipts = 'read_receipts';

/// The server flag (wire name) of the "Who can message you" setting (F9,
/// `FEATURE_DM_POLICY`). Choosing "People you follow" needs it for the
/// caller; going back to "Everyone" never does (the undo rule).
const kFeatureDmPolicy = 'dm_policy';

/// Who may start a direct message with the caller (identity `DmPolicy`).
/// `DM_POLICY_UNSPECIFIED` is the same as [everyone] and is never sent.
enum WhoCanMessage {
  /// Anyone; a sender the caller does not follow arrives as a request.
  everyone('Everyone'),

  /// Only accounts the caller follows.
  following('People you follow');

  const WhoCanMessage(this.label);

  /// The option's label, also the Settings row's subtitle.
  final String label;
}

/// The caller's own message-privacy settings **as the server last confirmed
/// them** (a `GetMe` or `UpdateProfile` answer of this session), never a local
/// guess: the Settings switches show this value, not the one being saved.
class OwnPrivacy {
  const OwnPrivacy({
    required this.userId,
    required this.readReceipts,
    required this.whoCanMessage,
  });

  /// The account these values belong to; a reader compares it with the
  /// signed-in uid, so another account's values are never shown.
  final String userId;
  final bool readReceipts;

  /// Null: a policy this app version does not know (a newer server value,
  /// security review m2). It is never shown as Everyone; Settings selects
  /// nothing and still offers the way back to Everyone.
  final WhoCanMessage? whoCanMessage;

  @override
  bool operator ==(Object other) =>
      other is OwnPrivacy &&
      other.userId == userId &&
      other.readReceipts == readReceipts &&
      other.whoCanMessage == whoCanMessage;

  @override
  int get hashCode => Object.hash(userId, readReceipts, whoCanMessage);

  /// No values: the uid is personal data and stays out of logs.
  @override
  String toString() =>
      'OwnPrivacy(readReceipts: $readReceipts, who: ${whoCanMessage?.name ?? 'unknown'})';
}

/// Whether the "Read receipts" switch shows: with the flag on (and Messages
/// usable), or whatever the flags say while receipts are on, so they can
/// always be turned off (the undo rule). [refused] is a FEATURE_DISABLED
/// answer to turning them on this session.
bool readReceiptsRowVisible({
  required bool flagOn,
  required bool messagingOn,
  required bool value,
  bool refused = false,
}) => value || (flagOn && messagingOn && !refused);

/// Whether the "Who can message you" choice shows: with the flag on (and
/// Messages usable), or whatever the flags say while it is anything but
/// Everyone ("People you follow", or a policy this app does not know), so it
/// can always be set back to Everyone (the undo rule).
bool whoCanMessageRowVisible({
  required bool flagOn,
  required bool messagingOn,
  required WhoCanMessage? value,
  bool refused = false,
}) => value != WhoCanMessage.everyone || (flagOn && messagingOn && !refused);

/// Whether [value] is anything but the defaults (receipts off, Everyone):
/// then the Message settings page stays reachable with its flags off.
bool ownPrivacyIsSet(OwnPrivacy value) =>
    value.readReceipts || value.whoCanMessage != WhoCanMessage.everyone;
