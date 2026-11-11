import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/graph/presentation/managed_accounts_screen.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/widgets/settings_choice_row.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/settings_tablet_rig.dart';

/// The three looks of Settings (phone raised cards, tablet flat boxes,
/// desktop master | detail) over the unchanged rows. Row parity per flag
/// mode and width lives in `settings_tablet_test.dart`.

const _categoryList = [
  'Your account',
  'Privacy & safety',
  'Display',
  'Scheduled posts',
  'About',
  'Sign out',
];

const _privacyRows = [
  'Protect your posts',
  'Blocked accounts',
  'Muted accounts',
];

Finder _searchField(Finder scope) =>
    find.descendant(of: scope, matching: find.byType(TextField));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, Finder field, String text) async {
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

/// The vertical order of [texts] on screen (their top edges).
List<double> _tops(WidgetTester tester, List<String> texts) => [
  for (final text in texts) tester.getTopLeft(find.text(text)).dy,
];

void main() {
  group('phone (< 600dp): raised groups', () {
    const titles = [
      'Your account',
      'Privacy & safety',
      'App',
      'Data',
      'Session',
    ];

    testWidgets('five raised groups, uppercase labels in order, header '
        'semantics read the title', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 390, height: 2600);

      final groups = tester
          .widgetList<SettingsGroup>(find.byType(SettingsGroup))
          .toList();
      expect([for (final g in groups) g.title], titles);
      expect({for (final g in groups) g.style}, {SettingsGroupStyle.raised});

      final labels = [for (final t in titles) t.toUpperCase()];
      final tops = _tops(tester, labels);
      expect([...tops]..sort(), tops, reason: 'labels top to bottom');
      for (final title in titles) {
        // Shown in capitals; the original title is not drawn.
        expect(find.text(title), findsNothing, reason: title);
        expect(
          tester.getSemantics(find.text(title.toUpperCase())),
          matchesSemantics(label: title, isHeader: true),
        );
      }
      handle.dispose();
    });

    testWidgets('raised: no hairlines between rows, rows at least 64dp', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 390, height: 2600);

      expect(
        find.descendant(
          of: find.byType(SettingsGroup),
          matching: find.byType(Divider),
        ),
        findsNothing,
      );
      for (final row in tester.widgetList<SettingsRow>(
        find.byType(SettingsRow),
      )) {
        expect(
          tester.getSize(find.byWidget(row)).height,
          greaterThanOrEqualTo(64),
          reason: row.title,
        );
      }
    });

    testWidgets('Change handle shows the @handle as its subtitle', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 390, height: 2600);

      final row = tester.widget<SettingsRow>(
        find.widgetWithText(SettingsRow, 'Change handle'),
      );
      expect(row.subtitle, '@alice');
    });

    testWidgets('the pills of the choice rows are laid out in a Wrap', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 390, height: 2600);

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(SettingsChoiceRow<ThemeMode>),
          matching: find.byType(Wrap),
        ),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('tablet and desktop pages: flat groups', () {
    for (final width in [700.0, 1024.0, 1440.0]) {
      testWidgets('${width.toInt()}: Your account is flat PROFILE then DATA', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: 1600,
          location: '/settings?c=account',
        );

        final page = width < 1200
            ? find.byType(SettingsScreen)
            : find.byType(SettingsDesktopDetail);
        final groups = tester.widgetList<SettingsGroup>(
          find.descendant(of: page, matching: find.byType(SettingsGroup)),
        );
        expect([for (final g in groups) g.title], ['Profile', 'Data']);
        expect({for (final g in groups) g.style}, {SettingsGroupStyle.flat});
        expect(
          tester.getTopLeft(find.text('PROFILE')).dy,
          lessThan(tester.getTopLeft(find.text('DATA')).dy),
        );
        expect(settingsRowTitles(tester, page), [
          'Edit profile',
          'Change handle',
          'Email',
          'Download my data',
          'Delete account',
        ]);
      });
    }

    testWidgets('another category is one flat group named after it', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 700, location: '/settings?c=privacy');

      final groups = tester
          .widgetList<SettingsGroup>(
            find.descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(SettingsGroup),
            ),
          )
          .toList();
      expect(groups, hasLength(1));
      expect(groups.single.title, 'Privacy & safety');
      expect(groups.single.style, SettingsGroupStyle.flat);
      expect(find.text('PRIVACY & SAFETY'), findsOneWidget);
      expect(
        settingsRowTitles(tester, find.byType(SettingsScreen)),
        _privacyRows,
      );
    });
  });

  group('desktop (ui_shell, 1440dp): master | detail', () {
    testWidgets('bare /settings: search, the categories, Your account '
        'selected, its page beside', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 1440, height: 1600);

      expect(inCategoriesPane(find.text('Search settings')), findsOneWidget);
      expect(settingsRowTitles(tester, findCategoriesPane()), _categoryList);
      expect(selectedInCategoriesPane(tester), 'Your account');
      expect(
        tester.getSemantics(
          inCategoriesPane(
            find.bySemanticsLabel(RegExp(r'^Your account(\n|$)')),
          ),
        ),
        isSemantics(isButton: true, isSelected: true),
      );
      final detail = find.byType(SettingsDesktopDetail);
      expect(
        find.descendant(of: detail, matching: find.text('PROFILE')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: detail, matching: find.text('DATA')),
        findsOneWidget,
      );
      expect(find.text('Select a setting'), findsNothing);
      handle.dispose();
    });

    testWidgets('a category in the master shows its rows in the detail', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 1440, height: 1600);

      await _tap(tester, inCategoriesPane(find.text('Privacy & safety')));

      expect(rig.uri.toString(), '/settings?c=privacy');
      expect(selectedInCategoriesPane(tester), 'Privacy & safety');
      expect(
        settingsRowTitles(tester, find.byType(SettingsDesktopDetail)),
        _privacyRows,
      );
    });

    testWidgets('a detail row replaces the detail; the master and its '
        'selection stay', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 1440, height: 1600);
      await _tap(tester, inCategoriesPane(find.text('Privacy & safety')));

      await _tap(
        tester,
        find.descendant(
          of: find.byType(SettingsDesktopDetail),
          matching: find.text('Blocked accounts'),
        ),
      );

      expect(rig.uri.path, AppRouter.blockedAccountsPath);
      expect(find.byType(SettingsDesktopDetail), findsNothing);
      expect(find.byType(BlockedAccountsScreen), findsOneWidget);
      expect(findCategoriesPane(), findsOneWidget);
      expect(selectedInCategoriesPane(tester), 'Privacy & safety');
      expect(settingsRowTitles(tester, findCategoriesPane()), _categoryList);
    });

    testWidgets('/settings?c=about deep link: About selected, its rows', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 1440,
        height: 1600,
        location: '/settings?c=about',
      );

      expect(selectedInCategoriesPane(tester), 'About');
      expect(settingsRowTitles(tester, find.byType(SettingsDesktopDetail)), [
        'Community rules',
        'Privacy Policy',
      ]);
    });

    testWidgets('the Appearance choices sit with their heading in the '
        'detail', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 1440,
        height: 1600,
        location: '/settings?c=display',
      );

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(SettingsDesktopDetail),
          matching: find.byType(SettingsChoiceRow<ThemeMode>),
        ),
        findsOneWidget,
      );
    });
  });

  group('search settings', () {
    // Band A: the categories list is the page. Desktop: the master pane.
    for (final (name, width) in const [
      ('tablet band A', 700.0),
      ('desktop', 1440.0),
    ]) {
      final list = width < 1200
          ? find.byType(SettingsScreen)
          : findCategoriesPane();

      testWidgets('$name: "muted" lists Muted accounts under Privacy & '
          'safety and opens that category', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: width, height: 1600);

        await _type(tester, _searchField(list), 'muted');

        expect(settingsRowTitles(tester, list), ['Muted accounts']);
        expect(
          tester
              .widget<SettingsRow>(
                find.descendant(
                  of: list,
                  matching: find.widgetWithText(SettingsRow, 'Muted accounts'),
                ),
              )
              .subtitle,
          'Privacy & safety',
        );
        expect(
          find.descendant(of: list, matching: find.text('Sign out')),
          findsNothing,
          reason: 'Sign out is not a search result',
        );

        await _tap(
          tester,
          find.descendant(of: list, matching: find.text('Muted accounts')),
        );

        expect(rig.uri.toString(), '/settings?c=privacy');
        final page = width < 1200
            ? find.byType(SettingsScreen)
            : find.byType(SettingsDesktopDetail);
        expect(settingsRowTitles(tester, page), _privacyRows);
      });

      testWidgets('$name: no match says so', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: width, height: 1600);

        await _type(tester, _searchField(list), 'zzz');

        expect(find.text('No settings match your search'), findsOneWidget);
        expect(settingsRowTitles(tester, list), isEmpty);
      });

      testWidgets('$name: clearing the search brings the categories back', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: width, height: 1600);
        await _type(tester, _searchField(list), 'zzz');

        await _type(tester, _searchField(list), '');

        expect(find.text('No settings match your search'), findsNothing);
        expect(settingsRowTitles(tester, list), _categoryList);
      });
    }

    testWidgets('a category name matches the category itself', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 700, height: 1600);

      await _type(tester, _searchField(find.byType(SettingsScreen)), 'about');

      expect(settingsRowTitles(tester, find.byType(SettingsScreen)), ['About']);
    });
  });
}
