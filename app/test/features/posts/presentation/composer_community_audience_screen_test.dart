import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/features/posts/presentation/widgets/audience_pill.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pbc;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/scheduled_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _idA = '1000000000000000001';
const _idB = '1000000000000000002';

pbc.Community _community(String id, String name, {int members = 1200}) =>
    pbc.Community(
      communityId: id,
      name: name,
      memberCount: Int64(members),
      viewerRole: pbc.CommunityRole.COMMUNITY_ROLE_MEMBER,
    );

/// The audience pill and "Choose audience" sheet of `/compose`.
void main() {
  late _MockPostsRepository repo;
  late _MockCommunities communities;
  late PendingPostsCubit pending;
  late int listCalls;

  setUpAll(() {
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  setUp(() {
    repo = _MockPostsRepository();
    communities = _MockCommunities();
    pending = PendingPostsCubit();
    listCalls = 0;
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
    when(() => communities.cachedMine).thenReturn(null);
    when(() => communities.myCommunities()).thenAnswer((_) async {
      listCalls++;
      return MyCommunities(
        communities: [
          _community(_idA, 'Nets Twitter', members: 6500),
          _community(_idB, 'Gardeners', members: 1),
        ],
        canCreate: false,
      );
    });
  });

  tearDown(() => pending.close());

  void stubCreate({bool labelled = true}) {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
        communityId: any(named: 'communityId'),
      ),
    ).thenAnswer((i) async {
      final view = postView(1);
      final id = i.namedArguments[#communityId] as String;
      if (labelled && id.isNotEmpty) {
        view.post.community = pb.CommunityRef(id: id, name: 'Nets Twitter');
      }
      return view;
    });
  }

  String sentCommunity() {
    final captured = verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
        communityId: captureAny(named: 'communityId'),
      ),
    ).captured;
    return captured.single as String;
  }

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'communities', 'posts', 'scheduled_posts'},
    bool isPrivate = false,
    String community = '',
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
        profile: identity.Profile(
          userId: 'me',
          handle: 'me',
          isPrivate: isPrivate,
        ),
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
          builder: (context, state) => ComposerScreen(communityId: community),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: repo),
          RepositoryProvider<CommunitiesRepository>.value(value: communities),
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

  final pill = find.byType(AudiencePill);
  final pillTap = find.descendant(of: pill, matching: find.byType(InkWell));

  Future<void> choose(WidgetTester tester, String name) async {
    await tester.tap(pillTap);
    await tester.pumpAndSettle();
    expect(find.text('Choose audience'), findsOneWidget);
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  group('offer', () {
    testWidgets('flag off: no pill and no call', (tester) async {
      await open(tester, features: const {'posts'});
      expect(pill, findsNothing);
      verifyNever(() => communities.myCommunities());
    });

    testWidgets('no memberships: no pill', (tester) async {
      when(() => communities.myCommunities()).thenAnswer(
        (_) async => const MyCommunities(communities: [], canCreate: false),
      );
      await open(tester);
      expect(pill, findsNothing);
    });

    testWidgets('a protected account: no pill and no call', (tester) async {
      await open(tester, isPrivate: true);
      expect(pill, findsNothing);
      verifyNever(() => communities.myCommunities());
    });

    testWidgets('a membership: "Everyone" pill under the avatar row', (
      tester,
    ) async {
      await open(tester);
      expect(pill, findsOneWidget);
      expect(find.text('Everyone'), findsOneWidget);
      expect(listCalls, 1);
    });

    testWidgets('schedule mode hides the pill and Everyone is restored', (
      tester,
    ) async {
      await open(tester);
      final cubit = BlocProvider.of<ComposerCubit>(
        tester.element(find.byType(TextField)),
      );
      cubit.scheduleChanged(scheduledBase().add(const Duration(days: 2)));
      await tester.pumpAndSettle();
      expect(pill, findsNothing);
      cubit.scheduleChanged(null);
      await tester.pumpAndSettle();
      expect(pill, findsOneWidget);
    });
  });

  group('choosing', () {
    testWidgets(
      'the sheet lists Everyone then My Communities (name, N members)',
      (tester) async {
        await open(tester);
        await tester.tap(pillTap);
        await tester.pumpAndSettle();
        expect(find.text('Choose audience'), findsOneWidget);
        expect(find.text('Everyone'), findsNWidgets(2), reason: 'pill + row');
        expect(find.text('My Communities'), findsOneWidget);
        expect(find.text('Nets Twitter'), findsOneWidget);
        expect(find.text('6500 members'), findsOneWidget);
        expect(find.text('1 member'), findsOneWidget);
      },
    );

    testWidgets(
      'a community is chosen, replaces the reply control and is sent',
      (tester) async {
        stubCreate();
        await open(tester);
        await choose(tester, 'Nets Twitter');
        expect(
          find.descendant(of: pill, matching: find.text('Nets Twitter')),
          findsOneWidget,
        );
        expect(find.textContaining('can reply'), findsNothing);
        await tester.enterText(find.byType(TextField), 'hello community');
        await tester.pump();
        await tester.tap(find.text('Post'));
        await tester.pumpAndSettle();
        expect(sentCommunity(), _idA);
        expect(find.text('home page'), findsOneWidget);
      },
    );

    testWidgets('Everyone sends no community', (tester) async {
      stubCreate();
      await open(tester);
      await tester.enterText(find.byType(TextField), 'hello all');
      await tester.pump();
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(sentCommunity(), '');
    });

    testWidgets('a server that drops the label is warned about', (
      tester,
    ) async {
      stubCreate(labelled: false);
      await open(tester);
      await choose(tester, 'Gardeners');
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(find.text(kCommunityNotAddedMessage), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('not a member: Everyone again and a friendly message', (
      tester,
    ) async {
      when(
        () => repo.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: any(named: 'replyToPostId'),
          quoteOfPostId: any(named: 'quoteOfPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
          replyPolicy: any(named: 'replyPolicy'),
          communityId: any(named: 'communityId'),
        ),
      ).thenThrow(
        CommunityForbiddenException(CommunityForbiddenReason.notMember),
      );
      await open(tester);
      await choose(tester, 'Nets Twitter');
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(
        find.text('Only members of this community can do that.'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: pill, matching: find.text('Everyone')),
        findsOneWidget,
      );
      expect(find.text('hello'), findsOneWidget, reason: 'the text stays');
    });

    testWidgets('/compose?community=<id> preselects a joined community', (
      tester,
    ) async {
      await open(tester, community: _idB);
      expect(
        find.descendant(of: pill, matching: find.text('Gardeners')),
        findsOneWidget,
      );
    });

    testWidgets('a community the caller is not in: Everyone and a notice', (
      tester,
    ) async {
      await open(tester, community: '1000000000000000099');
      expect(
        find.descendant(of: pill, matching: find.text('Everyone')),
        findsOneWidget,
      );
      expect(find.textContaining('not in that community'), findsOneWidget);
    });

    testWidgets('a failed read of the list says so when one was asked for', (
      tester,
    ) async {
      when(() => communities.myCommunities())
          .thenThrow(const NetworkException('offline'));
      await open(tester, community: _idA);
      expect(pill, findsNothing);
      expect(
        find.textContaining("Couldn't load your communities"),
        findsOneWidget,
      );
    });
  });

  group('keyboard and semantics', () {
    testWidgets('the pill opens from the keyboard and rows are menu items', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Choose audience, Everyone'))
            .label,
        'Choose audience, Everyone',
      );
      // Tab to the pill (the text field has the focus first), then Enter.
      var onPill = false;
      for (var i = 0; i < 20 && !onPill; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final ctx = FocusManager.instance.primaryFocus?.context;
        onPill = ctx?.findAncestorWidgetOfExactType<AudiencePill>() != null;
      }
      expect(onPill, isTrue, reason: 'the pill is reachable with Tab');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Choose audience'), findsOneWidget);
      for (final label in [
        'Everyone',
        'Nets Twitter, 6500 members',
        'Gardeners, 1 member',
      ]) {
        final node = tester.getSemantics(find.bySemanticsLabel(label).last);
        expect(
          node.getSemanticsData().role,
          SemanticsRole.menuItem,
          reason: label,
        );
      }
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Everyone').last)
            .flagsCollection
            .isSelected,
        isNotNull,
      );
      handle.dispose();
    });
  });

  group('matrix', () {
    forEachThemeAndWidth(
      'pill and sheet fit',
      (tester, env) async {
        await open(
          tester,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );
        when(() => communities.cachedMine).thenReturn(null);
        expect(pill, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(pillTap);
        await tester.pumpAndSettle();
        expect(find.text('My Communities'), findsOneWidget);
        expect(tester.takeException(), isNull);
        // 48dp target.
        expect(tester.getSize(pill).height, greaterThanOrEqualTo(48));
      },
      textScales: kMatrixTextScalesLarge,
      height: 844,
    );
  });
}
