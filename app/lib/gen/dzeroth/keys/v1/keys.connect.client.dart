//
//  Generated code. Do not modify.
//  source: dzeroth/keys/v1/keys.proto
//

import "package:connectrpc/connect.dart" as connect;
import "keys.pb.dart" as dzerothkeysv1keys;
import "keys.connect.spec.dart" as specs;

extension type KeyServiceClient (connect.Transport _transport) {
  /// Publish the caller's encryption device. Needs the flag on for the caller. Naturally idempotent by device_id:
  /// same id and same key => refreshes last_seen_at (at most once per 24 h) and returns the device; same id with a
  /// different key => INVALID_ARGUMENT + VALIDATION "signature_public_key"; a sixth device => FAILED_PRECONDITION +
  /// LIMIT_REACHED "key_devices" (never evicts). Validation: device_id and signature_public_key as in the header,
  /// idempotency_key format. One transaction: 1 device read + a query of at most 6 device documents, 1 write.
  Future<dzerothkeysv1keys.RegisterKeyDeviceResponse> registerKeyDevice(
    dzerothkeysv1keys.RegisterKeyDeviceRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.KeyService.registerKeyDevice,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's devices, at most 5, oldest first; inactive ones (not seen for 30 days) are included, flagged by
  /// last_seen_at. Needs the flag only not globally off. Query of at most 5 device documents (Limit 5).
  Future<dzerothkeysv1keys.ListMyKeyDevicesResponse> listMyKeyDevices(
    dzerothkeysv1keys.ListMyKeyDevicesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.KeyService.listMyKeyDevices,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Remove one of the caller's devices together with its key package pool and its last-resort package. A missing
  /// device is success (idempotent). Needs the flag only not globally off. Validation: device_id format,
  /// idempotency_key format. Bounded delete of the device document and at most 100 pool documents.
  Future<dzerothkeysv1keys.RemoveKeyDeviceResponse> removeKeyDevice(
    dzerothkeysv1keys.RemoveKeyDeviceRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.KeyService.removeKeyDevice,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Add key packages to a registered device's pool and optionally replace its last-resort package. Needs the flag on
  /// for the caller. Naturally idempotent: a key package's document id is derived from its bytes, so a replay stores
  /// nothing twice, and duplicates within one request are stored once. The pool holds at most 100: packages beyond the
  /// free space are dropped (the response carries the resulting count). Unknown device => NOT_FOUND. Neither key
  /// packages nor a last-resort package => VALIDATION "key_packages". Marks the device seen (at most once per 24 h).
  /// One transaction: 1 device read + at most 100 reads, at most 101 writes.
  Future<dzerothkeysv1keys.UploadKeyPackagesResponse> uploadKeyPackages(
    dzerothkeysv1keys.UploadKeyPackagesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.KeyService.uploadKeyPackages,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Active devices of up to 10 users. Needs the flag on for the caller. For each target other than the caller, the
  /// caller must be allowed to message the target by the messaging send rules; an unknown or non-ACTIVE user, a block in
  /// either direction and any other refusal answer ONE byte-identical FAILED_PRECONDITION + CANNOT_MESSAGE. A target
  /// with the flag off or with no active device answers success with an empty device list. Only active devices are
  /// returned; key_package_count and has_last_resort are zeroed for other users' devices. Validation: 1-10 user_ids
  /// (VALIDATION "user_ids"). At most 10 users x (1 user read + a query of at most 5 devices), no writes.
  Future<dzerothkeysv1keys.GetKeyDevicesResponse> getKeyDevices(
    dzerothkeysv1keys.GetKeyDevicesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.KeyService.getKeyDevices,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Claim one key package per active device of user_id. Needs the flag on for the caller. Same send-rules check and
  /// the same single CANNOT_MESSAGE refusal as GetKeyDevices. For each active device the server consumes one one-time
  /// package, else returns the device's last-resort package (last_resort = true, not consumed), else
  /// has_key_package = false. One transaction, at most 10 reads and 10 writes. NOT replayable: a retry consumes fresh
  /// packages, and idempotency_key is format-checked only. Claiming for the caller's own user id requires
  /// exclude_device_id to be one of the caller's devices (VALIDATION "exclude_device_id"); that device is left out.
  /// Limited by RATE_LIMIT_KEYS_CLAIM_PER_MIN and the daily cap KEYS_CLAIMS_PER_DAY (see Errors).
  Future<dzerothkeysv1keys.ClaimKeyPackagesResponse> claimKeyPackages(
    dzerothkeysv1keys.ClaimKeyPackagesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.KeyService.claimKeyPackages,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
