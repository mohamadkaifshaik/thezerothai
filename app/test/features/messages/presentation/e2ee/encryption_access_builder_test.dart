import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_access_builder.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_encryption_device.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  Future<List<EncryptionAccess>> pump(
    WidgetTester tester, {
    required Set<String> features,
    EncryptionDevice? device,
    Stream<OnboardingState>? states,
  }) async {
    final bloc = _MockOnboardingBloc();
    whenListen(
      bloc,
      states ?? const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
    final seen = <EncryptionAccess>[];
    Widget tree = EncryptionAccessBuilder(
      builder: (context, access) {
        seen.add(access);
        return const SizedBox.shrink();
      },
    );
    if (device != null) {
      tree = RepositoryProvider<EncryptionDevice>.value(
        value: device,
        child: tree,
      );
    }
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: BlocProvider<OnboardingBloc>.value(value: bloc, child: tree),
      ),
    );
    return seen;
  }

  testWidgets(
    'no EncryptionDevice in the tree is hidden even with the flag on',
    (tester) async {
      final seen = await pump(tester, features: {kFeatureE2eeDm});
      expect(seen.last, EncryptionAccess.hidden);
    },
  );

  testWidgets('rebuilds when the vault status changes', (tester) async {
    final device = FakeEncryptionDevice(
      status: VaultStatus.ready,
      flag: E2eeFlag.off,
    );
    final seen = await pump(tester, features: {}, device: device);
    expect(seen.last, EncryptionAccess.manage);
    device.vaultStatus.value = VaultStatus.unsupported;
    await tester.pump();
    expect(seen.last, EncryptionAccess.unsupported);
  });

  testWidgets('rebuilds when enabled_features changes', (tester) async {
    final device = FakeEncryptionDevice(vaultKnown: false, flag: E2eeFlag.off);
    final seen = await pump(
      tester,
      features: {},
      device: device,
      states: Stream.value(
        const OnboardingState(enabledFeatures: {kFeatureE2eeDm}),
      ),
    );
    expect(seen.first, EncryptionAccess.hidden);
    await tester.pump();
    expect(seen.last, EncryptionAccess.full);
  });

  testWidgets('flag on with an unsupported platform is unsupported', (
    tester,
  ) async {
    final device = FakeEncryptionDevice(status: VaultStatus.unsupported);
    final seen = await pump(tester, features: {kFeatureE2eeDm}, device: device);
    expect(seen.last, EncryptionAccess.unsupported);
  });

  testWidgets('flag off with a vault known on this device is manage', (
    tester,
  ) async {
    final device = FakeEncryptionDevice(flag: E2eeFlag.off);
    final seen = await pump(tester, features: {}, device: device);
    expect(seen.last, EncryptionAccess.manage);
  });

  testWidgets('flag off and no vault is hidden and makes no device call', (
    tester,
  ) async {
    final device = FakeEncryptionDevice(
      status: VaultStatus.off,
      vaultKnown: false,
      flag: E2eeFlag.off,
    );
    final seen = await pump(tester, features: {}, device: device);
    expect(seen.last, EncryptionAccess.hidden);
    expect(device.retryOpenCalls, 0);
  });
}
