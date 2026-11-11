/// The server flag (wire name) of the push preferences (F6,
/// `FEATURE_NOTIFICATION_PREFS`). `GetNotificationPrefs` and
/// `UpdateNotificationPrefs` also need `notifications`.
const kFeatureNotificationPrefs = 'notification_prefs';

/// One push group of `NotificationPrefs`, in the order Settings lists them.
enum NotificationPrefsGroup {
  plans('Plans', 'Join requests, accepted requests and cancelled plans'),
  mentionsReplies('Mentions and replies', 'Mentions, replies and quotes'),
  likesReposts('Likes and reposts', 'Likes and reposts of your posts'),
  followers('Followers', 'New followers and follow requests'),
  messages('Messages', 'New direct messages');

  const NotificationPrefsGroup(this.label, this.description);

  final String label;
  final String description;
}

/// Push on or off per group, **as the server answered** (Get or Update). A
/// save always sends every group, so it is built from this value and never
/// from defaults (`UpdateNotificationPrefs` is a full replace and a missing
/// group would be off).
class NotificationPushPrefs {
  const NotificationPushPrefs({
    required this.plans,
    required this.mentionsReplies,
    required this.likesReposts,
    required this.followers,
    required this.messages,
  });

  final bool plans;
  final bool mentionsReplies;
  final bool likesReposts;
  final bool followers;
  final bool messages;

  bool isOn(NotificationPrefsGroup group) => switch (group) {
    NotificationPrefsGroup.plans => plans,
    NotificationPrefsGroup.mentionsReplies => mentionsReplies,
    NotificationPrefsGroup.likesReposts => likesReposts,
    NotificationPrefsGroup.followers => followers,
    NotificationPrefsGroup.messages => messages,
  };

  /// These values with [group] set to [on]; every other group unchanged.
  NotificationPushPrefs withGroup(NotificationPrefsGroup group, bool on) =>
      NotificationPushPrefs(
        plans: group == NotificationPrefsGroup.plans ? on : plans,
        mentionsReplies: group == NotificationPrefsGroup.mentionsReplies
            ? on
            : mentionsReplies,
        likesReposts: group == NotificationPrefsGroup.likesReposts
            ? on
            : likesReposts,
        followers: group == NotificationPrefsGroup.followers ? on : followers,
        messages: group == NotificationPrefsGroup.messages ? on : messages,
      );

  @override
  bool operator ==(Object other) =>
      other is NotificationPushPrefs &&
      other.plans == plans &&
      other.mentionsReplies == mentionsReplies &&
      other.likesReposts == likesReposts &&
      other.followers == followers &&
      other.messages == messages;

  @override
  int get hashCode =>
      Object.hash(plans, mentionsReplies, likesReposts, followers, messages);

  @override
  String toString() =>
      'NotificationPushPrefs(plans: $plans, mentionsReplies: $mentionsReplies, '
      'likesReposts: $likesReposts, followers: $followers, '
      'messages: $messages)';
}
