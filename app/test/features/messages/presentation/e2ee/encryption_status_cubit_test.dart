import 'dart:async';

import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';

/// A device whose retry waits for the test.
class _SlowDevice extends FakeEncryptionDevice {
  Completer<void> gate = Completer<void>();
  Object? failWith;

  @override
  Future<void> retryOpen() async {
    retryOpenCalls++;
    await gate.future;
    if (failWith != null) throw failWith!;
  }
}

void main() {
  late FakeEncryptionDevice device;
  late FakeEncryptedMessaging messaging;
  late bool flagOn;
  late List<Object> reported;

  EncryptionStatusCubit make({
    EncryptionDevice? override,
    bool withMessaging = true,
  }) => EncryptionStatusCubit(
    device: override ?? device,
    messaging: withMessaging ? messaging : null,
    flagOn: () => flagOn,
    onUnexpectedError: (e, _) => reported.add(e),
  );

  setUp(() {
    device = FakeEncryptionDevice();
    device.deviceKeys.value = DeviceKeysStatus.ready;
    messaging = FakeEncryptedMessaging();
    flagOn = true;
    reported = [];
  });

  test('starts from the current facts', () {
    final cubit = make();
    expect(cubit.state.kind, EncryptionStatusKind.none);
    expect(cubit.state.access, EncryptionAccess.full);
    cubit.close();
  });

  test('emits when the vault status, device keys, engine flag, '
      'removedElsewhere or unavailableLong change', () async {
    final cubit = make();
    final seen = <EncryptionStatus>[];
    final sub = cubit.stream.listen(seen.add);

    device.vaultStatus.value = VaultStatus.unavailable;
    expect(cubit.state.kind, EncryptionStatusKind.unavailable);
    expect(cubit.state.unavailableLong, isFalse);

    device.unavailableLong.value = true;
    expect(cubit.state.unavailableLong, isTrue);

    device.vaultStatus.value = VaultStatus.ready;
    expect(cubit.state.kind, EncryptionStatusKind.none);

    device.deviceKeys.value = DeviceKeysStatus.deviceLimitReached;
    expect(cubit.state.kind, EncryptionStatusKind.deviceLimitReached);
    device.deviceKeys.value = DeviceKeysStatus.ready;

    device.engineUnavailable.value = true;
    expect(cubit.state.kind, EncryptionStatusKind.engineUnavailable);
    device.engineUnavailable.value = false;

    messaging.removedElsewhere.value = true;
    expect(cubit.state.kind, EncryptionStatusKind.removedElsewhere);
    messaging.removedElsewhere.value = false;
    expect(cubit.state.kind, EncryptionStatusKind.none);

    await Future<void>.delayed(Duration.zero);
    expect(seen.length, 9);
    await sub.cancel();
    await cubit.close();
  });

  test('refresh picks up a flag change', () async {
    device.flag = E2eeFlag.off;
    flagOn = false;
    final cubit = make();
    expect(cubit.state.kind, EncryptionStatusKind.dormant);
    device.flag = E2eeFlag.on;
    flagOn = true;
    cubit.refresh();
    expect(cubit.state.kind, EncryptionStatusKind.none);
    expect(cubit.state.mayStart, isTrue);
    await cubit.close();
  });

  test('refresh picks up vaultKnown (flag off: hidden, then manage)', () async {
    device.flag = E2eeFlag.off;
    device.vaultKnown = false;
    flagOn = false;
    final cubit = make();
    expect(cubit.state.access, EncryptionAccess.hidden);
    expect(cubit.state.kind, EncryptionStatusKind.none);
    device.vaultKnown = true;
    cubit.refresh();
    expect(cubit.state.access, EncryptionAccess.manage);
    expect(cubit.state.kind, EncryptionStatusKind.dormant);
    await cubit.close();
  });

  test(
    'retry calls retryOpen once and ignores a second tap while running',
    () async {
      final slow = _SlowDevice()..vaultStatus.value = VaultStatus.unavailable;
      final cubit = make(override: slow);
      final first = cubit.retry();
      final second = cubit.retry();
      expect(slow.retryOpenCalls, 1);
      slow.gate.complete();
      await first;
      await second;
      expect(slow.retryOpenCalls, 1);
      // Once finished a new tap runs again.
      slow.gate = Completer<void>()..complete();
      await cubit.retry();
      expect(slow.retryOpenCalls, 2);
      await cubit.close();
    },
  );

  test('retry does nothing while opening', () async {
    device.vaultStatus.value = VaultStatus.opening;
    final cubit = make();
    await cubit.retry();
    expect(device.retryOpenCalls, 0);
    await cubit.close();
  });

  test(
    'a failing retry reports a fixed StateError and clears the flag',
    () async {
      final slow = _SlowDevice()
        ..vaultStatus.value = VaultStatus.unavailable
        ..failWith = Exception('secret detail')
        ..gate.complete();
      final cubit = make(override: slow);
      await cubit.retry();
      expect(reported, hasLength(1));
      expect(reported.single, isA<StateError>());
      expect(reported.single.toString(), 'Bad state: retryOpen');
      slow.failWith = null;
      await cubit.retry();
      expect(slow.retryOpenCalls, 2);
      await cubit.close();
    },
  );

  test('dismissHistoryLost hides it until the cubit is recreated', () async {
    device.historyLostThisOpen = true;
    var cubit = make();
    expect(cubit.state.historyLost, isTrue);
    cubit.dismissHistoryLost();
    expect(cubit.state.historyLost, isFalse);
    // A later change keeps it hidden.
    device.vaultStatus.value = VaultStatus.unavailable;
    expect(cubit.state.historyLost, isFalse);
    await cubit.close();
    cubit = make();
    expect(cubit.state.historyLost, isTrue);
    await cubit.close();
  });

  test('with no port removedElsewhere is false', () async {
    final cubit = make(withMessaging: false);
    messaging.removedElsewhere.value = true;
    expect(cubit.state.kind, EncryptionStatusKind.none);
    await cubit.close();
  });

  test(
    'close removes every listener and a late notification is ignored',
    () async {
      final cubit = make();
      expect(device.vaultStatus.listenerCount, 1);
      expect(device.deviceKeys.listenerCount, 1);
      expect(device.engineUnavailable.listenerCount, 1);
      expect(device.unavailableLong.listenerCount, 1);
      // The port's notifier has no counter: its listener is observed instead.
      // ignore: invalid_use_of_protected_member
      expect(messaging.removedElsewhere.hasListeners, isTrue);
      await cubit.close();
      // ignore: invalid_use_of_protected_member
      expect(messaging.removedElsewhere.hasListeners, isFalse);
      expect(device.vaultStatus.listenerCount, 0);
      expect(device.deviceKeys.listenerCount, 0);
      expect(device.engineUnavailable.listenerCount, 0);
      expect(device.unavailableLong.listenerCount, 0);
      device.vaultStatus.value = VaultStatus.unavailable;
      messaging.removedElsewhere.value = true;
      expect(cubit.state.kind, EncryptionStatusKind.none);
    },
  );

  test('an access that is hidden adds listeners but draws nothing', () async {
    device.flag = E2eeFlag.off;
    device.vaultKnown = false;
    flagOn = false;
    device.vaultStatus.value = VaultStatus.keyLost;
    final cubit = make();
    expect(cubit.state.kind, EncryptionStatusKind.none);
    expect(cubit.state.historyLost, isFalse);
    await cubit.close();
  });
}
