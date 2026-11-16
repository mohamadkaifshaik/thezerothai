import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pbenum.dart' as beacons;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';


class _MockPosts extends Mock implements PostsRepository {}

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _plan = '1234567890123456789';

void main() {
  late _MockPosts repo;
  late _MockAuth auth;
  late _MockOnboarding onboarding;
  late PendingPostsCubit pending;

  final preview = pb.BeaconPreview(
    beaconId: _plan,
    title: 'Flat white before work',
    activity: beacons.BeaconActivity.BEACON_ACTIVITY_COFFEE,
    status: beacons.BeaconStatus.BEACON_STATUS_OPEN,
  );

  setUp(() {
    repo = _MockPosts();
    auth = _MockAuth();
    onboarding = _MockOnboarding();
    pending = PendingPostsCubit();
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'me',
          email: 'me@example.com',
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: const {
          kFeatureBeacons,
          kFeaturePostBeaconEmbed,
          'engagement',
          'quotes',
        },
      ),
    );
  });

  tearDown(() => pending.close());

  /// The real `/compose` route, opened at [location] with [extra].
  Future<void> open(
    WidgetTester tester,
    String location, {
    Object? extra,
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home page')),
        ),
        AppRouter.composeRoute(),
      ],
    );
    addTearDown(router.dispose);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
            theme: buildAppTheme(brightness: Brightness.light),
          ),
        ),
      ),
    );
    unawaited(router.push(location, extra: extra));
    await tester.pumpAndSettle();
  }

  final card = find.byKey(const ValueKey('composer-plan-preview'));

  testWidgets('?plan=<id> with a preview extra shows the plan card', (
    tester,
  ) async {
    await open(tester, AppRouter.composePlanPath(_plan), extra: preview);

    expect(card, findsOneWidget);
    expect(find.text('Flat white before work'), findsOneWidget);
  });

  testWidgets('?plan=<id> without an extra (cold start) shows the line', (
    tester,
  ) async {
    await open(tester, AppRouter.composePlanPath(_plan));

    expect(card, findsOneWidget);
    expect(find.text('Sharing a plan'), findsOneWidget);
  });

  testWidgets('a malformed plan id attaches nothing', (tester) async {
    await open(tester, '/compose?plan=bad', extra: preview);

    expect(card, findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a quote wins: the plan is ignored', (tester) async {
    await open(
      tester,
      '/compose?quote=1234567890123456780&plan=$_plan',
      extra: preview,
    );

    expect(card, findsNothing);
    expect(find.text('Quoting a post'), findsOneWidget);
  });
}
