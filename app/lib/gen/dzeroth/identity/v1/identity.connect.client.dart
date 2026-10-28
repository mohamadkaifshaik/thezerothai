//
//  Generated code. Do not modify.
//  source: dzeroth/identity/v1/identity.proto
//

import "package:connectrpc/connect.dart" as connect;
import "identity.pb.dart" as dzerothidentityv1identity;
import "identity.connect.spec.dart" as specs;

extension type IdentityServiceClient (connect.Transport _transport) {
  /// Creates the caller's profile after Firebase sign-up. Idempotent by uid: a replay returns the existing profile.
  /// Transaction: read users/{uid} + handles/{h}; create users, handles, graph.
  /// Firestore: reads 2/2, writes 3/3.
  /// Needs a verified identity (Google, Apple or a password account with a verified email; ADR-0010 D5 A2, A10),
  /// else FAILED_PRECONDITION + EMAIL_NOT_VERIFIED at 0 reads. Its reads are charged to the caller IP's key but never
  /// rejected by it (charge-only, ADR-0010 D5 A8).
  Future<dzerothidentityv1identity.CreateProfileResponse> createProfile(
    dzerothidentityv1identity.CreateProfileRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.createProfile,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

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
  Future<dzerothidentityv1identity.CheckHandleAvailabilityResponse> checkHandleAvailability(
    dzerothidentityv1identity.CheckHandleAvailabilityRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.checkHandleAvailability,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's own profile + account state. users/{uid} instance-cached 60 s (updated in place on own writes);
  /// unread count = count() aggregation on notifications with createdAt > users.notificationsSeenAt (1 read per
  /// 1,000 matches, cached 30 s). enabled_features comes from server env config (ADR-0008 D6): 0 reads.
  /// pending_follow_request_count (ADR-0025 D7): for a protected caller only, a count() aggregation on followRequests
  /// where followeeId == caller (1 read per 1,000 matches, min 1), cached 30 s; 0 reads for every other caller. A
  /// failed count leaves it 0 and GetMe still answers.
  /// unread_conversation_count (ADR-0027 D10): only when FEATURE_MESSAGING is on for the caller, a count() aggregation
  /// on users/{uid}/dmInbox where unreadCount > 0, Limit 100 (1 read, min 1), cached 30 s; 0 reads otherwise.
  /// Firestore: reads 2/1 (+1 for a protected caller, cached 30 s; +1 count() of unread conversations with messaging
  /// on, cached 30 s), writes 0.
  Future<dzerothidentityv1identity.GetMeResponse> getMe(
    dzerothidentityv1identity.GetMeRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.getMe,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Public profile by id or handle. Returns NOT_FOUND if the target blocked the caller, byte-identical to the
  /// error for a missing user (no existence leak). The check uses the caller's own graph (blockedBy, ADR-0008 D2).
  /// A caller who blocks the target still gets the profile (so they can unblock).
  /// A protected account's profile (ADR-0025 D4) is returned to every caller with every field, is_private and the
  /// counts included, except pinned_post_id, which is empty unless the caller is the account or follows it (0 extra
  /// reads: the follow bit comes from the caller's cached graph).
  /// Reads: handles (if by handle) + users + caller graph; all instance-cached 60 s; a handle that doesn't exist is
  /// negatively cached 10 s (ADR-0010 D5).
  /// Charged, like every RPC, to the per-uid daily Firestore read budget (2,000 reads/uid/IST day per instance,
  /// ADR-0010 D5); over it => RATE_LIMITED, metadata["limit"] = "read_budget_daily", retry_after = time to IST
  /// midnight, 0 reads.
  /// Firestore: reads 3/0-1 (+1 if the caller's blockedBy overflowed, ADR-0008 D2), writes 0.
  Future<dzerothidentityv1identity.GetProfileResponse> getProfile(
    dzerothidentityv1identity.GetProfileRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.getProfile,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Partial update; only fields that are set are changed. Naturally idempotent (sets values).
  /// A change to display_name or avatar enqueues the author-snapshot refresh job (ADR-0003):
  /// async <= 100 post writes, limited to 5 snapshot-affecting edits/user/day.
  /// Private accounts (ADR-0025 D1, D8, D12): is_private=true needs FEATURE_PRIVATE_ACCOUNTS (wire name
  /// "private_accounts") on for the caller, else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] =
  /// "private_accounts", 0 writes, checked before any read; a request that sets it with other fields is refused whole
  /// while the flag is off for the caller. is_private=false is accepted from any caller whatever the flag, globally off
  /// included. A changed is_private runs one transaction that reads users, the protected-author set and quotas fresh
  /// and writes isPrivate, the set (add or remove the uid) and quotas.privacyToggles: reads 4 cold / 3 warm, writes 3.
  /// A value equal to the stored one writes nothing and is not charged. QUOTA_PRIVACY_TOGGLES_PER_DAY, 4 per IST day,
  /// both directions counted => RESOURCE_EXHAUSTED + QUOTA_EXCEEDED, metadata["quota"] = "privacy_toggles"; protecting
  /// while PROTECTED_AUTHORS_MAX (20,000) accounts are protected => FAILED_PRECONDITION + LIMIT_REACHED,
  /// metadata["limit"] = "private_accounts"; both 0 writes. No post is rewritten (there is no visibility job): every
  /// read path applies the new setting at once on the instance that committed it and within 60 s on the others.
  /// Existing followers stay. After an unprotect commit the server publishes one privacy_public job (the jobs topic)
  /// that accepts every pending follow request (2 reads, 3 writes and 1 delete per request, + 1 write per page of 100),
  /// so the request path adds 0 reads and 0 writes for it; a failed publish is logged at ERROR. A toggle enqueues no
  /// author-snapshot job and spends no snapshot-affecting edit.
  /// Profile extras (ADR-0024 D1-D3, D9, Amendment 1 A2): setting banner_media_id, location, website or pinned_post_id
  /// (any non-empty value, whitespace-only included) needs FEATURE_PROFILE_EXTRAS (wire name "profile_extras") on for the
  /// caller; otherwise FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "profile_extras", 0 writes, checked
  /// before validation. A request from outside the cohort that mixes a clear with a set is refused whole. The exact
  /// string "" is a clear (banner removed, location or website emptied, pin removed) and is accepted from any
  /// authenticated caller whatever the flag, globally off included: 1 read and 1 write like a bio edit. While the flag
  /// is globally off the response omits website and pinned_post_id (Profile). DEGRADED_MODE=readonly still refuses the
  /// write. The display_name, bio and avatar path is unchanged. A banner, location, website or pin change does not enqueue the author-snapshot job
  /// and spends no snapshot-affecting edit (none of them is in AuthorSnapshot). Field rules are on the request fields.
  /// Firestore: reads 2 cold / 1 warm (users + avatar media), +1 per banner resolve (the media doc), +1 per pin check
  /// (the post, cache-first: 1 cold / 0 warm); 4 worst cold with a banner and a pin, planning 2 (ADR-0024 D13);
  /// writes 1 (0 when the request changes nothing, W3-22 L-4; + async jobs above). Per-uid daily call cap
  /// PROFILE_UPDATES_PER_DAY, 100 calls/uid/IST day per instance (300 with 3) => RATE_LIMITED,
  /// metadata["limit"] = "profile_update_daily", retry_after = time to IST midnight, 0 reads.
  /// Replaced and removed images (ADR-0024 Amendment 1 A4): a commit that replaced or removed the avatar or the banner
  /// hands the old image to a best-effort retire step after the commit. On this request path that is 0 extra reads (the
  /// old URLs come from the document the transaction read), 0 extra writes and at most 2 Pub/Sub publishes, one per image,
  /// so the budget above is unchanged; a failed hand-over is logged at ERROR and the image stays until account deletion.
  /// The async job (kind profile_media_retired on the jobs topic) costs 2 reads, 1 write and 2 Class A operations per
  /// image, and deletes the old public objects 24-48 h later through a bucket lifecycle rule, only while
  /// PROFILE_MEDIA_RETIRE allows it (off by default; banner, or all for avatars too). A retired image can never be set
  /// again: it answers MEDIA_NOT_READY like any unusable id.
  Future<dzerothidentityv1identity.UpdateProfileResponse> updateProfile(
    dzerothidentityv1identity.UpdateProfileRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.updateProfile,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Rename. Transaction: read users + handles/{new}; create handles/{new}, delete handles/{old}, update users.
  /// Cooldown 7 days (config HANDLE_CHANGE_COOLDOWN). Enqueues the author-snapshot refresh job.
  /// Firestore: reads 2/2, writes 2/2 + deletes 1/1 (+ async snapshot job).
  Future<dzerothidentityv1identity.ChangeHandleResponse> changeHandle(
    dzerothidentityv1identity.ChangeHandleRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.changeHandle,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Irreversible account deletion of the caller's own account (ADR-0011). The uid always comes from the ID token; the
  /// request has no uid field and must never get one. Requires a recent sign-in: ID token auth_time older than
  /// ACCOUNT_DELETE_REAUTH_MAX_AGE (5 min) or missing => FAILED_PRECONDITION + ERROR_REASON_REAUTH_REQUIRED, 0 writes.
  /// ACTIVE and SUSPENDED callers may both delete (ADR-0011 Q3): this is the only RPC the account-status interceptor
  /// lets a SUSPENDED or DELETING caller through to.
  /// Sync part: one transaction reads users/{uid} fresh and sets status = DELETING, updatedAt, deletionRequestedAt and
  /// deletionJob{seq: 0} (no job doc); after the commit it publishes {kind: account_delete, uid, seq: 0} to the
  /// `jobs` Pub/Sub topic. A failed publish still returns success: a replay or the daily backstop re-publishes.
  /// Replay: a caller already DELETING (same or new idempotency_key) gets the stored deletion_requested_at, 0 writes,
  /// and the current job seq is re-published (deduped by the job).
  /// The job (`/internal/pubsub/jobs`, self-chaining, <= 20 s of work per delivery) disables the Firebase Auth user and
  /// revokes refresh tokens on its first delivery, waits until 120 s after deletionRequestedAt (ADR-0008 D10), then
  /// deletes posts, the social graph, later-slice data, exports, handle and quotas in batches of <= 500, then the
  /// Firebase Auth user, and users/{uid} last. Reference account (300 posts, 100 following, 100 followers) completes in
  /// about 3-5 minutes. Existing ID tokens stay valid up to 1 h but are rejected by the interceptor.
  /// Firestore (sync part): reads 2/1 (interceptor + users), writes 1/1; replay reads 2/1, writes 0.
  /// Never rejected by the read budget (charge-only, CLAUDE.md rule 10); bounded instead by account_ops_daily:
  /// 20 calls/uid/IST day per instance shared with RequestAccountExport and GetAccountExport (RATE_LIMITED,
  /// metadata["limit"] = "account_ops_daily"; ADR-0010 D5 A6). DEGRADED_MODE=readonly rejects it (ADR-0011 Q8); a
  /// started deletion still finishes.
  Future<dzerothidentityv1identity.DeleteAccountResponse> deleteAccount(
    dzerothidentityv1identity.DeleteAccountRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.deleteAccount,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Starts a data export of the caller's own account (1/day/user, quota "exports"; over it => RESOURCE_EXHAUSTED +
  /// QUOTA_EXCEEDED, metadata["quota"] = "exports"). Doc id = hash(uid, idempotency_key), so a replay with the same key
  /// returns the same export and status. After the commit it publishes {kind: account_export, export_id} to the `jobs`
  /// topic; one delivery writes a single JSON file (account, profile, graph, posts; never who blocked you) to the
  /// private `<project>-exports` bucket and sets READY, usually within a minute (ADR-0011 D-B, D-D).
  /// Firestore: reads 2/1 (interceptor + quotas), writes 2/2 (exports doc + quotas); replay reads 3/2, writes 0.
  /// Never rejected by the read budget; bounded by account_ops_daily (see DeleteAccount). DEGRADED_MODE=readonly
  /// rejects it.
  Future<dzerothidentityv1identity.RequestAccountExportResponse> requestAccountExport(
    dzerothidentityv1identity.RequestAccountExportRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.requestAccountExport,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Export status; when READY returns a fresh 15-minute signed GET URL (signed per call, never stored or logged).
  /// NOT_FOUND, byte-identical in every case, when the export doesn't exist, belongs to another user, or is past
  /// expires_at (even if the TTL or bucket lifecycle has not deleted it yet; ADR-0011 Q6).
  /// Firestore: reads 2/1 (interceptor + exports, read fresh), writes 0.
  /// Never rejected by the read budget; bounded by account_ops_daily (see DeleteAccount).
  Future<dzerothidentityv1identity.GetAccountExportResponse> getAccountExport(
    dzerothidentityv1identity.GetAccountExportRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.IdentityService.getAccountExport,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
