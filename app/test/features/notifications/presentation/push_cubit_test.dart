import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_push_messaging.dart';

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

void main() {
  late MockNotificationsRepository repo;
  late FakePushMessaging messaging;
  late List<String> opened;
  late int foreground;
  late List<Object> unexpected;
  var enabled = true;

  setUpAll(() {
    registerFallbackValue(DevicePlatform.DEVICE_PLATFORM_ANDROID);
  });

  setUp(() {
    enabled = true;
    repo = MockNotificationsRepository();
    messaging = FakePushMessaging();
    opened = [];
    foreground = 0;
    unexpected = [];
    when(() => repo.enabled).thenAnswer((_) => enabled);
    when(() => repo.deviceId(any())).thenAnswer((_) async => 'device-1');
    when(() => repo.existingDeviceId()).thenAnswer((_) async => 'device-1');
    when(
      () => repo.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
        fcmToken: any(named: 'fcmToken'),
        platform: any(named: 'platform'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => repo.unregisterDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
      ),
    ).thenAnswer((_) async {});
  });

  PushCubit build() => PushCubit(
    messaging: messaging,
    repository: repo,
    onOpen: opened.add,
    onForeground: () => foreground++,
    onUnexpectedError: (e, _) => unexpected.add(e),
  );

  void verifyRegistered(int times, {String token = 'fcm-token-1'}) {
    verify(
      () => repo.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: 'device-1',
        fcmToken: token,
        platform: DevicePlatform.DEVICE_PLATFORM_ANDROID,
      ),
    ).called(times);
  }

  test(
    'start never asks the OS; without permission nothing registers',
    () async {
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.start();

      expect(messaging.permissionRequests, 0);
      expect(cubit.state.canPrompt, isTrue);
      expect(messaging.tokenReads, 0);
      verifyNever(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
          fcmToken: any(named: 'fcmToken'),
          platform: any(named: 'platform'),
        ),
      );
    },
  );

  test('enable (the explicit tap) asks the OS then registers once', () async {
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.start();

    await cubit.enable();

    expect(messaging.permissionRequests, 1);
    expect(cubit.state.permission, PushPermission.granted);
    expect(cubit.state.canPrompt, isFalse);
    verifyRegistered(1);
  });

  test('a refused prompt registers nothing and stops prompting', () async {
    messaging.nextPermissionAnswer = PushPermission.denied;
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.start();

    await cubit.enable();

    expect(cubit.state.permission, PushPermission.denied);
    expect(cubit.state.canPrompt, isFalse);
    expect(messaging.tokenReads, 0);
  });

  test('already granted: registers once per start, and again on a token '
      'refresh', () async {
    messaging.currentPermission = PushPermission.granted;
    final cubit = build();
    addTearDown(cubit.close);

    await cubit.start();
    await cubit.start(); // idempotent per session
    verifyRegistered(1);

    messaging.refresh.add('fcm-token-2');
    await pumpEventQueue();

    verifyRegistered(1, token: 'fcm-token-2');
  });

  test('web / unsupported: nothing is read or registered', () async {
    messaging.supported = false;
    final cubit = build();
    addTearDown(cubit.close);

    await cubit.start();
    await cubit.enable();

    expect(cubit.state.supported, isFalse);
    expect(messaging.permissionReads, 0);
    expect(messaging.permissionRequests, 0);
    expect(messaging.tokenReads, 0);
  });

  test('flag off: start does nothing', () async {
    enabled = false;
    messaging.currentPermission = PushPermission.granted;
    final cubit = build();
    addTearDown(cubit.close);

    await cubit.start();

    expect(messaging.permissionReads, 0);
    expect(messaging.tokenReads, 0);
  });

  test(
    'foreground messages bump the badge hook and the received count',
    () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();

      messaging.foreground.add(const PushMessage(type: 'follow'));
      await pumpEventQueue();

      expect(foreground, 1);
      expect(cubit.state.received, 1);
    },
  );

  test(
    'a tap opens the post, else the actor; a cold start opens once',
    () async {
      messaging.launch = const PushMessage(postId: '77');
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(opened, ['/post/77']);

      messaging.opened.add(const PushMessage(type: 'follow', actorId: 'u9'));
      await pumpEventQueue();
      messaging.opened.add(const PushMessage(type: 'x'));
      await pumpEventQueue();

      expect(opened, ['/post/77', '/u/u9']);
    },
  );

  test('registration failures are silent; unknown ones are reported', () async {
    messaging.currentPermission = PushPermission.granted;
    when(
      () => repo.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
        fcmToken: any(named: 'fcmToken'),
        platform: any(named: 'platform'),
      ),
    ).thenThrow(const RateLimitedException('cap'));
    final cubit = build();
    addTearDown(cubit.close);

    await cubit.start();
    expect(unexpected, isEmpty);

    messaging.refresh.add('t2');
    when(
      () => repo.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
        fcmToken: any(named: 'fcmToken'),
        platform: any(named: 'platform'),
      ),
    ).thenThrow(const UnknownApiException('boom'));
    await pumpEventQueue();
    expect(unexpected, hasLength(1));
  });

  test('unregister removes the stored device and never throws', () async {
    final cubit = build();
    addTearDown(cubit.close);

    await cubit.unregister();
    verify(
      () => repo.unregisterDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: 'device-1',
      ),
    ).called(1);

    when(
      () => repo.unregisterDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
      ),
    ).thenThrow(const NetworkException('offline'));
    await cubit.unregister();
  });

  test('unregister with no stored device sends nothing', () async {
    when(() => repo.existingDeviceId()).thenAnswer((_) async => '');
    final cubit = build();
    addTearDown(cubit.close);

    await cubit.unregister();

    verifyNever(
      () => repo.unregisterDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
      ),
    );
  });
}
