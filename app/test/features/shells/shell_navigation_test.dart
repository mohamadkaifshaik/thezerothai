import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/app_account_chip.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_drawer.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:dzeroth/features/shells/domain/shells_feature_flag.dart';
import 'package:dzeroth/features/shells/presentation/advertise_screen.dart';
import 'package:dzeroth/features/shells/presentation/calls_screen.dart';
import 'package:dzeroth/features/shells/presentation/creator_studio_screen.dart';
import 'package:dzeroth/features/shells/presentation/premium_dialog.dart';
import 'package:dzeroth/shared/widgets/app_main_column.dart';
import 'package:dzeroth/shared/widgets/app_menu_item_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/geometry.dart';
import '../../support/shells_harness.dart';
import '../../support/theme_harness.dart';

const _labels = ['Creator tools', 'Premium', 'Advertise', 'Calls'];

/// W8-2: the shell entry points. Under 600 dp four drawer rows; from 600 dp a
/// rail-only "More" item that opens a menu (the account chip menu is left
/// alone); `shells` and `ui_shell` both gate them; `kVisibleShells` chooses
/// which shells exist.
void main() {
  Future<void> openDrawer(WidgetTester tester) async {
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
  }

  Finder moreItem() => find.bySemanticsLabel(RegExp(r'^More, menu'));

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(moreItem());
    await tester.pumpAndSettle();
  }

  Finder menuLabels() => find.descendant(
    of: find.byType(PopupMenuItem<ShellEntry>),
    matching: find.byType(AppMenuItemRow),
  );

  group('descriptors', () {
    test('the four entries, in order, with their icons and labels', () {
      expect(kShellEntries.map((e) => e.kind), ShellKind.values);
      expect(kShellEntries.map((e) => e.label), _labels);
      expect(kShellEntries.map((e) => e.icon), [
        Icons.insights_outlined,
        Icons.workspace_premium_outlined,
        Icons.campaign_outlined,
        Icons.call_outlined,
      ]);
      expect(kShellEntries.map((e) => e.path), [
        AppRouter.creatorStudioPath,
        AppRouter.premiumPath,
        AppRouter.advertisePath,
        AppRouter.callsPath,
      ]);
      expect(kShellEntries.where((e) => e.opensAsDialog).map((e) => e.kind), [
        ShellKind.premium,
      ]);
      expect(kVisibleShells, ShellKind.values.toSet());
    });
  });

  group('drawer rows (under 600 dp)', () {
    for (final brightness in Brightness.values) {
      for (final scale in kMatrixTextScalesLarge) {
        shellsTest('four rows after the feature rows, before Settings, under a '
            'divider [${brightness.name} x$scale]', (tester) async {
          final open = await pumpBareDrawer(
            tester,
            flags: {...kShellFlags, 'posts', 'bookmarks'},
            brightness: brightness,
            textScale: scale,
          );
          await open();

          double top(String label) =>
              tester.getTopLeft(find.text(label).last).dy;
          final order = [
            top('Profile'),
            top('History'),
            for (final label in _labels) top(label),
            top('Settings'),
            top('Sign out'),
          ];
          expect(order, orderedEquals([...order]..sort()));
          // The divider sits between History and Creator tools, 1dp thick.
          final dividers = find.descendant(
            of: find.byType(AppDrawer),
            matching: find.byType(Divider),
          );
          expect(dividers, findsOneWidget);
          final divider = tester.getRect(dividers);
          expect(divider.height, 1);
          expect(divider.top, greaterThan(top('History')));
          expect(divider.top, lessThan(top('Creator tools')));
          expectNoOverflow(tester);
        });
      }
    }

    shellsTest('each row opens its page and closes the drawer', (tester) async {
      final pages = {
        'Creator tools': find.byType(CreatorStudioScreen),
        'Advertise': find.byType(AdvertiseScreen),
        'Calls': find.byType(CallsScreen),
      };
      for (final entry in pages.entries) {
        final app = await pumpShellsApp(tester);
        await openDrawer(tester);
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();

        expect(entry.value, findsOneWidget, reason: entry.key);
        expect(find.byType(AppDrawer), findsNothing);
        expect(app.path, isNot(AppRouter.homePath));
      }
    });

    shellsTest('Premium closes the drawer and pushes the dialog over Home', (
      tester,
    ) async {
      final app = await pumpShellsApp(tester);
      await openDrawer(tester);
      await tester.tap(find.text('Premium'));
      await tester.pumpAndSettle();

      expect(find.byType(AppDrawer), findsNothing);
      expect(find.byType(PremiumDialog), findsOneWidget);
      expect(app.path, AppRouter.premiumPath);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.homePath);
    });

    shellsTest('a row announces its label once, as a button', (tester) async {
      await pumpShellsApp(tester);
      await openDrawer(tester);

      expect(
        tester.getSemantics(find.bySemanticsLabel('Calls')),
        matchesSemantics(label: 'Calls', isButton: true, hasTapAction: true),
      );
    });

    shellsTest('rows are 48 dp targets at least', (tester) async {
      await pumpShellsApp(tester);
      await openDrawer(tester);
      for (final label in _labels) {
        expectMinTarget(
          tester,
          find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
        );
      }
    });
  });

  group('flag matrix: shells x ui_shell x kVisibleShells', () {
    for (final shells in [false, true]) {
      for (final uiShell in [false, true]) {
        final flags = {
          if (shells) kFeatureShells,
          if (uiShell) kFeatureUiShell,
        };
        final expectEntries = shells && uiShell;

        shellsTest('drawer, flags $flags', (tester) async {
          // Without ui_shell there is no drawer at all.
          await pumpShellsApp(tester, flags: flags);
          if (!uiShell) {
            expect(find.byType(AppDrawer), findsNothing);
            return;
          }
          await openDrawer(tester);
          for (final label in _labels) {
            expect(
              find.text(label),
              expectEntries ? findsOneWidget : findsNothing,
              reason: label,
            );
          }
        });

        for (final width in [600.0, 1200.0]) {
          shellsTest('rail ${width.toInt()}dp, flags $flags', (tester) async {
            await pumpShellsApp(tester, flags: flags, size: Size(width, 800));

            expect(moreItem(), expectEntries ? findsOneWidget : findsNothing);
          });
        }
      }
    }

    for (final kind in ShellKind.values) {
      final label = kShellEntries.firstWhere((e) => e.kind == kind).label;
      shellsTest('only ${kind.name} visible: one drawer row', (tester) async {
        useVisibleShells({kind});
        await pumpShellsApp(tester);
        await openDrawer(tester);

        for (final other in _labels) {
          expect(
            find.text(other),
            other == label ? findsOneWidget : findsNothing,
            reason: other,
          );
        }
      });

      shellsTest('only ${kind.name} visible: one More menu item', (
        tester,
      ) async {
        useVisibleShells({kind});
        await pumpShellsApp(tester, size: const Size(1200, 800));
        await openMore(tester);

        expect(menuLabels(), findsOneWidget);
        expect(
          find.descendant(of: menuLabels(), matching: find.text(label)),
          findsOneWidget,
        );
      });
    }

    shellsTest('an empty kVisibleShells leaves no entry and no More item', (
      tester,
    ) async {
      useVisibleShells({});
      await pumpShellsApp(tester, size: const Size(1200, 800));
      expect(moreItem(), findsNothing);
    });

    shellsTest('with shells on and ui_shell off the routes still work', (
      tester,
    ) async {
      final app = await pumpShellsApp(
        tester,
        flags: {kFeatureShells},
        location: AppRouter.callsPath,
      );
      expect(app.path, AppRouter.callsPath);
      expect(find.byType(CallsScreen), findsOneWidget);
      expect(moreItem(), findsNothing);
    });
  });

  group('More item (600 dp and up)', () {
    for (final width in [600.0, 1200.0]) {
      for (final brightness in Brightness.values) {
        for (final scale in kMatrixTextScalesLarge) {
          shellsTest('last in the rail; menu lists the four entries '
              '[${width.toInt()}dp ${brightness.name} x$scale]', (
            tester,
          ) async {
            await pumpShellsApp(
              tester,
              size: Size(width, 900),
              brightness: brightness,
              textScale: scale,
            );
            final rail = tester.widget<NavigationRail>(
              find.byType(NavigationRail),
            );
            // The last tab of the rail ("Tab 3 of 3").
            final spoken = tester.getSemantics(moreItem()).label;
            expect(RegExp(r'Tab (\d+) of \1$').hasMatch(spoken), isTrue);
            expect(rail.selectedIndex, 0, reason: 'Home is selected');

            await openMore(tester);

            expect(menuLabels(), findsNWidgets(4));
            expect([
              for (final e in tester.widgetList<AppMenuItemRow>(menuLabels()))
                e.label,
            ], _labels);
            expectNoOverflow(tester);
            // Opening the menu does not navigate.
            expect(find.byType(CreatorStudioScreen), findsNothing);
          });
        }
      }
    }

    shellsTest('the phone bottom bar never shows More', (tester) async {
      await pumpShellsApp(tester);

      expect(find.byType(AppBottomBar), findsOneWidget);
      expect(moreItem(), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
    });

    shellsTest('announces as "More, menu"', (tester) async {
      await pumpShellsApp(tester, size: const Size(1200, 800));

      expect(moreItem(), findsOneWidget);
      expect(find.bySemanticsLabel('More'), findsNothing);
    });

    shellsTest('announces as "More, menu" in the icon-only rail', (
      tester,
    ) async {
      await pumpShellsApp(tester, size: const Size(600, 800));

      expect(moreItem(), findsOneWidget);
    });

    shellsTest('choosing Creator tools goes to its page; More is selected', (
      tester,
    ) async {
      final app = await pumpShellsApp(tester, size: const Size(1200, 800));
      await openMore(tester);
      await tester.tap(
        find.descendant(of: menuLabels(), matching: find.text('Creator tools')),
      );
      await tester.pumpAndSettle();

      expect(app.path, AppRouter.creatorStudioPath);
      expect(find.byType(CreatorStudioScreen), findsOneWidget);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, rail.destinations.length - 1);
    });

    for (final entry in {
      AppRouter.creatorStudioPath: 'Creator tools',
      AppRouter.advertisePath: 'Advertise',
      AppRouter.callsPath: 'Calls',
    }.entries) {
      for (final width in [600.0, 1200.0]) {
        shellsTest('${entry.key} at ${width.toInt()}dp selects only More', (
          tester,
        ) async {
          await pumpShellsApp(
            tester,
            location: entry.key,
            size: Size(width, 800),
          );
          final rail = tester.widget<NavigationRail>(
            find.byType(NavigationRail),
          );
          expect(rail.selectedIndex, rail.destinations.length - 1);
        });
      }
    }

    shellsTest('Premium opens as a dialog over Home and Home stays selected', (
      tester,
    ) async {
      final app = await pumpShellsApp(tester, size: const Size(1200, 800));
      await openMore(tester);
      await tester.tap(
        find.descendant(of: menuLabels(), matching: find.text('Premium')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PremiumDialog), findsOneWidget);
      expect(app.path, AppRouter.premiumPath);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 0);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.homePath);
    });

    shellsTest('Escape closes the More menu without navigating', (
      tester,
    ) async {
      final app = await pumpShellsApp(tester, size: const Size(1200, 800));
      await openMore(tester);
      expect(menuLabels(), findsNWidgets(4));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(menuLabels(), findsNothing);
      expect(app.path, AppRouter.homePath);
    });

    shellsTest('the account chip menu stays Profile / Settings / Sign out', (
      tester,
    ) async {
      await pumpShellsApp(tester, size: const Size(1200, 800));
      await tester.tap(find.byType(AppAccountChip));
      await tester.pumpAndSettle();

      final items = find.byWidgetPredicate((w) => w is PopupMenuItem);
      expect(items, findsNWidgets(3));
      for (final label in ['Profile', 'Settings', 'Sign out']) {
        expect(
          find.descendant(of: items, matching: find.text(label)),
          findsOneWidget,
        );
      }
      for (final label in _labels) {
        expect(find.text(label), findsNothing);
      }
    });
  });

  group('Premium dialog', () {
    for (final brightness in Brightness.values) {
      for (final width in kMatrixWidths) {
        for (final scale in kMatrixTextScalesLarge) {
          shellsTest('title, Close and the body, no overflow '
              '[${brightness.name} ${width.toInt()}dp x$scale]', (
            tester,
          ) async {
            final app = await pumpShellsApp(
              tester,
              size: Size(width, 800),
              brightness: brightness,
              textScale: scale,
            );
            app.router.router.push(
              AppRouter.premiumPath,
              extra: kShellPushExtra,
            );
            await tester.pumpAndSettle();

            expect(find.text('Premium'), findsOneWidget);
            expect(find.text('Coming soon'), findsOneWidget);
            expect(find.byTooltip('Close'), findsOneWidget);
            // Close is the only button.
            expect(
              find.descendant(
                of: find.byType(PremiumDialog),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is IconButton ||
                      w is TextButton ||
                      w is ElevatedButton ||
                      w is FilledButton ||
                      w is OutlinedButton,
                ),
              ),
              findsOneWidget,
            );
            final target = tester.getSemantics(find.byTooltip('Close')).rect;
            expect(target.width, greaterThanOrEqualTo(48));
            expect(target.height, greaterThanOrEqualTo(48));
            final dialog = tester.getRect(
              find.descendant(
                of: find.byType(PremiumDialog),
                matching: find.byType(Divider),
              ),
            );
            if (width < 600) {
              expect(dialog.width, width, reason: 'full screen');
              expect(tester.getSize(find.byType(Dialog)).height, 800);
            } else {
              expect(dialog.width, lessThanOrEqualTo(600));
              expect(dialog.center.dx, closeTo(width / 2, 1));
            }
            expectNoOverflow(tester);
          });
        }
      }
    }

    shellsTest('the title is a header', (tester) async {
      final app = await pumpShellsApp(tester);
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('Premium')),
        matchesSemantics(label: 'Premium', isHeader: true),
      );
    });

    shellsTest('focus returns to the opener when it closes', (tester) async {
      final opener = FocusNode();
      addTearDown(opener.dispose);
      late BuildContext context;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return Scaffold(
                body: ElevatedButton(
                  focusNode: opener,
                  onPressed: () {},
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      );
      opener.requestFocus();
      await tester.pump();
      expect(opener.hasFocus, isTrue);

      final route = const PremiumDialogPage().createRoute(context);
      Navigator.of(context).push(route);
      await tester.pumpAndSettle();
      expect(find.byType(PremiumDialog), findsOneWidget);
      expect(opener.hasFocus, isFalse);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.byType(PremiumDialog), findsNothing);
      expect(opener.hasFocus, isTrue);
    });
  });

  group('shell pages', () {
    final pages = {
      // Creator tools has its own screen test (creator_studio_screen_test).
      'Advertise': AppRouter.advertisePath,
      'Calls': AppRouter.callsPath,
    };
    for (final entry in pages.entries) {
      for (final brightness in Brightness.values) {
        for (final width in kMatrixWidths) {
          for (final scale in kMatrixTextScalesLarge) {
            shellsTest(
              '${entry.key}: header, Back and "Coming soon", no overflow '
              '[${brightness.name} ${width.toInt()}dp x$scale]',
              (tester) async {
                await pumpShellsApp(
                  tester,
                  location: entry.value,
                  size: Size(width, 800),
                  brightness: brightness,
                  textScale: scale,
                );

                // The Calls page also has a "Calls" group title (W8-7).
                expect(
                  find.descendant(
                    of: find.byType(AppMainColumn),
                    matching: find.text(entry.key),
                  ),
                  entry.key == 'Calls' ? findsNWidgets(2) : findsOneWidget,
                );
                expect(
                  find.textContaining(
                    RegExp('coming soon', caseSensitive: false),
                  ),
                  findsWidgets,
                );
                expect(find.byTooltip('Back'), findsOneWidget);
                expectNoOverflow(tester);
              },
            );
          }
        }
      }
    }
  });
}
