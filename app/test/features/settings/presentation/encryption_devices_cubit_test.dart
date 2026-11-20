import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/settings/presentation/bloc/encryption_devices_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_encrypted_messaging.dart';

const _mine = OwnDevice(
  ref: 'ref-mine',
  thisDevice: true,
  inConversations: true,
);
const _other = OwnDevice(ref: 'ref-other', thisDevice: false);

void main() {
  late FakeEncryptedMessaging port;
  late List<Object> reported;

  setUp(() {
    port = FakeEncryptedMessaging()
      ..setOwnDevices(const OwnDeviceList(devices: [_mine, _other]));
    reported = [];
  });

  EncryptionDevicesCubit make() => EncryptionDevicesCubit(
    messaging: port,
    onUnexpectedError: (e, _) => reported.add(e),
  );

  blocTest<EncryptionDevicesCubit, EncryptionDevicesState>(
    'load emits loading then ready',
    build: make,
    act: (c) => c.load(),
    verify: (c) {
      expect(c.state.status, EncryptionDevicesStatus.ready);
      expect(c.state.list!.devices, hasLength(2));
      expect(port.calls, ['ownDevices']);
    },
    expect: () => [
      isA<EncryptionDevicesState>().having(
        (s) => s.status,
        'status',
        EncryptionDevicesStatus.loading,
      ),
      isA<EncryptionDevicesState>().having(
        (s) => s.status,
        'status',
        EncryptionDevicesStatus.ready,
      ),
    ],
  );

  test('a thrown error is failed with the typed error', () async {
    port.failNextOn('ownDevices', const NetworkException('x'));
    final c = make();
    addTearDown(c.close);
    await c.load();
    expect(c.state.status, EncryptionDevicesStatus.failed);
    expect(c.state.error, isA<NetworkException>());
    expect(reported, isEmpty);
  });

  test('an untyped error is failed, reported as a fixed StateError', () async {
    port.failNextOn('ownDevices', ArgumentError.value('ref-secret'));
    final c = make();
    addTearDown(c.close);
    await c.load();
    expect(c.state.status, EncryptionDevicesStatus.failed);
    expect(c.state.error, isNull);
    expect(reported.single, isA<StateError>());
    expect(reported.single.toString(), isNot(contains('ref-secret')));
  });

  test(
    'remove calls the port once with the ref, reloads, and returns true',
    () async {
      final c = make();
      addTearDown(c.close);
      await c.load();
      port.calls.clear();
      expect(await c.remove('ref-other'), isTrue);
      expect(port.removedDevices, ['ref-other']);
      expect(port.calls, ['removeDevice', 'ownDevices', 'retryDeviceSetup']);
      expect(c.state.removing, isNull);
      expect(c.state.status, EncryptionDevicesStatus.ready);
    },
  );

  test('remove failure keeps the list and exposes the error', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    final before = c.state.list;
    port.failNextOn('removeDevice', const NetworkException('x'));
    expect(await c.remove('ref-other'), isFalse);
    expect(c.state.list, same(before));
    expect(c.state.error, isA<NetworkException>());
    expect(c.state.removing, isNull);
    expect(port.calls, isNot(contains('retryDeviceSetup')));
  });

  test('a failed reload after a removal still answers true', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    port.failNextOn('ownDevices', const NetworkException('x'));
    expect(await c.remove('ref-other'), isTrue);
    expect(c.state.status, EncryptionDevicesStatus.ready);
    expect(c.state.list, isNotNull);
  });

  test('removalsPending follows the port\'s listenable', () async {
    port.removalsPending.value = 3;
    final c = make();
    addTearDown(c.close);
    expect(c.state.removalsPending, 3);
    port.removalsPending.value = 12;
    expect(c.state.removalsPending, 12);
    await c.load();
    expect(c.state.removalsPending, 12);
  });

  test('retryDeviceSetup is called after a successful removal', () async {
    final c = make();
    addTearDown(c.close);
    await c.load();
    await c.remove('ref-other');
    expect(port.retryDeviceSetupCalls, 1);
  });

  test('closing the cubit stops listening', () async {
    final c = make();
    await c.close();
    port.removalsPending.value = 5;
    expect(c.state.removalsPending, 0);
  });
}
