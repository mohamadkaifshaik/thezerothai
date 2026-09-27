//
//  Generated code. Do not modify.
//  source: dzeroth/identity/v1/identity.proto
//

import "package:connectrpc/connect.dart" as connect;
import "identity.pb.dart" as dzerothidentityv1identity;

abstract final class IdentityService {
  /// Fully-qualified name of the IdentityService service.
  static const name = 'dzeroth.identity.v1.IdentityService';

  /// Creates the caller's profile after Firebase sign-up. Idempotent by uid: a replay returns the existing profile.
  /// Transaction: read users/{uid} + handles/{h}; create users, handles, graph.
  /// Firestore: reads 2/2, writes 3/3.
  static const createProfile = connect.Spec(
    '/$name/CreateProfile',
    connect.StreamType.unary,
    dzerothidentityv1identity.CreateProfileRequest.new,
    dzerothidentityv1identity.CreateProfileResponse.new,
  );

  /// Handle availability check for the sign-up form. In-memory rate limited (10/min/uid).
  /// Firestore: reads 1/1, writes 0.
  static const checkHandleAvailability = connect.Spec(
    '/$name/CheckHandleAvailability',
    connect.StreamType.unary,
    dzerothidentityv1identity.CheckHandleAvailabilityRequest.new,
    dzerothidentityv1identity.CheckHandleAvailabilityResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The caller's own profile + account state. users/{uid} instance-cached 60 s (updated in place on own writes);
  /// unread count = count() aggregation on notifications with createdAt > users.notificationsSeenAt (1 read per
  /// 1,000 matches, cached 30 s).
  /// Firestore: reads 2/1, writes 0.
  static const getMe = connect.Spec(
    '/$name/GetMe',
    connect.StreamType.unary,
    dzerothidentityv1identity.GetMeRequest.new,
    dzerothidentityv1identity.GetMeResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Public profile by id or handle. Returns NOT_FOUND if the profile blocks the caller (no existence leak).
  /// Reads: handles (if by handle) + users + target graph (blocked-by check) + caller graph; all instance-cached 60 s.
  /// Firestore: reads 4/0-1, writes 0.
  static const getProfile = connect.Spec(
    '/$name/GetProfile',
    connect.StreamType.unary,
    dzerothidentityv1identity.GetProfileRequest.new,
    dzerothidentityv1identity.GetProfileResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Partial update; only fields that are set are changed. Naturally idempotent (sets values).
  /// A change to display_name or avatar enqueues the author-snapshot refresh job (ADR-0003):
  /// async <= 100 post writes, limited to 5 snapshot-affecting edits/user/day.
  /// A change to is_private enqueues the visibility job (writes = author's post count; limited to 1 toggle/day).
  /// Firestore: reads 2/1 (users + avatar media), writes 1/1 (+ async jobs above).
  static const updateProfile = connect.Spec(
    '/$name/UpdateProfile',
    connect.StreamType.unary,
    dzerothidentityv1identity.UpdateProfileRequest.new,
    dzerothidentityv1identity.UpdateProfileResponse.new,
  );

  /// Rename. Transaction: read users + handles/{new}; create handles/{new}, delete handles/{old}, update users.
  /// Cooldown 7 days (config HANDLE_CHANGE_COOLDOWN). Enqueues the author-snapshot refresh job.
  /// Firestore: reads 2/2, writes 2/2 + deletes 1/1 (+ async snapshot job).
  static const changeHandle = connect.Spec(
    '/$name/ChangeHandle',
    connect.StreamType.unary,
    dzerothidentityv1identity.ChangeHandleRequest.new,
    dzerothidentityv1identity.ChangeHandleResponse.new,
  );

  /// Irreversible account deletion. Requires a recent sign-in (ID token auth_time < 5 min).
  /// Sets users.status = DELETING and publishes `account-delete`; the resumable job deletes every owned
  /// document and object in batches of <= 500 and finally the Firebase Auth user (ADR-0003, Privacy).
  /// Firestore (sync part): reads 1/1, writes 1/1.
  static const deleteAccount = connect.Spec(
    '/$name/DeleteAccount',
    connect.StreamType.unary,
    dzerothidentityv1identity.DeleteAccountRequest.new,
    dzerothidentityv1identity.DeleteAccountResponse.new,
  );

  /// Starts a data export (1/day/user). Doc id = hash(uid, idempotency_key) so a replay returns the same export.
  /// Firestore: reads 1/1 (quotas), writes 2/2 (exports doc + quotas).
  static const requestAccountExport = connect.Spec(
    '/$name/RequestAccountExport',
    connect.StreamType.unary,
    dzerothidentityv1identity.RequestAccountExportRequest.new,
    dzerothidentityv1identity.RequestAccountExportResponse.new,
  );

  /// Export status; when READY returns a fresh 15-minute signed GET URL (signed per call, never stored).
  /// Firestore: reads 1/1, writes 0.
  static const getAccountExport = connect.Spec(
    '/$name/GetAccountExport',
    connect.StreamType.unary,
    dzerothidentityv1identity.GetAccountExportRequest.new,
    dzerothidentityv1identity.GetAccountExportResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
