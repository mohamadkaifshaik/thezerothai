import 'dart:async';

import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';

/// A scriptable [PushMessaging] for cubit and widget tests: no platform
/// channels, records what was asked.
class FakePushMessaging implements PushMessaging {
  FakePushMessaging({
    this.supported = true,
    this.currentPermission = PushPermission.notDetermined,
    this.nextPermissionAnswer = PushPermission.granted,
    this.currentToken = 'fcm-token-1',
  });

  @override
  bool supported;

  @override
  DevicePlatform platform = DevicePlatform.DEVICE_PLATFORM_ANDROID;

  PushPermission currentPermission;
  PushPermission nextPermissionAnswer;
  String? currentToken;
  PushMessage? launch;

  int permissionRequests = 0;
  int permissionReads = 0;
  int tokenReads = 0;
  int tokenDeletes = 0;

  final refresh = StreamController<String>.broadcast();
  final foreground = StreamController<PushMessage>.broadcast();
  final opened = StreamController<PushMessage>.broadcast();

  @override
  Future<PushPermission> permission() async {
    permissionReads++;
    return currentPermission;
  }

  @override
  Future<PushPermission> requestPermission() async {
    permissionRequests++;
    currentPermission = nextPermissionAnswer;
    return currentPermission;
  }

  @override
  Future<String?> token() async {
    tokenReads++;
    return currentToken;
  }

  @override
  Future<void> deleteToken() async {
    tokenDeletes++;
  }

  @override
  Stream<String> get onTokenRefresh => refresh.stream;

  @override
  Stream<PushMessage> get onForegroundMessage => foreground.stream;

  @override
  Stream<PushMessage> get onOpenedApp => opened.stream;

  @override
  Future<PushMessage?> initialMessage() async => launch;
}
