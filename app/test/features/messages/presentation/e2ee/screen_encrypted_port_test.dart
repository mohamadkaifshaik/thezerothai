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
  final seen = <EncryptedMessaging?>[];

  setUp(() {
    port = FakeEncryptedMessaging();
    device = FakeEncryptionDevice(vaultKnown: false, flag: E2eeFlag.off);
    onboarding = _MockOnboardingBloc();
    seen.clear();
  });

  Future<void> pump(
    WidgetTester tester, {
    bool withDevice = true,
    bool withPort = true,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
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
          child: StatefulBuilder(
            builder: (context, setState) => ScreenEncryptedPort(
              builder: (context, p) {
                seen.add(p);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() {}),
                  child: const SizedBox(width: 50, height: 50),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('access hidden: no port', (tester) async {
    await pump(tester);
    expect(seen.single, isNull);
  });

  testWidgets('manage (a vault here, flag off): the port', (tester) async {
    device.vaultKnown = true;
    await pump(tester);
    expect(seen.single, same(port));
  });

  testWidgets('no provider for the port or the device: no port', (
    tester,
  ) async {
    await pump(tester, withPort: false);
    expect(seen.single, isNull);
    seen.clear();
    await pump(tester, withDevice: false);
    expect(seen.single, isNull);
  });

  testWidgets('the answer is taken once: a later access change and rebuilds '
      'give every reader the same port', (tester) async {
    await pump(tester);
    expect(seen.single, isNull);
    // The vault appears while the screen is open.
    device.vaultKnown = true;
    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    expect(seen.length, greaterThan(1));
    expect(seen.every((p) => p == null), isTrue);
  });
}
