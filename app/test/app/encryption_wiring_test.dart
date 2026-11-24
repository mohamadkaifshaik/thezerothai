import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/app_widget.dart';
import 'package:dzeroth/app/session_encryption_device.dart';
import 'package:dzeroth/app/session_wiring.dart' show wireE2eeFlag;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/settings/presentation/encryption_settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/reset_encryption_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/data/likes_repository.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/message_outbox.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/bloc/conversations_session.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_access_builder.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_encrypted_messaging.dart';
import '../support/fake_encryption_device.dart';
import '../support/fake_network_type_service.dart';
import '../support/fake_vault_world.dart';
import '../support/fake_push_messaging.dart';
import '../support/media_fixtures.dart' show MockMediaRepository;
import '../support/messaging_fixtures.dart';
import '../support/suggestions_fixtures.dart';
import '../support/thread_test_support.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockAccount extends Mock implements AccountRepository {}

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockTimeline extends Mock implements TimelineRepository {}

class _MockNotifications extends Mock implements NotificationsRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

class _MockEngagement extends Mock implements EngagementRepository {}

class _MockLikes extends Mock implements LikesRepository {}

class _MockBookmarks extends Mock implements BookmarksRepository {}

class _MockVaultSession extends Mock implements VaultSession {}

class _MockMessaging extends Mock implements MessagingRepository {
  @override
  final MessageOutbox outbox = MessageOutbox();

  _MockMessaging() {
    // Messaging on, so the hoisted folders are kept (access `hidden` would
    // drop them for its own reason and hide what these tests look at).
    when(() => gate)
        .thenReturn(MessagingFeatureGate(isMessagingEnabled: () => true));
    when(probeAccess).thenAnswer((_) async {});
    when(() => conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
  }
}

/// Plan 5b Task 14 (PR 14a): the encryption objects reach the widget tree
/// through `AppWidget`, and with none of them the app is today's app.
void main() {
  late _MockAuthBloc authBloc;
  late _MockOnboardingBloc onboardingBloc;
  late _MockNotifications notifications;
  late _MockMessaging messagingRepo;
  late PushCubit push;
  late UnreadBadgeCubit unreadBadge;
  late AppDatabase database;
  late StreamController<OnboardingState> onboardingStates;
  late StreamController<AuthState> authStates;
  late FakeEncryptedMessaging port;
  late FakeEncryptionDevice device;

  const e2ee = 'e2ee_dm';

  OnboardingState ready({Set<String> flags = const {}}) =>
      OnboardingState(status: OnboardingStatus.ready, enabledFeatures: flags);

  setUpAll(() {
    registerFallbackValue(const OnboardingRefreshRequested());
    registerFallbackValue(Folder.FOLDER_INBOX);
  });

  setUp(() {
    authBloc = _MockAuthBloc();
    onboardingBloc = _MockOnboardingBloc();
    notifications = _MockNotifications();
    messagingRepo = _MockMessaging();
    unreadBadge = UnreadBadgeCubit();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    onboardingStates = StreamController<OnboardingState>.broadcast();
    authStates = StreamController<AuthState>.broadcast();
    port = FakeEncryptedMessaging();
    device = FakeEncryptionDevice();
    when(() => notifications.enabled).thenReturn(true);
    push = PushCubit(
      messaging: FakePushMessaging(
        currentPermission: PushPermission.notDetermined,
      ),
      repository: notifications,
    );
    when(() => messagingRepo.cachedConversation(any()))
        .thenAnswer((_) async => null);
    when(() => messagingRepo.rateLimitedFor()).thenReturn(null);
    when(() => messagingRepo.rateLimitHold).thenReturn(RateLimitHold());
    when(() => messagingRepo.cachedConversations(any()))
        .thenAnswer((_) async => const ConversationsSnapshot());
  });

  tearDown(() async {
    await push.close();
    await unreadBadge.close();
    await database.close();
    await onboardingStates.close();
    await authStates.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    required OnboardingState onboarding,
    bool withEncryption = true,
    bool withPort = true,
    bool withDevice = true,
    bool withVault = true,
    VaultSession? vaultSession,
    String? signedInUid,
    Listenable? flagApplied,
    EncryptionDevice? adapter,
  }) async {
    whenListen(
      authBloc,
      authStates.stream,
      initialState: signedInUid == null
          ? const AuthState(status: AuthStatus.unauthenticated)
          : AuthState(
              status: AuthStatus.authenticated,
              user: AppUser(
                uid: signedInUid,
                emailVerified: true,
                isPasswordProvider: false,
              ),
            ),
    );
    whenListen(
      onboardingBloc,
      onboardingStates.stream,
      initialState: onboarding,
    );
    final bookmarks = _MockBookmarks();
    when(() => bookmarks.events)
        .thenAnswer((_) => const Stream<BookmarkEvent>.empty());
    await tester.pumpWidget(
      AppWidget(
        networkTypeService: FakeNetworkTypeService(),
        authBloc: authBloc,
        onboardingBloc: onboardingBloc,
        identityRepository: _MockIdentity(),
        graphRepository: _MockGraph(),
        suggestionsRepository: FakeSuggestionsRepository(const []),
        accountRepository: _MockAccount(),
        authRepository: _MockAuthRepository(),
        database: database,
        postsRepository: _MockPosts(),
        timelineRepository: _MockTimeline(),
        postsGate: PostsFeatureGate(isPostsEnabled: () => false),
        mediaRepository: MockMediaRepository(),
        notificationsRepository: notifications,
        messagingRepository: messagingRepo,
        moderationRepository: _MockModeration(),
        engagementRepository: _MockEngagement(),
        bookmarksRepository: bookmarks,
        likesRepository: _MockLikes(),
        pushCubit: push,
        unreadBadgeCubit: unreadBadge,
        vaultSession: withEncryption && withVault
            ? vaultSession ?? _MockVaultSession()
            : null,
        e2eeFlagApplied: flagApplied,
        encryptionDevice: withEncryption && withDevice
            ? adapter ?? device
            : null,
        encryptedMessaging: withEncryption && withPort ? port : null,
      ),
    );
    await tester.pump();
  }

  BuildContext tree(WidgetTester tester) =>
      tester.element(find.byType(Navigator).first);

  group('without the three objects', () {
    testWidgets('AppWidget builds and the access is hidden', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: {e2ee}),
        withEncryption: false,
      );
      final context = tree(tester);
      expect(EncryptionAccessBuilder.of(context), EncryptionAccess.hidden);
      expect(context.read<EncryptedMessaging?>(), isNull);
      expect(context.read<EncryptionDevice?>(), isNull);
      expect(context.read<VaultSession?>(), isNull);
      expect(context.read<EncryptionStatusCubit?>(), isNull);
    });

    testWidgets('the hoisted inbox takes no port without a device (a port '
        'is provided, the device is not) and calls nothing', (tester) async {
      await pump(tester, onboarding: ready(flags: {e2ee}), withDevice: false);
      expect(tree(tester).read<EncryptedMessaging?>(), same(port));
      when(() => messagingRepo.refreshConversations(any())).thenAnswer(
        (_) async => ConversationsResult(
          ConversationsSnapshot(
            conversations: [
              threadConv(id: hexId(0xc1))
                ..encryption =
                    ConversationEncryption.CONVERSATION_ENCRYPTION_MLS,
            ],
          ),
        ),
      );
      final cubit = tree(tester)
          .read<ConversationsSession>()
          .cubitFor(Folder.FOLDER_INBOX);
      await tester.runAsync(cubit.load);
      expect(cubit.state.conversations, isNotEmpty);
      expect(port.calls, isEmpty);
    });
  });

  group('with them', () {
    testWidgets('the access is full with the flag on', (tester) async {
      await pump(tester, onboarding: ready(flags: {e2ee}));
      final context = tree(tester);
      expect(EncryptionAccessBuilder.of(context), EncryptionAccess.full);
      expect(context.read<EncryptedMessaging?>(), same(port));
      expect(context.read<EncryptionDevice?>(), same(device));
      expect(context.read<VaultSession?>(), isNotNull);
      expect(context.read<EncryptionStatusCubit?>(), isNotNull);
    });

    testWidgets('a platform with no vault (iOS): a device, no port: the '
        'access is unsupported, the nullable port reads as null and the '
        'status shows nothing', (tester) async {
      device.vaultStatus.value = VaultStatus.unsupported;
      await pump(tester, onboarding: ready(flags: {e2ee}), withPort: false);
      final context = tree(tester);
      expect(EncryptionAccessBuilder.of(context), EncryptionAccess.unsupported);
      expect(context.read<EncryptedMessaging?>(), isNull);
      expect(
        context.read<EncryptionStatusCubit>().state.kind,
        EncryptionStatusKind.none,
      );
    });

    testWidgets('the access is manage with the flag off and a known vault', (
      tester,
    ) async {
      device.vaultKnown = true;
      await pump(tester, onboarding: ready());
      expect(EncryptionAccessBuilder.of(tree(tester)), EncryptionAccess.manage);
    });

    testWidgets('the access is hidden with the flag off and no vault', (
      tester,
    ) async {
      device.vaultKnown = false;
      await pump(tester, onboarding: ready());
      expect(EncryptionAccessBuilder.of(tree(tester)), EncryptionAccess.hidden);
      final status = tree(tester).read<EncryptionStatusCubit>().state;
      expect(status.kind, EncryptionStatusKind.none);
    });

    testWidgets('the status cubit refreshes when enabled_features change', (
      tester,
    ) async {
      device
        ..flag = E2eeFlag.on
        ..vaultKnown = false;
      await pump(tester, onboarding: ready());
      final cubit = tree(tester).read<EncryptionStatusCubit>();
      expect(cubit.state.access, EncryptionAccess.hidden);
      onboardingStates.add(ready(flags: {e2ee}));
      await tester.pump();
      expect(cubit.state.access, EncryptionAccess.full);
      onboardingStates.add(ready());
      await tester.pump();
      expect(cubit.state.access, EncryptionAccess.hidden);
    });

    testWidgets('the status cubit exists from the first frame and its retry '
        'reaches the device', (tester) async {
      device.vaultStatus.value = VaultStatus.unavailable;
      await pump(tester, onboarding: ready(flags: {e2ee}));
      final cubit = tree(tester).read<EncryptionStatusCubit>();
      expect(cubit.state.kind, EncryptionStatusKind.unavailable);
      await tester.runAsync(cubit.retry);
      expect(device.retryOpenCalls, 1);
    });
  });

  group('the hoisted inbox previews', () {
    pb.Conversation mls() =>
        threadConv(id: hexId(0xc1))
          ..encryption = ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;

    Future<void> openInbox(WidgetTester tester) async {
      when(() => messagingRepo.refreshConversations(any())).thenAnswer(
        (_) async =>
            ConversationsResult(ConversationsSnapshot(conversations: [mls()])),
      );
      final cubit = tree(tester)
          .read<ConversationsSession>()
          .cubitFor(Folder.FOLDER_INBOX);
      await tester.runAsync(cubit.load);
    }

    testWidgets('with access full the port is asked', (tester) async {
      await pump(tester, onboarding: ready(flags: {e2ee}));
      await openInbox(tester);
      expect(port.calls, anyOf(contains('previews'), contains('hasLocal')));
    });

    testWidgets('with access hidden the port is never called', (tester) async {
      device.vaultKnown = false;
      await pump(tester, onboarding: ready());
      await openInbox(tester);
      expect(port.calls, isEmpty);
    });

    testWidgets('fix round C: the vault leaving ready (flag still on) drops '
        'the previews from the hoisted cubit while the inbox is off screen', (
      tester,
    ) async {
      await pump(tester, onboarding: ready(flags: {e2ee}));
      port.local.add(hexId(0xc1));
      port.setPreviews({
        hexId(0xc1): const ConversationPreview(
          kind: PreviewKind.text,
          text: 'hello',
        ),
      });
      await openInbox(tester);
      final cubit = tree(tester)
          .read<ConversationsSession>()
          .ifCreated(Folder.FOLDER_INBOX)!;
      expect(cubit.state.previews, isNotEmpty);
      device.vaultStatus.value = VaultStatus.keyLost;
      await tester.pump();
      expect(cubit.state.previews, isEmpty);
      expect(cubit.state.knownEncrypted, isEmpty);
    });

    testWidgets('an access drop clears the previews while the inbox is off '
        'screen', (tester) async {
      await pump(tester, onboarding: ready(flags: {e2ee}));
      port.local.add(hexId(0xc1));
      port.setPreviews({
        hexId(0xc1): const ConversationPreview(
          kind: PreviewKind.text,
          text: 'hello',
        ),
      });
      await openInbox(tester);
      final cubit = tree(tester)
          .read<ConversationsSession>()
          .ifCreated(Folder.FOLDER_INBOX)!;
      expect(cubit.state.previews, isNotEmpty);
      // The flag turns off and the device has no vault any more.
      device.vaultKnown = false;
      onboardingStates.add(ready());
      await tester.pump();
      expect(cubit.state.previews, isEmpty);
      expect(cubit.state.knownEncrypted, isEmpty);
    });
  });

  AuthState signedInAs(String uid) => AuthState(
    status: AuthStatus.authenticated,
    user: AppUser(uid: uid, emailVerified: true, isPasswordProvider: false),
  );

  group('fix round D: per-account state', () {
    testWidgets('an account switch resets the device adapter, the reset '
        'holder and the status dismissals', (tester) async {
      device.historyLostThisOpen = true;
      final vault = _MockVaultSession();
      when(() => vault.resetByUser()).thenAnswer((_) async => true);
      await pump(
        tester,
        onboarding: ready(flags: {e2ee}),
        vaultSession: vault,
        signedInUid: 'u1',
      );
      final context = tree(tester);
      final status = context.read<EncryptionStatusCubit>();
      final holder = context.read<ResetEncryptionHolder>();
      status.dismissHistoryLost();
      expect(status.state.historyLost, isFalse);
      await tester.runAsync(() async {
        await holder.cubit.run();
        await Future<void>.delayed(Duration.zero);
      });
      expect(holder.cubit.state, ResetEncryptionPhase.done);
      expect(device.resetForAccountCalls, 0);

      authStates.add(signedInAs('u2'));
      await tester.pump();

      expect(device.resetForAccountCalls, 1);
      expect(status.state.historyLost, isTrue);
      expect(holder.cubit.state, ResetEncryptionPhase.idle);
      expect(holder.attach(), isNull);
    });
  });

  group('fix round F: the status follows the session applying the flag', () {
    testWidgets('unknown to on with a ready vault: the status ends with '
        'mayStart true (a refresh at answer time would read the old flag)', (
      tester,
    ) async {
      final world = FakeVaultWorld();
      // An earlier launch made the vault (the marker says one is here); this
      // launch opens it before the flag answer is known.
      await tester.runAsync(
        () => world.launch().onSignedIn('user-a', flag: E2eeFlag.on),
      );
      final session = world.launch();
      final applied = ValueNotifier<int>(0);
      final adapter = SessionEncryptionDevice(
        session: session,
        deviceKeys: ValueNotifier(DeviceKeysStatus.dormant),
        engineUnavailable: ValueNotifier(false),
      );
      addTearDown(adapter.dispose);
      await tester.runAsync(
        () => session.onSignedIn('user-a', flag: E2eeFlag.unknown),
      );
      expect(session.status.value, VaultStatus.ready);
      final sub = wireE2eeFlag(
        states: onboardingStates.stream,
        uidOf: (_) => 'user-a',
        vaultSession: session,
        onFlagOnWithOpenVault: () {},
        onFlagApplied: () => applied.value++,
      );
      addTearDown(sub.cancel);
      device = FakeEncryptionDevice();
      await pump(
        tester,
        onboarding: ready(),
        flagApplied: applied,
        adapter: adapter,
      );
      final status = tree(tester).read<EncryptionStatusCubit>();
      expect(status.state.mayStart, isFalse);
      await tester.runAsync(() async {
        onboardingStates.add(ready(flags: {e2ee}));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(session.mayStart, isTrue);
      expect(status.state.mayStart, isTrue);
    });

    testWidgets('a change of another enabled feature also refreshes the '
        'status', (tester) async {
      await pump(tester, onboarding: ready(flags: {e2ee}));
      final status = tree(tester).read<EncryptionStatusCubit>();
      var emitted = 0;
      final sub = status.stream.listen((_) => emitted++);
      addTearDown(sub.cancel);
      onboardingStates.add(ready(flags: {e2ee, 'dm_share_check'}));
      await tester.pump();
      expect(emitted, 1);
      // The same set again: nothing.
      onboardingStates.add(ready(flags: {e2ee, 'dm_share_check'}));
      await tester.pump();
      expect(emitted, 1);
    });
  });

  group('fix round H: through AppWidget', () {
    testWidgets('the port, the device and the reset holder reach a route '
        'pushed above the router (the modal search panel)', (tester) async {
      await pump(tester, onboarding: ready(flags: {e2ee}));
      EncryptedMessaging? seenPort;
      ResetEncryptionHolder? seenHolder;
      unawaited(
        showModalBottomSheet<void>(
          context: tree(tester),
          builder: (c) {
            seenPort = c.read<EncryptedMessaging?>();
            seenHolder = c.read<ResetEncryptionHolder?>();
            return const SizedBox();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(seenPort, same(port));
      expect(seenHolder, isNotNull);
    });

    testWidgets('the encryption Settings page builds from the provided '
        'objects', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: {e2ee}),
        signedInUid: 'u1',
      );
      GoRouter.of(tree(tester)).go(AppRouter.encryptionSettingsPath);
      await tester.pumpAndSettle();
      expect(find.byType(EncryptionSettingsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // (The vault status listener calling encryptionAccessLost is covered by
    // the fix round C test above.)
    testWidgets('dispose removes every listener from the device', (
      tester,
    ) async {
      await pump(tester, onboarding: ready(flags: {e2ee}));
      final before = device.vaultStatus.listenerCount;
      expect(before, greaterThanOrEqualTo(2));
      await tester.pumpWidget(const SizedBox());
      expect(device.vaultStatus.listenerCount, 0);
    });
  });
}
