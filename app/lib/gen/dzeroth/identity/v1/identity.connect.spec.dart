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
  /// Needs a verified identity (Google, Apple or a password account with a verified email),
  /// else FAILED_PRECONDITION + EMAIL_NOT_VERIFIED.
  static const createProfile = connect.Spec(
    '/$name/CreateProfile',
    connect.StreamType.unary,
    dzerothidentityv1identity.CreateProfileRequest.new,
    dzerothidentityv1identity.CreateProfileResponse.new,
  );

  /// Handle availability check for the sign-up form. In-memory rate limited (20/min/uid) and capped
  /// at 100 calls/uid/IST day per instance (RATE_LIMITED, metadata["limit"] = "check_handle_daily").
  /// Only the per-minute bucket and check_handle_daily can reject.
  /// Needs a verified identity: a password account whose email is unverified, and any sign-in other than Google,
  /// Apple or verified password, gets FAILED_PRECONDITION + EMAIL_NOT_VERIFIED before any lookup
  /// (and before any rate limiter). The client shows the "verify your email" banner and refreshes the ID token.
  /// "Taken" is reported even when the handle's owner blocked the caller (accepted residual).
  /// Free handles are negatively cached 10 s per instance (a just-freed handle may read "taken" for <= 60 s).
  static const checkHandleAvailability = connect.Spec(
    '/$name/CheckHandleAvailability',
    connect.StreamType.unary,
    dzerothidentityv1identity.CheckHandleAvailabilityRequest.new,
    dzerothidentityv1identity.CheckHandleAvailabilityResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The caller's own profile + account state. users/{uid} instance-cached 60 s (updated in place on own writes);
  /// unread count = count() aggregation on notifications with createdAt > users.notificationsSeenAt (cached 30 s).
  /// enabled_features comes from server env config, with no lookup.
  /// pending_follow_request_count: for a protected caller only, a count() aggregation on followRequests
  /// where followeeId == caller, cached 30 s; every other caller gets 0 without a lookup. A
  /// failed count leaves it 0 and GetMe still answers.
  /// unread_conversation_count: only when FEATURE_MESSAGING is on for the caller, a count() aggregation
  /// on users/{uid}/dmInbox where unreadCount > 0, Limit 100, cached 30 s; no lookup otherwise.
  /// home_tabs: from users/{uid}, already read, so no lookup.
  static const getMe = connect.Spec(
    '/$name/GetMe',
    connect.StreamType.unary,
    dzerothidentityv1identity.GetMeRequest.new,
    dzerothidentityv1identity.GetMeResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Public profile by id or handle. Returns NOT_FOUND if the target blocked the caller, byte-identical to the
  /// error for a missing user (no existence leak). The check uses the caller's own graph (blockedBy).
  /// A caller who blocks the target still gets the profile (so they can unblock).
  /// A protected account's profile is returned to every caller with every field, is_private and the
  /// counts included, except pinned_post_id, which is empty unless the caller is the account or follows it (0 extra
  /// reads: the follow bit comes from the caller's cached graph).
  /// Reads: handles (if by handle) + users + caller graph; all instance-cached 60 s; a handle that doesn't exist is
  /// negatively cached 10 s.
  static const getProfile = connect.Spec(
    '/$name/GetProfile',
    connect.StreamType.unary,
    dzerothidentityv1identity.GetProfileRequest.new,
    dzerothidentityv1identity.GetProfileResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Partial update; only fields that are set are changed. Naturally idempotent (sets values).
  /// A change to display_name or avatar enqueues the author-snapshot refresh job:
  /// async <= 100 post writes, limited to 5 snapshot-affecting edits/user/day.
  /// Private accounts: is_private=true needs FEATURE_PRIVATE_ACCOUNTS (wire name
  /// "private_accounts") on for the caller, else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] =
  /// "private_accounts", writing nothing, checked before any read; a request that sets it with other fields is refused whole
  /// while the flag is off for the caller. is_private=false is accepted from any caller whatever the flag, globally off
  /// included. A changed is_private runs one transaction that reads users, the protected-author set and quotas fresh
  /// and writes isPrivate, the set (add or remove the uid) and quotas.privacyToggles.
  /// A value equal to the stored one writes nothing and is not charged. QUOTA_PRIVACY_TOGGLES_PER_DAY, 4 per IST day,
  /// both directions counted => RESOURCE_EXHAUSTED + QUOTA_EXCEEDED, metadata["quota"] = "privacy_toggles"; protecting
  /// while PROTECTED_AUTHORS_MAX (20,000) accounts are protected => FAILED_PRECONDITION + LIMIT_REACHED,
  /// metadata["limit"] = "private_accounts"; both write nothing. No post is rewritten (there is no visibility job): every
  /// read path applies the new setting at once on the instance that committed it and within 60 s on the others.
  /// Existing followers stay. After an unprotect commit the server publishes one privacy_public job (the jobs topic)
  /// that accepts every pending follow request (in pages of 100),
  /// so the request path does none of that work; a failed publish is logged at ERROR. A toggle enqueues no
  /// author-snapshot job and spends no snapshot-affecting edit.
  /// Profile extras: setting banner_media_id, location, website or pinned_post_id
  /// (any non-empty value, whitespace-only included) needs FEATURE_PROFILE_EXTRAS (wire name "profile_extras") on for the
  /// caller; otherwise FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "profile_extras", writing nothing, checked
  /// before validation. A request from outside the cohort that mixes a clear with a set is refused whole. The exact
  /// string "" is a clear (banner removed, location or website emptied, pin removed) and is accepted from any
  /// authenticated caller whatever the flag, globally off included, and is handled like a bio edit. While the flag
  /// is globally off the response omits website and pinned_post_id (Profile). DEGRADED_MODE=readonly still refuses the
  /// write. The display_name, bio and avatar path is unchanged. A banner, location, website or pin change does not enqueue the author-snapshot job
  /// and spends no snapshot-affecting edit (none of them is in AuthorSnapshot). Field rules are on the request fields.
  /// A request that changes nothing writes nothing. Per-uid daily call cap
  /// PROFILE_UPDATES_PER_DAY, 100 calls/uid/IST day per instance (300 with 3) => RATE_LIMITED,
  /// metadata["limit"] = "profile_update_daily", retry_after = time to IST midnight, before any lookup.
  /// Replaced and removed images: a commit that replaced or removed the avatar or the banner
  /// hands the old image to a best-effort retire step after the commit (the old URLs come from the document the
  /// transaction read, and at most 2 Pub/Sub publishes go out, one per image); a failed hand-over is logged at ERROR and the image stays until account deletion.
  /// The async job (kind profile_media_retired on the jobs topic) runs once per
  /// image, and deletes the old public objects 24-48 h later through a bucket lifecycle rule, only while
  /// PROFILE_MEDIA_RETIRE allows it (off by default; banner, or all for avatars too). A retired image can never be set
  /// again: it answers MEDIA_NOT_READY like any unusable id.
  static const updateProfile = connect.Spec(
    '/$name/UpdateProfile',
    connect.StreamType.unary,
    dzerothidentityv1identity.UpdateProfileRequest.new,
    dzerothidentityv1identity.UpdateProfileResponse.new,
  );

  /// Rename. Transaction: read users + handles/{new}; create handles/{new}, delete handles/{old}, update users.
  /// Cooldown 7 days (config HANDLE_CHANGE_COOLDOWN). Enqueues the author-snapshot refresh job.
  static const changeHandle = connect.Spec(
    '/$name/ChangeHandle',
    connect.StreamType.unary,
    dzerothidentityv1identity.ChangeHandleRequest.new,
    dzerothidentityv1identity.ChangeHandleResponse.new,
  );

  /// Irreversible account deletion of the caller's own account. The uid always comes from the ID token; the
  /// request has no uid field and must never get one. Requires a recent sign-in: ID token auth_time older than
  /// ACCOUNT_DELETE_REAUTH_MAX_AGE (5 min) or missing => FAILED_PRECONDITION + ERROR_REASON_REAUTH_REQUIRED, writing nothing.
  /// ACTIVE and SUSPENDED callers may both delete: this is the only RPC the account-status interceptor
  /// lets a SUSPENDED or DELETING caller through to.
  /// Sync part: one transaction reads users/{uid} fresh and sets status = DELETING, updatedAt, deletionRequestedAt and
  /// deletionJob{seq: 0} (no job doc); after the commit it publishes {kind: account_delete, uid, seq: 0} to the
  /// `jobs` Pub/Sub topic. A failed publish still returns success: a replay or the daily backstop re-publishes.
  /// Replay: a caller already DELETING (same or new idempotency_key) gets the stored deletion_requested_at and writes nothing,
  /// and the current job seq is re-published (deduped by the job).
  /// The job (`/internal/pubsub/jobs`, self-chaining, <= 20 s of work per delivery) disables the Firebase Auth user and
  /// revokes refresh tokens on its first delivery, waits until 120 s after deletionRequestedAt, then
  /// deletes posts, the social graph, later-slice data, exports, handle and quotas in batches of <= 500, then the
  /// Firebase Auth user, and users/{uid} last. Reference account (300 posts, 100 following, 100 followers) completes in
  /// about 3-5 minutes. Existing ID tokens stay valid up to 1 h but are rejected by the interceptor.
  /// Bounded by account_ops_daily:
  /// 20 calls/uid/IST day per instance shared with RequestAccountExport and GetAccountExport (RATE_LIMITED,
  /// metadata["limit"] = "account_ops_daily"). DEGRADED_MODE=readonly rejects it; a
  /// started deletion still finishes.
  static const deleteAccount = connect.Spec(
    '/$name/DeleteAccount',
    connect.StreamType.unary,
    dzerothidentityv1identity.DeleteAccountRequest.new,
    dzerothidentityv1identity.DeleteAccountResponse.new,
  );

  /// Starts a data export of the caller's own account (1/day/user, quota "exports"; over it => RESOURCE_EXHAUSTED +
  /// QUOTA_EXCEEDED, metadata["quota"] = "exports"). Doc id = hash(uid, idempotency_key), so a replay with the same key
  /// returns the same export and status. After the commit it publishes {kind: account_export, export_id} to the `jobs`
  /// topic; one delivery writes a single JSON file (account, profile, graph, posts; never who blocked you) to the
  /// private `<project>-exports` bucket and sets READY, usually within a minute.
  /// Bounded by account_ops_daily (see DeleteAccount). DEGRADED_MODE=readonly
  /// rejects it.
  static const requestAccountExport = connect.Spec(
    '/$name/RequestAccountExport',
    connect.StreamType.unary,
    dzerothidentityv1identity.RequestAccountExportRequest.new,
    dzerothidentityv1identity.RequestAccountExportResponse.new,
  );

  /// Export status; when READY returns a fresh 15-minute signed GET URL (signed per call, never stored or logged).
  /// NOT_FOUND, byte-identical in every case, when the export doesn't exist, belongs to another user, or is past
  /// expires_at (even if the TTL or bucket lifecycle has not deleted it yet).
  /// Bounded by account_ops_daily (see DeleteAccount).
  static const getAccountExport = connect.Spec(
    '/$name/GetAccountExport',
    connect.StreamType.unary,
    dzerothidentityv1identity.GetAccountExportRequest.new,
    dzerothidentityv1identity.GetAccountExportResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
