import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/request_sign_out.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_dialogs.dart'
    show kSignOutDraftsBody;
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/widgets/unsent_posts_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _FailingDrafts extends FakeDraftsRepository {
  @override
  Future<void> deleteAll(String uid) async => throw StateError('disk');
}

/// Security L-5 fixes 1 and 2: the sign-out notice and the delete path
/// that does not depend on the `drafts` flag (no feature flags in the tree =
/// every flag off, so `/drafts` would redirect Home).
void main() {
  setUpAll(() => registerFallbackValue(const AuthSignOutRequested()));

  late _MockAuthBloc authBloc;
  late _MockOnboardingBloc onboardingBloc;
  late FakeDraftsRepository drafts;
  late List<Object> reported;

  ComposerDraft draft(String id, String uid) => ComposerDraft(
    id: id,
    uid: uid,
    text: 'unsent $id',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  setUp(() {
    authBloc = _MockAuthBloc();
    when(() => authBloc.add(any())).thenReturn(null);
    whenListen(
      authBloc,
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
    onboardingBloc = _MockOnboardingBloc();
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );
    reported = [];
    drafts = FakeDraftsRepository(
      drafts: [draft('a', 'uid-1'), draft('b', 'uid-1'), draft('c', 'uid-2')],
    );
  });

  Widget app() => MultiBlocProvider(
    providers: [
      BlocProvider<AuthBloc>.value(value: authBloc),
      BlocProvider<ThemeModeCubit>(
        create: (_) => ThemeModeCubit(_MemoryThemeStore()),
      ),
      BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
    ],
    child: const MaterialApp(home: SettingsScreen()),
  );

  Future<void> pump(
    WidgetTester tester, {
    DraftsRepository? repo,
    Set<String> flags = const {kFeaturePosts},
  }) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: flags),
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<DraftsRepository>.value(value: repo ?? drafts),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, _) => reported.add(error),
          ),
        ],
        child: app(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('Delete unsent posts on this device (drafts flag off)', () {
    testWidgets('posts on, drafts off: shown and deletes (no /drafts needed)', (
      tester,
    ) async {
      await pump(tester, flags: const {kFeaturePosts});
      expect(find.text(kUnsentPostsRowTitle), findsOneWidget);
      await tapText(tester, kUnsentPostsRowTitle);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(drafts.rows.map((d) => d.id), ['c']);
    });

    testWidgets('every flag off (kill switch for posts too): still shown', (
      tester,
    ) async {
      await pump(tester, flags: const {});
      expect(find.text(kUnsentPostsRowTitle), findsOneWidget);
    });

    testWidgets('drafts on: shown too (a privacy control, not only a '
        'fallback)', (tester) async {
      await pump(tester, flags: const {kFeaturePosts, kFeatureDrafts});
      expect(find.text(kUnsentPostsRowTitle), findsOneWidget);
    });

    testWidgets('shows with the count while this account has rows', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text(kUnsentPostsRowTitle), findsOneWidget);
      expect(find.text('2 unsent posts'), findsOneWidget);
    });

    testWidgets('is hidden when only another account has rows', (tester) async {
      drafts.rows.removeWhere((d) => d.uid == 'uid-1');
      await pump(tester);
      expect(find.text(kUnsentPostsRowTitle), findsNothing);
    });

    testWidgets('is hidden without a repository in the tree', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text(kUnsentPostsRowTitle), findsNothing);
    });

    testWidgets('confirm deletes only this uid and the row disappears', (
      tester,
    ) async {
      await pump(tester);
      await tapText(tester, kUnsentPostsRowTitle);
      expect(drafts.wiped, isEmpty, reason: 'asks first');
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(drafts.wiped, ['uid-1']);
      expect(drafts.rows.map((d) => d.id), ['c']);
      expect(find.text(kUnsentPostsDeleted), findsOneWidget);
      expect(find.text(kUnsentPostsRowTitle), findsNothing);
    });

    testWidgets('Keep keeps everything', (tester) async {
      await pump(tester);
      await tapText(tester, kUnsentPostsRowTitle);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(drafts.wiped, isEmpty);
      expect(find.text(kUnsentPostsRowTitle), findsOneWidget);
    });

    testWidgets('a storage failure is said and reported without the text', (
      tester,
    ) async {
      final failing = _FailingDrafts()..rows.addAll(drafts.rows);
      await pump(tester, repo: failing);
      await tapText(tester, kUnsentPostsRowTitle);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text(kUnsentPostsDeleteFailed), findsOneWidget);
      expect(find.text(kUnsentPostsRowTitle), findsOneWidget);
      expect(reported.single.toString(), isNot(contains('unsent')));
    });
  });

  group('sign-out notice', () {
    testWidgets('shown when the signed-in uid has unsent posts', (
      tester,
    ) async {
      await pump(tester);
      await tapText(tester, 'Sign out');
      expect(find.text('Sign out?'), findsOneWidget);
      expect(find.text(kSignOutDraftsBody), findsOneWidget);
      verifyNever(() => authBloc.add(any()));
    });

    testWidgets('not shown when only another uid has rows: signs out', (
      tester,
    ) async {
      drafts.rows.removeWhere((d) => d.uid == 'uid-1');
      await pump(tester);
      await tapText(tester, 'Sign out');
      expect(find.text('Sign out?'), findsNothing);
      verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
    });

    testWidgets('Keep signs out and keeps every row', (tester) async {
      await pump(tester);
      await tapText(tester, 'Sign out');
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
      expect(drafts.rows, hasLength(3));
      expect(drafts.wiped, isEmpty);
    });

    testWidgets('Delete them removes only this uid, then signs out', (
      tester,
    ) async {
      await pump(tester);
      await tapText(tester, 'Sign out');
      await tester.tap(find.text('Delete them'));
      await tester.pumpAndSettle();
      expect(drafts.wiped, ['uid-1']);
      expect(drafts.rows.map((d) => '${d.uid}/${d.id}'), ['uid-2/c']);
      verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
    });

    testWidgets('Cancel stays signed in and keeps the rows', (tester) async {
      await pump(tester);
      await tapText(tester, 'Sign out');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(() => authBloc.add(any()));
      expect(drafts.rows, hasLength(3));
    });

    testWidgets('a failed delete keeps the user signed in and says so', (
      tester,
    ) async {
      final failing = _FailingDrafts()..rows.addAll(drafts.rows);
      await pump(tester, repo: failing);
      await tapText(tester, 'Sign out');
      await tester.tap(find.text('Delete them'));
      await tester.pumpAndSettle();
      verifyNever(() => authBloc.add(any()));
      expect(find.text(kSignOutDeleteFailed), findsOneWidget);
      expect(failing.rows, hasLength(3));
    });
  });
}
