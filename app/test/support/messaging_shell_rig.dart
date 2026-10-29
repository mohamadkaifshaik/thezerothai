import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_push_messaging.dart';

class _MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

/// The app-wide cubits the messaging screens read since W7-19: the push cubit
/// (a message push nudges the open inbox or conversation, and says whether
/// push covers the thread poll) and the Messages badge. `AppWidget` provides
/// them in the app; a screen test provides them with [providers].
///
/// Create it in `setUp` (it registers its own teardown). [push] runs over a
/// [FakePushMessaging]; call [start] to subscribe it to [messaging], then
/// `messaging.foreground.add(...)` delivers a foreground push.
class MessagingShellRig {
  MessagingShellRig({
    PushPermission permission = PushPermission.granted,
    DevicePlatform platform = DevicePlatform.DEVICE_PLATFORM_ANDROID,
  }) : messaging = FakePushMessaging(currentPermission: permission)
         ..platform = platform {
    registerFallbackValue(DevicePlatform.DEVICE_PLATFORM_ANDROID);
    final repository = _MockNotificationsRepository();
    when(() => repository.enabled).thenReturn(true);
    when(() => repository.deviceId(any())).thenAnswer((_) async => 'device-1');
    when(() => repository.existingDeviceId())
        .thenAnswer((_) async => 'device-1');
    when(
      () => repository.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
        fcmToken: any(named: 'fcmToken'),
        platform: any(named: 'platform'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => repository.unregisterDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
      ),
    ).thenAnswer((_) async {});
    push = PushCubit(messaging: messaging, repository: repository);
    addTearDown(() async {
      await push.close();
      await badge.close();
    });
  }

  final FakePushMessaging messaging;
  late final PushCubit push;
  final MessagesBadgeCubit badge = MessagesBadgeCubit();

  List<BlocProvider<dynamic>> get providers => [
    BlocProvider<PushCubit>.value(value: push),
    BlocProvider<MessagesBadgeCubit>.value(value: badge),
  ];

  /// Subscribes [push] to [messaging] (and registers the device).
  Future<void> start() => push.start();

  /// A foreground direct-message push for [conversationId].
  void messagePush(String conversationId) => messaging.foreground.add(
    PushMessage(type: 'message', conversationId: conversationId),
  );
}
