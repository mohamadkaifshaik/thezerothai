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
  /// same id and same key => refreshes last_seen_at (at most once per 24 h; call it periodically, see the header) and
  /// returns the device; same id with a different key => INVALID_ARGUMENT + VALIDATION "signature_public_key" (the
  /// stored key is kept); a sixth device => FAILED_PRECONDITION + LIMIT_REACHED "key_devices" (never evicts). Validation: device_id and signature_public_key as in the header,
  /// idempotency_key format. One transaction: 1 device read + a query of at most 6 device documents, 1 write.
  static const registerKeyDevice = connect.Spec(
    '/$name/RegisterKeyDevice',
    connect.StreamType.unary,
    dzerothkeysv1keys.RegisterKeyDeviceRequest.new,
    dzerothkeysv1keys.RegisterKeyDeviceResponse.new,
  );

  /// The caller's devices, at most 5, oldest first; inactive ones (not seen for 30 days) are included, flagged by
  /// last_seen_at and KeyDevice.inactive. Needs the flag only not globally off. Query of at most 5 device documents
  /// (Limit 5). No cursor: the device limit caps the list at 5.
  static const listMyKeyDevices = connect.Spec(
    '/$name/ListMyKeyDevices',
    connect.StreamType.unary,
    dzerothkeysv1keys.ListMyKeyDevicesRequest.new,
    dzerothkeysv1keys.ListMyKeyDevicesResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Remove one of the caller's devices together with its key package pool and its last-resort package. A missing
  /// device is success (idempotent); pool documents left under a missing device are deleted too. Needs the flag only
  /// not globally off. Validation: device_id format, idempotency_key format. Not one atomic write: the pool is deleted
  /// first, in pages of at most 100 documents, then one transaction deletes the device document only when its pool is
  /// empty. The pool never holds more than 100 (UploadKeyPackages enforces that), so one page normally suffices; if
  /// uploads keep refilling the pool, the sweep repeats for at most 5 rounds and then answers UNAVAILABLE (retry). A
  /// failed or timed-out call may already have deleted some pool documents; retrying finishes the removal.
  static const removeKeyDevice = connect.Spec(
    '/$name/RemoveKeyDevice',
    connect.StreamType.unary,
    dzerothkeysv1keys.RemoveKeyDeviceRequest.new,
    dzerothkeysv1keys.RemoveKeyDeviceResponse.new,
  );

  /// Add key packages to a registered device's pool and optionally replace its last-resort package. Needs the flag on
  /// for the caller. Naturally idempotent: a key package's document id is derived from its bytes, so a replay stores
  /// nothing twice while the packages are still in the pool, and duplicates within one request are stored once. A
  /// replay after a claim can re-add a package that was already handed out (the server does not remember consumed
  /// packages), so clients must tolerate a Welcome built on a consumed package and should follow a retried upload with
  /// fresh packages. The pool holds at most 100: packages beyond the free space are dropped: when the pool is full the
  /// oldest stay and the new packages are not stored (the response carries the resulting count, which can be
  /// momentarily higher than the pool if a claim runs concurrently). An empty
  /// last_resort_key_package means none sent: the stored one is kept. Unknown device => NOT_FOUND. Neither key packages
  /// nor a last-resort package => VALIDATION "key_packages". Marks the device seen (at most once per 24 h). One
  /// transaction: 1 device read + at most 100 reads, at most 101 writes.
  static const uploadKeyPackages = connect.Spec(
    '/$name/UploadKeyPackages',
    connect.StreamType.unary,
    dzerothkeysv1keys.UploadKeyPackagesRequest.new,
    dzerothkeysv1keys.UploadKeyPackagesResponse.new,
  );

  /// Devices of up to 10 users. Needs the flag only not globally off. Validation (1-10 user_ids, each a well-formed
  /// user id, no duplicates, the caller's own id twice included, else VALIDATION "user_ids") and the send-rules check
  /// for every id come first: for each target other than the caller, the caller must be allowed to
  /// message the target by the messaging send rules; an unknown or non-ACTIVE user, a block in either direction and any
  /// other refusal answer ONE byte-identical FAILED_PRECONDITION + CANNOT_MESSAGE, and one refused target fails the
  /// whole call with that single CANNOT_MESSAGE (no partial result). Then, per target other than the caller: devices
  /// are returned when the caller and the target both have the flag on, or the two share an encrypted conversation
  /// (computed by the server from the two raw uids; the conversation read may be up to 60 s stale); otherwise the
  /// answer is an empty success, also for a caller whose flag is off (never FEATURE_DISABLED unless the flag is
  /// globally off). For a pair that shares an encrypted conversation every registered device is returned, each
  /// carrying its inactive flag; otherwise active devices only, oldest first. The caller's own id returns the caller's
  /// active devices only when the caller's flag is on, else none (use ListMyKeyDevices). For other users only device_id,
  /// signature_public_key and inactive are returned: created_at and last_seen_at are absent, key_package_count is 0
  /// and has_last_resort is false. The caller's own devices carry every field. Reads: for each target other than the
  /// caller, the send-rules check reads at most 4 documents, all cache-first (the caller's graph, the target's profile
  /// and, only when the target accepts messages from accounts they follow, one follow edge and the conversation), plus
  /// the target's graph when the caller has been blocked by so many accounts that their own list is truncated (then
  /// at most 5), plus one conversation read per other target (served from a copy at most 60 s old when the conversation
  /// exists; a Firestore read whenever no conversation exists); then at most 10 queries of at most 5 devices (the
  /// caller and each target whose devices are returned: nothing is read for a refused or empty-success target). A
  /// failed read is an error, never an empty list. No writes.
  static const getKeyDevices = connect.Spec(
    '/$name/GetKeyDevices',
    connect.StreamType.unary,
    dzerothkeysv1keys.GetKeyDevicesRequest.new,
    dzerothkeysv1keys.GetKeyDevicesResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Claim one key package per active device of user_id, devices oldest first. Needs the flag on for the caller. Same
  /// send-rules check and the same single CANNOT_MESSAGE refusal as GetKeyDevices; a target with the flag off is an
  /// empty success, and a flag-off caller cannot claim (FEATURE_DISABLED), so a flag-off target or caller can neither
  /// be claimed for nor claim; a malformed user_id is VALIDATION "user_id". The response carries conversation_id (see
  /// ClaimKeyPackagesResponse). For each active device the server consumes one
  /// one-time package (which one is unspecified), else returns the device's last-resort package (last_resort = true,
  /// not consumed), else has_key_package = false. Under heavy contention on one device the last-resort package (or
  /// has_key_package = false) may be returned although one-time packages remain; contention is never an error. A
  /// returned last-resort package may be one the device replaced a moment earlier (a stale read in a millisecond
  /// window); the receiving device may then be unable to use it, and the sender should claim again.
  /// There is no transaction: per device, one atomic write deletes one one-time package and decrements the count. Not
  /// atomic across devices. Reads without contention: at most 15 (1 query of at most 5 devices + 1 or 2 pool queries of
  /// at most 1 document per device); with contention at most 110 (at most 10 picks per device, 2 pool queries each, plus
  /// 1 device read); plus the send-rules check's at most 4 (5, see GetKeyDevices) for another user. At most 10
  /// committed writes.
  /// NOT replayable: a retry consumes fresh packages, and idempotency_key is format-checked only. A failed or timed-out
  /// call is not proof that nothing was consumed: packages may already have been taken, including for earlier devices
  /// of the same call when a later device fails. Claiming for the caller's own user id requires exclude_device_id to be
  /// one of the caller's devices, an inactive one included (VALIDATION "exclude_device_id"); that device is left out.
  /// For another user exclude_device_id must be empty or a well-formed device id (VALIDATION "exclude_device_id") and
  /// is ignored. Limited by RATE_LIMIT_KEYS_CLAIM_PER_MIN and the daily caps KEYS_CLAIMS_PER_DAY and
  /// KEYS_CLAIMS_PER_TARGET_PER_DAY (see Errors).
  static const claimKeyPackages = connect.Spec(
    '/$name/ClaimKeyPackages',
    connect.StreamType.unary,
    dzerothkeysv1keys.ClaimKeyPackagesRequest.new,
    dzerothkeysv1keys.ClaimKeyPackagesResponse.new,
  );
}
