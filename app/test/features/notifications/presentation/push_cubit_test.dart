import 'dart:async';

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

/// A messaging whose permission read can be held, to race start with stop.
class _SlowPermissionMessaging extends FakePushMessaging {
  _SlowPermissionMessaging() : super(currentPermission: PushPermission.granted);

  final gate = Completer<void>();

  @override
  Future<PushPermission> permission() async {
    await gate.future;
    return super.permission();
  }
}

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

  test(
    'permissionKnown is false until start or enable has read the OS',
    () async {
      messaging.currentPermission = PushPermission.granted;
      final cubit = build();
      addTearDown(cubit.close);

      // Only the default: a granted user would look like "not asked yet".
      expect(cubit.state.canPrompt, isTrue);
      expect(cubit.state.permissionKnown, isFalse);

      await cubit.start();
      expect(cubit.state.permission, PushPermission.granted);
      expect(cubit.state.permissionKnown, isTrue);

      await cubit.stop();
      expect(cubit.state.permissionKnown, isFalse);
    },
  );

  test('enable marks the answer as known', () async {
    messaging.nextPermissionAnswer = PushPermission.denied;
    final cubit = build();
    addTearDown(cubit.close);

    await cubit.enable();

    expect(cubit.state.permissionKnown, isTrue);
  });

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

  group('sign-out and races', () {
    test(
      'unregister then deletes the FCM token, after the Unregister RPC',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.unregister();

        verify(
          () => repo.unregisterDevice(
            idempotencyKey: any(named: 'idempotencyKey'),
            deviceId: 'device-1',
          ),
        ).called(1);
        expect(messaging.tokenDeletes, 1);
      },
    );

    test('the token is deleted even when the Unregister RPC fails', () async {
      when(
        () => repo.unregisterDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
        ),
      ).thenThrow(const NetworkException('offline'));
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.unregister();

      expect(messaging.tokenDeletes, 1);
    });

    test(
      'a token refresh after unregister never registers the device again',
      () async {
        messaging.currentPermission = PushPermission.granted;
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.start();
        verifyRegistered(1);

        await cubit.unregister();
        messaging.refresh.add('fcm-token-2');
        await pumpEventQueue();

        verifyNever(
          () => repo.registerDevice(
            idempotencyKey: any(named: 'idempotencyKey'),
            deviceId: any(named: 'deviceId'),
            fcmToken: 'fcm-token-2',
            platform: any(named: 'platform'),
          ),
        );
      },
    );

    test('a register still reading the device id when unregister runs is '
        'dropped', () async {
      messaging.currentPermission = PushPermission.granted;
      final idGate = Completer<String>();
      when(() => repo.deviceId(any())).thenAnswer((_) => idGate.future);
      final cubit = build();
      addTearDown(cubit.close);
      final starting = cubit.start();
      await pumpEventQueue();

      await cubit.unregister();
      idGate.complete('device-1');
      await starting;

      verifyNever(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
          fcmToken: any(named: 'fcmToken'),
          platform: any(named: 'platform'),
        ),
      );
    });

    test(
      'stop deletes the token; stop(invalidateToken: false) keeps it',
      () async {
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.start();

        await cubit.stop(invalidateToken: false);
        expect(messaging.tokenDeletes, 0);

        await cubit.start();
        await cubit.stop();
        expect(messaging.tokenDeletes, 1);
      },
    );

    test('stop clears listeners: later messages do nothing', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();

      await cubit.stop();
      messaging.foreground.add(const PushMessage(type: 'like'));
      await pumpEventQueue();

      expect(foreground, 0);
      expect(cubit.state.received, 0);
    });

    test('a stop that lands while start awaits the permission leaves no '
        'listeners and registers nothing', () async {
      final slow = _SlowPermissionMessaging();
      final cubit = PushCubit(
        messaging: slow,
        repository: repo,
        onForeground: () => foreground++,
      );
      addTearDown(cubit.close);
      final starting = cubit.start();
      await pumpEventQueue();

      await cubit.stop();
      slow.gate.complete();
      await starting;
      slow.foreground.add(const PushMessage(type: 'like'));
      await pumpEventQueue();

      expect(foreground, 0);
      expect(slow.tokenReads, 0);
      verifyNever(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
          fcmToken: any(named: 'fcmToken'),
          platform: any(named: 'platform'),
        ),
      );
    });

    test('start works again after stop (a new sign-in)', () async {
      messaging.currentPermission = PushPermission.granted;
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      await cubit.stop();

      await cubit.start();

      verifyRegistered(2);
    });
  });

  group('direct-message pushes (W7-19)', () {
    final id = 'cd34' * 8; // 32 lower-case hex
    late List<String> messagePushes;

    setUp(() => messagePushes = []);

    PushCubit buildMessaging() => PushCubit(
      messaging: messaging,
      repository: repo,
      onOpen: opened.add,
      onForeground: () => foreground++,
      onMessagePush: messagePushes.add,
      onUnexpectedError: (e, _) => unexpected.add(e),
    );

    test('a foreground message push reaches the Messages hook only: the '
        'notifications hook and count stay put', () async {
      final cubit = buildMessaging();
      addTearDown(cubit.close);
      await cubit.start();

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: id),
      );
      await pumpEventQueue();

      expect(messagePushes, [id]);
      expect(foreground, 0);
      expect(cubit.state.received, 0);
      expect(cubit.state.messagePushes, 1);
      expect(cubit.state.lastMessageConversationId, id);
    });

    test('other pushes keep their own path', () async {
      final cubit = buildMessaging();
      addTearDown(cubit.close);
      await cubit.start();

      messaging.foreground.add(const PushMessage(type: 'like', postId: '5'));
      await pumpEventQueue();

      expect(foreground, 1);
      expect(cubit.state.received, 1);
      expect(cubit.state.messagePushes, 0);
      expect(messagePushes, isEmpty);
    });

    test(
      'a message push without a well-formed conversation id is dropped',
      () async {
        final cubit = buildMessaging();
        addTearDown(cubit.close);
        await cubit.start();

        for (final bad in ['', 'ABC', '${id}0']) {
          messaging.foreground.add(
            PushMessage(type: 'message', conversationId: bad),
          );
        }
        await pumpEventQueue();

        expect(messagePushes, isEmpty);
        expect(foreground, 0);
        expect(cubit.state.received, 0);
        expect(cubit.state.messagePushes, 0);
      },
    );

    test('the counter grows per push, so a second push for the same '
        'conversation still nudges', () async {
      final cubit = buildMessaging();
      addTearDown(cubit.close);
      await cubit.start();

      final seen = <int>[];
      final sub = cubit.stream.listen((s) => seen.add(s.messagePushes));
      messaging.foreground
        ..add(PushMessage(type: 'message', conversationId: id))
        ..add(PushMessage(type: 'message', conversationId: id));
      await pumpEventQueue();
      await sub.cancel();

      expect(cubit.state.messagePushes, 2);
      expect(seen, [1, 2]);
    });

    test('a tap opens the conversation; a cold start opens it once', () async {
      messaging.launch = PushMessage(type: 'message', conversationId: id);
      final cubit = buildMessaging();
      addTearDown(cubit.close);
      await cubit.start();
      expect(opened, ['/messages/$id']);

      final other = 'ef56' * 8;
      messaging.opened.add(PushMessage(type: 'message', conversationId: other));
      await pumpEventQueue();
      // A malformed id opens nothing.
      messaging.opened.add(
        const PushMessage(type: 'message', conversationId: 'x'),
      );
      await pumpEventQueue();

      expect(opened, ['/messages/$id', '/messages/$other']);
      expect(messagePushes, isEmpty); // a tap is not a foreground push
    });

    test('after stop, message pushes do nothing', () async {
      final cubit = buildMessaging();
      addTearDown(cubit.close);
      await cubit.start();
      await cubit.stop();

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: id),
      );
      await pumpEventQueue();

      expect(messagePushes, isEmpty);
      expect(cubit.state.messagePushes, 0);
    });
  });

  group('registered (the 30 s hot poll of ADR-0027 D7, W7-19)', () {
    test('Android, once RegisterDevice answered', () async {
      messaging.currentPermission = PushPermission.granted;
      final cubit = build();
      addTearDown(cubit.close);
      expect(cubit.pushCoversThreads, isFalse);

      await cubit.start();

      expect(cubit.state.registered, isTrue);
      expect(cubit.pushCoversThreads, isTrue);
    });

    test(
      'iOS gets no message push yet: registered, but threads keep 15 s',
      () async {
        messaging
          ..currentPermission = PushPermission.granted
          ..platform = DevicePlatform.DEVICE_PLATFORM_IOS;
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.start();

        expect(cubit.state.registered, isTrue);
        expect(cubit.pushCoversThreads, isFalse);
      },
    );

    test('not without permission, nor on web', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.registered, isFalse);
      expect(cubit.pushCoversThreads, isFalse);

      final web = PushCubit(
        messaging: FakePushMessaging(supported: false),
        repository: repo,
      );
      addTearDown(web.close);
      await web.start();
      expect(web.pushCoversThreads, isFalse);
    });

    test('not when RegisterDevice failed', () async {
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

      expect(cubit.state.registered, isFalse);
      expect(cubit.pushCoversThreads, isFalse);
    });

    test('enable() registers after a grant', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.pushCoversThreads, isFalse);

      await cubit.enable();

      expect(cubit.pushCoversThreads, isTrue);
    });

    test('sign-out clears it: unregister, and stop', () async {
      messaging.currentPermission = PushPermission.granted;
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.registered, isTrue);

      await cubit.unregister();
      expect(cubit.state.registered, isFalse);
      expect(cubit.pushCoversThreads, isFalse);

      final other = build();
      addTearDown(other.close);
      await other.start();
      expect(other.state.registered, isTrue);
      await other.stop();
      expect(other.state.registered, isFalse);
    });
  });
}
