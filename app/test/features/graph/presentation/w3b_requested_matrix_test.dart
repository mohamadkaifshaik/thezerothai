import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_account_chip.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/protected_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/suggestions_fixtures.dart' show suggestedUser;
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// W3-35c: "Requested" and its cancel confirm in a list row, and the wide
/// layouts' account menu, in the W3-21 matrix. The profile header's own
/// Requested is `w3_protected_profile_test.dart`.
void main() {
  late _MockGraph graphRepo;

  setUp(() {
    graphRepo = _MockGraph();
    when(
      () => graphRepo.unfollow(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async => graph.Relationship(userId: 'u1'));
  });

  const longName =
      'A very long display name that would fill the whole row and more';

  graph.UserListItem requestedRow() {
    final item = suggestedUser(
      1,
      follow: graph.FollowState.FOLLOW_STATE_REQUESTED,
    );
    item.user
      ..isPrivate = true
      ..displayName = longName;
    return item;
  }

  Future<void> openRow(WidgetTester tester, MatrixEnv env) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(
      value: graphRepo,
      child: UserListRow(item: requestedRow()),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
  );

  forEachThemeAndWidth('Requested in a row: 48dp, clear of the name and the '
      'lock, inside the screen', (tester, env) async {
    await openRow(tester, env);
    expectNoOverflow(tester);
    final button = find.widgetWithText(OutlinedButton, 'Requested');
    expect(button, findsOneWidget);
    expectMinTarget(tester, button, reason: 'Requested');
    expectInsideHorizontally(tester, button, env.size.width);
    final rect = tester.getRect(button);
    expect(rect.overlaps(tester.getRect(find.text(longName))), isFalse);
    expect(rect.overlaps(tester.getRect(find.text('@user1'))), isFalse);
    expect(rect.overlaps(tester.getRect(find.byType(ProtectedBadge))), isFalse);
  }, textScales: kMatrixTextScalesLarge);

  forEachThemeAndWidth('the cancel confirm: both buttons 48dp and inside the '
      'screen; Cancel request sends one Unfollow', (tester, env) async {
    await openRow(tester, env);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Requested'));
    await tester.pumpAndSettle();
    expectNoOverflow(tester);
    expect(find.text('Cancel your follow request?'), findsOneWidget);
    verifyNever(
      () => graphRepo.unfollow(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    );
    for (final button in [
      find.widgetWithText(TextButton, 'Keep request'),
      find.widgetWithText(FilledButton, 'Cancel request'),
    ]) {
      await tester.ensureVisible(button);
      expectMinTarget(tester, button);
      expectInsideHorizontally(tester, button, env.size.width);
    }

    await tester.tap(find.widgetWithText(FilledButton, 'Cancel request'));
    await tester.pumpAndSettle();
    verify(
      () => graphRepo.unfollow(
        userId: 'u1',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge);

  group('wide layouts: the account menu', () {
    // D-2 (medium): below 600 dp the drawer carries "Follow requests"; from
    // 600 dp the rail and `AppAccountChip` replace it, and the chip's menu
    // is Profile / Settings / Sign out only (app_account_chip.dart:51-61).
    // A protected account on a tablet, desktop or the web has no entry to
    // its requests except a notification row. Flip to false when fixed.
    const d2Open = true;

    for (final env in [
      for (final brightness in Brightness.values)
        for (final width in const [600.0, 1200.0])
          MatrixEnv(
            brightness: brightness,
            size: Size(width, 800),
            textScale: 1,
          ),
    ]) {
      testWidgets(
        'D-2: a protected account finds Follow requests in the chip menu '
        '[$env]',
        (tester) async {
          final onboarding = _MockOnboarding();
          whenListen(
            onboarding,
            const Stream<OnboardingState>.empty(),
            initialState: OnboardingState(
              status: OnboardingStatus.ready,
              pendingFollowRequestCount: 2,
              enabledFeatures: const {'graph'},
              profile: identity.Profile(
                userId: 'me',
                handle: 'me',
                displayName: 'Me',
                isPrivate: true,
              ),
            ),
          );
          final auth = _MockAuth();
          whenListen(
            auth,
            const Stream<AuthState>.empty(),
            initialState: const AuthState(status: AuthStatus.authenticated),
          );
          await pumpThemed(
            tester,
            MultiBlocProvider(
              providers: [
                BlocProvider<OnboardingBloc>.value(value: onboarding),
                BlocProvider<AuthBloc>.value(value: auth),
                BlocProvider<ThemeModeCubit>(
                  create: (_) => ThemeModeCubit(_NoThemeStore()),
                ),
              ],
              child: Align(
                alignment: Alignment.bottomLeft,
                child: AppAccountChip(extended: env.size.width >= 1200),
              ),
            ),
            brightness: env.brightness,
            size: env.size,
            textScale: env.textScale,
          );
          await tester.tap(find.byType(AppAccountChip));
          await tester.pumpAndSettle();
          expect(find.text('Follow requests'), findsOneWidget);
        },
        skip: d2Open,
      );
    }
  });
}
