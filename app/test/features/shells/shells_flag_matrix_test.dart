import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/app_drawer.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:dzeroth/features/shells/domain/shells_feature_flag.dart';
import 'package:dzeroth/features/shells/presentation/advertise_screen.dart';
import 'package:dzeroth/features/shells/presentation/calls_screen.dart';
import 'package:dzeroth/features/shells/presentation/creator_studio_screen.dart';
import 'package:dzeroth/features/shells/presentation/premium_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/shells_harness.dart';
import '../../support/theme_harness.dart';

/// W8-8: the flag-off and visibility matrix at 360 / 600 / 1200 dp on the real
/// router. Complements the per-ticket tests (`shell_navigation_test`,
/// `app_router_shells_test`), which run one width for the redirects.
void main() {
  final labels = kShellEntries.map((e) => e.label).toList();
  final routes = {
    ShellKind.creatorStudio: (
      AppRouter.creatorStudioPath,
      find.byType(CreatorStudioScreen),
    ),
    ShellKind.premium: (AppRouter.premiumPath, find.byType(PremiumDialog)),
    ShellKind.advertise: (
      AppRouter.advertisePath,
      find.byType(AdvertiseScreen),
    ),
    ShellKind.calls: (AppRouter.callsPath, find.byType(CallsScreen)),
  };
  Finder moreItem() => find.bySemanticsLabel(RegExp(r'^More, menu'));

  Future<void> openDrawer(WidgetTester tester) async {
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
  }

  /// No shell label anywhere: the rail, the bar, the drawer, the menu.
  void expectNoEntries(double width) {
    for (final label in labels) {
      expect(find.text(label), findsNothing, reason: '$label at $width');
    }
    expect(moreItem(), findsNothing);
  }

  for (final width in kMatrixWidths) {
    final size = Size(width, 900);
    final dp = '${width.toInt()}dp';

    group('shells off, $dp', () {
      for (final uiShell in [true, false]) {
        final flags = {if (uiShell) kFeatureUiShell};

        shellsTest('no entry anywhere (ui_shell $uiShell)', (tester) async {
          await pumpShellsApp(tester, flags: flags, size: size);
          if (width < 600 && uiShell) {
            await openDrawer(tester);
            expect(find.byType(AppDrawer), findsOneWidget);
          }
          expectNoEntries(width);
        });

        for (final entry in routes.entries) {
          final (path, page) = entry.value;
          shellsTest('$path redirects to /home (ui_shell $uiShell)', (
            tester,
          ) async {
            final app = await pumpShellsApp(
              tester,
              flags: flags,
              size: size,
              location: path,
            );
            expect(app.path, AppRouter.homePath);
            expect(page, findsNothing);

            // A push (the way the Premium entry opens it) is redirected too.
            app.router.router.push(path, extra: kShellPushExtra);
            await tester.pumpAndSettle();
            expect(app.path, AppRouter.homePath);
            expect(page, findsNothing);
          });
        }
      }
    });

    group('ui_shell off, shells on, $dp', () {
      shellsTest('no entry at all', (tester) async {
        await pumpShellsApp(tester, flags: {kFeatureShells}, size: size);
        expect(find.byType(AppDrawer), findsNothing);
        expectNoEntries(width);
      });
    });

    group('one visible kind, $dp', () {
      for (final kind in ShellKind.values) {
        final entry = kShellEntries.firstWhere((e) => e.kind == kind);

        shellsTest('${kind.name}: exactly that entry', (tester) async {
          useVisibleShells({kind});
          await pumpShellsApp(tester, size: size);
          if (width < 600) {
            await openDrawer(tester);
            expect(moreItem(), findsNothing);
          } else {
            await tester.tap(moreItem());
            await tester.pumpAndSettle();
            expect(find.byType(PopupMenuItem<ShellEntry>), findsOneWidget);
          }
          for (final label in labels) {
            expect(
              find.text(label),
              label == entry.label ? findsOneWidget : findsNothing,
              reason: '$label with only ${kind.name} at $dp',
            );
          }
        });

        for (final target in ShellKind.values) {
          final (path, page) = routes[target]!;
          final exists = target == kind;
          shellsTest(
            '${kind.name}: $path ${exists ? 'opens' : 'is not a route'}',
            (tester) async {
              useVisibleShells({kind});
              final app = await pumpShellsApp(tester, size: size);
              app.router.router.push(path, extra: kShellPushExtra);
              await tester.pumpAndSettle();

              expect(page, exists ? findsOneWidget : findsNothing);
              for (final other in routes.entries.where(
                (e) => e.key != target,
              )) {
                expect(other.value.$2, findsNothing);
              }
            },
          );
        }
      }
    });

    shellsTest('both flags on, all kinds: four entries, $dp', (tester) async {
      await pumpShellsApp(tester, size: size);
      if (width < 600) {
        await openDrawer(tester);
      } else {
        await tester.tap(moreItem());
        await tester.pumpAndSettle();
      }
      for (final label in labels) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });
  }
}
