import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/settings/domain/settings_categories.dart';
import 'package:dzeroth/features/settings/presentation/protect_posts_messages.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/widgets/unsent_posts_row.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';
import '../../../support/settings_tablet_rig.dart';
import '../../../support/theme_harness.dart';

/// Every row of the flat list with all the rig's flags on, in order: the
/// legacy groups (phones, desktop, either flag off).
const _flatRows = [
  'Email',
  'Edit profile',
  'Change handle',
  'Scheduled posts',
  'Appearance',
  kProtectPostsTitle,
  'Blocked accounts',
  'Muted accounts',
  'Download my data',
  'Community rules',
  'Privacy Policy',
  'Delete account',
  'Sign out',
];

/// The tablet categories list (plan section 4.3 order), Sign out last.
const _categoryList = [
  'Your account',
  'Privacy & safety',
  'Display',
  'Scheduled posts',
  'About',
  'Sign out',
];

/// Each category's page, with all the rig's flags on.
const _categoryRows = <SettingsCategory, List<String>>{
  SettingsCategory.account: [
    'Email',
    'Edit profile',
    'Change handle',
    'Download my data',
    'Delete account',
  ],
  SettingsCategory.privacy: [
    kProtectPostsTitle,
    'Blocked accounts',
    'Muted accounts',
  ],
  SettingsCategory.display: ['Appearance'],
  SettingsCategory.about: ['Community rules', 'Privacy Policy'],
};

/// Each leaf: its row title, path and category.
const _leaves = <(String, String, SettingsCategory)>[
  ('Edit profile', AppRouter.editProfilePath, SettingsCategory.account),
  ('Change handle', AppRouter.changeHandlePath, SettingsCategory.account),
  ('Download my data', AppRouter.exportDataPath, SettingsCategory.account),
  ('Delete account', AppRouter.deleteAccountPath, SettingsCategory.account),
  ('Blocked accounts', AppRouter.blockedAccountsPath, SettingsCategory.privacy),
  ('Muted accounts', AppRouter.mutedAccountsPath, SettingsCategory.privacy),
];

/// The widths of the brief: both sides of 600, 840 and 1200, plus 360 and
/// 1024.
const _widths = [360.0, 599.0, 600.0, 839.0, 840.0, 1024.0, 1199.0, 1200.0];

List<String> _titles(WidgetTester tester, Finder scope) => [
  for (final row in tester.widgetList<SettingsRow>(
    find.descendant(of: scope, matching: find.byType(SettingsRow)),
  ))
    row.title,
];

/// The onstage page of `/settings` (the pushed one in band A).
Finder _page() => find.byType(SettingsScreen);

SettingsRow _paneRow(WidgetTester tester, String title) =>
    tester.widget<SettingsRow>(
      inCategoriesPane(find.widgetWithText(SettingsRow, title)),
    );

String? _selectedInPane(WidgetTester tester) {
  for (final row in tester.widgetList<SettingsRow>(
    inCategoriesPane(find.byType(SettingsRow)),
  )) {
    if (row.selected) return row.title;
  }
  return null;
}

/// System back (the Android button / browser back): pops the shell's top
/// page, or the root page above the shell.
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The app bar title of the page of `/settings` or of a leaf.
Finder _barTitle(String title) =>
    find.descendant(of: find.byType(AppBar), matching: find.text(title));

void main() {
  setUpAll(() {
    registerFallbackValue(const AuthSignOutRequested());
  });

  group('flag modes x widths (plan section 2.3)', () {
    for (final MapEntry(key: mode, value: flags)
        in kSettingsFlagModes.entries) {
      for (final width in _widths) {
        final tablet =
            mode == 'ui_shell + ui_tablet' && width >= 600 && width < 1200;
        final desktopSplit = width >= 1200 && mode.startsWith('ui_shell');
        testWidgets('$mode at ${width.toInt()}dp', (tester) async {
          final rig = SettingsTabletRig();
          await rig.pump(tester, width: width, height: 1600, flags: flags);

          expect(tester.takeException(), isNull);
          if (!tablet) {
            // Today's Settings, row for row: the flat groups, no category.
            expect(findCategoriesPane(), findsNothing);
            expect(find.byType(SettingsList), findsOneWidget);
            expect(_titles(tester, find.byType(SettingsList)), _flatRows);
            expect(find.text('Your account'), findsNothing);
            expect(find.text('Account'), findsOneWidget);
            expect(
              find.text('Select a setting'),
              desktopSplit ? findsOneWidget : findsNothing,
            );
            if (!desktopSplit) {
              // The legacy column: at most 600 dp.
              expect(
                tester.getSize(find.byType(SettingsList)).width,
                lessThanOrEqualTo(AppBreakpoints.mobile),
              );
            }
            return;
          }
          expect(find.byType(SettingsList), findsNothing);
          expect(find.text('Account'), findsNothing);
          if (width < AppBreakpoints.expanded) {
            // Band A: the categories list is the page.
            expect(findCategoriesPane(), findsNothing);
            expect(_titles(tester, _page()), _categoryList);
            expect(find.text('Select a setting'), findsNothing);
          } else {
            // Band B: the categories beside the placeholder.
            expect(_titles(tester, findCategoriesPane()), _categoryList);
            expect(_titles(tester, _page()), isEmpty);
            expect(inSettingsPage(find.text('Select a setting')), findsOne);
            expect(
              inSettingsPage(find.byIcon(Icons.settings_outlined)),
              findsOne,
            );
            expect(_selectedInPane(tester), isNull);
            expect(find.byType(ContextPane), findsNothing);
          }
        });
      }
    }
  });

  group('band B geometry (plan section 3, code LD)', () {
    for (final (width, list, detail) in const [
      (840.0, 320.0, 439.0),
      (1024.0, 377.0, 566.0),
      (1199.0, 400.0, 718.0),
    ]) {
      testWidgets('${width.toInt()}dp: rail 80 | list $list | 1 | detail '
          '$detail', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: width, location: '/settings?c=account');

        final pane = tester.getRect(
          find.byKey(const ValueKey('tablet-list-pane')),
        );
        final page = tester.getRect(_page());
        expect(pane.left, AppSize.railCompact);
        expect(pane.width, list + 1);
        expect(
          ShellGeometry.listPaneWidthFor(width - AppSize.railCompact),
          list,
        );
        expect(page.left, AppSize.railCompact + list + 1);
        expect(page.width, detail);
        expect(AppSize.railCompact + list + 1 + detail, width);
        expect(find.byType(ContextPane), findsNothing);
        // The reading column of the detail: at most 680, centred.
        final column = tester.getRect(
          find.descendant(of: _page(), matching: find.byType(ListView)),
        );
        expect(column.width, detail.clamp(0, AppSize.readableMax));
        expect(column.center.dx, closeTo(page.center.dx, 0.5));
      });
    }

    testWidgets('RTL: the rail on the right, then the list, then the detail', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, textDirection: TextDirection.rtl);

      final pane = tester.getRect(
        find.byKey(const ValueKey('tablet-list-pane')),
      );
      expect(pane.right, 1024 - AppSize.railCompact);
      expect(tester.getRect(_page()).right, pane.left);
    });
  });

  group('band A (600-839): categories list, then push', () {
    for (final category in SettingsCategory.values) {
      testWidgets('${category.label}: pushed page, back to the list', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: 744);

        await _tapText(tester, find.text(category.label));

        expect(rig.uri.toString(), settingsCategoryLocation(category));
        expect(_barTitle(category.label), findsOneWidget);
        expect(_titles(tester, _page()), _categoryRows[category]);
        // Pushed: the default back arrow pops to the list.
        expect(find.byType(BackButton), findsOneWidget);
        await _tapText(tester, find.byType(BackButton));
        expect(rig.uri.toString(), AppRouter.settingsPath);
        expect(_titles(tester, _page()), _categoryList);
      });
    }

    for (final (title, path, category) in _leaves) {
      testWidgets('$title: pushed over its category; back returns to it', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: 744);
        await _tapText(tester, find.text(category.label));

        await _tapText(tester, find.text(title));
        expect(rig.uri.path, path);
        expect(find.byType(SettingsScreen), findsNothing);

        await _systemBack(tester);
        expect(rig.uri.toString(), settingsCategoryLocation(category));
        expect(_titles(tester, _page()), _categoryRows[category]);

        await _systemBack(tester);
        expect(rig.uri.toString(), AppRouter.settingsPath);
        expect(_titles(tester, _page()), _categoryList);
      });
    }

    testWidgets('Scheduled posts opens the root page full screen', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 744);

      await _tapText(tester, find.text('Scheduled posts'));
      expect(rig.uri.path, AppRouter.scheduledPostsPath);
      expect(find.text('Scheduled stub'), findsOneWidget);
      expect(find.byType(AppNavRail), findsNothing, reason: 'no rail');

      await _systemBack(tester);
      expect(rig.uri.toString(), AppRouter.settingsPath);
      expect(_titles(tester, _page()), _categoryList);
    });
  });

  group('band B (840-1199): categories | detail', () {
    for (final category in SettingsCategory.values) {
      testWidgets('${category.label}: the detail, the row selected', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final rig = SettingsTabletRig();
        await rig.pump(tester);

        await _tapText(tester, inCategoriesPane(find.text(category.label)));

        expect(rig.uri.toString(), settingsCategoryLocation(category));
        expect(_titles(tester, _page()), _categoryRows[category]);
        expect(inSettingsPage(_barTitle(category.label)), findsOneWidget);
        expect(_selectedInPane(tester), category.label);
        expect(
          tester.getSemantics(
            inCategoriesPane(find.bySemanticsLabel(category.label)),
          ),
          isSemantics(isButton: true, isSelected: true),
        );
        // The categories are beside it: no back arrow.
        expect(inSettingsPage(find.byType(BackButton)), findsNothing);
        // The list stays as it was.
        expect(_titles(tester, findCategoriesPane()), _categoryList);
        handle.dispose();
      });
    }

    for (final (title, path, category) in _leaves) {
      testWidgets('$title: replaces the detail; up returns to its category', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, location: settingsCategoryLocation(category));

        await _tapText(tester, inSettingsPage(find.text(title)));
        expect(rig.uri.path, path);
        expect(find.byType(SettingsScreen), findsNothing);
        // The leaf's category stays selected; the list stays.
        expect(_selectedInPane(tester), category.label);
        expect(_titles(tester, findCategoriesPane()), _categoryList);

        if (path == AppRouter.changeHandlePath) {
          // The form header's Cancel is its way up.
          await _tapText(tester, find.text('Cancel'));
        } else {
          await _tapText(tester, find.byType(BackButton));
        }
        expect(rig.uri.toString(), settingsCategoryLocation(category));
        expect(_titles(tester, _page()), _categoryRows[category]);
        expect(_selectedInPane(tester), category.label);
      });
    }

    testWidgets('a pane row opens another category from a leaf', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, location: AppRouter.blockedAccountsPath);
      expect(_selectedInPane(tester), 'Privacy & safety');

      await _tapText(tester, inCategoriesPane(find.text('Display')));
      expect(rig.uri.toString(), '/settings?c=display');
      expect(_titles(tester, _page()), ['Appearance']);
    });

    testWidgets('Scheduled posts stays root; the selection does not change', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, location: '/settings?c=account');
      expect(_selectedInPane(tester), 'Your account');

      await _tapText(tester, inCategoriesPane(find.text('Scheduled posts')));
      expect(rig.uri.path, AppRouter.scheduledPostsPath);
      expect(find.text('Scheduled stub'), findsOneWidget);
      expect(find.byType(AppNavRail), findsNothing, reason: 'full screen');
      expect(findCategoriesPane(), findsNothing);

      await _systemBack(tester);
      expect(rig.uri.toString(), '/settings?c=account');
      expect(_selectedInPane(tester), 'Your account');
      expect(_paneRow(tester, 'Scheduled posts').selected, isFalse);
      expect(_titles(tester, _page()), _categoryRows[SettingsCategory.account]);
    });
  });

  group('the URL is the source of truth (?c=)', () {
    testWidgets('typed /settings?c=privacy in band A: the page, up to the '
        'list (nothing to pop)', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 700, location: '/settings?c=privacy');

      expect(_barTitle('Privacy & safety'), findsOneWidget);
      expect(_titles(tester, _page()), _categoryRows[SettingsCategory.privacy]);
      await _tapText(tester, find.byType(BackButton));
      expect(rig.uri.toString(), AppRouter.settingsPath);
      expect(_titles(tester, _page()), _categoryList);
    });

    testWidgets('typed /settings?c=privacy in band B: selected, its detail', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, location: '/settings?c=privacy');

      expect(_selectedInPane(tester), 'Privacy & safety');
      expect(_titles(tester, _page()), _categoryRows[SettingsCategory.privacy]);
    });

    for (final c in ['nope', 'scheduled', '', 'ACCOUNT']) {
      for (final width in [700.0, 1024.0]) {
        testWidgets('unknown c="$c" at ${width.toInt()}: the list (A) or the '
            'placeholder (B), nothing selected', (tester) async {
          final rig = SettingsTabletRig();
          await rig.pump(tester, width: width, location: '/settings?c=$c');

          expect(tester.takeException(), isNull);
          if (width < 840) {
            expect(_titles(tester, _page()), _categoryList);
          } else {
            expect(inSettingsPage(find.text('Select a setting')), findsOne);
            expect(_selectedInPane(tester), isNull);
          }
        });
      }
    }

    testWidgets('a category with no rows is hidden and its c falls back', (
      tester,
    ) async {
      // No email, no account or privacy flags: Your account and Privacy &
      // safety have no rows.
      for (final width in [700.0, 1024.0]) {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: width,
          location: '/settings?c=account',
          flags: kSettingsFlagModes['ui_shell + ui_tablet']!
              .where((f) => f.startsWith('ui_'))
              .toSet(),
          email: null,
        );

        final list = width < 840 ? _page() : findCategoriesPane();
        expect(_titles(tester, list), ['Display', 'About', 'Sign out']);
        if (width >= 840) {
          expect(inSettingsPage(find.text('Select a setting')), findsOne);
        }
      }
    });

    testWidgets('desktop (>= 1200) ignores c: today\'s list and placeholder', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 1200,
        height: 1600,
        location: '/settings?c=account',
      );

      expect(findCategoriesPane(), findsNothing);
      expect(find.text('Select a setting'), findsOneWidget);
      expect(_titles(tester, find.byType(SettingsList)), _flatRows);
    });

    testWidgets('a leaf typed in band A goes up to its category, then to the '
        'list', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 700, location: AppRouter.mutedAccountsPath);

      await _tapText(tester, find.byType(BackButton));
      expect(rig.uri.toString(), '/settings?c=privacy');
      await _tapText(tester, find.byType(BackButton));
      expect(rig.uri.toString(), AppRouter.settingsPath);
    });
  });

  group('special rows', () {
    for (final width in [600.0, 839.0, 840.0, 1199.0]) {
      testWidgets('Appearance is a dialog at ${width.toInt()}', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: width, location: '/settings?c=display');

        await _tapText(tester, inSettingsPage(find.text('Appearance')));
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);

        await _tapText(tester, find.text('Dark'));
        expect(find.byType(Dialog), findsNothing);
        expect(
          inSettingsPage(find.widgetWithText(SettingsRow, 'Appearance')),
          findsOneWidget,
        );
        expect(inSettingsPage(find.text('Dark')), findsOneWidget);
      });
    }

    testWidgets('Appearance stays a bottom sheet on phones', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 599, height: 1600);

      await _tapText(tester, find.text('Appearance'));
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('About: external links, no navigation', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, location: '/settings?c=about');

      await _tapText(tester, inSettingsPage(find.text('Community rules')));
      await _tapText(tester, inSettingsPage(find.text('Privacy Policy')));
      expect(rig.launcher.launched, hasLength(2));
      expect(rig.uri.toString(), '/settings?c=about');
      expect(inSettingsPage(find.byIcon(Icons.open_in_new)), findsNWidgets(2));
    });

    for (final width in [700.0, 1024.0]) {
      testWidgets('Sign out is last and on its own at ${width.toInt()}', (
        tester,
      ) async {
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: width);
        final list = width < 840 ? _page() : findCategoriesPane();

        expect(_titles(tester, list).last, 'Sign out');
        final groups = tester
            .widgetList<SettingsGroup>(
              find.descendant(of: list, matching: find.byType(SettingsGroup)),
            )
            .toList();
        expect(groups, hasLength(2));
        expect(groups.last.rows, hasLength(1));

        await _tapText(
          tester,
          find.descendant(of: list, matching: find.text('Sign out')),
        );
        verify(() => rig.auth.add(const AuthSignOutRequested())).called(1);
      });
    }

    testWidgets('Messages shows only when messagesEntry (read-only Messages)', (
      tester,
    ) async {
      final gate = MessagingFeatureGate(isMessagingEnabled: () => false);
      await gate.probe(hasCached: () async => true, refresh: () async {});
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        location: '/settings?c=privacy',
        messagingGate: gate,
      );

      expect(_titles(tester, _page()), [
        ..._categoryRows[SettingsCategory.privacy]!,
        'Messages',
      ]);
      await _tapText(tester, inSettingsPage(find.text('Messages')));
      expect(find.text('inbox body'), findsOneWidget);
    });

    testWidgets('no Messages row with the rail destination (full access)', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, location: '/settings?c=privacy');

      expect(find.text('Messages'), findsNothing);
    });
  });

  group('Unsent posts (Your account, section 4.3)', () {
    FakeDraftsRepository oneUnsent() => FakeDraftsRepository(
      drafts: [
        ComposerDraft(
          id: 'd1',
          uid: 'u-alice',
          text: 'unsent',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
    );

    for (final width in [700.0, 1024.0]) {
      testWidgets('${width.toInt()}: after Download my data, before Delete '
          'account; it asks first', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: width,
          location: '/settings?c=account',
          drafts: oneUnsent(),
        );

        expect(_titles(tester, _page()), [
          'Email',
          'Edit profile',
          'Change handle',
          'Download my data',
          kUnsentPostsRowTitle,
          'Delete account',
        ]);
        await _tapText(tester, inSettingsPage(find.text(kUnsentPostsRowTitle)));
        expect(find.byType(Dialog), findsOneWidget);
      });
    }

    for (final width in [700.0, 1024.0]) {
      testWidgets('${width.toInt()}: the only account row still shows the '
          'category in the list and opens its page', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: width,
          location: '/settings?c=account',
          flags: kSettingsTabletFlags.where((f) => f.startsWith('ui_')).toSet(),
          email: null,
          drafts: oneUnsent(),
        );

        expect(_titles(tester, _page()), [kUnsentPostsRowTitle]);
        if (width >= 840) {
          expect(_titles(tester, findCategoriesPane()), [
            'Your account',
            'Display',
            'About',
            'Sign out',
          ]);
          expect(_selectedInPane(tester), 'Your account');
        }
      });
    }

    testWidgets('Sign out from the band B list pane asks about the unsent '
        'posts first', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, drafts: oneUnsent());

      await _tapText(tester, inCategoriesPane(find.text('Sign out')));
      expect(find.byType(Dialog), findsOneWidget);
      verifyNever(() => rig.auth.add(any()));
    });
  });

  group('state across 839 <-> 840', () {
    testWidgets('a leaf keeps its text and the shell navigator', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 839);
      await _tapText(tester, find.text('Your account'));
      await _tapText(tester, find.text('Change handle'));
      await tester.enterText(find.byType(TextField), 'newname');
      await tester.pump(const Duration(seconds: 1));
      final navigator = Navigator.of(tester.element(find.byType(TextField)));
      final field = tester.state(find.byType(EditableText));

      await rig.resize(tester, 840);
      expect(_selectedInPane(tester), 'Your account');
      expect(tester.state(find.byType(EditableText)), same(field));
      expect(
        Navigator.of(tester.element(find.byType(TextField))),
        same(navigator),
      );
      expect(find.text('newname'), findsOneWidget);

      await rig.resize(tester, 839);
      expect(findCategoriesPane(), findsNothing);
      expect(tester.state(find.byType(EditableText)), same(field));
      expect(find.text('newname'), findsOneWidget);

      // Still the pushed stack: back to the category, then the list.
      await _systemBack(tester);
      expect(rig.uri.toString(), '/settings?c=account');
      await _systemBack(tester);
      expect(_titles(tester, _page()), _categoryList);
    });

    testWidgets('a pushed category becomes the detail and back again', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 839);
      await _tapText(tester, find.text('Privacy & safety'));

      await rig.resize(tester, 840);
      expect(_selectedInPane(tester), 'Privacy & safety');
      expect(_titles(tester, _page()), _categoryRows[SettingsCategory.privacy]);
      expect(inSettingsPage(find.byType(BackButton)), findsNothing);

      await rig.resize(tester, 839);
      expect(findCategoriesPane(), findsNothing);
      expect(_barTitle('Privacy & safety'), findsOneWidget);
      await _tapText(tester, find.byType(BackButton));
      expect(_titles(tester, _page()), _categoryList);
    });

    testWidgets('a band B leaf goes up to its category in band A', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 840, location: '/settings?c=privacy');
      await _tapText(tester, inSettingsPage(find.text('Blocked accounts')));

      await rig.resize(tester, 839);
      expect(_barTitle('Blocked accounts'), findsOneWidget);
      await _tapText(tester, find.byType(BackButton));
      expect(rig.uri.toString(), '/settings?c=privacy');
      expect(_barTitle('Privacy & safety'), findsOneWidget);
    });

    testWidgets('the selection survives 1199 <-> 1200 through the URL', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 1199,
        location: AppRouter.mutedAccountsPath,
      );
      expect(_selectedInPane(tester), 'Privacy & safety');

      await rig.resize(tester, 1200);
      // Desktop: today's flat master with the open page's row selected.
      expect(findCategoriesPane(), findsNothing);
      final muted = tester.widget<SettingsRow>(
        find.widgetWithText(SettingsRow, 'Muted accounts'),
      );
      expect(muted.selected, isTrue);

      await rig.resize(tester, 1199);
      expect(_selectedInPane(tester), 'Privacy & safety');
    });
  });

  group(
    'leaves typed with nothing to pop (real Blocked and Change handle)',
    () {
      // Only the tablet layout gains an up button / a category exit; phones,
      // desktop and the legacy 600-1199 layout keep today's: no back arrow on
      // the first page, and Cancel goes to /settings.
      final cases = <(String, double, Set<String>, bool)>[
        ('phone, both flags', 390, kSettingsTabletFlags, false),
        ('tablet A, both flags', 700, kSettingsTabletFlags, true),
        ('tablet B, both flags', 1024, kSettingsTabletFlags, true),
        (
          '600-1199, ui_shell only',
          834,
          kSettingsFlagModes['ui_shell only']!,
          false,
        ),
        ('600-1199, neither', 834, kSettingsFlagModes['neither']!, false),
        ('desktop, both flags', 1200, kSettingsTabletFlags, false),
      ];
      for (final (name, width, flags, tablet) in cases) {
        testWidgets('$name: Blocked accounts '
            '${tablet ? 'goes up to Privacy & safety' : 'has no up button'}', (
          tester,
        ) async {
          final rig = SettingsTabletRig();
          await rig.pump(
            tester,
            width: width,
            flags: flags,
            location: AppRouter.blockedAccountsPath,
          );

          final up = find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(BackButton),
          );
          if (!tablet) {
            expect(up, findsNothing);
            return;
          }
          expect(up, findsOneWidget);
          await _tapText(tester, up);
          expect(rig.uri.toString(), '/settings?c=privacy');
        });

        testWidgets('$name: Change handle Cancel goes to '
            '${tablet ? 'Your account' : '/settings'}', (tester) async {
          final rig = SettingsTabletRig();
          await rig.pump(
            tester,
            width: width,
            flags: flags,
            location: AppRouter.changeHandlePath,
          );

          await _tapText(tester, find.text('Cancel'));
          expect(
            rig.uri.toString(),
            tablet ? '/settings?c=account' : AppRouter.settingsPath,
          );
        });
      }
    },
  );

  group('tablet matrix cells (plan section 5.5, 20 cells)', () {
    for (final brightness in Brightness.values) {
      for (final width in kTabletMatrixWidths) {
        for (final scale in kTabletTextScales) {
          testWidgets('${brightness.name} ${width.toInt()}dp x$scale', (
            tester,
          ) async {
            final rig = SettingsTabletRig();
            await rig.pump(
              tester,
              width: width,
              height: kTabletHeights[width]!,
              location: '/settings?c=account',
              textScale: scale,
              brightness: brightness,
            );

            expect(tester.takeException(), isNull);
            final rail = tester.getRect(find.byType(AppNavRail));
            expect(rail.left, 0, reason: 'the rail is pinned');
            final content = width - AppSize.railCompact;
            final page = tester.getRect(_page());
            if (width < AppBreakpoints.expanded) {
              expect(findCategoriesPane(), findsNothing);
              expect(page.left, AppSize.railCompact);
              expect(page.width, content);
            } else {
              final list = ShellGeometry.listPaneWidthFor(content);
              expect(
                tester.getRect(find.byKey(const ValueKey('tablet-list-pane'))),
                Rect.fromLTWH(AppSize.railCompact, 0, list + 1, page.height),
              );
              expect(page.width, content - list - 1);
              // No dead strip: rail + list + hairline + detail = W.
              expect(AppSize.railCompact + list + 1 + page.width, width);
            }
            // The header spans the pane; the rows sit in the readable
            // column (at most 680, centred).
            expect(
              tester
                  .getRect(
                    find.descendant(of: _page(), matching: find.byType(AppBar)),
                  )
                  .width,
              page.width,
            );
            final column = tester.getRect(
              find.descendant(of: _page(), matching: find.byType(ListView)),
            );
            expect(column.width, lessThanOrEqualTo(AppSize.readableMax));
            expect(column.center.dx, closeTo(page.center.dx, 0.5));
          });
        }
      }
    }
  });

  group('text scale 2.0', () {
    for (final brightness in Brightness.values) {
      for (final (width, height) in const [
        (600.0, 960.0),
        (839.0, 1194.0),
        (840.0, 1194.0),
        (1024.0, 768.0),
        (1199.0, 834.0),
      ]) {
        for (final location in [
          '/settings',
          '/settings?c=account',
          AppRouter.blockedAccountsPath,
        ]) {
          testWidgets('${brightness.name} ${width.toInt()}x${height.toInt()} '
              '$location', (tester) async {
            final rig = SettingsTabletRig();
            await rig.pump(
              tester,
              width: width,
              height: height,
              location: location,
              textScale: 2,
              brightness: brightness,
            );

            expect(tester.takeException(), isNull);
            for (final row in tester.widgetList<SettingsRow>(
              find.byType(SettingsRow),
            )) {
              expect(
                tester.getSize(find.byWidget(row)).height,
                greaterThanOrEqualTo(AppSpacing.minTapTarget),
                reason: row.title,
              );
            }
          });
        }
      }
    }
  });

  group('focus order: rail, list pane, then detail', () {
    for (final direction in TextDirection.values) {
      testWidgets('${direction.name}: Tab and Shift+Tab', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          location: '/settings?c=account',
          textDirection: direction,
        );
        String region() {
          final context = FocusManager.instance.primaryFocus?.context;
          if (context == null) return 'none';
          if (context.findAncestorWidgetOfExactType<AppNavRail>() != null) {
            return 'rail';
          }
          if (context.findAncestorWidgetOfExactType<SettingsCategoriesPane>() !=
              null) {
            return 'list';
          }
          if (context.findAncestorWidgetOfExactType<SettingsScreen>() != null) {
            return 'detail';
          }
          return 'other';
        }

        Future<void> tab({bool back = false}) async {
          if (back) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          if (back) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();
        }

        Focus.of(
          tester.element(
            find.descendant(
              of: find.byType(AppNavRail),
              matching: find.byIcon(Icons.home_outlined),
            ),
          ),
        ).requestFocus();
        await tester.pump();
        expect(region(), 'rail');

        await tab();
        expect(region(), 'list', reason: 'the list pane after the rail');
        var steps = 0;
        while (region() == 'list' && steps++ < 20) {
          await tab();
        }
        expect(region(), 'detail', reason: 'the detail after the list');
        await tab(back: true);
        expect(region(), 'list', reason: 'Shift+Tab back into the list');
      });
    }
  });
}
