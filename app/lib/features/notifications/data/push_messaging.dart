import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart';

/// The OS-level push permission, reduced to what the UI needs.
enum PushPermission {
  /// Never asked: the in-app prompt may be shown.
  notDetermined,
  granted,

  /// Refused (or provisional-less); only system settings can change it.
  denied,
}

/// The data fields of an FCM message (ADR-0017 D6: `type`, `notificationId`,
/// `postId`, `actorId`; never post text).
@immutable
class PushMessage {
  const PushMessage({
    this.type = '',
    this.notificationId = '',
    this.postId = '',
    this.actorId = '',
  });

  final String type;
  final String notificationId;
  final String postId;
  final String actorId;

  /// App location to open on tap: the post, else the actor's profile (what
  /// the in-app list does); null when the message names neither.
  String? get location {
    if (postId.isNotEmpty) return '/post/${Uri.encodeComponent(postId)}';
    if (actorId.isNotEmpty) return '/u/$actorId';
    return null;
  }

  factory PushMessage.fromData(Map<String, dynamic> data) {
    String field(String key) => data[key] is String ? data[key] as String : '';
    return PushMessage(
      type: field('type'),
      notificationId: field('notificationId'),
      postId: field('postId'),
      actorId: field('actorId'),
    );
  }
}

/// The push platform surface, behind an interface so tests (and the web
/// build) never touch platform channels. Web push is out of scope (ADR-0017
/// D11): [supported] is false there and nothing else is called.
abstract class PushMessaging {
  /// iOS and Android only.
  bool get supported;

  /// The platform reported to RegisterDevice; unspecified when unsupported.
  DevicePlatform get platform;

  Future<PushPermission> permission();

  /// Shows the OS permission dialog (call from an explicit user action).
  Future<PushPermission> requestPermission();

  /// The current FCM registration token, or null when unavailable.
  Future<String?> token();

  Stream<String> get onTokenRefresh;

  /// Messages received while the app is in the foreground (the OS shows no
  /// banner for these).
  Stream<PushMessage> get onForegroundMessage;

  /// A notification tapped while the app was in the background.
  Stream<PushMessage> get onOpenedApp;

  /// The notification that launched the app from terminated state, once.
  Future<PushMessage?> initialMessage();
}

/// [PushMessaging] over `firebase_messaging`.
class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging({FirebaseMessaging? messaging})
    : _messaging = messaging;

  FirebaseMessaging? _messaging;
  FirebaseMessaging get _m => _messaging ??= FirebaseMessaging.instance;

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  DevicePlatform get platform {
    if (kIsWeb) return DevicePlatform.DEVICE_PLATFORM_UNSPECIFIED;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => DevicePlatform.DEVICE_PLATFORM_IOS,
      TargetPlatform.android => DevicePlatform.DEVICE_PLATFORM_ANDROID,
      _ => DevicePlatform.DEVICE_PLATFORM_UNSPECIFIED,
    };
  }

  PushPermission _map(AuthorizationStatus status) => switch (status) {
    AuthorizationStatus.authorized ||
    AuthorizationStatus.provisional => PushPermission.granted,
    AuthorizationStatus.denied ||
    AuthorizationStatus.deniedPermanently => PushPermission.denied,
    AuthorizationStatus.notDetermined => PushPermission.notDetermined,
  };

  @override
  Future<PushPermission> permission() async =>
      _map((await _m.getNotificationSettings()).authorizationStatus);

  @override
  Future<PushPermission> requestPermission() async =>
      _map((await _m.requestPermission()).authorizationStatus);

  @override
  Future<String?> token() => _m.getToken();

  @override
  Stream<String> get onTokenRefresh => _m.onTokenRefresh;

  @override
  Stream<PushMessage> get onForegroundMessage =>
      FirebaseMessaging.onMessage.map((m) => PushMessage.fromData(m.data));

  @override
  Stream<PushMessage> get onOpenedApp => FirebaseMessaging.onMessageOpenedApp
      .map((m) => PushMessage.fromData(m.data));

  @override
  Future<PushMessage?> initialMessage() async {
    final message = await _m.getInitialMessage();
    return message == null ? null : PushMessage.fromData(message.data);
  }
}
