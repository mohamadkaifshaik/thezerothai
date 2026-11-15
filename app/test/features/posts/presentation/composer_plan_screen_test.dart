import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
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
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pbenum.dart' as beacons;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _MockPosts extends Mock implements PostsRepository {}

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _plan = '1234567890123456789';
const _flags = {
  kFeatureBeacons,
  kFeaturePostBeaconEmbed,
  'engagement',
  'polls',
};

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
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
  });

  tearDown(() => pending.close());

  void stubCreate(Future<pb.PostView> Function() answer) => when(
    () => repo.createPost(
      idempotencyKey: any(named: 'idempotencyKey'),
      text: any(named: 'text'),
      replyToPostId: any(named: 'replyToPostId'),
      quoteOfPostId: any(named: 'quoteOfPostId'),
      mediaIds: any(named: 'mediaIds'),
      mediaAltTexts: any(named: 'mediaAltTexts'),
      beaconId: any(named: 'beaconId'),
    ),
  ).thenAnswer((_) => answer());

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = _flags,
    String plan = _plan,
    pb.BeaconPreview? withPreview,
    Size size = const Size(400, 800),
    Brightness brightness = Brightness.light,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: features,
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/compose',
          builder: (_, _) =>
              ComposerScreen(planId: plan, planPreview: withPreview),
        ),
      ],
    );
    addTearDown(router.dispose);
    tester.view.physicalSize = size;
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
            theme: buildAppTheme(brightness: brightness),
          ),
        ),
      ),
    );
    unawaited(router.push('/compose'));
    await tester.pumpAndSettle();
  }

  final previewCard = find.byKey(const ValueKey('composer-plan-preview'));
  final remove = find.byTooltip('Remove plan');

  Future<void> post(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
    await tester.pumpAndSettle();
  }

  List<String> sentBeaconIds() => verify(
    () => repo.createPost(
      idempotencyKey: any(named: 'idempotencyKey'),
      text: any(named: 'text'),
      replyToPostId: any(named: 'replyToPostId'),
      quoteOfPostId: any(named: 'quoteOfPostId'),
      mediaIds: any(named: 'mediaIds'),
      mediaAltTexts: any(named: 'mediaAltTexts'),
      beaconId: captureAny(named: 'beaconId'),
    ),
  ).captured.cast<String>();

  testWidgets('shows the plan card, not tappable, with a remove button', (
    tester,
  ) async {
    await open(tester, withPreview: preview);

    expect(previewCard, findsOneWidget);
    expect(find.text('Flat white before work'), findsOneWidget);
    // Preview mode: no "Ask to join".
    expect(find.text('Ask to join'), findsNothing);
    expect(remove, findsOneWidget);
  });

  testWidgets('Post sends the plan as beacon_id', (tester) async {
    stubCreate(() async => postView(9));
    await open(tester, withPreview: preview);

    await post(tester, 'come along');

    expect(sentBeaconIds(), [_plan]);
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('removing the plan sends a plain post', (tester) async {
    stubCreate(() async => postView(9));
    await open(tester, withPreview: preview);

    await tester.tap(remove);
    await tester.pump();
    expect(previewCard, findsNothing);
    await post(tester, 'just text');

    expect(sentBeaconIds(), ['']);
  });

  testWidgets('the poll button is disabled with its reason while a plan is '
      'attached', (tester) async {
    await open(tester, withPreview: preview);

    final poll = find.byTooltip("Polls can't go with a plan");
    expect(poll, findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(of: poll, matching: find.byType(IconButton)).first,
          )
          .onPressed,
      isNull,
    );

    await tester.tap(remove);
    await tester.pump();
    expect(find.byTooltip('Add poll'), findsOneWidget);
  });

  testWidgets('without a preview (page reload) a plain line stands in', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Sharing a plan'), findsOneWidget);
    expect(remove, findsOneWidget);
  });

  testWidgets('VALIDATION beacon_id shows its own message', (tester) async {
    stubCreate(
      () async => throw const ValidationException('bad', field: 'beacon_id'),
    );
    await open(tester, withPreview: preview);

    await post(tester, 'come along');

    expect(
      find.textContaining("This plan can't be shared in this post"),
      findsOneWidget,
    );
  });

  testWidgets('NOT_FOUND reads as the plan, and the plan stays', (
    tester,
  ) async {
    stubCreate(() async => throw const NotFoundException('beacon not found'));
    await open(tester, withPreview: preview);

    await post(tester, 'come along');

    expect(find.text("This plan isn't available any more."), findsOneWidget);
    expect(previewCard, findsOneWidget);
  });

  testWidgets('post_beacon_embed off: a plain composer, no plan', (
    tester,
  ) async {
    stubCreate(() async => postView(9));
    await open(
      tester,
      withPreview: preview,
      features: {kFeatureBeacons, 'engagement', 'polls'},
    );

    expect(previewCard, findsNothing);
    await post(tester, 'text only');
    expect(sentBeaconIds(), ['']);
  });

  for (final brightness in Brightness.values) {
    for (final size in const [
      Size(390, 844),
      Size(800, 900),
      Size(1280, 900),
    ]) {
      testWidgets(
        '${size.width.toInt()} dp, ${brightness.name}: the preview fits',
        (tester) async {
          await open(
            tester,
            withPreview: preview,
            size: size,
            brightness: brightness,
          );

          expect(previewCard, findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
