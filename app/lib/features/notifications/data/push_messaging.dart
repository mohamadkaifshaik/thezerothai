import 'dart:async';

import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import '../domain/notification_location.dart';

/// The OS-level push permission, reduced to what the UI needs.
enum PushPermission {
  /// Never asked: the in-app prompt may be shown.
  notDetermined,
  granted,

  /// Refused (or provisional-less); only system settings can change it.
  denied,
}

/// The data fields of an FCM message (ADR-0017 D6: `type`, `notificationId`,
/// `postId`, `actorId`; never post text). A direct-message push (ADR-0027 D9)
/// carries `type=message` and `conversationId` only.
@immutable
class PushMessage {
  const PushMessage({
    this.type = '',
    this.notificationId = '',
    this.postId = '',
    this.actorId = '',
    this.conversationId = '',
  });

  final String type;
  final String notificationId;
  final String postId;
  final String actorId;
  final String conversationId;

  /// A direct-message push (push-only: no notification row).
  bool get isMessage => type == kNotificationTypeMessage;

  /// App location to open on tap (see [notificationLocation]).
  String? get location => notificationLocation(
    type: type,
    postId: postId,
    actorId: actorId,
    conversationId: conversationId,
  );

  factory PushMessage.fromData(Map<String, dynamic> data) {
    String field(String key) => data[key] is String ? data[key] as String : '';
    return PushMessage(
      type: field('type'),
      notificationId: field('notificationId'),
      postId: field('postId'),
      actorId: field('actorId'),
      conversationId: field('conversationId'),
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

  /// Invalidates this installation's FCM token (sign-out), so a signed-out
  /// device can never be pushed to with the old registration. Best effort.
  Future<void> deleteToken();

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
  Future<String?> token() async {
    try {
      return await _m.getToken();
    } on FirebaseException catch (error) {
      // iOS has no APNs token yet (simulator, push not provisioned, first
      // launch): an expected "not available", not a bug to report.
      if (error.code == 'apns-token-not-set') return null;
      rethrow;
    }
  }

  @override
  Stream<String> get onTokenRefresh => _m.onTokenRefresh;

  @override
  Future<void> deleteToken() async {
    try {
      await _m.deleteToken();
    } on FirebaseException catch (error) {
      if (error.code == 'apns-token-not-set') return;
      rethrow;
    }
  }

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
