import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/follow_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_send_repository.dart';
import '../../../support/thread_test_support.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W7-17: the round "Message" button on another user's profile.
void main() {
  late _MockGraph graphRepository;

  setUp(() {
    graphRepository = _MockGraph();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  final profile = identity.Profile(
    userId: 'u-kaif',
    handle: 'kaif',
    displayName: 'Kaif Shaik',
  );

  Future<void> header(
    WidgetTester tester, {
    bool own = false,
    bool graphEnabled = true,
    bool blocking = false,
    VoidCallback? onMessage,
    Size size = const Size(400, 800),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<ModerationRepository>.value(
            value: _MockModeration(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (e, s) {}),
        ],
        child: MaterialApp(
          theme: buildAppTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfileHeader(
                profile: profile,
                isOwnProfile: own,
                graphEnabled: graphEnabled,
                relationship: own || !graphEnabled
                    ? null
                    : graph.Relationship(userId: 'u-kaif', blocking: blocking),
                onMessage: onMessage,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder button() => find.byType(MessageButton);

  group('ProfileHeader Message button', () {
    testWidgets('sits left of Follow, is a 48dp target and calls back', (
      tester,
    ) async {
      var taps = 0;
      await header(tester, onMessage: () => taps++);

      expect(button(), findsOneWidget);
      final message = tester.getRect(button());
      final follow = tester.getRect(find.byType(FollowButton));
      expect(message.right, lessThanOrEqualTo(follow.left));
      expect(message.width, greaterThanOrEqualTo(48));
      expect(message.height, greaterThanOrEqualTo(48));
      expect(find.byTooltip('Message @kaif'), findsOneWidget);
      expect(find.byIcon(Icons.mail_outline), findsOneWidget);

      await tester.tap(button());
      expect(taps, 1);
    });

    testWidgets('hidden when the viewer blocks the profile', (tester) async {
      await header(tester, blocking: true, onMessage: () {});
      expect(button(), findsNothing);
      expect(find.text('Unblock'), findsOneWidget);
    });

    testWidgets('hidden without a callback (messaging off for the caller)', (
      tester,
    ) async {
      await header(tester);
      expect(button(), findsNothing);
    });

    testWidgets('hidden on the viewer\'s own profile', (tester) async {
      await header(tester, own: true, onMessage: () {});
      expect(button(), findsNothing);
    });

    testWidgets('graph off: the button is still offered (the server is '
        'authoritative)', (tester) async {
      await header(tester, graphEnabled: false, onMessage: () {});
      expect(button(), findsOneWidget);
      expect(find.byType(FollowButton), findsNothing);
    });

    for (final width in [360.0, 600.0, 1200.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final brightness in Brightness.values) {
          testWidgets(
            'no overflow [${width.toInt()}dp x$scale ${brightness.name}]',
            (tester) async {
              await header(
                tester,
                onMessage: () {},
                size: Size(width, 800),
                textScale: scale,
                brightness: brightness,
              );
              expect(tester.takeException(), isNull);
              expect(button(), findsOneWidget);
              final rect = tester.getRect(button());
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(width));
            },
          );
        }
      }
    }
  });

  group('ProfileScreen wiring (messaging flag)', () {
    late _MockIdentity identityRepository;
    late _MockOnboarding onboarding;
    late FakeSendRepository messaging;

    setUp(() {
      identityRepository = _MockIdentity();
      onboarding = _MockOnboarding();
      messaging = FakeSendRepository();
      when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
        (_) async => identity.Profile(
          userId: 'target-uid',
          handle: 'kaif',
          displayName: 'Kaif Shaik',
        ),
      );
    });

    Future<GoRouter> openScreen(
      WidgetTester tester, {
      required Set<String> features,
      bool blocking = false,
    }) async {
      when(() => graphRepository.profileRelationshipFor('target-uid'))
          .thenAnswer(
            (_) async => ProfileRelationship(
              relationship: graph.Relationship(
                userId: 'target-uid',
                blocking: blocking,
              ),
            ),
          );
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(
          enabledFeatures: features,
          profile: identity.Profile(userId: 'viewer-uid', handle: 'me'),
        ),
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const ProfileScreen(handle: 'kaif'),
          ),
          GoRoute(
            path: '/messages/new/draft',
            builder: (context, state) => Scaffold(
              body: Text(
                'draft ${(state.extra! as common.AuthorSnapshot).userId}',
              ),
            ),
          ),
          GoRoute(
            path: '/messages/:id',
            builder: (context, state) =>
                Scaffold(body: Text('thread ${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<IdentityRepository>.value(
              value: identityRepository,
            ),
            RepositoryProvider<GraphRepository>.value(value: graphRepository),
            RepositoryProvider<MessagingRepository>.value(value: messaging),
          ],
          child: BlocProvider<OnboardingBloc>.value(
            value: onboarding,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('messaging on: the button opens a draft with that person', (
      tester,
    ) async {
      await openScreen(tester, features: const {'graph', 'messaging'});
      expect(find.byType(MessageButton), findsOneWidget);

      await tester.tap(find.byType(MessageButton));
      await tester.pumpAndSettle();

      expect(find.text('draft target-uid'), findsOneWidget);
    });

    testWidgets('messaging on and a conversation is cached: it opens, no '
        'draft', (tester) async {
      messaging.cachedByPeer['target-uid'] = threadConv(id: kThreadId);
      await openScreen(tester, features: const {'graph', 'messaging'});

      await tester.tap(find.byType(MessageButton));
      await tester.pumpAndSettle();

      expect(find.text('thread $kThreadId'), findsOneWidget);
    });

    testWidgets('messaging off: no button', (tester) async {
      await openScreen(tester, features: const {'graph'});
      expect(find.byType(MessageButton), findsNothing);
      expect(find.text('Follow'), findsOneWidget);
    });

    testWidgets('a blocked target: no button', (tester) async {
      await openScreen(
        tester,
        features: const {'graph', 'messaging'},
        blocking: true,
      );
      expect(find.byType(MessageButton), findsNothing);
    });
  });
}
