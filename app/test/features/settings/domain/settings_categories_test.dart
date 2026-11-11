import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/settings/domain/settings_categories.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the categories, in the design order, with their ids and labels', () {
    expect(
      [for (final c in SettingsCategory.values) (c.id, c.label)],
      [
        ('account', 'Your account'),
        ('privacy', 'Privacy & safety'),
        ('notifications', 'Notifications'),
        ('display', 'Display'),
        ('about', 'About'),
      ],
    );
  });

  test('ids parse; anything else is no category', () {
    for (final c in SettingsCategory.values) {
      expect(settingsCategoryFromId(c.id), c);
    }
    for (final bad in [null, '', 'nope', 'Account', 'scheduled', ' account']) {
      expect(settingsCategoryFromId(bad), isNull, reason: '$bad');
    }
  });

  test('the location of a category is /settings?c=<id>', () {
    expect(
      settingsCategoryLocation(SettingsCategory.privacy),
      '/settings?c=privacy',
    );
    for (final c in SettingsCategory.values) {
      final uri = Uri.parse(settingsCategoryLocation(c));
      expect(uri.path, AppRouter.settingsPath);
      expect(uri.queryParameters[kSettingsCategoryParam], c.id);
    }
  });

  test('every Settings leaf route belongs to its category', () {
    expect(
      {
        for (final path in [
          AppRouter.editProfilePath,
          AppRouter.changeHandlePath,
          AppRouter.exportDataPath,
          AppRouter.deleteAccountPath,
          AppRouter.blockedAccountsPath,
          AppRouter.mutedAccountsPath,
          AppRouter.messageSettingsPath,
          AppRouter.notificationSettingsPath,
        ])
          path: settingsCategoryOfLeaf(path),
      },
      {
        AppRouter.editProfilePath: SettingsCategory.account,
        AppRouter.changeHandlePath: SettingsCategory.account,
        AppRouter.exportDataPath: SettingsCategory.account,
        AppRouter.deleteAccountPath: SettingsCategory.account,
        AppRouter.blockedAccountsPath: SettingsCategory.privacy,
        AppRouter.mutedAccountsPath: SettingsCategory.privacy,
        AppRouter.messageSettingsPath: SettingsCategory.privacy,
        AppRouter.notificationSettingsPath: SettingsCategory.notifications,
      },
    );
    for (final other in [
      AppRouter.settingsPath,
      AppRouter.scheduledPostsPath,
      AppRouter.onboardingDeletePath,
      '/settings/unknown',
      '/home',
    ]) {
      expect(settingsCategoryOfLeaf(other), isNull, reason: other);
    }
  });

  test('the selection of a shell location', () {
    expect(settingsCategoryForUri(Uri.parse('/settings')), isNull);
    expect(
      settingsCategoryForUri(Uri.parse('/settings?c=display')),
      SettingsCategory.display,
    );
    expect(settingsCategoryForUri(Uri.parse('/settings?c=nope')), isNull);
    expect(
      settingsCategoryForUri(Uri.parse(AppRouter.mutedAccountsPath)),
      SettingsCategory.privacy,
    );
    // A leaf ignores a query: the path decides.
    expect(
      settingsCategoryForUri(Uri.parse('/settings/export?c=about')),
      SettingsCategory.account,
    );
    expect(settingsCategoryForUri(Uri.parse('/home?c=account')), isNull);
  });
}
