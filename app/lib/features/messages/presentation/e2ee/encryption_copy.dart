// Every user-visible string of the encrypted-messaging screens (Plan 5b). Text is quoted from the plan's Copy
// section; fixed strings come from the addendum, the spec or the contract and are never reworded. Nothing here
// claims more than the design allows.

import '../../domain/e2ee/encrypted_messaging.dart' show UnsentDiscard;

// ---------------------------------------------------------------------------------------------------------------
// Notes and help
// ---------------------------------------------------------------------------------------------------------------

/// Note of a conversation that is end-to-end encrypted.
const kEncryptedNoteText =
    'Messages in this conversation are end-to-end encrypted.';

/// Note over the inbox when only some conversations are encrypted.
const kEncryptionMixedNoteText =
    'Some conversations are end-to-end encrypted. Each one says so at the top.';

/// Settings entry label.
const kEncryptionEntryLabel = 'Encryption';

/// Label of the help entry.
const kEncryptionHowItWorksLabel = 'How this works';

/// Help, line 1.
const kEncryptionHelp1 =
    'Messages are encrypted on your device and decrypted only on the devices in '
    'this conversation.';

/// Help, line 2: the honest limit.
const kEncryptionHelp2 =
    'Until you and the other person compare security codes, and each of you '
    'recognises every device listed as your own, a compromised server could add '
    'a device or force a reset.';

/// Help, line 3: what a code check covers.
const kEncryptionHelp3 =
    'Comparing codes checks this moment only. If a device changes later, the '
    'code changes, and a line is shown in the conversation on devices that are '
    "already part of it. You don't see these lines in a request you haven't "
    'accepted.';

/// Help, web builds only.
const kEncryptionHelpWeb =
    "On the web, the app's code comes from our servers each time you open it, "
    'so this protection depends on our servers not being compromised.';

/// Help, line 4: storage.
const kEncryptionHelp4 =
    'Messages are stored only on your devices. A new device starts with no '
    'history. If you lose every device, the messages are gone.';

/// Help, line 5: a removed or lost device.
const kEncryptionHelp5 =
    'A device that is removed or lost can keep reading and sending until each '
    'conversation has been updated, and it keeps what it already had. Updating '
    "can take days, and it doesn't happen in conversations with someone you've "
    "blocked or in requests that haven't been accepted.";

/// Help, line 6: reporting.
const kEncryptionHelp6 =
    'If you report a message, that message is sent to our reviewers.';

/// Help, line 7: what the server still sees.
const kEncryptionHelp7 =
    'We can still see who you message, when, and the rough size of each '
    'message. If you share a post, we can tell which post.';

/// Help, line 8: what the server can do.
const kEncryptionHelp8 =
    'The server can delay, drop or reorder messages, and it or the other '
    'person can stop a conversation from sending.';

/// Help, line 9: the flag turned off for the account.
const kEncryptionHelp9 =
    "If encrypted messages are turned off for your account, you keep your "
    "conversations but can't add devices or reset encryption.";

/// Help, line 10 (security read M6): local copies can be removed.
const kEncryptionHelp10 =
    'Messages can be removed from your devices when you delete a conversation '
    'on another device or when a message is taken down.';

/// Note on web builds.
const kWebStorageNote =
    "Clearing this browser's data deletes the encrypted messages stored here. "
    'Treat the web as a second device, not the place to keep your history.';

/// The help lines of Settings > Encrypted messages > About, in order. [web]
/// adds [kEncryptionHelpWeb] and [kWebStorageNote]. Also the About page's text
/// while the claim is not live (a typed URL), so that page never says more
/// than this list.
List<String> encryptionHelpLines({required bool web}) => [
  kEncryptionHelp1,
  kEncryptionHelp2,
  kEncryptionHelp3,
  if (web) kEncryptionHelpWeb,
  kEncryptionHelp4,
  kEncryptionHelp5,
  kEncryptionHelp6,
  kEncryptionHelp7,
  kEncryptionHelp8,
  kEncryptionHelp9,
  kEncryptionHelp10,
  if (web) kWebStorageNote,
];

// ---------------------------------------------------------------------------------------------------------------
// The claim (Plan 6 Task 4.A, §4.2)
// ---------------------------------------------------------------------------------------------------------------
//
// COUNSEL DRAFT: quoted verbatim from Plan 6 §4.2; counsel and the owner may
// change the words, so they live here only. Shown only while `claimVisible`
// holds (`claim_live` and `e2ee_required` in enabled_features, a capable
// build, a vault that opens); the headline is never drawn without
// [kClaimCoversLink] beside it. The words of §4.5 must never appear in lib/
// (test/guards/claim_copy_guard_test.dart).

/// The headline (Messages inbox and Settings > Encrypted messages > About).
const kClaimHeadline = 'We cannot read your messages.';

/// The link that always sits next to [kClaimHeadline]; opens the About page.
const kClaimCoversLink = 'What this covers';

/// Title of the About page.
const kClaimAboutTitle = 'About encrypted messages';

/// The About page's lead, under [kClaimHeadline].
const kClaimAboutLead =
    'Direct messages on Android and on the web are end-to-end encrypted. Each '
    'message is locked on your device and can only be unlocked on the devices '
    'in that conversation. Our servers pass the locked message along and '
    'cannot open it.';

/// Section header: what the claim covers.
const kClaimCoversHeader = 'What this covers';

/// The items under [kClaimCoversHeader].
///
/// Fix round 1 (security H1, controller ruling; flagged to the owner and
/// counsel): §4.2 also listed "which post you share in one", but
/// `CheckPostShare` tells the server the post id before an encrypted share
/// (as [kEncryptionHelp7] says on the same screen), so that is listed under
/// [kClaimNotCoveredHeader] instead.
const kClaimCoversItems = <String>['The text of your direct messages.'];

/// Section header: what the claim does not cover.
const kClaimNotCoveredHeader = "What this doesn't cover";

/// One item of [kClaimNotCoveredHeader]: a bold [title] and its [body].
typedef ClaimItem = ({String title, String body});

/// The items under [kClaimNotCoveredHeader] before the lost-device item.
const kClaimNotCoveredItems = <ClaimItem>[
  (
    title: 'Who you message and when.',
    body:
        'We can see who you talk to, when, how often, and the rough size of '
        'each message. If you open a post someone shared with you, we can tell '
        'which post you opened.',
  ),
  // Fix round 1 (security H1): the share check sees the post id.
  (
    title: 'Which post you share.',
    body:
        'When you share a post in a message, we check that it can be shared, '
        'so we can tell which post you shared.',
  ),
  (
    title: 'Notifications.',
    body:
        'A notification says only that you have a new message. It never '
        "contains the sender or the text. It is delivered through Google's or "
        "your browser's push service.",
  ),
  (
    title: 'Reports.',
    body:
        'If you report a message, you send that message to us. Our reviewers '
        'can read it, and we keep it with the report for up to 180 days, even '
        'if an account is deleted.',
  ),
  (
    title: 'The web.',
    body:
        "On the web, the app's code comes from our servers each time you open "
        'it. So on the web, this protection depends on our servers not being '
        'compromised.',
  ),
  // Fix round 1 (security L4): names the app, not the devices.
  (
    title: 'The iPhone and iPad app.',
    body: "Encrypted messages aren't available there yet.",
  ),
  (
    title: 'Your devices.',
    body:
        'Messages are stored only on your devices. Anyone who can use your '
        'unlocked phone, or your signed-in browser, can read them. If you lose '
        'every device, the messages are gone.',
  ),
];

/// The lost-device item of [kClaimNotCoveredHeader] (its title).
const kClaimLostDeviceItemTitle = 'A lost or stolen device.';

/// Its body with `device_sign_out` on: points to [kClaimLostDeviceHeader].
const kClaimLostDeviceItemBody = 'See "If a device is lost or stolen" below.';

/// With `device_sign_out` off (Plan 6 §5.3: no stolen-device statement
/// then; the existing [kRemovalsNote] meaning): drawn in the lost-device
/// item's slot as an UNTITLED line, followed by [kRemovalsNote] (fix round 1,
/// code review B1: no "stolen" anywhere on the page then).
const kClaimLostDeviceItemBodyNoSignOut =
    'Remove a lost device in Settings. Until each conversation has been '
    'updated, that device may still receive and send messages.';

/// The items after the lost-device item.
const kClaimNotCoveredItemsAfter = <ClaimItem>[
  (
    title: "Checking who you're talking to.",
    body:
        'Until you and the other person compare security codes, and each of you '
        'recognises every device listed as your own, a compromised server could '
        'add a device to your conversation or reset it. A comparison checks '
        'that moment only.',
  ),
  (
    title: 'Delivery.',
    body:
        'We can delay, drop or reorder messages, and we or the other person can '
        'stop a conversation from sending. Messages can also be removed from '
        'your devices when you delete a conversation on another device or when '
        'a message is taken down.',
  ),
];

/// Section header shown only with `device_sign_out` on (Plan 6 §5.3).
const kClaimLostDeviceHeader = 'If a device is lost or stolen';

/// The section's text, only with `device_sign_out` on (Plan 6 §5.3).
const kClaimLostDeviceBody =
    "Remove it in Settings → Encrypted messages. You'll be asked to sign in "
    'again, and your other devices will be signed out. Until you remove it, '
    'anyone using that device can read and send your messages. After you '
    "remove it, it can't sign back in without your password, but it keeps the "
    'messages it already had, and it may still get new messages in some '
    'conversations until each one has been updated. That can take days, and it '
    "doesn't happen in conversations with someone you've blocked or in "
    "requests you haven't accepted. If someone may know your password, change "
    'it.';

// ---------------------------------------------------------------------------------------------------------------
// Thread lines, placeholders and send states
// ---------------------------------------------------------------------------------------------------------------

/// System line (fixed, R6).
const kLineEncryptionReset = 'Encryption was reset';

/// System line: the other person added a device.
String lineDeviceAddedTheirs(String name) => name.isEmpty
    ? 'They have a new device in this conversation'
    : '$name has a new device in this conversation';

/// System line: the other person's device was removed.
String lineDeviceRemovedTheirs(String name) => name.isEmpty
    ? 'One of their devices was removed from this conversation'
    : 'A device of $name was removed from this conversation';

/// System line: one of the user's devices was removed.
const kLineDeviceRemovedMine =
    'One of your devices was removed from this conversation';

/// System line (fixed, M2).
const kLineUnknownDevice = 'An unknown device was added';

/// System line: an unknown device left.
const kLineUnknownDeviceRemoved = 'An unknown device was removed';

/// Alert title when a device is added to the user's own account.
const kOwnDeviceAlertTitle = 'A new device was added to your account';

/// Alert body for the same.
const kOwnDeviceAlertBody =
    "It can read and send messages in this conversation. If you don't "
    'recognise it, remove it.';

/// Alert action for the same.
const kOwnDeviceAlertAction = 'Check your devices';

/// Placeholder (fixed, spec 7.5).
const kCouldNotDecryptText = "Couldn't decrypt this message";

/// Placeholder of a message this device still holds and will try to decrypt
/// again (owner-approved 2026-11-21). Promises no success and no time.
const kWaitingToDecryptText = 'Waiting to decrypt this message';

/// Placeholder (fixed).
const kCouldNotVerifyText = "This message couldn't be verified";

/// Placeholder for a message that cannot be drawn.
const kCannotDisplayText = "This message can't be displayed";

/// Inbox and notification stand-in.
const kEncryptedPlaceholderText = 'Encrypted message';

/// Separator above the first encrypted row (security read M12).
const kNotEncryptedAboveText =
    'Messages above this line are not end-to-end encrypted';

/// Link of a shared post.
const kViewSharedPostLabel = 'View post';

/// Status of an own row waiting to send.
const kOutgoingWaitingText = 'Waiting to send';

/// Status of an own row that cannot be sent now.
const kOutgoingNotSentBlockedText = 'Not sent';

/// Status of an own row at the per-target daily cap.
const kOutgoingTryTomorrowText = 'Not sent. Try again tomorrow';

// Plan 5a Task 13b (gate item 22): the starting refusals and failed rows
// with no typed error reach the screens as a `SendProblem` and reuse the
// lines above. `LookupFailed`, `StartUnavailable`, `InitDiscarded` and a
// failed row with no typed error (after a restart only its stored name is
// left) are `retryable` ("Not sent. Tap to retry"); `PeerHasNoDevice`, and a
// peer whose listed devices are all inactive, are `peerHasNoDevice`
// (kStatePeerNoDeviceText); a device whose vault marker cannot be read is a
// `retryable` refusal, "try again", never `blocked` (F5).

/// Stopping the first message of a new encrypted conversation (the
/// starter's `discardInit`, gate item 23): the server may already hold it.
/// Never promises delivery (preflag review I-1: it may stay held for good).
const kInitDiscardHeldText =
    "This message can't be stopped now. It may still be delivered.";

/// The same, when what the server holds could not be checked.
const kInitDiscardNotDecidedText =
    "Couldn't check this message right now. Try again.";

/// The same, stopped. Never says the conversation is gone (preflag fix 3,
/// L-1), and the message may still wait and go out once the conversation
/// is ready (fix round 2, ruling 7: another device's start came first).
const kInitDiscardedText =
    'Stopped. This message may wait and go out once the conversation is '
    'ready, or you can try again.';

/// An own unsent row that no longer opens on this device (the port's
/// `EncryptedThread.unreadableUnsent`, gate item 18), with its delete
/// action (`deleteUnreadableUnsent`). Controller copy of 2026-11-23; the
/// owner may edit it.
const kUnsentUnreadableText =
    "This message couldn't be read on this device, so it won't be sent. "
    'Delete it?';

/// The action under an own message that has not been delivered (the port's
/// `discardUnsent`). NEW COPY (Plan 5b Task 14b): the owner may edit it.
const kUnsentDiscardAction = 'Discard';

/// The action of an unreadable unsent row (the port's
/// `deleteUnreadableUnsent`); the row's text ends "Delete it?". NEW COPY
/// (Plan 5b Task 14b): the owner may edit it.
const kUnsentUnreadableDeleteAction = 'Delete';

/// After an unreadable unsent row is deleted while other own messages are
/// still waiting: the port does not send them by itself, so the user is
/// offered one try. NEW COPY (Plan 5b Task 14b): the owner may edit it.
const kUnsentDeletedWaitingText =
    'Deleted. Your other messages are still waiting.';

/// The action of the line above (the port's `retrySend` of the oldest waiting
/// row). NEW COPY (Plan 5b Task 14b): the owner may edit it.
const kUnsentRetryWaitingAction = 'Try sending';

/// The line for the port's `discardUnsent` answer (port additions, gate items
/// 14, 15, 23); null where the thread itself shows the result (the row is
/// gone, shown delivered, or was not there).
String? unsentDiscardText(UnsentDiscard result) => switch (result) {
  UnsentDiscard.stopped => kInitDiscardedText,
  UnsentDiscard.held => kInitDiscardHeldText,
  UnsentDiscard.notDecided => kInitDiscardNotDecidedText,
  UnsentDiscard.discarded ||
  UnsentDiscard.delivered ||
  UnsentDiscard.none => null,
};

// ---------------------------------------------------------------------------------------------------------------
// Conversation states
// ---------------------------------------------------------------------------------------------------------------

/// Waiting state title (MP:186).
const kStateWaitingTitle = 'Waiting for this device to be added';

/// Waiting state body.
const kStateWaitingBody =
    'You can read and send here after one of your other devices, or the other '
    'person, opens the app.';

/// Stuck state title.
const kStateStuckTitle = "This conversation can't continue on this device";

/// Stuck state body when a reset is offered.
const kStateStuckBodyCanReset =
    'Resetting encryption starts it again with the devices available now.';

/// Stuck state body when no reset is offered.
const kStateStuckBodyNoReset =
    "It can't be repaired from this device right now. You can still read the "
    'messages already here.';

/// Unknown-device state body (its title is [kLineUnknownDevice]).
const kStateUnknownDeviceBody =
    "Messages aren't sent while it is in this conversation. This device tries "
    "to remove it if it can't be matched to you or the other person.";

/// `changesBlocked` title when the composer cannot send.
const kStateBlockedTitle =
    "Messages can't be sent in this conversation right now";

/// `changesBlocked` title when the composer works (copy point of 2026-11-19, re-read N4).
const kStateBlockedCanSendTitle =
    'Device changes in this conversation are paused until the next day';

/// `changesBlocked` body when the composer works (re-read N4).
const kStateBlockedCanSendBody =
    'Device changes here keep being undone, so this device has paused them '
    'until the next day. A device you removed may still get messages here until '
    'then. You can wait, block this person, or reset encryption.';

/// `changesBlocked` body, reset offered.
const kStateBlockedBodyCanReset =
    'An unknown device keeps being added. You can wait, block this person, or '
    'reset encryption.';

/// `changesBlocked` body, no reset.
const kStateBlockedBodyNoReset =
    'An unknown device keeps being added. You can wait or block this person.';

/// Device list unreadable, title (fixed, M2).
const kStateListUnverifiableTitle = "The device list can't be checked";

/// Device list unreadable, body.
const kStateListUnverifiableBody =
    'You can keep messaging the devices already in this conversation. There is '
    'no security code until it can be checked.';

/// The peer cannot receive encrypted messages (fixed, R11). Shown only when the conversation is already encrypted,
/// or the peer's device list is non-empty with no usable key package.
const kStatePeerNoDeviceText = "They can't receive encrypted messages yet";

// Plan 6 Task 1.B: `e2ee_required` (every new send is encrypted). NEW COPY:
// the owner may edit every string of this block.

/// A send refused because the peer has no device that can receive encrypted
/// messages (`SendProblem.peerHasNoDevice`): title. Owner may edit.
const kPeerCannotReceiveYetTitle = "They can't receive encrypted messages yet";

/// The same: body. Owner may edit.
const kPeerCannotReceiveYetBody =
    "They need to update the app and open it. Your message hasn't been sent.";

/// Shown instead of `kMessagesNotEncryptedText` in a thread that is not
/// encrypted yet while `e2ee_required` is on. Owner may edit.
///
/// Amends the plan's Task 1.B wording ("New messages here will be end-to-end
/// encrypted once both of you are on the latest app."), security review L4:
/// the messages already in the thread stay readable by the operator, so the
/// note keeps saying so before it says what changes for new ones.
const kRequiredNoteText =
    'Earlier messages here are not end-to-end encrypted. New messages will be '
    'once both of you are on the latest app.';

/// [kRequiredNoteText] for a draft thread, which has no earlier messages to
/// disclose (code review Minor 1): the plan's Task 1.B wording. Owner may
/// edit.
const kRequiredDraftNoteText =
    'New messages here will be end-to-end encrypted once both of you are on '
    'the latest app.';

/// `e2ee_required` is on but this device may not start encryption (`e2ee_dm`
/// off: the server's required flag is not gated by it, ruling of 2026-11-25):
/// a conversation that is not encrypted yet gets no send at all
/// (`SendProblem.requiredUnavailable`). Title. Owner may edit.
const kRequiredUnavailableTitle = 'Messages are being upgraded';

/// The same: body. Owner may edit.
const kRequiredUnavailableBody =
    'Sending is paused while encrypted messaging finishes rolling out. Your '
    "message hasn't been sent.";

/// `e2ee_required` is on and this device cannot hold a vault
/// (`SendProblem.requiredNotOnThisDevice`, security review L5): the body
/// under [kNotOnThisDeviceText], the existing line for such a device. Owner
/// may edit.
const kRequiredNotOnThisDeviceBody = "Your message hasn't been sent.";

/// This device has no vault (fixed, R11).
const kNotOnThisDeviceText =
    "Encrypted messages aren't available on this device yet.";

/// Conversation reset: menu action.
const kConversationResetAction = 'Reset encryption';

/// Conversation reset: dialog title.
const kConversationResetTitle = 'Reset encryption for this conversation?';

/// Conversation reset: dialog message.
const kConversationResetMessage =
    'This starts the encryption again with the devices available now. Messages '
    'already on your devices stay. Everyone sees "Encryption was reset" and the '
    'security code changes.';

/// Conversation reset: confirm button.
const kConversationResetConfirm = 'Reset';

/// Conversation reset: failure.
const kConversationResetFailed = "Couldn't reset encryption. Please try again.";

/// Conversation reset: refused, the request is not accepted.
const kConversationResetNotAcceptedText =
    'You can reset encryption once the request is accepted.';

// ---------------------------------------------------------------------------------------------------------------
// Device status surface
// ---------------------------------------------------------------------------------------------------------------

/// Status while the vault opens.
const kStatusOpeningText = 'Opening encrypted messages…';

/// Key lost, title.
const kStatusKeyLostTitle = "Encrypted messages can't be opened on this device";

/// Key lost, body.
const kStatusKeyLostBody =
    "This device's key for them wasn't found. Nothing has been deleted. If it "
    'is still missing the next time you open the app, at least an hour from '
    'now, the encrypted messages on this device are deleted and the device is '
    'set up again.';

/// Key lost, body when the device cannot be set up again.
const kStatusKeyLostBodyNoRestart =
    "This device's key for them wasn't found. Nothing has been deleted. If it "
    'is still missing the next time you open the app, at least an hour from '
    'now, the encrypted messages on this device are deleted. You will not be '
    'able to use encrypted messages on this device afterwards.';

/// Browser storage changed, title.
const kStatusStorageChangedTitle =
    "Your encrypted messages are in browser storage this page can't use right "
    'now';

/// Browser storage changed, body.
const kStatusStorageChangedBody =
    'Nothing has been deleted. They may open again if you open the app the way '
    'you did before. If not, you can reset encrypted messages in this browser, '
    'which deletes them here.';

/// Vault unavailable, title.
const kStatusUnavailableTitle = "Encrypted messages can't be opened right now";

/// Vault unavailable, body (re-read N2: states its way out).
const kStatusUnavailableBody =
    'Nothing has been deleted. Tap Try again, or come back to the app later: it '
    "tries again each time. You don't need to sign out.";

/// Vault unavailable for long, body (second re-read R4): the last sentence names sign-out and its cost.
const kStatusUnavailableLongBody =
    'Nothing has been deleted. Tap Try again, or come back to the app later: it '
    "tries again each time. If they still don't open, signing out lets you send "
    'messages again, but it deletes the encrypted messages on this device.';

/// A send refused because the vault on this device is not open (re-read N2).
const kSendWaitsForVaultText =
    "Messages can't be sent until encrypted messages open on this device.";

/// Held by another tab, title.
const kStatusHeldElsewhereTitle = 'Encrypted messages are open in another tab';

/// Held by another tab, body.
const kStatusHeldElsewhereBody =
    'Use that tab, or close it and try again here.';

/// Engine unavailable, title (R16).
const kStatusEngineUnavailableTitle = 'Encrypted messaging unavailable';

/// Engine unavailable, body.
const kStatusEngineUnavailableBody =
    'It tries again the next time you come back to the app.';

/// Device limit, title.
const kStatusDeviceLimitTitle = 'Device limit reached';

/// Device limit, body.
const kStatusDeviceLimitBody =
    'You can use encrypted messages on up to 5 devices. Remove one to use them '
    'on this device.';

/// History lost, title.
const kStatusHistoryLostTitle =
    'Earlier encrypted messages are no longer on this device';

/// History lost, body.
const kStatusHistoryLostBody =
    'Its encrypted storage had to be set up again. New messages are kept from '
    'now on.';

/// Removed device, title (fixed, R17).
const kStatusRemovedTitle = 'This device was removed';

/// Removed device, body.
const kStatusRemovedBody =
    'It was removed from your encrypted messages. The messages already here '
    'are kept. Set this device up again, or sign out.';

/// Removed device, body when it cannot be set up again.
const kStatusRemovedBodyNoRestart =
    'It was removed from your encrypted messages. The messages already here '
    "are kept. It can't be set up again right now.";

/// Setup failed.
const kStatusSetupFailedText =
    "Couldn't finish setting up encrypted messages on this device. It will try "
    'again.';

/// Unusable device record, title.
const kStatusDeviceRecordTitle =
    'Encrypted messages on this device need a reset';

/// Unusable device record, body.
const kStatusDeviceRecordBody =
    "This device's encryption record can't be used. Resetting deletes the "
    'encrypted messages stored here and sets the device up again.';

/// Dormant device.
const kStatusDormantText =
    "You can still read and send in your encrypted conversations on this "
    "device. You can't add devices or reset encryption right now.";

/// Offline.
const kStatusOfflineText =
    "You're offline. Showing the encrypted messages saved on this device.";

/// Status button.
const kStatusTryAgain = 'Try again';

/// Status button.
const kStatusReset = 'Reset…';

/// Status button.
const kStatusManageDevices = 'Manage devices';

/// Status button.
const kStatusDismiss = 'Dismiss';

/// Status button.
const kStatusDetails = 'Details';

/// Removed card: check again (security read M5).
const kStatusCheckAgain = 'Check again';

/// Set up again: action.
const kSetUpAgainAction = 'Set up again';

/// Set up again: dialog title.
const kSetUpAgainTitle = 'Set up this device again?';

/// Set up again: dialog message.
const kSetUpAgainMessage =
    'It gets a new identity and waits to be added to each conversation. The '
    'messages already here are kept.';

// ---------------------------------------------------------------------------------------------------------------
// Settings: encrypted messages and devices
// ---------------------------------------------------------------------------------------------------------------

/// Settings screen title.
const kEncryptionSettingsTitle = 'Encrypted messages';

/// Settings unavailable, title.
const kEncryptionSettingsUnavailableTitle =
    "Encrypted messages aren't available";

/// Settings unavailable, body.
const kEncryptionSettingsUnavailableBody =
    'There is nothing to manage here right now.';

/// Section header.
const kDevicesThisHeader = 'This device';

/// Section header.
const kDevicesOthersHeader = 'Your other devices';

/// Section header.
const kDevicesAboutHeader = 'About';

/// Row title of this device.
const kDeviceThisTitle = 'This device';

/// This device has no registration.
const kDeviceNotSetUp = 'Not set up';

/// Row title with the date the device was added.
String deviceAddedTitle(String date) => 'Device added $date';

/// Row subtitle with the date the device was added.
String deviceAddedSubtitle(String date) => 'Added $date';

/// Row line with the last activity ([relative] is made by `formatRelativeTimeSpoken`).
String deviceLastActive(String relative) => 'Last active $relative';

/// Inactive device marker.
const kDeviceInactive = 'Not used for 30 days';

/// Pill of a device in conversations but not in the list.
const kDeviceUnlistedPill = 'Not in your device list';

/// Note for the same.
const kDeviceUnlistedNote =
    'This device is in your conversations but not in your device list. Your '
    'devices try to remove it from each conversation as they update it.';

/// Pill of a device in the list but in no conversation.
const kDeviceNotJoinedPill = 'Not in your conversations yet';

/// Row title of a device with no date.
const kDeviceUnknownDate = 'Device with no date';

/// Count of devices.
String devicesCount(int n) => '$n of 5 devices';

/// No other devices.
const kDevicesNoOthers = 'No other devices';

/// Loading.
const kDevicesLoading = 'Loading your devices';

/// Load failure.
const kDevicesLoadFailed = "Couldn't load your device list.";

/// Offline note.
const kDevicesOfflineNote =
    "You're offline. Showing the devices in your conversations on this device.";

/// Remove: button.
const kDeviceRemoveAction = 'Remove';

/// Remove: dialog title.
const kDeviceRemoveTitle = 'Remove this device?';

/// Remove: dialog message (second sentence fixed, R17).
const kDeviceRemoveMessage =
    'It keeps the messages it already has. Until each conversation has been '
    'updated, that device may still receive and send messages.';

/// Remove: done.
const kDeviceRemovedText = 'Device removed';

/// Remove: failure (security read M11).
const kDeviceRemoveFailedText =
    "Couldn't remove the device. It can still read and send in your encrypted "
    'conversations. In a conversation, you can still block the person or reset '
    'encryption.';

// Device removal copy (lane D PR 4, removal design §4; the owner may edit).
// The title naming the device, the sign-out message, the keyed results and
// the footer show only with `device_sign_out` on (a REMOTE removal then also
// signs out every other session); the "Confirm it's you" texts show on every
// removal (the server wants a recent sign-in for every REMOTE removal).

/// Remove: dialog title naming the device by its added date (the only name a
/// device has), or this device's generic title without one.
String deviceRemoveTitleNamed(String? date) =>
    date == null ? kDeviceRemoveTitle : 'Remove the device added $date?';

/// Remove: dialog message. The design's sentences, then R17's fixed
/// sentence (the queue needs time to update each conversation).
///
/// Remover copy (controller ruling 2026-11-27, H1 options a + b): since H1 a
/// removal that signs the other sessions out also revokes this device's
/// sign-in, so the warning says this device too has to sign in again.
const kDeviceRemoveSignOutMessage =
    'It will stop receiving your encrypted messages. You\'ll also be signed '
    'out on all your devices, this one too, and you\'ll need to sign in '
    'again.\n\n'
    'Until each conversation has been updated, that device may still receive '
    'and send messages.';

/// The re-sign-in before a removal: title.
const kConfirmItsYouTitle = "Confirm it's you";

/// The re-sign-in before a removal: body.
const kConfirmItsYouBody = 'Sign in again to remove this device.';

/// The re-sign-in before a removal: the button that opens the sign-in.
const kConfirmItsYouAction = 'Continue';

/// The removal missed the sign-in window and waits: the body of the same
/// prompt, asked again.
const kConfirmItsYouAgainBody =
    'Your sign-in has expired. Sign in again to finish removing this device.';

/// The removal still missed the sign-in window after the second "Confirm
/// it's you" (fix round ruling 5, N5).
const kDeviceRemoveReauthFailedText =
    "Couldn't confirm it's you, so the device wasn't removed. Try again.";

// Parked device removals (Plan 5b Task 14b item 5; NEW COPY, the owner may
// edit it): a removal the server answered REAUTH_REQUIRED waits for the user
// to sign in again. Shown on the Settings page whatever device_sign_out says.

/// The banner for [count] parked removals; its action is [kConfirmItsYouTitle].
String parkedRemovalsText(int count) => count == 1
    ? "A device removal is waiting. Confirm it's you to finish it."
    : "$count device removals are waiting. Confirm it's you to finish them.";

/// The banner's second action: give the removals up. The device stays.
const kParkedRemovalDropAction = "Don't remove";

/// The confirmation of [kParkedRemovalDropAction]: title for [count] removals.
String parkedRemovalDropTitle(int count) =>
    count == 1 ? "Don't remove this device?" : "Don't remove these devices?";

/// The same: the message says the device stays.
String parkedRemovalDropMessage(int count) => count == 1
    ? 'The device stays. It can still read and send in your encrypted '
          'conversations.'
    : 'The devices stay. They can still read and send in your encrypted '
          'conversations.';

/// Removed, `other_sessions_ended` false. Plan 5a Task 13b (controller
/// ruling 3, 2026-11-23): no "change your password too". Why: the #1097
/// audit (H1) found that a password change alone may not sign a thief's
/// device out, so that advice could give false comfort; the line states only
/// what is true. Shown only with `device_sign_out` on (off today); the owner
/// may reword it.
///
/// 13b-i review I2 (controller decision, 2026-11-23): `false` means the cut
/// was NOT made (keys.proto `other_sessions_ended`), so the removed device
/// itself can stay signed in as well; the line never implies that removing
/// a device signs it out. The two-seat security seat checks the wording.
///
/// Branch audit L3 (controller wording, 2026-11-23; the owner may edit):
/// "sign out on it" is a step a lost or stolen device's owner cannot take,
/// and "Removed." alone could read as cut off while the removal commits
/// are still pending (`removalsPending`). The line is honest about both:
/// the device stops getting new messages only once the removal finishes,
/// and it was not signed out.
const kDeviceRemovedSessionsKept =
    "Removed. It won't get new encrypted messages once the removal "
    "finishes. That device wasn't signed out of your account.";

/// Removed, `other_sessions_ended` true, and this device's sign-in was NOT
/// revoked (remover copy fix round 1, R2: the forced-refresh probe found it
/// alive, e.g. a removal replayed after a re-sign-in). The snackbar.
const kDeviceRemovedSessionsEnded =
    'Removed. Your other devices were signed out.';

/// Removed, `other_sessions_ended` true, and the probe found this device's
/// sign-in revoked too, or could not tell (remover copy, controller ruling
/// 2026-11-27, H1 options a + b; fix round 1, n1 wording). The body of
/// [kDeviceRemovedSignInAgainTitle]'s dialog, never a snackbar; the app then
/// signs this device out itself instead of failing later at a token refresh.
/// The owner may reword it.
const kDeviceRemovedThisDeviceToo =
    'Removed. This device was signed out too. Sign in again to keep going.';

/// The title of the dialog that shows [kDeviceRemovedThisDeviceToo].
const kDeviceRemovedSignInAgainTitle = 'All your devices were signed out';

/// Its one action. Closing the dialog with it, or with the system back, signs
/// this device out. The barrier does not close it, and neither does Escape
/// (`barrierDismissible: false`; fix round 1, m1).
const kDeviceRemovedSignInAgainAction = 'Sign in again';

/// The sign-in screens' notice after THIS device removed another one and so
/// signed itself out (`AuthState.signedOutAfterOwnRemoval`). Different from
/// the notice the removed device gets (`SessionEndedException.userMessage`).
const kSignedOutAfterOwnRemovalNotice =
    'You removed a device, so every device was signed out. Sign in again.';

/// The removed result: keyed on `other_sessions_ended` when it is known;
/// null (the port does not pass it on yet, Task 13-ii) keeps the plain text.
String deviceRemovedText({bool? otherSessionsEnded}) =>
    switch (otherSessionsEnded) {
      true => kDeviceRemovedSessionsEnded,
      false => kDeviceRemovedSessionsKept,
      null => kDeviceRemovedText,
    };

/// Device list footer.
const kDevicesUnrecognisedFooter = "Don't recognise a device? Remove it.";

/// Conversations still to update.
String removalsPendingText(int n) => n == 1
    ? '1 conversation still to update'
    : '$n conversations still to update';

/// Note under the pending count.
const kRemovalsNote =
    'With many conversations this can take more than a day. Conversations with '
    "someone you've blocked, and requests that haven't been accepted, are not "
    'updated.';

// ---------------------------------------------------------------------------------------------------------------
// Reset encrypted messages (R15)
// ---------------------------------------------------------------------------------------------------------------

/// Screen title.
const kResetTitle = 'Reset encrypted messages';

/// Lead.
const kResetLead =
    'This deletes the encrypted messages and keys stored on this device. It '
    'cannot be undone.';

/// Point 1.
const kResetPoint1 = 'Messages that are only on this device are gone for good.';

/// Point 2.
const kResetPoint2 = 'Your other devices keep their messages.';

/// Point 3, only when the device may start again.
const kResetPoint3 =
    'This device is then set up as a new device and waits to be added to each '
    'conversation.';

/// Point 4.
const kResetPoint4 =
    "If this device can't reach the server, it may stay in your device list "
    'until you remove it from another device.';

/// Warning when the device cannot start again (fixed, R15).
const kResetNoRestartWarning =
    'You will not be able to use encrypted messages on this device afterwards';

/// Action.
const kResetAction = 'Reset encrypted messages';

/// First confirmation, title.
const kResetConfirmTitle = 'Delete encrypted messages on this device?';

/// First confirmation, message.
const kResetConfirmMessage = 'This cannot be undone.';

/// First confirmation, button.
const kResetConfirmLabel = 'Delete and reset';

/// Second confirmation, title (its message is [kResetNoRestartWarning] and a full stop).
const kResetSecondTitle = 'Are you sure?';

/// Second confirmation, button.
const kResetSecondLabel = 'Delete anyway';

/// Done.
const kResetDoneText = 'Encrypted messages were reset on this device';

/// Failure.
const kResetFailedText = "Couldn't finish the reset. Try again.";

/// Nothing to reset, title.
const kResetNothingTitle = 'Nothing to reset';

/// Nothing to reset, body.
const kResetNothingBody =
    "Encrypted messages on this device don't need a reset.";

// ---------------------------------------------------------------------------------------------------------------
// Security code (R4)
// ---------------------------------------------------------------------------------------------------------------

/// Header.
const kSecurityCodeHeader = 'Security code';

/// Intro, naming the other person.
String securityCodeIntro(String name) => name.isEmpty
    ? 'Compare these numbers with the other person, in person or on a call you '
          'trust.'
    : 'Compare these numbers with $name, in person or on a call you trust.';

/// What a match means.
const kSecurityCodeMeaning =
    'If you both see the same numbers, and each of you recognises every device '
    'listed as your own, there is no hidden device in this conversation right '
    'now.';

/// The limit of a match.
const kSecurityCodeMoment =
    'This checks this moment only. If a device changes later, the code changes.';

/// The user's device count.
String securityCodeMine(int n) => 'Your devices in this conversation: $n';

/// The other person's device count.
String securityCodeTheirs(int n) => 'Their devices in this conversation: $n';

/// No code: unknown device.
const kNoCodeUnknownDevice =
    'No security code right now. An unknown device was added.';

/// No code: the list cannot be checked.
const kNoCodeUnverifiable =
    "No security code right now. The device list can't be checked.";

/// No code: this device is not a member.
const kNoCodeNotAMember =
    'No security code yet. This device is waiting to be added.';

/// No code: a sent request.
const kNoCodeSentRequest =
    'The security code is available after they accept your request.';

/// No code: any other reason.
const kNoCodeUnavailable = 'No security code right now.';

/// Loading.
const kSecurityCodeLoading = 'Loading security code';

/// Failure.
const kSecurityCodeFailed = "Couldn't show the security code.";

/// Spoken label of one group of five digits (1 to 12).
String securityCodeGroupLabel(int i, String digits) =>
    'Group $i of 12: ${digits.split('').join(' ')}';

// ---------------------------------------------------------------------------------------------------------------
// Sign-out, report, search, errors
// ---------------------------------------------------------------------------------------------------------------

/// Sign-out confirmation, title.
const kSignOutVaultTitle = 'Sign out of this device?';

/// Sign-out confirmation, message.
const kSignOutVaultMessage =
    'Signing out deletes the encrypted messages stored on this device. Your '
    'other devices keep theirs.';

/// Sign-out confirmation, button.
const kSignOutVaultLabel = 'Sign out';

/// Report detail for an encrypted message.
const kReportEncryptedDetail =
    'This message is end-to-end encrypted. Reporting sends this one message '
    'from your device to our reviewers so they can read it, and it is kept with '
    'the report. The rest of the conversation is not sent.';

/// Report detail for an unverified message.
const kReportUnverifiedDetail =
    "We couldn't confirm this message is exactly what was sent. The report "
    'says so.';

/// Report not possible any more.
const kReportUnavailableText =
    "This message can't be reported from this device anymore.";

/// Spoken while the reset runs.
const kResetRunningLabel = 'Resetting';

/// Spoken label of a row's Remove button.
String deviceRemoveLabel(String date) =>
    date.isEmpty ? 'Remove device' : 'Remove device added $date';

/// Search subtitle, idle.
const kSearchSavedIdleSubtitle =
    'Searches the messages saved on this device, including encrypted ones.';

/// Search subtitle, empty.
const kSearchSavedEmptySubtitle =
    'Only messages saved on this device are searched.';
