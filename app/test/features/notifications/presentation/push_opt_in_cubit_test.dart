import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

void main() {
  // Relative to the real clock, moved only by the injected `now`.
  final base = DateTime.now().toUtc();
  late DateTime now;
  late FakePushOptInStore store;
  late FakePushMessaging messaging;
  late MockNotificationsRepository repo;
  late PushCubit push;
  late PushOptInCubit cubit;

  setUpAll(() {
    registerFallbackValue(DevicePlatform.DEVICE_PLATFORM_ANDROID);
  });

  setUp(() {
    now = base;
    store = FakePushOptInStore();
    messaging = FakePushMessaging();
    repo = MockNotificationsRepository();
    when(() => repo.enabled).thenReturn(true);
    when(() => repo.deviceId(any())).thenAnswer((_) async => 'device-1');
    when(
      () => repo.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
        fcmToken: any(named: 'fcmToken'),
        platform: any(named: 'platform'),
      ),
    ).thenAnswer((_) async {});
    push = PushCubit(messaging: messaging, repository: repo);
    cubit = PushOptInCubit(store: store, push: push, now: () => now);
  });

  tearDown(() async {
    await cubit.close();
    await push.close();
  });

  test('hidden until the record of the signed-in account has loaded', () async {
    expect(cubit.state.canOffer, isFalse);

    final loading = cubit.load('uid-a');
    expect(cubit.state.uid, 'uid-a');
    expect(cubit.state.canOffer, isFalse);

    await loading;
    expect(cubit.state.canOffer, isTrue);
  });

  test('no record: offered; sign-out resets', () async {
    await cubit.load('uid-a');
    expect(cubit.state.canOffer, isTrue);

    await cubit.load(null);
    expect(cubit.state.uid, isNull);
    expect(cubit.state.canOffer, isFalse);
  });

  test('"Not now" hides at once and is saved for that uid', () async {
    await cubit.load('uid-a');
    await cubit.notNow();

    expect(cubit.state.dismissed, isTrue);
    expect(cubit.state.canOffer, isFalse);
    expect(store.records['uid-a'], base);
    expect(store.records.keys, ['uid-a']);
  });

  test('a record just under 30 days old hides, 30 days old shows', () async {
    store.records['uid-a'] = base;

    now = base.add(const Duration(days: 29, hours: 23));
    await cubit.load('uid-a');
    expect(cubit.state.canOffer, isFalse);

    await cubit.load(null);
    now = base.add(const Duration(days: 30));
    await cubit.load('uid-a');
    expect(cubit.state.canOffer, isTrue);
  });

  test('two accounts do not share the dismissal', () async {
    await cubit.load('uid-a');
    await cubit.notNow();

    await cubit.load('uid-b');
    expect(cubit.state.canOffer, isTrue);
    expect(store.records.containsKey('uid-b'), isFalse);

    await cubit.load('uid-a');
    expect(cubit.state.canOffer, isFalse);
  });

  test('a slow read for the previous account is dropped', () async {
    store.records['uid-a'] = base;
    final slow = cubit.load('uid-a');
    final next = cubit.load('uid-b');
    await Future.wait([slow, next]);

    expect(cubit.state.uid, 'uid-b');
    expect(cubit.state.dismissed, isFalse);
    expect(cubit.state.canOffer, isTrue);
  });

  test(
    'a broken disk shows the card and keeps "Not now" for the session',
    () async {
      store.failReads = true;
      await cubit.load('uid-a');
      expect(cubit.state.canOffer, isTrue);

      store.failWrites = true;
      await cubit.notNow();
      expect(cubit.state.canOffer, isFalse);
    },
  );

  test('"Not now" before the record loaded is ignored', () async {
    await cubit.notNow();
    expect(store.writes, 0);
  });

  group('turnOn', () {
    setUp(() async {
      await push.start();
      await cubit.load('uid-a');
    });

    test('a grant registers once and records no denial', () async {
      await cubit.turnOn();

      expect(messaging.permissionRequests, 1);
      expect(push.state.permission, PushPermission.granted);
      expect(cubit.state.denied, isFalse);
      verify(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: 'device-1',
          fcmToken: 'fcm-token-1',
          platform: any(named: 'platform'),
        ),
      ).called(1);
    });

    test('a denial is noted and registers nothing', () async {
      messaging.nextPermissionAnswer = PushPermission.denied;
      await cubit.turnOn();

      expect(push.state.permission, PushPermission.denied);
      expect(cubit.state.denied, isTrue);
      verifyNever(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
          fcmToken: any(named: 'fcmToken'),
          platform: any(named: 'platform'),
        ),
      );
    });

    test('a second tap after the answer asks nothing more', () async {
      messaging.nextPermissionAnswer = PushPermission.denied;
      await cubit.turnOn();
      await cubit.turnOn();

      expect(messaging.permissionRequests, 1);
    });

    test('sign-out clears the denial', () async {
      messaging.nextPermissionAnswer = PushPermission.denied;
      await cubit.turnOn();
      await cubit.load(null);

      expect(cubit.state.denied, isFalse);
    });
  });
}
