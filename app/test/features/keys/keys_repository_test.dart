import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_key_server.dart';

const _id = '0123456789abcdef0123456789abcdef';
const _key1 = '11111111-1111-4111-8111-111111111111';
const _key2 = '22222222-2222-4222-8222-222222222222';

Uint8List _sig([int fill = 7]) => Uint8List.fromList(List.filled(32, fill));

void main() {
  late FakeKeyServer server;
  late bool flag;
  late bool hasVault;
  late ServiceFeatureGate gate;
  late KeysRepository repo;
  late int refreshes;

  setUp(() {
    server = FakeKeyServer();
    flag = true;
    refreshes = 0;
    gate = ServiceFeatureGate(
      isEnabled: () => flag,
      onDisabledByServer: () => refreshes++,
    );
    hasVault = false;
    repo = KeysRepository(
      apiClient: server.apiClient,
      gate: gate,
      deviceFacts: () => hasVault,
    );
  });

  test('register sends the id, key and idempotency key; the same id and '
      'key again is accepted (idempotent)', () async {
    final r = await repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key1,
    );
    expect(r.device.deviceId, _id);
    final again = await repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key2,
    );
    expect(again.device.deviceId, _id);
    expect(server.registrations.map((r) => r.idempotencyKey), [_key1, _key2]);
    expect(server.registrations.first.signaturePublicKey, _sig());
    expect(server.devices.keys, [_id]);
  });

  test(
    'a different key for a known id is VALIDATION signature_public_key',
    () async {
      await repo.registerDevice(
        deviceId: _id,
        signaturePublicKey: _sig(),
        idempotencyKey: _key1,
      );
      await expectLater(
        repo.registerDevice(
          deviceId: _id,
          signaturePublicKey: _sig(9),
          idempotencyKey: _key2,
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.field,
            'field',
            'signature_public_key',
          ),
        ),
      );
    },
  );

  test('a sixth device is LimitReached key_devices', () async {
    for (var i = 0; i < 5; i++) {
      await repo.registerDevice(
        deviceId: 'device-$i-0123456789abcdef',
        signaturePublicKey: _sig(),
        idempotencyKey: _key1,
      );
    }
    await expectLater(
      repo.registerDevice(
        deviceId: _id,
        signaturePublicKey: _sig(),
        idempotencyKey: _key2,
      ),
      throwsA(
        isA<LimitReachedException>().having(
          (e) => e.quota,
          'quota',
          'key_devices',
        ),
      ),
    );
  });

  test('upload sends the one-time packages and the last-resort one; the '
      'count comes back; listMine reports it', () async {
    await repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key1,
    );
    final packages = [
      for (var i = 0; i < 3; i++) Uint8List.fromList([i, 1, 2]),
    ];
    final r = await repo.uploadKeyPackages(
      deviceId: _id,
      keyPackages: packages,
      lastResortKeyPackage: Uint8List.fromList([9, 9]),
      idempotencyKey: _key2,
    );
    expect(r.keyPackageCount, 3);
    expect(r.hasLastResort, isTrue);
    final sent = server.uploads.single;
    expect(sent.idempotencyKey, _key2);
    expect(sent.keyPackages, packages);
    expect(sent.lastResortKeyPackage, [9, 9]);

    final list = await repo.listMine();
    expect(list.devices.single.keyPackageCount, 3);
    expect(list.devices.single.hasLastResort, isTrue);
  });

  test('upload without a last-resort package leaves the field empty', () async {
    await repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key1,
    );
    await repo.uploadKeyPackages(
      deviceId: _id,
      keyPackages: [
        Uint8List.fromList([1]),
      ],
      idempotencyKey: _key2,
    );
    expect(server.uploads.single.lastResortKeyPackage, isEmpty);
  });

  test('remove deletes the device; a missing device is success', () async {
    await repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key1,
    );
    await repo.removeDevice(
      deviceId: _id,
      idempotencyKey: _key2,
      reason: pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
    );
    expect(server.devices, isEmpty);
    await repo.removeDevice(
      deviceId: _id,
      idempotencyKey: _key2,
      reason: pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
    );
    expect(server.calls, ['register', 'remove', 'remove']);
  });

  test('remove sends the reason it is given: SIGN_OUT leaves no mark, '
      'REMOTE marks the id', () async {
    await repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key1,
    );
    await repo.removeDevice(
      deviceId: _id,
      idempotencyKey: _key2,
      reason: pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
    );
    expect(server.removedMarks, isEmpty);
    await repo.removeDevice(
      deviceId: _id,
      idempotencyKey: _key1,
      reason: pb.RemoveReason.REMOVE_REASON_REMOTE,
    );
    expect(server.removals.map((r) => r.reason), [
      pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
      pb.RemoveReason.REMOVE_REASON_REMOTE,
    ]);
    expect(server.removedMarks, {_id});
    await expectLater(
      repo.registerDevice(
        deviceId: _id,
        signaturePublicKey: _sig(),
        idempotencyKey: _key2,
      ),
      throwsA(isA<DeviceRemovedException>()),
    );
  });

  // One call per method, in a fixed order: register, list, remove, upload,
  // get, claim.
  List<Future<Object?> Function()> allSix() => [
    () => repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key1,
    ),
    () => repo.listMine(),
    () => repo.removeDevice(
      deviceId: _id,
      idempotencyKey: _key1,
      reason: pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
    ),
    () => repo.uploadKeyPackages(
      deviceId: _id,
      keyPackages: [
        Uint8List.fromList([1]),
      ],
      idempotencyKey: _key1,
    ),
    () => repo.getDevices(['u1']),
    () => repo.claim(userId: 'u1', idempotencyKey: _key1),
  ];

  test('flag off and no vault on this device: nothing is sent and '
      'FeatureDisabled is thrown', () async {
    flag = false;
    for (final call in allSix()) {
      await expectLater(call(), throwsA(isA<FeatureDisabledException>()));
    }
    expect(server.rpcCount, 0);
    expect(repo.enabled, isFalse);
  });

  test('flag off with a vault on this device: list, remove and lookup are '
      'sent; register, upload and claim are not', () async {
    flag = false;
    hasVault = true;
    final calls = allSix();
    await calls[1]();
    await calls[2]();
    await calls[4]();
    expect(server.calls, ['list', 'remove', 'get']);
    for (final i in [0, 3, 5]) {
      await expectLater(calls[i](), throwsA(isA<FeatureDisabledException>()));
    }
    expect(server.calls, ['list', 'remove', 'get']);
    expect(repo.enabled, isFalse);
  });

  test('flag on: all six are sent', () async {
    final calls = allSix();
    // Removal last: the upload needs the registered device.
    for (final i in [0, 1, 3, 4, 5, 2]) {
      await calls[i]();
    }
    expect(server.calls, [
      'register',
      'list',
      'upload',
      'get',
      'claim',
      'remove',
    ]);
  });

  test('a server FEATURE_DISABLED on list, remove or lookup is rethrown and '
      'not recorded in the gate', () async {
    flag = false;
    hasVault = true;
    final calls = allSix();
    for (final i in [1, 2, 4]) {
      server.failNext[const ['', 'list', 'remove', '', 'get'][i]] = [
        keyServerError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        ),
      ];
      await expectLater(calls[i](), throwsA(isA<FeatureDisabledException>()));
    }
    expect(refreshes, 0);
    flag = true;
    expect(repo.enabled, isTrue);
  });

  test('an unknown error on listMine with the flag off and a vault reports '
      'once', () async {
    final reported = <Object>[];
    gate = ServiceFeatureGate(
      isEnabled: () => flag,
      onDisabledByServer: () => refreshes++,
      onUnexpectedError: (error, _) => reported.add(error),
    );
    repo = KeysRepository(
      apiClient: server.apiClient,
      gate: gate,
      deviceFacts: () => hasVault,
    );
    flag = false;
    hasVault = true;
    server.failNext['list'] = [
      connect.ConnectException(connect.Code.internal, 'boom'),
    ];
    await expectLater(repo.listMine(), throwsA(isA<UnknownApiException>()));
    expect(reported, hasLength(1));
    expect(reported.single, isA<UnknownApiException>());
    expect(refreshes, 0);
  });

  test('claim carries conversationId and lookup carries inactive', () async {
    server.claimConversationId = '0123456789abcdef0123456789abcdef';
    await repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key1,
    );
    server.devices[_id]!.inactive = true;
    final claimed = await repo.claim(userId: 'u1', idempotencyKey: _key2);
    expect(claimed.conversationId, '0123456789abcdef0123456789abcdef');
    final got = await repo.getDevices(['u1']);
    expect(got.users.single.devices.single.inactive, isTrue);
  });

  test(
    'removal is gated too: with the flag off nothing reaches KeyService',
    () async {
      flag = false;
      await expectLater(
        repo.removeDevice(
          deviceId: _id,
          idempotencyKey: _key1,
          reason: pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(server.rpcCount, 0);
    },
  );

  test('a server FEATURE_DISABLED is remembered by the gate (no further RPC) '
      'and asks for one GetMe refresh', () async {
    server.featureEnabled = false;
    await expectLater(
      repo.registerDevice(
        deviceId: _id,
        signaturePublicKey: _sig(),
        idempotencyKey: _key1,
      ),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(refreshes, 1);
    expect(repo.enabled, isFalse);
    await expectLater(
      repo.listMine(),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(server.rpcCount, 1);
    gate.reset();
    expect(repo.enabled, isTrue);
  });

  test('rate limiting carries the retry hint', () async {
    server.failNext['list'] = [
      keyServerError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        retryAfter: const Duration(seconds: 30),
      ),
    ];
    await expectLater(
      repo.listMine(),
      throwsA(
        isA<RateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 30),
        ),
      ),
    );
  });

  test('claim takes one package per device except the excluded one; '
      'getDevices is a typed call (later plans)', () async {
    await repo.registerDevice(
      deviceId: _id,
      signaturePublicKey: _sig(),
      idempotencyKey: _key1,
    );
    await repo.uploadKeyPackages(
      deviceId: _id,
      keyPackages: [
        Uint8List.fromList([1]),
        Uint8List.fromList([2]),
      ],
      idempotencyKey: _key2,
    );
    final claimed = await repo.claim(
      userId: 'me',
      excludeDeviceId: 'other-device-0123456789',
      idempotencyKey: _key1,
    );
    expect(claimed.keyPackages.single.deviceId, _id);
    expect(server.devices[_id]!.pool, hasLength(1));
    final claimRequest = server.requests
        .whereType<pb.ClaimKeyPackagesRequest>()
        .single;
    expect(claimRequest.excludeDeviceId, 'other-device-0123456789');
    expect(claimRequest.idempotencyKey, _key1);
  });
}
