import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;

import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_gradient_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// Layout and state coverage of the restyled `/compose` screen (UI slice
/// compose + detail). Behaviour (NFC counting, the Post rules, the optimistic
/// post, idempotency) is owned by composer_screen_test.dart; the NFC and
/// Post-disabled cases are repeated here against the new header so a layout
/// change cannot loosen them.
void main() {
  late _MockPostsRepository repo;
  late PendingPostsCubit pending;

  setUp(() {
    repo = _MockPostsRepository();
    pending = PendingPostsCubit();
  });

  tearDown(() => pending.close());

  void stubCreate(Future<dynamic> Function() answer) {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((_) async => await answer());
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => const ComposerScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: repo),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    unawaited(router.push('/compose'));
    await tester.pumpAndSettle();
  }

  AppGradientButton post(WidgetTester tester) =>
      tester.widget(find.widgetWithText(AppGradientButton, 'Post'));

  TextButton cancel(WidgetTester tester) =>
      tester.widget(find.widgetWithText(TextButton, 'Cancel'));

  group('layout', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final brightness in Brightness.values) {
        for (final textScale in const [1.0, 2.0]) {
          testWidgets(
            '${size.width.toInt()}x${size.height.toInt()} ${brightness.name} '
            'text x$textScale: no overflow, 48dp targets, header visible',
            (tester) async {
              await open(
                tester,
                size: size,
                brightness: brightness,
                textScale: textScale,
              );
              await tester.enterText(find.byType(TextField), 'hello');
              await tester.pump();

              expect(tester.takeException(), isNull);
              expect(find.text('Cancel'), findsOneWidget);
              expect(find.text('Post'), findsOneWidget);
              expect(find.text('New post'), findsOneWidget);
              final cancelSize = tester.getSize(
                find.widgetWithText(TextButton, 'Cancel'),
              );
              expect(cancelSize.height, greaterThanOrEqualTo(48));
              final postSize = tester.getSize(find.byType(AppGradientButton));
              expect(postSize.height, greaterThanOrEqualTo(48));
            },
          );
        }
      }
    }

    testWidgets('320 wide at text x2: the header buttons still fit', (
      tester,
    ) async {
      await open(tester, size: const Size(320, 640), textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byType(AppGradientButton), findsOneWidget);
    });

    testWidgets('wide screens keep the composer in the main column', (
      tester,
    ) async {
      await open(tester, size: const Size(1440, 900));

      const gutter = (1440 - AppLayout.mainColumnMaxWidth) / 2;
      expect(
        tester.getTopLeft(find.text('Cancel')).dx,
        greaterThanOrEqualTo(gutter),
      );
      expect(
        tester.getTopRight(find.byType(AppGradientButton)).dx,
        lessThanOrEqualTo(1440 - gutter),
      );
      expect(
        tester.getSize(find.byType(TextField)).width,
        lessThanOrEqualTo(AppLayout.mainColumnMaxWidth),
      );
    });

    testWidgets('phones use the full width', (tester) async {
      await open(tester);
      expect(tester.getTopLeft(find.text('Cancel')).dx, lessThan(32));
      expect(
        tester.getTopRight(find.byType(AppGradientButton)).dx,
        greaterThan(390 - 32),
      );
    });
  });

  group('empty and data', () {
    testWidgets('empty: Post disabled, Cancel enabled, counter 280', (
      tester,
    ) async {
      await open(tester);
      expect(post(tester).onPressed, isNull);
      expect(post(tester).busy, isFalse);
      expect(cancel(tester).onPressed, isNotNull);
      expect(find.text('280'), findsOneWidget);
      expect(find.text("What's happening?"), findsOneWidget);
    });

    testWidgets('typed text enables Post and updates the counter', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      expect(post(tester).onPressed, isNotNull);
      expect(find.text('275'), findsOneWidget);
    });

    testWidgets('whitespace only keeps Post disabled', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '   \n  ');
      await tester.pump();
      expect(post(tester).onPressed, isNull);
    });
  });

  group('character counter still counts NFC code points', () {
    testWidgets('280 decomposed pairs count as 280 (0 left), Post enabled', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'é' * 280);
      await tester.pump();
      expect(find.text('0'), findsOneWidget);
      expect(post(tester).onPressed, isNotNull);
    });

    testWidgets('281 decomposed pairs are over the limit: -1, Post disabled', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'é' * 281);
      await tester.pump();
      expect(find.text('-1'), findsOneWidget);
      expect(post(tester).onPressed, isNull);
    });

    testWidgets('281 plain characters: -1, spoken, Post disabled', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      await tester.enterText(find.byType(TextField), 'a' * 281);
      await tester.pump();
      expect(find.text('-1'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Characters over the limit: 1'),
        findsOneWidget,
      );
      expect(post(tester).onPressed, isNull);
      handle.dispose();
    });

    testWidgets('the counter sits at the end of the bottom bar', (
      tester,
    ) async {
      await open(tester);
      expect(
        tester.getTopRight(find.text('280')).dx,
        greaterThan(390 - AppSpacing.lg - AppSpacing.md),
      );
    });
  });

  group('posting and error states', () {
    testWidgets('posting: Post is busy, Cancel and the field are off, then '
        'the screen closes', (tester) async {
      final done = Completer<dynamic>();
      stubCreate(() => done.future);
      await open(tester);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();

      await tester.tap(find.widgetWithText(AppGradientButton, 'Post'));
      await tester.pump();

      expect(post(tester).busy, isTrue);
      expect(post(tester).onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(cancel(tester).onPressed, isNull);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(tester.takeException(), isNull);

      // A second tap while sending sends nothing.
      await tester.tap(find.byType(AppGradientButton), warnIfMissed: false);
      await tester.pump();
      verify(
        () => repo.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: 'hello',
          replyToPostId: any(named: 'replyToPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
        ),
      ).called(1);

      done.complete(postView(1));
      await tester.pumpAndSettle();
      expect(find.text('home page'), findsOneWidget);
    });

    testWidgets('error: the snackbar explains, the text stays and Post is '
        'back', (tester) async {
      stubCreate(() async => throw const QuotaExceededException('quota'));
      await open(tester);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppGradientButton, 'Post'));
      await tester.pumpAndSettle();

      expect(find.textContaining("reached today's limit"), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(post(tester).onPressed, isNotNull);
      expect(post(tester).busy, isFalse);
      expect(cancel(tester).onPressed, isNotNull);
    });

    testWidgets('Cancel leaves the screen', (tester) async {
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('home page'), findsOneWidget);
    });
  });

  group('semantics', () {
    testWidgets('Cancel and Post are buttons, the title is a header', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();

      expect(
        tester.getSemantics(find.widgetWithText(TextButton, 'Cancel')),
        isSemantics(label: 'Cancel', isButton: true, isEnabled: true),
      );
      expect(
        tester.getSemantics(find.byType(AppGradientButton)),
        isSemantics(label: 'Post', isButton: true, isEnabled: true),
      );
      expect(find.bySemanticsLabel('Post'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('New post')),
        isSemantics(label: 'New post', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('Post is announced disabled while the draft is empty', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      expect(
        tester.getSemantics(find.byType(AppGradientButton)),
        isSemantics(label: 'Post', isButton: true, isEnabled: false),
      );
      handle.dispose();
    });
  });
}
