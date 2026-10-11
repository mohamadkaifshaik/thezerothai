//
//  Generated code. Do not modify.
//  source: dzeroth/notifications/v1/notifications.proto
//

import "package:connectrpc/connect.dart" as connect;
import "notifications.pb.dart" as dzerothnotificationsv1notifications;
import "notifications.connect.spec.dart" as specs;

extension type NotificationServiceClient (connect.Transport _transport) {
  /// Newest-first notifications for the caller. Every RPC checks FEATURE_NOTIFICATIONS (FAILED_PRECONDITION +
  /// FEATURE_DISABLED when off, 0 reads).
  /// Firestore: reads 1 + page_size worst (21 at the default page; the seen_at profile is cached by the
  /// account-status interceptor), refresh with 0 new items 1 read, planning 21 cold / 5 refresh; writes 0.
  /// Rate limit: default per-minute bucket. Counted against the per-uid daily read budget.
  Future<dzerothnotificationsv1notifications.ListNotificationsResponse> listNotifications(
    dzerothnotificationsv1notifications.ListNotificationsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.NotificationService.listNotifications,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Sets users/{uid}.notificationsSeenAt = now (the badge count drops to 0 within the 30 s GetMe cache; this
  /// instance's cache is evicted at once). Naturally idempotent: a replay just moves seen_at forward.
  /// Firestore: reads 0, writes 1.
  Future<dzerothnotificationsv1notifications.MarkNotificationsSeenResponse> markNotificationsSeen(
    dzerothnotificationsv1notifications.MarkNotificationsSeenRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.NotificationService.markNotificationsSeen,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Registers (or refreshes) this installation's FCM token under users/{uid}/devices/{device_id}. A token that was
  /// registered by another account on the same device is removed from that account (privacy). At most 5 devices per
  /// user: registering a 6th evicts the least recently refreshed one. Call on sign-in, on token refresh and once per
  /// app start. Naturally idempotent by device_id.
  /// Rate limit: 50 Register/Unregister calls per uid per day (limit_name "notification_devices_daily").
  /// Firestore: reads worst 8 (device doc, token index, previous owner's device, device list <= 6), typical 2;
  /// writes worst 5, typical 2.
  Future<dzerothnotificationsv1notifications.RegisterDeviceResponse> registerDevice(
    dzerothnotificationsv1notifications.RegisterDeviceRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.NotificationService.registerDevice,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Removes the device (call on sign-out, before the ID token is dropped). Unknown device_id is a no-op success.
  /// Firestore: reads 1, writes 0 or 2 (device doc + token index).
  Future<dzerothnotificationsv1notifications.UnregisterDeviceResponse> unregisterDevice(
    dzerothnotificationsv1notifications.UnregisterDeviceRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.NotificationService.unregisterDevice,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
