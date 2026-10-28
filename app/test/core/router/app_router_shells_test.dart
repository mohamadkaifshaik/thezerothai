import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:dzeroth/features/shells/domain/shells_feature_flag.dart';
import 'package:dzeroth/features/shells/presentation/advertise_screen.dart';
import 'package:dzeroth/features/shells/presentation/calls_screen.dart';
import 'package:dzeroth/features/shells/presentation/creator_studio_screen.dart';
import 'package:dzeroth/features/shells/presentation/premium_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/shells_harness.dart';

/// The W8-2 routes on the real router: `shells` gates all four paths,
/// `kVisibleShells` decides which exist, `/premium` is a push-only dialog.
void main() {
  final pagePaths = {
    AppRouter.creatorStudioPath: find.byType(CreatorStudioScreen),
    AppRouter.advertisePath: find.byType(AdvertiseScreen),
    AppRouter.callsPath: find.byType(CallsScreen),
  };

  test('the path constants', () {
    expect(AppRouter.creatorStudioPath, '/creator-studio');
    expect(AppRouter.premiumPath, '/premium');
    expect(AppRouter.advertisePath, '/advertise');
    expect(AppRouter.callsPath, '/calls');
    expect(kFeatureShells, 'shells');
  });

  group('shells flag off: every shell path redirects to /home', () {
    for (final path in [
      AppRouter.creatorStudioPath,
      AppRouter.premiumPath,
      AppRouter.advertisePath,
      AppRouter.callsPath,
    ]) {
      for (final flags in <Set<String>>[
        const {},
        // ui_shell alone is not enough: the routes need `shells`.
        const {kFeatureUiShell},
      ]) {
        testWidgets('$path with $flags', (tester) async {
          final app = await pumpShellsApp(tester, flags: flags, location: path);

          expect(app.path, AppRouter.homePath);
          for (final finder in pagePaths.values) {
            expect(finder, findsNothing);
          }
          expect(find.byType(PremiumDialog), findsNothing);
        });
      }
    }

    testWidgets('a push of /premium is redirected too', (tester) async {
      final app = await pumpShellsApp(tester, flags: const {});
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();

      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.homePath);
    });
  });

  group('shells flag on', () {
    for (final entry in pagePaths.entries) {
      testWidgets('${entry.key} opens its page (ui_shell not needed)', (
        tester,
      ) async {
        final app = await pumpShellsApp(
          tester,
          flags: const {kFeatureShells},
          location: entry.key,
        );

        expect(app.path, entry.key);
        expect(entry.value, findsOneWidget);
        // Creator tools shows one "Coming soon" pill per placeholder row.
        expect(
          find.text('Coming soon'),
          entry.key == AppRouter.creatorStudioPath
              ? findsWidgets
              : findsOneWidget,
        );
      });
    }

    testWidgets('the shell pages go back Home when nothing is below them', (
      tester,
    ) async {
      final app = await pumpShellsApp(
        tester,
        flags: kShellFlags,
        location: AppRouter.callsPath,
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(app.path, AppRouter.homePath);
    });

    testWidgets('Back pops when the page was pushed', (tester) async {
      final app = await pumpShellsApp(tester);
      app.router.router.push(AppRouter.callsPath);
      await tester.pumpAndSettle();
      expect(find.byType(CallsScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.byType(CallsScreen), findsNothing);
      expect(app.path, AppRouter.homePath);
    });

    testWidgets('/premium as the first location lands on /home without a '
        'dialog (typed URL, reload, cold start)', (tester) async {
      final app = await pumpShellsApp(tester, location: AppRouter.premiumPath);

      expect(app.path, AppRouter.homePath);
      expect(find.byType(PremiumDialog), findsNothing);
    });

    testWidgets('a pushed /premium opens the dialog over Home; Close returns '
        'to Home', (tester) async {
      final app = await pumpShellsApp(tester);
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();

      expect(find.byType(PremiumDialog), findsOneWidget);
      expect(find.text('Premium'), findsOneWidget);
      expect(find.text('Coming soon'), findsOneWidget);
      // The page below is still there.
      expect(find.byType(Scaffold, skipOffstage: false), findsWidgets);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.homePath);
    });

    testWidgets('Escape closes the dialog', (tester) async {
      final app = await pumpShellsApp(tester, size: const Size(1200, 800));
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();
      expect(find.byType(PremiumDialog), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.homePath);
    });

    testWidgets('a tap on the barrier closes the dialog (600 dp and up)', (
      tester,
    ) async {
      final app = await pumpShellsApp(tester, size: const Size(1200, 800));
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.homePath);
    });

    testWidgets('system Back closes the dialog', (tester) async {
      final app = await pumpShellsApp(tester);
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.homePath);
    });

    testWidgets('the dialog opens over a shell page and leaves it there', (
      tester,
    ) async {
      final app = await pumpShellsApp(
        tester,
        location: AppRouter.advertisePath,
      );
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(app.path, AppRouter.advertisePath);
      expect(find.byType(AdvertiseScreen), findsOneWidget);
    });
  });

  group('kVisibleShells narrows the routes', () {
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
    for (final visible in ShellKind.values) {
      for (final target in ShellKind.values) {
        final exists = visible == target;
        testWidgets('only ${visible.name} visible: ${routes[target]!.$1} '
            '${exists ? 'opens' : 'is an unknown route'}', (tester) async {
          useVisibleShells({visible});
          final app = await pumpShellsApp(tester);
          app.router.router.push(routes[target]!.$1, extra: kShellPushExtra);
          await tester.pumpAndSettle();

          expect(routes[target]!.$2, exists ? findsOneWidget : findsNothing);
          // Every other shell stays closed.
          for (final other in ShellKind.values.where((k) => k != target)) {
            expect(routes[other]!.$2, findsNothing);
          }
        });
      }
    }
  });

  testWidgets('a cold start on /calls signed out is not stashed: after '
      'sign-in the app opens Home', (tester) async {
    final app = await pumpShellsApp(
      tester,
      location: AppRouter.callsPath,
      signedIn: false,
    );
    expect(app.path, AppRouter.signInPath);

    app.signIn();
    await tester.pumpAndSettle();
    app.router.router.go('/');
    await tester.pumpAndSettle();

    expect(app.path, AppRouter.homePath);
    expect(find.byType(CallsScreen), findsNothing);
  });

  test('deepLinkTarget keeps none of the four shell paths', () {
    for (final path in [
      AppRouter.creatorStudioPath,
      AppRouter.premiumPath,
      AppRouter.advertisePath,
      AppRouter.callsPath,
    ]) {
      expect(AppRouter.deepLinkTarget(Uri.parse(path)), isNull, reason: path);
    }
  });
}
