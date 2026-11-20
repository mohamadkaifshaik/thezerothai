import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/core/widgets/shell_fab.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_encrypted_messaging.dart';
import 'fake_encryption_device.dart';
import 'messaging_shell_rig.dart';

class MockInboxRepository extends Mock implements MessagingRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The inbox screen over a mocked repository, with the encryption objects of
/// the tree under the test's control: [withDevice] / [withPort] /
/// [withStatusCubit] leave one out (a tree without the wiring).
class EncryptedInboxRig {
  EncryptedInboxRig({
    this.flag = E2eeFlag.on,
    bool vault = true,
    VaultStatus vaultStatus = VaultStatus.ready,
    bool historyLost = false,
    this.withDevice = true,
    this.withPort = true,
    this.withStatusCubit = true,
    FakeEncryptedMessaging? port,
  }) : port = port ?? FakeEncryptedMessaging(),
       device = FakeEncryptionDevice(
         status: vaultStatus,
         vaultKnown: vault,
         flag: flag,
         historyLostThisOpen: historyLost,
       ),
       repo = MockInboxRepository(),
       onboarding = _MockOnboardingBloc(),
       shell = MessagingShellRig() {
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => repo.cachedConversations(any()))
        .thenAnswer((_) async => const ConversationsSnapshot());
    when(() => repo.refreshConversations(any())).thenAnswer(
      (_) async => const ConversationsResult(ConversationsSnapshot()),
    );
  }

  /// `unknown` and `off` both leave `e2ee_dm` out of `enabled_features`.
  final E2eeFlag flag;
  final bool withDevice;
  final bool withPort;
  final bool withStatusCubit;
  final FakeEncryptedMessaging port;
  final FakeEncryptionDevice device;
  final MockInboxRepository repo;
  final OnboardingBloc onboarding;
  final MessagingShellRig shell;

  /// Every error handed to the unexpected-error reporter.
  final List<Object> reported = [];

  /// Every location the inbox pushed that this rig knows.
  final List<String> pushed = [];

  EncryptionStatusCubit? statusCubit;

  late bool _flagOn = flag == E2eeFlag.on;
  final StreamController<OnboardingState> _flagChanges =
      StreamController<OnboardingState>.broadcast();

  Set<String> get features => {'messaging', if (_flagOn) kFeatureE2eeDm};

  /// Flips `e2ee_dm` in `enabled_features` while the screen is open.
  void setFlagOn(bool on) {
    _flagOn = on;
    _flagChanges.add(OnboardingState(enabledFeatures: features));
  }

  static ConversationsSnapshot snap(
    List<pb.Conversation> rows, {
    bool more = false,
  }) => ConversationsSnapshot(
    conversations: rows,
    sinceToken: 's',
    olderPageToken: more ? 'older' : '',
  );

  /// One folder: [cached] on disk, [network] after the refresh.
  void stub({
    List<pb.Conversation>? cached,
    List<pb.Conversation>? network,
    Folder folder = Folder.FOLDER_INBOX,
    bool more = false,
  }) {
    when(() => repo.cachedConversations(folder)).thenAnswer(
      (_) async =>
          cached == null ? const ConversationsSnapshot() : snap(cached),
    );
    when(() => repo.refreshConversations(folder)).thenAnswer(
      (_) async =>
          ConversationsResult(snap(network ?? cached ?? const [], more: more)),
    );
  }

  Future<void> open(
    WidgetTester tester, {
    Folder folder = Folder.FOLDER_INBOX,
    Size size = const Size(400, 800),
    double textScale = 1,
    TextDirection textDirection = TextDirection.ltr,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      _flagChanges.stream,
      initialState: OnboardingState(enabledFeatures: features),
    );
    addTearDown(_flagChanges.close);
    final status = statusCubit = withStatusCubit && withDevice
        ? EncryptionStatusCubit(
            device: device,
            messaging: withPort ? port : null,
            flagOn: () => features.contains(kFeatureE2eeDm),
          )
        : null;
    if (status != null) addTearDown(status.close);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => ShellFabHost(
            child: ConversationsScreen(folder: folder, onNewMessage: () {}),
          ),
        ),
        GoRoute(
          path: '/messages',
          builder: (context, state) => const Scaffold(body: Text('inbox page')),
        ),
        GoRoute(
          path: '/messages/requests',
          builder: (context, state) => const Scaffold(body: Text('requests')),
        ),
        GoRoute(
          path: AppRouter.encryptionSettingsPath,
          builder: (context, state) {
            pushed.add(state.uri.path);
            return const Scaffold(body: Text('encryption settings'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, _) => reported.add(error),
          ),
          if (withDevice)
            RepositoryProvider<EncryptionDevice>.value(value: device),
          if (withPort)
            RepositoryProvider<EncryptedMessaging?>.value(value: port),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            ...shell.providers,
            if (status != null)
              BlocProvider<EncryptionStatusCubit>.value(value: status),
          ],
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Directionality(
              textDirection: textDirection,
              child: MaterialApp.router(
                theme: appLightTheme,
                routerConfig: router,
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }
}
