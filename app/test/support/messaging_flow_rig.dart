import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pb.dart'
    as moderation;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import 'fake_transport.dart';
import 'messaging_fixtures.dart';
import 'messaging_shell_rig.dart';
import 'thread_test_support.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockTimeline extends Mock implements TimelineRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// A tiny in-memory messaging server behind a [FakeTransport] handler: it
/// keeps conversations and messages, answers the six messaging RPCs plus
/// graph `Block` and moderation `ReportContent`, and records what the client
/// sent. It is stateful (Accept moves a request to the Inbox, Send appends a
/// message), so a whole cross-screen flow can run through the real
/// repositories, store and cubits with only the wire faked.
class FakeMessagingServer {
  FakeMessagingServer({Iterable<pb.Conversation> conversations = const []}) {
    for (final c in conversations) {
      this.conversations[c.id] = c.deepCopy();
    }
  }

  final Map<String, pb.Conversation> conversations = {};

  /// Per conversation, newest first.
  final Map<String, List<pb.Message>> messages = {};

  /// Every procedure the client called, in order.
  final List<String> calls = [];
  final List<pb.SendMessageRequest> sends = [];
  final List<graph.BlockRequest> blocks = [];
  final List<moderation.ReportContentRequest> reports = [];

  /// A procedure to fail with (once), e.g. to script an error.
  final Map<String, Object> failures = {};

  /// While set, `ListMessages` waits for it before answering (a response in
  /// flight, e.g. at sign-out).
  Completer<void>? listMessagesGate;

  int count(String procedure) => calls.where((c) => c == procedure).length;

  /// The `ListMessages` calls made so far (the polls and the opens).
  int get messageListCalls => count('/${MessagingService.name}/ListMessages');

  int _nextMessage = 1000;

  Future<Object> handle(String procedure, Object input) async {
    calls.add(procedure);
    final failure = failures.remove(procedure);
    if (failure != null) throw failure;
    if (procedure == '/${MessagingService.name}/ListConversations') {
      final request = input as pb.ListConversationsRequest;
      final rows =
          conversations.values.where((c) => c.folder == request.folder).toList()
            ..sort(
              (a, b) =>
                  b.updatedAt.toDateTime().compareTo(a.updatedAt.toDateTime()),
            );
      return pb.ListConversationsResponse(
        conversations: rows,
        sinceToken: 'since-${request.folder.value}',
        requestCount: Int64(
          conversations.values
              .where((c) => c.folder == Folder.FOLDER_REQUESTS)
              .length,
        ),
      );
    }
    if (procedure == '/${MessagingService.name}/ListMessages') {
      final request = input as pb.ListMessagesRequest;
      await listMessagesGate?.future;
      return pb.ListMessagesResponse(
        messages: messages[request.conversationId] ?? const [],
        conversation: conversations[request.conversationId],
        sinceToken: 'since-thread',
      );
    }
    if (procedure == '/${MessagingService.name}/SendMessage') {
      final request = input as pb.SendMessageRequest;
      sends.add(request);
      final id = request.conversationId;
      final message = pb.Message(
        id: hexId(_nextMessage++),
        conversationId: id,
        fromSelf: true,
        text: request.text,
        state: MessageState.MESSAGE_STATE_VISIBLE,
        createdAt: ts.Timestamp.fromDateTime(DateTime.now().toUtc()),
      );
      (messages[id] ??= []).insert(0, message);
      return pb.SendMessageResponse(
        message: message,
        conversation: conversations[id],
      );
    }
    if (procedure == '/${MessagingService.name}/MarkConversationRead') {
      final request = input as pb.MarkConversationReadRequest;
      conversations[request.conversationId]?.unreadCount = Int64.ZERO;
      return pb.MarkConversationReadResponse();
    }
    if (procedure == '/${MessagingService.name}/AcceptMessageRequest') {
      final request = input as pb.AcceptMessageRequestRequest;
      conversations[request.conversationId]
        ?..state = ConversationState.CONVERSATION_STATE_ACCEPTED
        ..folder = Folder.FOLDER_INBOX
        ..canReply = true;
      return pb.AcceptMessageRequestResponse();
    }
    if (procedure == '/${MessagingService.name}/DeleteConversation') {
      final request = input as pb.DeleteConversationRequest;
      conversations.remove(request.conversationId);
      messages.remove(request.conversationId);
      return pb.DeleteConversationResponse();
    }
    if (procedure == '/${GraphService.name}/ListFollowing') {
      // The caller follows Sam only.
      return graph.ListFollowingResponse(
        users: [
          graph.UserListItem(
            user: common.AuthorSnapshot(
              userId: 'u-sam',
              handle: 'sam',
              displayName: 'Sam Rivera',
            ),
          ),
        ],
      );
    }
    if (procedure == '/${GraphService.name}/Block') {
      final request = input as graph.BlockRequest;
      blocks.add(request);
      for (final c in conversations.values) {
        if (c.peer.userId == request.userId) c.canReply = false;
      }
      return graph.BlockResponse(
        relationship: graph.Relationship(
          userId: request.userId,
          blocking: true,
        ),
      );
    }
    if (procedure == '/${ModerationService.name}/ReportContent') {
      reports.add(input as moderation.ReportContentRequest);
      return moderation.ReportContentResponse(
        reportId: 'r${reports.length}',
        alreadyReported: false,
      );
    }
    throw StateError('FakeMessagingServer: unexpected $procedure');
  }
}

/// The whole messaging client over one fake server: the real [AppRouter], the
/// real [MessagingRepository], [GraphRepository] and [ModerationRepository]
/// (one in-memory drift database, one [FakeTransport]), with only the auth
/// and onboarding blocs mocked. It is the rig of the W7-21 cross-screen
/// flows; per-screen tests use mocked repositories instead.
///
/// Create it inside a test or `setUp` (it registers its own teardown).
class MessagingFlowRig {
  MessagingFlowRig({
    required this.server,
    Set<String> flags = const {'messaging', 'graph', 'reports', 'ui_shell'},
    this.signedIn = true,
  }) : flags = Set.of(flags) {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeTransport(server.handle);
    final api = ApiClient.withTransport(transport);
    messagingRepository = MessagingRepository(
      apiClient: api,
      store: MessagingStore(database),
      gate: MessagingFeatureGate(isMessagingEnabled: () => true),
      rateLimitHold: RateLimitHold(),
    );
    graphRepository = GraphRepository(apiClient: api, database: database);
    moderationRepository = ModerationRepository(
      apiClient: api,
      gate: ServiceFeatureGate(isEnabled: () => true),
    );
    shell = MessagingShellRig();
    addTearDown(() async {
      await unreadBadge.close();
      await _authStates.close();
      await database.close();
    });
  }

  final FakeMessagingServer server;
  final Set<String> flags;
  final bool signedIn;

  late final AppDatabase database;
  late final FakeTransport transport;
  late final MessagingRepository messagingRepository;
  late final GraphRepository graphRepository;
  late final ModerationRepository moderationRepository;
  late final MessagingShellRig shell;
  final UnreadBadgeCubit unreadBadge = UnreadBadgeCubit();
  late AppRouter appRouter;

  final StreamController<AuthState> _authStates =
      StreamController<AuthState>.broadcast();
  late _MockAuthBloc _auth;

  static const _signedIn = AuthState(
    status: AuthStatus.authenticated,
    user: AppUser(
      uid: 'uid-1',
      email: 'a@example.com',
      emailVerified: true,
      isPasswordProvider: true,
    ),
  );
  static const _signedOut = AuthState(status: AuthStatus.unauthenticated);

  /// The location the router is at.
  ///
  /// A `push` does not move the route information, so this reads the top of
  /// the match stack.
  String get path => appRouter
      .router
      .routerDelegate
      .currentConfiguration
      .matches
      .last
      .matchedLocation;

  /// Opens the app at [location] (default the Inbox).
  Future<void> pump(
    WidgetTester tester, {
    String location = AppRouter.messagesPath,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    final auth = _auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    whenListen(
      auth,
      _authStates.stream,
      initialState: signedIn ? _signedIn : _signedOut,
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'uid-1', handle: 'me'),
        enabledFeatures: flags,
      ),
    );
    appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    appRouter.router.go(location);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(
            value: messagingRepository,
          ),
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<ModerationRepository>.value(
            value: moderationRepository,
          ),
          RepositoryProvider<IdentityRepository>.value(value: _MockIdentity()),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<UnreadBadgeCubit>.value(value: unreadBadge),
            ...shell.providers,
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: appRouter.router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Registers the device for push (Android, granted), as the app does once
  /// `GetMe` is ready; the open thread then polls at the slower hot interval
  /// when `notifications` is on for the caller.
  Future<void> start(WidgetTester tester) async {
    await shell.start();
    await tester.pump();
  }

  /// How many rows each messaging drift table holds.
  Future<({int conversations, int messages, int state})>
  messagingRowCounts() async {
    final db = database;
    return (
      conversations: (await db.select(db.conversationEntries).get()).length,
      messages: (await db.select(db.messageEntries).get()).length,
      state: (await db.select(db.messagingStateEntries).get()).length,
    );
  }

  /// Signs the user out the way the app does: the auth state turns
  /// unauthenticated (the router leaves the private screens) and the local
  /// cache is wiped by [wipeSessionData].
  Future<void> signOut(WidgetTester tester) async {
    when(() => _auth.state).thenReturn(_signedOut);
    _authStates.add(_signedOut);
    await tester.runAsync(
      () => wipeSessionData(
        database: database,
        timelineRepository: _MockTimeline(),
        messagingRepository: messagingRepository,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// An accepted conversation with Sam (in the Inbox): his message `m2` and
  /// the caller's `m1`.
  static FakeMessagingServer serverWithConversation() {
    final accepted = threadConv().deepCopy()
      ..updatedAt = ts.Timestamp.fromDateTime(kMsgBase)
      ..lastMessage = pb.MessagePreview(
        snippet: 'hello from sam',
        state: MessageState.MESSAGE_STATE_VISIBLE,
        createdAt: ts.Timestamp.fromDateTime(kMsgBase),
      );
    final server = FakeMessagingServer(conversations: [accepted]);
    server.messages[accepted.id] = [
      msg(2, conversationId: accepted.id, secondsAgo: 5, text: 'm2'),
      msg(
        1,
        conversationId: accepted.id,
        secondsAgo: 10,
        text: 'm1',
        fromSelf: true,
      ),
    ];
    return server;
  }

  /// A message request from Sam, with two messages.
  static FakeMessagingServer serverWithRequest() {
    final request =
        threadConv(
            state: ConversationState.CONVERSATION_STATE_REQUEST,
            folder: Folder.FOLDER_REQUESTS,
          ).deepCopy()
          ..updatedAt = ts.Timestamp.fromDateTime(kMsgBase)
          ..lastMessage = pb.MessagePreview(
            snippet: 'm2',
            state: MessageState.MESSAGE_STATE_VISIBLE,
            createdAt: ts.Timestamp.fromDateTime(kMsgBase),
          );
    final server = FakeMessagingServer(conversations: [request]);
    server.messages[request.id] = [
      msg(2, conversationId: request.id, secondsAgo: 5, text: 'm2'),
      msg(1, conversationId: request.id, secondsAgo: 10, text: 'm1'),
    ];
    return server;
  }
}
