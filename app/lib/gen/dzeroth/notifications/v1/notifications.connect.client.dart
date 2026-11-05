//
//  Generated code. Do not modify.
//  source: dzeroth/notifications/v1/notifications.proto
//

import "package:connectrpc/connect.dart" as connect;
import "notifications.pb.dart" as dzerothnotificationsv1notifications;
import "notifications.connect.spec.dart" as specs;

extension type NotificationServiceClient (connect.Transport _transport) {
  /// Newest-first notifications for the caller. Every RPC checks FEATURE_NOTIFICATIONS (FAILED_PRECONDITION +
  /// FEATURE_DISABLED when off, before any lookup).
  /// Rows whose most recent actor the caller blocks or mutes, or who blocks the caller, are hidden at read time
  /// (collapsed rows lose such actors from actor_count). Filtering runs after the page query, so a page can be
  /// shorter than page_size, or empty, while more rows exist: keep paging while next_page_token (or
  /// gap_page_token) is set; never infer the end from a short page.
  /// The caller's graph snapshot is cached 60 s and skipped on an empty page; the seen_at profile is cached by the
  /// account-status interceptor. Writes nothing.
  /// Rate limit: default per-minute bucket.
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
  /// instance's cache is evicted at once). Naturally idempotent: a replay just moves seen_at forward, and a call
  /// within 10 s of the previous mark returns that seen_at and writes nothing.
  /// Rate limit: default per-minute bucket; no daily cap.
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
  /// Rate limit: default per-minute bucket; no daily cap.
  /// Registering the same token again within 24 h writes nothing.
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
  /// Rate limit: default per-minute bucket; no daily cap.
  /// Deletes the device doc and its token index.
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
