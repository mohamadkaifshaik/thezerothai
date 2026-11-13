import 'package:flutter/material.dart';
import 'package:dzeroth/core/feature_flags/shells_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/advertise/presentation/advertise_screen.dart';
import 'package:dzeroth/features/calls/presentation/calls_screen.dart';
import 'package:dzeroth/features/creator_studio/presentation/creator_studio_screen.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/settings_tablet_rig.dart';

// The desktop Settings mock lists Creator Studio, Calls and Advertise beside
// the categories and opens them in the detail pane. Phone and tablet keep
// them as pages of their own (More menu / drawer); the routes are the same.

final _flags = {...kSettingsTabletFlags, kFeatureShells};

const _desktopList = [
  'Your account',
  'Privacy & safety',
  'Display',
  'Scheduled posts',
  'Creator Studio',
  'Calls',
  'Advertise',
  'About',
  'Sign out',
];

void main() {
  group('desktop (1440dp): the shells sit in the Settings master-detail', () {
    testWidgets('bare /settings lists them between Scheduled posts and About', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 1440, height: 1600, flags: _flags);
      expect(settingsRowTitles(tester, findCategoriesPane()), _desktopList);
      expect(selectedInCategoriesPane(tester), 'Your account');
    });

    for (final (title, path, screen) in [
      ('Creator Studio', AppRouter.creatorStudioPath, CreatorStudioScreen),
      ('Calls', AppRouter.callsPath, CallsScreen),
      ('Advertise', AppRouter.advertisePath, AdvertiseScreen),
    ]) {
      testWidgets('$path deep link: the categories stay, $title is selected', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: 1440,
          height: 1600,
          flags: _flags,
          location: path,
        );
        expect(findCategoriesPane(), findsOneWidget);
        expect(find.byType(SettingsDesktopDetail), findsNothing);
        expect(find.byType(screen), findsOneWidget);
        expect(selectedInCategoriesPane(tester), title);
        expect(settingsRowTitles(tester, findCategoriesPane()), _desktopList);
        expect(tester.takeException(), isNull);
      });

      testWidgets('tapping $title opens $path in the detail pane', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: 1440, height: 1600, flags: _flags);
        await tester.tap(inCategoriesPane(find.text(title)));
        await tester.pumpAndSettle();
        expect(rig.uri.path, path);
        expect(find.byType(screen), findsOneWidget);
        expect(selectedInCategoriesPane(tester), title);
      });
    }

    testWidgets('a category row from a shell page goes back to Settings', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 1440,
        height: 1600,
        flags: _flags,
        location: AppRouter.callsPath,
      );
      await tester.tap(inCategoriesPane(find.text('Display')));
      await tester.pumpAndSettle();
      expect(rig.uri.toString(), '/settings?c=display');
      expect(selectedInCategoriesPane(tester), 'Display');
    });

    testWidgets('search finds a shell by its name', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 1440, height: 1600, flags: _flags);
      await tester.enterText(inCategoriesPane(find.byType(TextField)), 'calls');
      await tester.pumpAndSettle();
      expect(settingsRowTitles(tester, findCategoriesPane()), ['Calls']);
    });

    testWidgets('without `shells` the list is today\'s', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 1440, height: 1600);
      expect(settingsRowTitles(tester, findCategoriesPane()), [
        'Your account',
        'Privacy & safety',
        'Display',
        'Scheduled posts',
        'About',
        'Sign out',
      ]);
    });
  });

  for (final width in <double>[390, 1024]) {
    testWidgets('${width.toInt()}: /calls is a page of its own, no Settings '
        'list beside it', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: width,
        height: 900,
        flags: _flags,
        location: AppRouter.callsPath,
      );
      expect(find.byType(CallsScreen), findsOneWidget);
      expect(findCategoriesPane(), findsNothing);
    });
  }
}
