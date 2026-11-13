import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/drafts_screen.dart';
import 'package:dzeroth/features/posts/presentation/scheduled_posts_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/composer_tablet_rig.dart';
import '../../../support/fake_drafts_repository.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockPostsRepository extends Mock implements PostsRepository {}

const _tablet = {kFeatureUiShell, kFeatureUiTablet};

/// T8f, one header rule, on the full-screen root pages where the old
/// placement floated furthest from the edge (172-260 dp at 1024-1199):
/// Drafts, Scheduled and the cold-start composer. On the tablet layout Back
/// or Close leads the column and the actions end it, while the content
/// stays in the 680 column. Phones, desktop and either flag off keep the
/// controls at the column's edges, as before.
void main() {
  final now = DateTime.now();

  Future<void> open(
    WidgetTester tester,
    String path, {
    required double width,
    Set<String> flags = _tablet,
    TextDirection textDirection = TextDirection.ltr,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final drafts = FakeDraftsRepository(
      drafts: [
        ComposerDraft(
          id: '0000000000000001',
          uid: 'uid-1',
          text: 'First thought',
          createdAt: now.subtract(const Duration(minutes: 6)),
          updatedAt: now.subtract(const Duration(minutes: 5)),
        ),
      ],
    );
    final posts = _MockPostsRepository();
    when(
      () => posts.listScheduledPosts(
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((_) async => pb.ListScheduledPostsResponse());
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'uid-1',
          email: 'a@example.com',
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(userId: 'uid-1', handle: 'me'),
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('came from')),
        ),
        GoRoute(
          path: '/drafts',
          builder: (context, state) => DraftsScreen(now: () => now),
        ),
        GoRoute(
          path: '/scheduled',
          builder: (context, state) => const ScheduledPostsScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<DraftsRepository>.value(value: drafts),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAppTheme(brightness: Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: Directionality(
                textDirection: textDirection,
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    unawaited(router.push<void>(path));
    await tester.pumpAndSettle();
  }

  Rect back(WidgetTester tester) => tester.getRect(find.byTooltip('Back'));

  /// The column's left edge on phones and desktop: 600 centred (the whole
  /// window below 600).
  double legacyColumnLeft(double width) => width < 600 ? 0 : (width - 600) / 2;

  const tabletWidths = [600.0, 839.0, 840.0, 1024.0, 1199.0];

  group('Drafts (full screen)', () {
    for (final width in tabletWidths) {
      for (final rtl in [false, true]) {
        testWidgets('${width.toInt()}${rtl ? ' RTL' : ''}: Back leads the '
            'window, Edit ends it, the list stays in the column', (
          tester,
        ) async {
          await open(
            tester,
            '/drafts',
            width: width,
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          );
          final edit = tester.getRect(find.widgetWithText(TextButton, 'Edit'));
          if (rtl) {
            expect(back(tester).right, moreOrLessEquals(width - AppSpacing.xs));
            expect(edit.left, moreOrLessEquals(AppSpacing.xs));
          } else {
            expect(back(tester).left, moreOrLessEquals(AppSpacing.xs));
            expect(edit.right, moreOrLessEquals(width - AppSpacing.xs));
          }
          final row = tester.getRect(find.text('First thought'));
          final column = width < AppSize.readableMax
              ? width
              : AppSize.readableMax;
          final columnLeft = (width - column) / 2;
          expect(row.left, greaterThanOrEqualTo(columnLeft));
          expect(row.right, lessThanOrEqualTo(columnLeft + column));
          // Both controls take real taps where they now sit.
          await tester.tapAt(edit.center);
          await tester.pumpAndSettle();
          expect(find.widgetWithText(TextButton, 'Done'), findsOneWidget);
          await tester.tapAt(back(tester).center);
          await tester.pumpAndSettle();
          expect(find.text('came from'), findsOneWidget);
        });
      }
    }

    testWidgets('text scale 2.0 at 600: Back and Edit stay in the window', (
      tester,
    ) async {
      await open(tester, '/drafts', width: 600, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(back(tester).left, moreOrLessEquals(AppSpacing.xs));
      final edit = tester.getRect(find.widgetWithText(TextButton, 'Edit'));
      expect(edit.right, moreOrLessEquals(600 - AppSpacing.xs));
    });

    for (final (width, flags) in <(double, Set<String>)>[
      (390, _tablet),
      (1200, _tablet),
      (1440, _tablet),
      (1024, {kFeatureUiShell}),
      (1024, {kFeatureUiTablet}),
      (1024, <String>{}),
    ]) {
      testWidgets('${width.toInt()} with $flags: Back where it was', (
        tester,
      ) async {
        await open(tester, '/drafts', width: width, flags: flags);
        expect(
          back(tester).left,
          moreOrLessEquals(legacyColumnLeft(width) + AppSpacing.xs),
        );
        final edit = tester.getRect(find.widgetWithText(TextButton, 'Edit'));
        final columnRight = width < 600 ? width : (width + 600) / 2;
        expect(edit.right, moreOrLessEquals(columnRight - AppSpacing.xs));
      });
    }
  });

  group('Scheduled (full screen)', () {
    for (final width in tabletWidths) {
      testWidgets('${width.toInt()}: Back leads the window', (tester) async {
        await open(tester, '/scheduled', width: width);
        expect(back(tester).left, moreOrLessEquals(AppSpacing.xs));
        await tester.tapAt(back(tester).center);
        await tester.pumpAndSettle();
        expect(find.text('came from'), findsOneWidget);
      });
    }

    testWidgets('1024 RTL: Back leads the window from the right', (
      tester,
    ) async {
      await open(
        tester,
        '/scheduled',
        width: 1024,
        textDirection: TextDirection.rtl,
      );
      expect(back(tester).right, 1024 - AppSpacing.xs);
    });

    for (final width in [390.0, 1440.0]) {
      testWidgets('${width.toInt()}: Back where it was', (tester) async {
        await open(tester, '/scheduled', width: width);
        expect(
          back(tester).left,
          moreOrLessEquals(legacyColumnLeft(width) + AppSpacing.xs),
        );
      });
    }
  });

  group('the cold-start composer (full screen)', () {
    Rect cancel(WidgetTester tester) => tester.getRect(
      find.descendant(of: findComposer(), matching: find.byTooltip('Close')),
    );
    Rect post(WidgetTester tester) => tester.getRect(
      find.descendant(of: findComposer(), matching: find.byType(AppPillButton)),
    );

    for (final width in tabletWidths) {
      for (final rtl in [false, true]) {
        testWidgets('${width.toInt()}${rtl ? ' RTL' : ''}: Close leads the '
            'column, Post ends it', (tester) async {
          final rig = ComposerTabletRig();
          await rig.pump(
            tester,
            width: width,
            height: 900,
            location: AppRouter.composePath,
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          );
          expect(dialogAround(findComposer()), findsNothing);
          // The header runs the width of the reading column, as the editor
          // does: Close at its start, Post at its end.
          final column = width < AppSize.readableMax
              ? width
              : AppSize.readableMax;
          final start = (width - column) / 2;
          final end = (width + column) / 2;
          if (rtl) {
            expect(cancel(tester).right, moreOrLessEquals(end - AppSpacing.sm));
            expect(post(tester).left, moreOrLessEquals(start + AppSpacing.md));
          } else {
            expect(
              cancel(tester).left,
              moreOrLessEquals(start + AppSpacing.sm),
            );
            expect(post(tester).right, moreOrLessEquals(end - AppSpacing.md));
          }
          final editor = tester.getRect(find.byType(EditableText).first);
          expect(editor.left, greaterThanOrEqualTo(start));
          expect(editor.right, lessThanOrEqualTo(end));
          // Close's real hit area closes the composer.
          await tester.tapAt(cancel(tester).center);
          await tester.pumpAndSettle();
          expect(findComposer(), findsNothing);
        });
      }
    }

    for (final width in [600.0, 1024.0]) {
      testWidgets('text scale 2.0 at ${width.toInt()}: Post is whole and in '
          'the window', (tester) async {
        final rig = ComposerTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: 900,
          location: AppRouter.composePath,
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(post(tester).right, lessThanOrEqualTo(width));
        expect(cancel(tester).left, greaterThanOrEqualTo(0));
        final label = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byType(AppPillButton),
            matching: find.text('Post'),
          ),
        );
        expect(label.didExceedMaxLines, isFalse);
      });
    }

    testWidgets('390: Close and Post at the header edges', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(
        tester,
        width: 390,
        height: 844,
        location: AppRouter.composePath,
      );
      expect(cancel(tester).left, moreOrLessEquals(AppSpacing.sm));
      expect(post(tester).right, moreOrLessEquals(390 - AppSpacing.md));
    });
  });
}
