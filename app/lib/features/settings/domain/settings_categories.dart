/// The Settings categories of the tablet layout (tablet plan section 4.3).
///
/// The URL is the source of truth: `/settings` is the categories list (band
/// A) or the placeholder (band B), and the open category is the `c` query
/// parameter (`/settings?c=account`), so no route is added (ADR-0034 section
/// 6). A leaf page (`/settings/<leaf>`) belongs to the category of
/// [settingsCategoryOfLeaf].
///
/// Only the categories whose rows exist are listed. The design's
/// Notifications, Creator tools, Calls and Advertise categories have no rows
/// in the app yet (approved new features), so they stay out until they are
/// built. "Scheduled posts" sits between Display and About in the list but is
/// not a category: it opens the root `/scheduled` route full screen and never
/// becomes a selection. Sign out ends the list.
enum SettingsCategory {
  account('account', 'Your account'),
  privacy('privacy', 'Privacy & safety'),
  display('display', 'Display'),
  about('about', 'About');

  const SettingsCategory(this.id, this.label);

  /// The value of the `c` query parameter.
  final String id;

  /// The row title in the categories list and the category page's title.
  final String label;
}

/// The name of the query parameter that selects a category.
const kSettingsCategoryParam = 'c';

/// The category whose [SettingsCategory.id] is [id]; null for a missing or
/// unknown value (the fallback: the list in band A, the placeholder in B).
SettingsCategory? settingsCategoryFromId(String? id) {
  if (id == null) return null;
  for (final category in SettingsCategory.values) {
    if (category.id == id) return category;
  }
  return null;
}

/// The location of [category]'s page: `/settings?c=<id>`.
String settingsCategoryLocation(SettingsCategory category) =>
    '/settings?$kSettingsCategoryParam=${category.id}';

/// The category a Settings leaf page belongs to (its "up" target and the
/// selection of the categories list while it is open); null for any other
/// path.
SettingsCategory? settingsCategoryOfLeaf(String path) => switch (path) {
  '/settings/profile' ||
  '/settings/handle' ||
  '/settings/export' ||
  '/settings/delete-account' => SettingsCategory.account,
  '/settings/blocked' || '/settings/muted' => SettingsCategory.privacy,
  _ => null,
};

/// The category the categories list marks for the shell [uri]: the `c` of
/// `/settings`, or the category of a leaf page. Whether that category has
/// visible rows is the list's own check.
SettingsCategory? settingsCategoryForUri(Uri uri) {
  if (uri.path == '/settings') {
    return settingsCategoryFromId(uri.queryParameters[kSettingsCategoryParam]);
  }
  return settingsCategoryOfLeaf(uri.path);
}
