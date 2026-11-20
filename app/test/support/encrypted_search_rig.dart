import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/message_search.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_search_panel.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_encrypted_messaging.dart';
import 'fake_encryption_device.dart';

class MockSearchRepository extends Mock implements MessagingRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The search panel (and the search cubit) over a mocked repository whose
/// cache holds [conversations] and [messages], with the encryption objects of
/// the tree under the test's control: [withDevice] / [withPort] leave one out.
class EncryptedSearchRig {
  EncryptedSearchRig({
    this.flag = E2eeFlag.on,
    bool vault = true,
    VaultStatus vaultStatus = VaultStatus.ready,
    this.withDevice = true,
    this.withPort = true,
    FakeEncryptedMessaging? port,
    this.conversations = const [],
    this.messages = const {},
  }) : port = port ?? FakeEncryptedMessaging(),
       device = FakeEncryptionDevice(
         status: vaultStatus,
         vaultKnown: vault,
         flag: flag,
       ),
       repo = MockSearchRepository(),
       onboarding = _MockOnboardingBloc() {
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(
      () =>
          repo.cachedSearchCorpus(conversationId: any(named: 'conversationId')),
    ).thenAnswer((invocation) async {
      final only = invocation.namedArguments[#conversationId] as String?;
      return SearchCorpus(
        conversations: [
          for (final c in conversations)
            if (only == null || c.id == only) c,
        ],
        messages: {
          for (final e in messages.entries)
            if (only == null || e.key == only) e.key: e.value,
        },
      );
    });
    when(() => repo.olderSearchToken(any())).thenAnswer((_) async => '');
  }

  /// `unknown` and `off` both leave `e2ee_dm` out of `enabled_features`.
  final E2eeFlag flag;
  final bool withDevice;
  final bool withPort;
  final FakeEncryptedMessaging port;
  final FakeEncryptionDevice device;
  final MockSearchRepository repo;
  final OnboardingBloc onboarding;
  final List<pb.Conversation> conversations;
  final Map<String, List<pb.Message>> messages;

  /// Every error handed to the unexpected-error reporter.
  final List<Object> reported = [];

  /// Every hit the panel opened.
  final List<MessageSearchHit> opened = [];

  late bool _flagOn = flag == E2eeFlag.on;
  final StreamController<OnboardingState> _flagChanges =
      StreamController<OnboardingState>.broadcast();

  Set<String> get features => {'messaging', if (_flagOn) kFeatureE2eeDm};

  /// Flips `e2ee_dm` in `enabled_features` while the panel is open.
  void setFlagOn(bool on) {
    _flagOn = on;
    _flagChanges.add(OnboardingState(enabledFeatures: features));
  }

  Future<void> pump(
    WidgetTester tester, {
    String? conversationId,
    Size size = const Size(400, 800),
    double textScale = 1,
    TextDirection textDirection = TextDirection.ltr,
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
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Directionality(
              textDirection: textDirection,
              child: MaterialApp(
                theme: appLightTheme,
                home: Scaffold(
                  body: MessageSearchPanel(
                    conversationId: conversationId,
                    debounce: Duration.zero,
                    onClose: () {},
                    onOpenHit: opened.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }
}
