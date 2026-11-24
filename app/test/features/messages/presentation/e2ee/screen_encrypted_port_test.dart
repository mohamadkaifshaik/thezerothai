import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/screen_encrypted_port.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late FakeEncryptedMessaging port;
  late FakeEncryptionDevice device;
  late _MockOnboardingBloc onboarding;
  late StreamController<OnboardingState> states;
  final seen = <ScreenPorts>[];

  setUp(() {
    port = FakeEncryptedMessaging();
    device = FakeEncryptionDevice(vaultKnown: false, flag: E2eeFlag.off);
    onboarding = _MockOnboardingBloc();
    states = StreamController<OnboardingState>.broadcast();
    seen.clear();
  });
  tearDown(() => states.close());

  Future<void> pump(
    WidgetTester tester, {
    bool withDevice = true,
    bool withPort = true,
  }) async {
    whenListen(
      onboarding,
      states.stream,
      initialState: const OnboardingState(),
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          if (withDevice)
            RepositoryProvider<EncryptionDevice>.value(value: device),
          if (withPort)
            RepositoryProvider<EncryptedMessaging?>.value(value: port),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: ScreenEncryptedPort(
            builder: (context, ports) {
              seen.add(ports);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
  }

  testWidgets('access hidden: sends still get the port, reads do not', (
    tester,
  ) async {
    await pump(tester);
    expect(seen.last.send, same(port));
    expect(seen.last.read, isNull);
  });

  testWidgets('manage (a vault here, flag off): both are the port', (
    tester,
  ) async {
    device.vaultKnown = true;
    await pump(tester);
    expect(seen.last.send, same(port));
    expect(seen.last.read, same(port));
  });

  testWidgets('no provider for the port: neither; no device: reads null', (
    tester,
  ) async {
    await pump(tester, withPort: false);
    expect(seen.last.send, isNull);
    expect(seen.last.read, isNull);
    await pump(tester, withDevice: false);
    expect(seen.last.send, same(port));
    expect(seen.last.read, isNull);
  });

  testWidgets('upgrade-only: hidden then a vault appears (a status change) '
      'gives the read port, and it is never taken back', (tester) async {
    await pump(tester);
    expect(seen.last.read, isNull);
    device.vaultKnown = true;
    device.vaultStatus.value = VaultStatus.opening;
    await tester.pump();
    expect(seen.last.read, same(port));
    device.vaultKnown = false;
    device.vaultStatus.value = VaultStatus.off;
    await tester.pump();
    expect(seen.last.read, same(port), reason: 'never port to null');
    expect(seen.last.send, same(port));
  });

  testWidgets('upgrade-only: the flag turning on (a flag-set change) gives '
      'the read port', (tester) async {
    await pump(tester);
    expect(seen.last.read, isNull);
    states.add(const OnboardingState(enabledFeatures: {'e2ee_dm'}));
    await tester.pump();
    await tester.pump();
    expect(seen.last.read, same(port));
  });

  testWidgets('the listeners are removed on dispose', (tester) async {
    await pump(tester);
    expect(device.vaultStatus.listenerCount, 1);
    await tester.pumpWidget(const SizedBox());
    expect(device.vaultStatus.listenerCount, 0);
  });
}
