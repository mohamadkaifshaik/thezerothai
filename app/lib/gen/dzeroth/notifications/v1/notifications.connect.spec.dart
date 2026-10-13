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
  /// Rows whose most recent actor the caller blocks or mutes, or who blocks the caller, are hidden at read time
  /// (collapsed rows lose such actors from actor_count). Filtering runs after the page query, so a page can be
  /// shorter than page_size, or empty, while more rows exist: keep paging while next_page_token (or
  /// gap_page_token) is set; never infer the end from a short page.
  /// Firestore: reads = rows scanned (minimum 1; 20 at the default page, 50 at the maximum) + the caller's graph
  /// snapshot (cached 60 s, 0 on a hit, +1 cold, skipped on an empty page); the seen_at profile is cached by the
  /// account-status interceptor. Refresh with 0 new items 1 (+1 graph); planning 21 cold / 5 refresh; writes 0.
  /// Rate limit: default per-minute bucket. Counted against the per-uid daily read budget.
  static const listNotifications = connect.Spec(
    '/$name/ListNotifications',
    connect.StreamType.unary,
    dzerothnotificationsv1notifications.ListNotificationsRequest.new,
    dzerothnotificationsv1notifications.ListNotificationsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Sets users/{uid}.notificationsSeenAt = now (the badge count drops to 0 within the 30 s GetMe cache; this
  /// instance's cache is evicted at once). Naturally idempotent: a replay just moves seen_at forward, and a call
  /// within 10 s of the previous mark returns that seen_at and writes nothing.
  /// Rate limit: 200 calls per uid per day (limit_name "notification_seen_daily").
  /// Firestore: reads 0 (the caller's profile is cached by the account-status interceptor; +1 on a cold
  /// instance), writes 1 (0 inside the 10 s window).
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
  /// Firestore: reads worst 9 (device doc, token index, previous owner's device, device list <= 5, the evicted
  /// device's token index), typical 2; writes worst 5, typical 2 (0 when the same token was registered < 24 h ago).
  static const registerDevice = connect.Spec(
    '/$name/RegisterDevice',
    connect.StreamType.unary,
    dzerothnotificationsv1notifications.RegisterDeviceRequest.new,
    dzerothnotificationsv1notifications.RegisterDeviceResponse.new,
  );

  /// Removes the device (call on sign-out, before the ID token is dropped). Unknown device_id is a no-op success.
  /// Rate limit: shares the per-uid daily cap of RegisterDevice (limit_name "notification_devices_daily").
  /// Firestore: reads 2 (device doc, then its token index; 1 when the device is unknown), deletes 0 or 2 (device
  /// doc + token index).
  static const unregisterDevice = connect.Spec(
    '/$name/UnregisterDevice',
    connect.StreamType.unary,
    dzerothnotificationsv1notifications.UnregisterDeviceRequest.new,
    dzerothnotificationsv1notifications.UnregisterDeviceResponse.new,
  );
}
