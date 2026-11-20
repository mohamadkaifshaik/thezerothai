// Every user-visible string of the encrypted-messaging screens (Plan 5b). Text is quoted from the plan's Copy
// section; fixed strings come from the addendum, the spec or the contract and are never reworded. Nothing here
// claims more than the design allows.

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
