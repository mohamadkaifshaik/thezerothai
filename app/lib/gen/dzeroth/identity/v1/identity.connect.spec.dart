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
  /// Needs a verified identity (Google, Apple or a password account with a verified email; ADR-0010 D5 A2, A10),
  /// else FAILED_PRECONDITION + EMAIL_NOT_VERIFIED at 0 reads. Its reads are charged to the caller IP's key but never
  /// rejected by it (charge-only, ADR-0010 D5 A8).
  static const createProfile = connect.Spec(
    '/$name/CreateProfile',
    connect.StreamType.unary,
    dzerothidentityv1identity.CreateProfileRequest.new,
    dzerothidentityv1identity.CreateProfileResponse.new,
  );

  /// Handle availability check for the sign-up form. In-memory rate limited (20/min/uid, ADR-0008 D7) and capped
  /// at 100 calls/uid/IST day per instance (RATE_LIMITED, metadata["limit"] = "check_handle_daily").
  /// Profile-exempt, so its reads are charged to the uid's daily Firestore read budget (over it => RATE_LIMITED,
  /// metadata["limit"] = "read_budget_daily", retry_after = time to IST midnight) and metered on the caller IP's
  /// (IPv6: /64) key, which is NEVER a reason to reject (ADR-0010 D5 A8): one address behind a carrier-grade NAT
  /// cannot block sign-ups for others. Only the per-minute bucket and check_handle_daily can still reject.
  /// Needs a verified identity: a password account whose email is unverified, and any sign-in other than Google,
  /// Apple or verified password (ADR-0010 D5 A10), gets FAILED_PRECONDITION + EMAIL_NOT_VERIFIED at 0 reads
  /// (before any rate limiter). The client shows the "verify your email" banner and refreshes the ID token.
  /// "Taken" is reported even when the handle's owner blocked the caller (accepted residual, ADR-0008 D9).
  /// Free handles are negatively cached 10 s per instance (a just-freed handle may read "taken" for <= 60 s).
  /// Firestore: reads 1/0-1, writes 0.
  static const checkHandleAvailability = connect.Spec(
    '/$name/CheckHandleAvailability',
    connect.StreamType.unary,
    dzerothidentityv1identity.CheckHandleAvailabilityRequest.new,
    dzerothidentityv1identity.CheckHandleAvailabilityResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The caller's own profile + account state. users/{uid} instance-cached 60 s (updated in place on own writes);
  /// unread count = count() aggregation on notifications with createdAt > users.notificationsSeenAt (1 read per
  /// 1,000 matches, cached 30 s). enabled_features comes from server env config (ADR-0008 D6): 0 reads.
  /// Firestore: reads 2/1, writes 0.
  static const getMe = connect.Spec(
    '/$name/GetMe',
    connect.StreamType.unary,
    dzerothidentityv1identity.GetMeRequest.new,
    dzerothidentityv1identity.GetMeResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Public profile by id or handle. Returns NOT_FOUND if the target blocked the caller, byte-identical to the
  /// error for a missing user (no existence leak). The check uses the caller's own graph (blockedBy, ADR-0008 D2).
  /// A caller who blocks the target still gets the profile (so they can unblock).
  /// Reads: handles (if by handle) + users + caller graph; all instance-cached 60 s; a handle that doesn't exist is
  /// negatively cached 10 s (ADR-0010 D5).
  /// Charged, like every RPC, to the per-uid daily Firestore read budget (2,000 reads/uid/IST day per instance,
  /// ADR-0010 D5); over it => RATE_LIMITED, metadata["limit"] = "read_budget_daily", retry_after = time to IST
  /// midnight, 0 reads.
  /// Firestore: reads 3/0-1 (+1 if the caller's blockedBy overflowed, ADR-0008 D2), writes 0.
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
  /// is_private=true is rejected with INVALID_ARGUMENT + VALIDATION (field "is_private") until private accounts ship
  /// (ADR-0008 D1); is_private=false is accepted. Once enabled, a change to is_private enqueues the visibility job
  /// (writes = author's post count; limited to 1 toggle/day).
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

  /// Irreversible account deletion. Requires a recent sign-in: ID token auth_time older than
  /// ACCOUNT_DELETE_REAUTH_MAX_AGE (5 min) or missing => FAILED_PRECONDITION + ERROR_REASON_REAUTH_REQUIRED, 0 writes.
  /// Sets users.status = DELETING and publishes `account-delete`; the resumable job deletes every owned
  /// document and object in batches of <= 500 and finally the Firebase Auth user (ADR-0003, Privacy).
  /// Firestore (sync part): reads 1/1, writes 1/1.
  /// Never rejected by the read budget (charge-only, CLAUDE.md rule 10); bounded instead by account_ops_daily:
  /// 20 calls/uid/IST day per instance shared with RequestAccountExport and GetAccountExport (RATE_LIMITED,
  /// metadata["limit"] = "account_ops_daily"; ADR-0010 D5 A6).
  static const deleteAccount = connect.Spec(
    '/$name/DeleteAccount',
    connect.StreamType.unary,
    dzerothidentityv1identity.DeleteAccountRequest.new,
    dzerothidentityv1identity.DeleteAccountResponse.new,
  );

  /// Starts a data export (1/day/user). Doc id = hash(uid, idempotency_key) so a replay returns the same export.
  /// Firestore: reads 1/1 (quotas), writes 2/2 (exports doc + quotas).
  /// Never rejected by the read budget; bounded by account_ops_daily (see DeleteAccount).
  static const requestAccountExport = connect.Spec(
    '/$name/RequestAccountExport',
    connect.StreamType.unary,
    dzerothidentityv1identity.RequestAccountExportRequest.new,
    dzerothidentityv1identity.RequestAccountExportResponse.new,
  );

  /// Export status; when READY returns a fresh 15-minute signed GET URL (signed per call, never stored).
  /// Firestore: reads 1/1, writes 0.
  /// Never rejected by the read budget; bounded by account_ops_daily (see DeleteAccount).
  static const getAccountExport = connect.Spec(
    '/$name/GetAccountExport',
    connect.StreamType.unary,
    dzerothidentityv1identity.GetAccountExportRequest.new,
    dzerothidentityv1identity.GetAccountExportResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
