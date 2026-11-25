import '../../../core/app_build.dart';

/// Copy of the "this build is too old for messaging" prompt (plan 6, section
/// 3.2 and Task 3.C). Fixed text: it names no person, conversation or message.

/// Android: the title, and the line under it on Android and the web.
const kUpdateToMessageTitle = 'Update the app to keep messaging';
const kUpdateToMessageBody = "This version can't open encrypted messages.";

/// Android: the button that opens the store listing.
const kUpdateAction = 'Update';

/// Web: a tab opened before a deploy.
const kReloadToMessageTitle = 'A new version is available';
const kReloadToMessageBody = 'Reload to keep messaging.';
const kReloadAction = 'Reload';

/// iOS: no build can do it yet, so there is no action.
const kIosNotYetTitle = "Messages aren't available on iPhone yet";

/// Which of the three looks of the prompt a build shows.
enum MessagingUpdateKind { android, web, ios }

/// The look for the platform word [platform] (`clientPlatformName()`): `web`
/// reloads, `ios` has nothing to update to, everything else (Android, and the
/// desktop dev targets) is "update the app".
MessagingUpdateKind messagingUpdateKindFor([String? platform]) =>
    switch (platform ?? clientPlatformName()) {
      'web' => MessagingUpdateKind.web,
      'ios' => MessagingUpdateKind.ios,
      _ => MessagingUpdateKind.android,
    };

/// The headline of the prompt for [kind].
String messagingUpdateTitle(MessagingUpdateKind kind) => switch (kind) {
  MessagingUpdateKind.android => kUpdateToMessageTitle,
  MessagingUpdateKind.web => kReloadToMessageTitle,
  MessagingUpdateKind.ios => kIosNotYetTitle,
};

/// The line under the headline, or null (iOS has none).
String? messagingUpdateBody(MessagingUpdateKind kind) => switch (kind) {
  MessagingUpdateKind.android => kUpdateToMessageBody,
  MessagingUpdateKind.web => kReloadToMessageBody,
  MessagingUpdateKind.ios => null,
};

/// The one-line text for a snackbar or notice shown mid-session (a floor raised
/// while the app is open): the web says "A new version is available. Reload to
/// keep messaging."; Android and iOS give the headline alone.
String messagingUpdateMessage(MessagingUpdateKind kind) => switch (kind) {
  MessagingUpdateKind.web => '$kReloadToMessageTitle. $kReloadToMessageBody',
  _ => messagingUpdateTitle(kind),
};

/// The button label, or null when the platform has no action.
String? messagingUpdateActionLabel(MessagingUpdateKind kind) => switch (kind) {
  MessagingUpdateKind.android => kUpdateAction,
  MessagingUpdateKind.web => kReloadAction,
  MessagingUpdateKind.ios => null,
};
