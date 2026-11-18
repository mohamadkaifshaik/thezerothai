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
  /// free space are dropped: when the pool is full the oldest stay and the new packages are not stored (the response
  /// carries the resulting count, which can be momentarily higher than the pool if a claim runs concurrently). An empty
  /// last_resort_key_package means none sent: the stored one is kept. Unknown device => NOT_FOUND. Neither key packages
  /// nor a last-resort package => VALIDATION "key_packages". Marks the device seen (at most once per 24 h). One
  /// transaction: 1 device read + at most 100 reads, at most 101 writes.
  static const uploadKeyPackages = connect.Spec(
    '/$name/UploadKeyPackages',
    connect.StreamType.unary,
    dzerothkeysv1keys.UploadKeyPackagesRequest.new,
    dzerothkeysv1keys.UploadKeyPackagesResponse.new,
  );

  /// Active devices of up to 10 users. Needs the flag on for the caller. For each target other than the caller, the
  /// caller must be allowed to message the target by the messaging send rules; an unknown or non-ACTIVE user, a block in
  /// either direction and any other refusal answer ONE byte-identical FAILED_PRECONDITION + CANNOT_MESSAGE. A target
  /// with the flag off or with no active device answers success with an empty device list. One refused target fails the
  /// whole call with that single CANNOT_MESSAGE (no partial result). Only active devices are returned, oldest first;
  /// key_package_count and has_last_resort are zeroed for other users' devices. Validation: 1-10 user_ids, each a
  /// well-formed user id, no duplicates (the caller's own id twice included), else VALIDATION "user_ids". Reads: for
  /// each target other than the caller, the send-rules check reads at most 4 documents, all cache-first (the caller's
  /// graph, the target's profile and, only when the target accepts messages from accounts they follow, one follow edge
  /// and the conversation); then at most 10 queries of at most 5 devices (the caller and each permitted target with the
  /// flag on: nothing is read for a refused or flag-off target). No writes.
  static const getKeyDevices = connect.Spec(
    '/$name/GetKeyDevices',
    connect.StreamType.unary,
    dzerothkeysv1keys.GetKeyDevicesRequest.new,
    dzerothkeysv1keys.GetKeyDevicesResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Claim one key package per active device of user_id, devices oldest first. Needs the flag on for the caller. Same
  /// send-rules check and the same single CANNOT_MESSAGE refusal as GetKeyDevices; a target with the flag off is an
  /// empty success; a malformed user_id is VALIDATION "user_id". For each active device the server consumes one
  /// one-time package (which one is unspecified), else returns the device's last-resort package (last_resort = true,
  /// not consumed), else has_key_package = false. Under heavy contention on one device the last-resort package (or
  /// has_key_package = false) may be returned although one-time packages remain; contention is never an error. A
  /// returned last-resort package may be one the device replaced a moment earlier (a stale read in a millisecond
  /// window); the receiving device may then be unable to use it, and the sender should claim again.
  /// There is no transaction: per device, one atomic write deletes one one-time package and decrements the count. Not
  /// atomic across devices. Reads without contention: at most 15 (1 query of at most 5 devices + 1 or 2 pool queries of
  /// at most 1 document per device); with contention at most 110 (at most 10 picks per device, 2 pool queries each, plus
  /// 1 device read); plus the send-rules check's at most 4 for another user. At most 10 committed writes.
  /// NOT replayable: a retry consumes fresh packages, and idempotency_key is format-checked only. A failed or timed-out
  /// call is not proof that nothing was consumed: packages may already have been taken, including for earlier devices
  /// of the same call when a later device fails. Claiming for the caller's own user id requires exclude_device_id to be
  /// one of the caller's devices, an inactive one included (VALIDATION "exclude_device_id"); that device is left out.
  /// For another user exclude_device_id must be empty or a well-formed device id (VALIDATION "exclude_device_id") and
  /// is ignored. Limited by RATE_LIMIT_KEYS_CLAIM_PER_MIN and the daily cap KEYS_CLAIMS_PER_DAY (see Errors).
  static const claimKeyPackages = connect.Spec(
    '/$name/ClaimKeyPackages',
    connect.StreamType.unary,
    dzerothkeysv1keys.ClaimKeyPackagesRequest.new,
    dzerothkeysv1keys.ClaimKeyPackagesResponse.new,
  );
}
