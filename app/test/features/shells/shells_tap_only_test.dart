import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/home/presentation/home_screen.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:dzeroth/features/shells/domain/shells_feature_flag.dart';
import 'package:dzeroth/features/shells/presentation/premium_dialog.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_push_messaging.dart';
import '../../support/fake_push_opt_in_store.dart';
import '../../support/shells_harness.dart';
import '../../support/timeline_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class _CountingObserver extends NavigatorObserver {
  final pushed = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route.settings.name);
}

/// Code lines of [file] with `//` comments (and doc comments) removed.
String _code(File file) => file
    .readAsLinesSync()
    .map((l) => l.replaceFirst(RegExp(r'//.*$'), ''))
    .join('\n');

List<File> _dartFiles(String dir) =>
    Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

String _name(File f) => f.path.replaceAll(r'\', '/').split('lib/').last;

/// W8-8, F7 and ADR-0026 D4: the Premium pop-up opens only when the user taps
/// the Premium entry. Structural tests on `lib/` plus widget tests that the
/// moments an automatic pop-up would use never open it.
void main() {
  group('structural: only the entry taps push premiumPath', () {
    final lib = _dartFiles('lib').where((f) => !_name(f).startsWith('gen/'));

    test('the path is named only by the router and shell_entries.dart', () {
      final users = {
        for (final f in lib)
          if (RegExp(r'premiumPath|/premium\b').hasMatch(_code(f))) _name(f),
      };
      expect(users, {
        'core/router/app_router.dart',
        'features/shells/domain/shell_entries.dart',
      });
    });

    test('the router never navigates to it; shell_entries pushes it once', () {
      final router = _code(File('lib/core/router/app_router.dart'));
      for (final line in router.split('\n')) {
        if (!line.contains('premiumPath')) continue;
        expect(
          RegExp(r'\.(push|go|replace|pushReplacement)\w*\(').hasMatch(line),
          isFalse,
          reason: 'router navigates to premiumPath: $line',
        );
      }
      final entries = _code(
        File('lib/features/shells/domain/shell_entries.dart'),
      );
      expect(
        RegExp(r'\.push\(').allMatches(entries).length,
        1,
        reason: 'one push in shell_entries.dart (openShellEntry)',
      );
      expect(
        entries,
        contains('context.push(entry.path, extra: kShellPushExtra)'),
      );
    });

    test('the push extra is held only by the router and shell_entries', () {
      final users = {
        for (final f in lib)
          if (_code(f).contains('kShellPushExtra')) _name(f),
      };
      expect(users, {
        'core/router/app_router.dart',
        'features/shells/domain/shell_entries.dart',
      });
    });

    test('openShellEntry is called only from the drawer and the More menu', () {
      final users = {
        for (final f in lib)
          if (_code(f).contains('openShellEntry')) _name(f),
      };
      expect(users, {
        'core/widgets/app_drawer.dart',
        'core/widgets/app_more_menu.dart',
        'features/shells/domain/shell_entries.dart',
      });
      // The drawer calls it inside a row's tap callback.
      expect(
        _code(File('lib/core/widgets/app_drawer.dart')),
        contains('() => openShellEntry(context, entry)'),
      );
    });

    test('the dialog page is built only by the router', () {
      for (final (pattern, owners) in [
        // The widget is created by its own page route ...
        (
          RegExp(r'PremiumDialog\('),
          {'features/shells/presentation/premium_dialog.dart'},
        ),
        // ... and that page only by the `/premium` route.
        (
          RegExp(r'PremiumDialogPage\('),
          {
            'core/router/app_router.dart',
            'features/shells/presentation/premium_dialog.dart',
          },
        ),
      ]) {
        final users = {
          for (final f in lib)
            if (pattern.hasMatch(_code(f))) _name(f),
        };
        // `const PremiumDialog({super.key})` matches its own declaration.
        expect(users, owners, reason: pattern.pattern);
      }
    });

    test('no timer, lifecycle hook or post-frame trigger in the shells', () {
      for (final f in _dartFiles('lib/features/shells')) {
        expect(
          RegExp(
            r'Timer\b|Future\.delayed|WidgetsBindingObserver|'
            r'didChangeAppLifecycleState|initState|addPostFrameCallback|'
            r'showDialog|showGeneralDialog',
          ).firstMatch(_code(f))?[0],
          isNull,
          reason: _name(f),
        );
      }
    });

    test('the sweep sees the real files (not an empty list)', () {
      expect(lib.length, greaterThan(100));
      expect(_dartFiles('lib/features/shells').length, greaterThanOrEqualTo(8));
    });
  });

  group('widget: the pop-up never opens by itself', () {
    setUpAll(() => registerFallbackValue(const OnboardingUserSignedOut()));

    shellsTest('app start on Home with both flags on', (tester) async {
      final app = await pumpShellsApp(tester);
      expect(app.path, AppRouter.homePath);
      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.router.router.canPop(), isFalse);
    });

    shellsTest('resume from the background (lifecycle resumed)', (
      tester,
    ) async {
      final app = await pumpShellsApp(tester, size: const Size(1200, 900));
      final binding = tester.binding;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      // Well past any refresh throttle or auto-refresh tick of the shell.
      await tester.pump(const Duration(minutes: 3));
      await tester.pumpAndSettle();

      expect(app.path, AppRouter.homePath);
      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.router.router.canPop(), isFalse);
    });

    shellsTest('opening and leaving Home and the shell pages', (tester) async {
      final app = await pumpShellsApp(tester);
      for (final path in [
        AppRouter.callsPath,
        AppRouter.homePath,
        AppRouter.creatorStudioPath,
        AppRouter.advertisePath,
        AppRouter.homePath,
      ]) {
        app.router.router.go(path);
        await tester.pumpAndSettle();
        expect(find.byType(PremiumDialog), findsNothing, reason: path);
      }
    });

    shellsTest('only an entry tap opens it (control)', (tester) async {
      final app = await pumpShellsApp(tester, size: const Size(1200, 900));
      expect(find.byType(PremiumDialog), findsNothing);
      await tester.tap(find.bySemanticsLabel(RegExp(r'^More, menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Premium'));
      await tester.pumpAndSettle();
      expect(find.byType(PremiumDialog), findsOneWidget);
      expect(app.path, AppRouter.premiumPath);
    });

    group('Home with the feed on, scrolled and refreshed', () {
      late MockTimelineRepository timeline;
      late MockPostsRepository posts;
      late _MockOnboardingBloc onboarding;
      late PendingPostsCubit pending;
      late PushCubit push;
      late PushOptInCubit optIn;
      const feed = FeedKey.home();

      setUp(() {
        timeline = MockTimelineRepository();
        posts = MockPostsRepository();
        onboarding = _MockOnboardingBloc();
        pending = PendingPostsCubit();
        final notifications = _MockNotificationsRepository();
        when(() => notifications.enabled).thenReturn(false);
        push = PushCubit(
          messaging: FakePushMessaging(),
          repository: notifications,
        );
        optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
        final posts30 = snapshotOf([
          for (var i = 30; i >= 1; i--) i,
        ], older: 'o');
        when(() => timeline.cached(feed)).thenAnswer((_) async => posts30);
        when(() => timeline.refresh(feed)).thenAnswer((_) async => posts30);
        when(() => timeline.loadOlder(feed)).thenAnswer((_) async => posts30);
        when(() => timeline.sinceRefresh(feed))
            .thenReturn(const Duration(seconds: 1));
        when(() => timeline.sinceRefreshAttempt(feed))
            .thenReturn(const Duration(seconds: 1));
        when(() => timeline.rateLimitedFor()).thenReturn(null);
        when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
        whenListen(
          onboarding,
          const Stream<OnboardingState>.empty(),
          initialState: OnboardingState(
            status: OnboardingStatus.ready,
            profile: identity.Profile(userId: 'me', handle: 'me'),
            enabledFeatures: {...kShellFlags, kFeaturePosts},
          ),
        );
      });

      tearDown(() async {
        await pending.close();
        await optIn.close();
        await push.close();
      });

      testWidgets('scroll, fling, pull to refresh and resume', (tester) async {
        final observer = _CountingObserver();
        final router = GoRouter(
          initialLocation: AppRouter.homePath,
          observers: [observer],
          routes: [
            GoRoute(
              path: AppRouter.homePath,
              builder: (_, _) => const HomeScreen(),
            ),
            // If anything pushed the pop-up, it would land here.
            GoRoute(
              path: AppRouter.premiumPath,
              builder: (_, _) => const PremiumDialog(),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              RepositoryProvider<TimelineRepository>.value(value: timeline),
              RepositoryProvider<PostsRepository>.value(value: posts),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<OnboardingBloc>.value(value: onboarding),
                BlocProvider<PendingPostsCubit>.value(value: pending),
                BlocProvider<PushCubit>.value(value: push),
                BlocProvider<PushOptInCubit>.value(value: optIn),
              ],
              child: MaterialApp.router(
                theme: appLightTheme,
                routerConfig: router,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('post 30'), findsOneWidget);
        observer.pushed.clear();

        final feedView = find.byType(CustomScrollView);
        await tester.drag(feedView, const Offset(0, -4000));
        await tester.pumpAndSettle();
        await tester.fling(feedView, const Offset(0, -3000), 3000);
        await tester.pumpAndSettle();
        await tester.fling(feedView, const Offset(0, 3000), 3000);
        await tester.pumpAndSettle();
        await tester.fling(feedView, const Offset(0, 400), 1000);
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(minutes: 3));
        await tester.pumpAndSettle();

        expect(find.byType(PremiumDialog), findsNothing);
        expect(observer.pushed, isEmpty, reason: 'no route was pushed');
        expect(
          router.routerDelegate.currentConfiguration.last.matchedLocation,
          AppRouter.homePath,
        );
        // The feed really did its work (the scroll was not a no-op).
        verify(() => timeline.loadOlder(feed)).called(greaterThan(0));
      });
    });
  });

  test('the harness flags are the two the entries need', () {
    expect(kShellFlags, {kFeatureShells, kFeatureUiShell});
    expect(kShellEntries.where((e) => e.opensAsDialog), hasLength(1));
  });
}
