//
//  Generated code. Do not modify.
//  source: dzeroth/keys/v1/keys.proto
//

import "package:connectrpc/connect.dart" as connect;
import "keys.pb.dart" as dzerothkeysv1keys;

abstract final class KeyService {
  /// Fully-qualified name of the KeyService service.
  static const name = 'dzeroth.keys.v1.KeyService';

  /// Publish the caller's encryption device. Needs the flag on for the caller. Naturally idempotent by device_id:
  /// same id and same key => refreshes last_seen_at (at most once per 24 h) and returns the device; same id with a
  /// different key => INVALID_ARGUMENT + VALIDATION "signature_public_key"; a sixth device => FAILED_PRECONDITION +
  /// LIMIT_REACHED "key_devices" (never evicts). Validation: device_id and signature_public_key as in the header,
  /// idempotency_key format. One transaction: 1 device read + a query of at most 6 device documents, 1 write.
  static const registerKeyDevice = connect.Spec(
    '/$name/RegisterKeyDevice',
    connect.StreamType.unary,
    dzerothkeysv1keys.RegisterKeyDeviceRequest.new,
    dzerothkeysv1keys.RegisterKeyDeviceResponse.new,
  );

  /// The caller's devices, at most 5, oldest first; inactive ones (not seen for 30 days) are included, flagged by
  /// last_seen_at. Needs the flag only not globally off. Query of at most 5 device documents (Limit 5).
  static const listMyKeyDevices = connect.Spec(
    '/$name/ListMyKeyDevices',
    connect.StreamType.unary,
    dzerothkeysv1keys.ListMyKeyDevicesRequest.new,
    dzerothkeysv1keys.ListMyKeyDevicesResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Remove one of the caller's devices together with its key package pool and its last-resort package. A missing
  /// device is success (idempotent). Needs the flag only not globally off. Validation: device_id format,
  /// idempotency_key format. Bounded delete of the device document and at most 100 pool documents.
  static const removeKeyDevice = connect.Spec(
    '/$name/RemoveKeyDevice',
    connect.StreamType.unary,
    dzerothkeysv1keys.RemoveKeyDeviceRequest.new,
    dzerothkeysv1keys.RemoveKeyDeviceResponse.new,
  );

  /// Add key packages to a registered device's pool and optionally replace its last-resort package. Needs the flag on
  /// for the caller. Naturally idempotent: a key package's document id is derived from its bytes, so a replay stores
  /// nothing twice, and duplicates within one request are stored once. The pool holds at most 100: packages beyond the
  /// free space are dropped (the response carries the resulting count). Unknown device => NOT_FOUND. Neither key
  /// packages nor a last-resort package => VALIDATION "key_packages". Marks the device seen (at most once per 24 h).
  /// One transaction: 1 device read + at most 100 reads, at most 101 writes.
  static const uploadKeyPackages = connect.Spec(
    '/$name/UploadKeyPackages',
    connect.StreamType.unary,
    dzerothkeysv1keys.UploadKeyPackagesRequest.new,
    dzerothkeysv1keys.UploadKeyPackagesResponse.new,
  );

  /// Active devices of up to 10 users. Needs the flag on for the caller. For each target other than the caller, the
  /// caller must be allowed to message the target by the messaging send rules; an unknown or non-ACTIVE user, a block in
  /// either direction and any other refusal answer ONE byte-identical FAILED_PRECONDITION + CANNOT_MESSAGE. A target
  /// with the flag off or with no active device answers success with an empty device list. Only active devices are
  /// returned; key_package_count and has_last_resort are zeroed for other users' devices. Validation: 1-10 user_ids
  /// (VALIDATION "user_ids"). At most 10 users x (1 user read + a query of at most 5 devices), no writes.
  static const getKeyDevices = connect.Spec(
    '/$name/GetKeyDevices',
    connect.StreamType.unary,
    dzerothkeysv1keys.GetKeyDevicesRequest.new,
    dzerothkeysv1keys.GetKeyDevicesResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Claim one key package per active device of user_id. Needs the flag on for the caller. Same send-rules check and
  /// the same single CANNOT_MESSAGE refusal as GetKeyDevices. For each active device the server consumes one one-time
  /// package, else returns the device's last-resort package (last_resort = true, not consumed), else
  /// has_key_package = false. One transaction, at most 10 reads and 10 writes. NOT replayable: a retry consumes fresh
  /// packages, and idempotency_key is format-checked only. Claiming for the caller's own user id requires
  /// exclude_device_id to be one of the caller's devices (VALIDATION "exclude_device_id"); that device is left out.
  /// Limited by RATE_LIMIT_KEYS_CLAIM_PER_MIN and the daily cap KEYS_CLAIMS_PER_DAY (see Errors).
  static const claimKeyPackages = connect.Spec(
    '/$name/ClaimKeyPackages',
    connect.StreamType.unary,
    dzerothkeysv1keys.ClaimKeyPackagesRequest.new,
    dzerothkeysv1keys.ClaimKeyPackagesResponse.new,
  );
}
