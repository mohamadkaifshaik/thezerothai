//
//  Generated code. Do not modify.
//  source: dzeroth/notifications/v1/notifications.proto
//

import "package:connectrpc/connect.dart" as connect;
import "notifications.pb.dart" as dzerothnotificationsv1notifications;

abstract final class NotificationService {
  /// Fully-qualified name of the NotificationService service.
  static const name = 'dzeroth.notifications.v1.NotificationService';

  /// Newest-first notifications for the caller. Every RPC checks FEATURE_NOTIFICATIONS (FAILED_PRECONDITION +
  /// FEATURE_DISABLED when off, 0 reads).
  /// Firestore: reads 1 + page_size worst (21 at the default page; the seen_at profile is cached by the
  /// account-status interceptor), refresh with 0 new items 1 read, planning 21 cold / 5 refresh; writes 0.
  /// Rate limit: default per-minute bucket. Counted against the per-uid daily read budget.
  static const listNotifications = connect.Spec(
    '/$name/ListNotifications',
    connect.StreamType.unary,
    dzerothnotificationsv1notifications.ListNotificationsRequest.new,
    dzerothnotificationsv1notifications.ListNotificationsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Sets users/{uid}.notificationsSeenAt = now (the badge count drops to 0 within the 30 s GetMe cache; this
  /// instance's cache is evicted at once). Naturally idempotent: a replay just moves seen_at forward.
  /// Firestore: reads 0, writes 1.
  static const markNotificationsSeen = connect.Spec(
    '/$name/MarkNotificationsSeen',
    connect.StreamType.unary,
    dzerothnotificationsv1notifications.MarkNotificationsSeenRequest.new,
    dzerothnotificationsv1notifications.MarkNotificationsSeenResponse.new,
  );

  /// Registers (or refreshes) this installation's FCM token under users/{uid}/devices/{device_id}. A token that was
  /// registered by another account on the same device is removed from that account (privacy). At most 5 devices per
  /// user: registering a 6th evicts the least recently refreshed one. Call on sign-in, on token refresh and once per
  /// app start. Naturally idempotent by device_id.
  /// Rate limit: 50 Register/Unregister calls per uid per day (limit_name "notification_devices_daily").
  /// Firestore: reads worst 8 (device doc, token index, previous owner's device, device list <= 6), typical 2;
  /// writes worst 5, typical 2.
  static const registerDevice = connect.Spec(
    '/$name/RegisterDevice',
    connect.StreamType.unary,
    dzerothnotificationsv1notifications.RegisterDeviceRequest.new,
    dzerothnotificationsv1notifications.RegisterDeviceResponse.new,
  );

  /// Removes the device (call on sign-out, before the ID token is dropped). Unknown device_id is a no-op success.
  /// Firestore: reads 1, writes 0 or 2 (device doc + token index).
  static const unregisterDevice = connect.Spec(
    '/$name/UnregisterDevice',
    connect.StreamType.unary,
    dzerothnotificationsv1notifications.UnregisterDeviceRequest.new,
    dzerothnotificationsv1notifications.UnregisterDeviceResponse.new,
  );
}
