import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/feature_flags.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/message_outbox.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/messaging_update_copy.dart';
import 'package:dzeroth/features/messages/presentation/widgets/messaging_update_required.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/dz_finders.dart';
import '../../support/messaging_fixtures.dart';
import '../../support/messaging_shell_rig.dart';
import '../../support/thread_test_support.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockMessagingRepository extends Mock implements MessagingRepository {
  @override
  final MessageOutbox outbox = MessageOutbox();
}

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockIdentityRepository extends Mock implements IdentityRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// A build below the server's floor for messaging
/// (`GetMe.features_needing_update`): `/messages` and every messages deep link
/// open the update prompt in place of the inbox (Plan 6 Task 3.C). With the
/// floor off (messaging simply off) nothing changes: Home, no destination.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );
  late MessagingShellRig rig;

  setUpAll(() => registerFallbackValue(Folder.FOLDER_INBOX));
  setUp(() => rig = MessagingShellRig());

  Future<(String, _MockMessagingRepository)> openAt(
    WidgetTester tester, {
    required Set<String> flags,
    Set<String> needingUpdate = const {},
    String location = AppRouter.messagesPath,
    double width = 390,
    StreamController<OnboardingState>? states,
    void Function(_MockMessagingRepository repo)? stub,
  }) async {
    final repo = _MockMessagingRepository();
    stub?.call(repo);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => repo.rateLimitHold).thenReturn(RateLimitHold());
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final badge = UnreadBadgeCubit();
    addTearDown(badge.close);
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );
    whenListen(
      onboarding,
      states?.stream ?? const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'uid-1', handle: 'me'),
        enabledFeatures: flags,
        featuresNeedingUpdate: needingUpdate,
      ),
    );
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    appRouter.router.go(location);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
          RepositoryProvider<GraphRepository>.value(
            value: _MockGraphRepository(),
          ),
          RepositoryProvider<IdentityRepository>.value(
            value: _MockIdentityRepository(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<UnreadBadgeCubit>.value(value: badge),
            ...rig.providers,
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(routerConfig: appRouter.router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (appRouter.router.routeInformationProvider.value.uri.path, repo);
  }

  const update = {'messaging'};

  testWidgets(
    'FEATURE_DISABLED with update_required shows the prompt, not a hidden tab',
    (tester) async {
      final (path, repo) = await openAt(
        tester,
        flags: const {kFeatureUiShell},
        needingUpdate: update,
      );

      expect(path, AppRouter.messagesPath);
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(find.byType(MessagingUpdateRequired), findsOneWidget);
      expect(find.text(kUpdateToMessageTitle), findsOneWidget);
      // The inbox's own header, not a plain AppBar.
      expect(find.byType(AppTopBar), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      // The destination is still there (selected on its own page).
      expect(byNavIcon(Icons.mail), findsOneWidget);
      verifyNever(() => repo.cachedConversations(any()));
      verifyNever(() => repo.refreshConversations(any()));
    },
  );

  for (final link in [
    AppRouter.messageRequestsPath,
    AppRouter.messageNewPath,
    AppRouter.messageDraftPath,
    AppRouter.messagePath(kThreadId),
  ]) {
    testWidgets('the deep link $link lands on the prompt', (tester) async {
      final (path, repo) = await openAt(
        tester,
        flags: const {kFeatureUiShell},
        needingUpdate: update,
        location: link,
      );

      expect(path, AppRouter.messagesPath);
      expect(find.byType(MessagingUpdateRequired), findsOneWidget);
      verifyNever(() => repo.refreshThread(any()));
      verifyNever(() => repo.refreshConversations(any()));
    });
  }

  for (final width in [390.0, 700.0, 1300.0]) {
    testWidgets('the prompt is inside the shell at ${width.toInt()} dp', (
      tester,
    ) async {
      await openAt(
        tester,
        flags: const {kFeatureUiShell},
        needingUpdate: update,
        width: width,
      );

      expect(tester.takeException(), isNull);
      expect(find.text(kUpdateToMessageTitle), findsOneWidget);
      expect(byNavIcon(Icons.mail), findsOneWidget);
    });
  }

  testWidgets('messaging simply off: Home, no destination, no prompt', (
    tester,
  ) async {
    final (path, _) = await openAt(
      tester,
      flags: const {kFeatureUiShell},
      location: AppRouter.messageRequestsPath,
    );

    expect(path, AppRouter.homePath);
    expect(find.byType(MessagingUpdateRequired), findsNothing);
    expect(byNavIcon(Icons.mail_outline), findsNothing);
    expect(byNavIcon(Icons.mail), findsNothing);
  });

  testWidgets('the floor arriving mid-session: a thread open with messaging on '
      'goes to the prompt, with no more thread or inbox reads', (tester) async {
    final states = StreamController<OnboardingState>.broadcast();
    addTearDown(states.close);
    final header = threadConv();
    final (_, repo) = await openAt(
      tester,
      flags: const {kFeatureUiShell, 'messaging'},
      location: AppRouter.messagePath(kThreadId),
      states: states,
      stub: (repo) {
        when(() => repo.cachedConversations(any())).thenAnswer(
          (_) async => const ConversationsSnapshot(conversations: []),
        );
        when(() => repo.refreshConversations(any())).thenAnswer(
          (_) async => ConversationsResult(
            const ConversationsSnapshot(conversations: []),
            requestCount: 0,
          ),
        );
        when(() => repo.cachedThread(any())).thenAnswer(
          (_) async =>
              ThreadSnapshot(messages: msgs(1, 2), conversation: header),
        );
        when(() => repo.refreshThread(any())).thenAnswer(
          (_) async =>
              ThreadSnapshot(messages: msgs(1, 2), conversation: header),
        );
        when(() => repo.cachedConversationWith(any()))
            .thenAnswer((_) async => null);
      },
    );
    expect(find.byType(MessagingUpdateRequired), findsNothing);

    clearInteractions(repo);
    states.add(
      OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'uid-1', handle: 'me'),
        enabledFeatures: const {kFeatureUiShell},
        featuresNeedingUpdate: const {'messaging'},
      ),
    );
    await tester.pumpAndSettle();

    final router = GoRouter.of(
      tester.element(find.byType(MessagingUpdateRequired)),
    );
    expect(router.routeInformationProvider.value.uri.path, '/messages');
    expect(find.byType(MessagingUpdateRequired), findsOneWidget);
    verifyNever(() => repo.refreshThread(any()));
    verifyNever(() => repo.refreshConversations(any()));
  });

  test(
    'needsUpdateFor: only when off AND listed (floors at 0 change nothing)',
    () {
      OnboardingState s(Set<String> on, Set<String> upd) =>
          OnboardingState(enabledFeatures: on, featuresNeedingUpdate: upd);
      expect(needsUpdateFor(s({}, {'messaging'}), 'messaging'), isTrue);
      expect(
        needsUpdateFor(s({'messaging'}, {'messaging'}), 'messaging'),
        isFalse,
      );
      expect(needsUpdateFor(s({}, {}), 'messaging'), isFalse);
      expect(needsUpdateFor(const OnboardingState(), 'messaging'), isFalse);
    },
  );
}
