import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
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

/// The reply-audience control of `/compose` (ADR-0021 D2, CMP-B3): the link,
/// the "Who can reply?" sheet, what is sent and the L-1 echo notice.
void main() {
  late _MockPostsRepository repo;
  late PendingPostsCubit pending;

  setUpAll(() {
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  setUp(() {
    repo = _MockPostsRepository();
    pending = PendingPostsCubit();
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() => pending.close());

  void stubCreate({ReplyPolicy echo = ReplyPolicy.REPLY_POLICY_UNSPECIFIED}) {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
      ),
    ).thenAnswer((_) async {
      final view = postView(1);
      view.post.replyPolicy = echo;
      return view;
    });
  }

  ReplyPolicy sent() {
    final captured = verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: captureAny(named: 'replyPolicy'),
      ),
    ).captured;
    return captured.single as ReplyPolicy;
  }

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'reply_audience'},
    String quote = '',
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
        enabledFeatures: features,
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
          builder: (context, state) => ComposerScreen(quoteOfPostId: quote),
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

  Finder link(String text) => find.text(text);

  Future<void> pick(WidgetTester tester, String optionLabel) async {
    await tester.tap(find.text('Everyone can reply'));
    await tester.pumpAndSettle();
    expect(find.text('Who can reply?'), findsOneWidget);
    await tester.tap(find.text(optionLabel));
    await tester.pumpAndSettle();
  }

  testWidgets('hidden when the feature is off', (tester) async {
    await open(tester, features: const {});
    expect(find.textContaining('can reply'), findsNothing);
  });

  testWidgets('hidden when the quote composer has no flag either', (
    tester,
  ) async {
    await open(
      tester,
      features: const {'engagement', 'quotes'},
      quote: postId(5),
    );
    expect(find.textContaining('can reply'), findsNothing);
  });

  testWidgets('shown on a new post: "Everyone can reply", 48dp target', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    expect(link('Everyone can reply'), findsOneWidget);
    expect(find.byIcon(Icons.public), findsOneWidget);
    final node = tester.getSemantics(
      find.bySemanticsLabel('Everyone can reply'),
    );
    expect(node.rect.height, greaterThanOrEqualTo(48));
    expect(node.getSemanticsData().hint, 'Choose who can reply');
    handle.dispose();
  });

  testWidgets('shown on a quote', (tester) async {
    await open(
      tester,
      features: const {'reply_audience', 'engagement', 'quotes'},
      quote: postId(5),
    );
    expect(link('Everyone can reply'), findsOneWidget);
  });

  testWidgets('default: Post sends UNSPECIFIED', (tester) async {
    stubCreate();
    await open(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(sent(), ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    expect(find.text('home page'), findsOneWidget);
    expect(find.text(kReplyPolicyNotAppliedMessage), findsNothing);
  });

  testWidgets('picking Accounts you follow: link text and FOLLOWING sent', (
    tester,
  ) async {
    stubCreate(echo: ReplyPolicy.REPLY_POLICY_FOLLOWING);
    await open(tester);
    await pick(tester, 'Accounts you follow');

    expect(link('Accounts you follow can reply'), findsOneWidget);
    expect(find.byIcon(Icons.how_to_reg_outlined), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(sent(), ReplyPolicy.REPLY_POLICY_FOLLOWING);
    expect(find.text(kReplyPolicyNotAppliedMessage), findsNothing);
  });

  testWidgets('picking Only accounts you mention: MENTIONED_ONLY sent', (
    tester,
  ) async {
    stubCreate(echo: ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY);
    await open(tester);
    await pick(tester, 'Only accounts you mention');

    expect(link('Only accounts you mention can reply'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(sent(), ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY);
  });

  testWidgets('choosing Everyone again sends UNSPECIFIED', (tester) async {
    stubCreate();
    await open(tester);
    await pick(tester, 'Accounts you follow');
    await tester.tap(find.text('Accounts you follow can reply'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyone'));
    await tester.pumpAndSettle();
    expect(link('Everyone can reply'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(sent(), ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  testWidgets('the choice survives typing', (tester) async {
    await open(tester);
    await pick(tester, 'Accounts you follow');
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump();
    expect(link('Accounts you follow can reply'), findsOneWidget);
  });

  testWidgets('echo mismatch: the notice shows on the page left behind', (
    tester,
  ) async {
    // An old revision dropped the field: the post comes back for everyone.
    stubCreate();
    await open(tester);
    await pick(tester, 'Only accounts you mention');
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(find.text('home page'), findsOneWidget);
    expect(find.text(kReplyPolicyNotAppliedMessage), findsOneWidget);
    expect(
      kReplyPolicyNotAppliedMessage,
      'Your reply setting could not be applied. Everyone can reply to this '
      'post.',
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('longest link at 360dp, text x1.3, ${brightness.name}: fits', (
      tester,
    ) async {
      await open(
        tester,
        size: const Size(360, 640),
        brightness: brightness,
        textScale: 1.3,
      );
      await pick(tester, 'Only accounts you mention');
      expect(tester.takeException(), isNull);
      final text = find.text('Only accounts you mention can reply');
      expect(text, findsOneWidget);
      expect(tester.getRect(text).right, lessThanOrEqualTo(360));
    });
  }
}
