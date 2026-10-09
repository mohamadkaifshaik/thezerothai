# Security review: account deletion and export (P8, ADR-0011, ticket T20)

- **Date:** 2026-10-08
- **Scope:** `git diff main...HEAD -- backend infra` on branch `docs/p8-t1-adr` (identity lifecycle, graph/posts erasers, apiserver
  wiring, `pkg/platform` additions, Terraform for the exports bucket, `jobs` topic, `accountLifecycleAuth` role and C4 alert).
- **Reviewer:** `security-auditor` agent, with the `code-reviewer` and `tester` findings as input. Fix status below was
  recorded after the follow-up commits and a live check on `dzeroth-dev`.
- **Original verdict:** conditional GO for the dev allowlist; NO-GO for prod until M-1, M-2 and M-3 were fixed.
  0 Critical, 0 High, 3 Medium, 7 Low.
- **Verdict after fixes:** the three Mediums are fixed and verified (live on dev for M-1). Prod stays flag-`off` until the
  items under "Before prod" are closed.

## Threat model summary (STRIDE)

| Threat | Controls | Residual |
|---|---|---|
| Spoofing | Connect RPCs verify Firebase ID tokens (signature, issuer, audience, expiry) and App Check (monitor mode). `/internal/*` uses `idtoken.Validate` (audience = the `run.app` URL) and then an email allowlist of only the `pubsub-push` service account. | `VerifyIDToken` does not ask Firebase whether the user was revoked or deleted (the cause of M-1, now closed at the `CreateProfile` boundary). |
| Tampering / elevation | Jobs never trust a uid in a message: C1 re-reads `users/{uid}` and requires `DELETING` plus matching job state. `DeleteAccount` uses the token uid only. Restricted (SUSPENDED/DELETING) callers may reach `DeleteAccount` only. | A stolen runtime service account token bypasses C1 to C3 entirely. Accepted in ADR-0011. |
| Repudiation | C3 NOTICE audit line per Auth mutation or lookup (hashed uid, op, outcome, actor). C1 refusals are ERROR and reach Error Reporting. | Identity Toolkit data-access audit logs need an Identity Platform upgrade (pricing change). Not enabled at Stage 0; revisit in the upgrade ADR. |
| Information disclosure | Export ids are `sha256(uid, rpc, key)`; Q6 returns one byte-identical NOT_FOUND for unknown, foreign, malformed and expired ids. Signed URLs are V4, one object, GET only, 15 min, `attachment` disposition, never logged. Exports bucket is private (public access prevention enforced, uniform access, only the runtime SA). | A signed URL can outlive `expireAt` by up to 15 min. The uid hash is stable across log lines, so lines are linkable by anyone who already knows a uid (project convention). |
| Denial of service / cost | The three RPCs share `account_ops_daily`; exports are capped at 1/day; DLQ loop is bounded to about 10 deliveries per stuck job per day. | Export replay amplification (L-4). |

## Findings and status

### Medium

**M-1. A deleted user's still-valid ID token could recreate the account. FIXED (option a), verified live on dev.**
- Cause: `authn/firebase.go` uses `VerifyIDToken` with no revocation check outside the emulators, and `CreateProfile` is
  exempt from the account-status interceptor. For about 50 minutes after deletion the old token could create a new ACTIVE
  `users/{uid}` plus handle for a uid with no Auth user (orphan data outside Q10, impossible for the user to delete), and a
  SUSPENDED user could shed suspension through delete then sign-up. A second signed-in device reached the same path without
  malice.
- Fix: on the not-found path of `CreateProfile` only (a first sign-up), the audited Auth wrapper looks up the caller's own
  uid (`signupTarget`, built from the verified token only) and refuses a missing or disabled Auth user with
  PERMISSION_DENIED; an Auth outage fails closed with UNAVAILABLE. Cost: 0 Firestore ops, 1 Auth call per real sign-up; replays
  make no Auth call. ADR-0011 amended 2026-10-08 (C1/C2/C3 wording).
- Auditor preference: a tombstone (`deletedUsers/{sha256(uid)}` with a 2 h TTL, checked inside the existing `CreateProfile`
  transaction) because it adds no Auth dependency to sign-up. The founder chose option (a) to keep authorization at the
  RPC boundary. Trade-off accepted: sign-ups depend on Identity Toolkit availability.
- Verification: unit tests with a verifier that does not check revocation (like production); emulator tests with such a verifier
  (the emulator's own verifier always checks, so it cannot reproduce the bug); live on `dzeroth-dev` on 2026-10-08: the
  same token replayed after deletion returned 403 `permission_denied`.

**M-2. Raw uids (including third parties') reached Cloud Logging and Error Reporting. FIXED.**
- Cause: eraser errors were returned unredacted; Firestore errors carry document paths (`documents/users/<uid>`,
  `follows/<a>_<b>`), and `graph/purge.go` put follow doc ids in its own errors. `RedactErr(err, uid)` alone cannot hide
  third-party ids. Export ids leaked through some wraps too.
- Fix: `logger.ScrubErr` replaces `documents/...` paths, the `<uid>_<uid>` edge-id shape and 64-hex export ids, and hashes
  known ids; it runs where every job error leaves (`retry()`) and in the export and objstore paths. Graph purge hashes
  counterpart ids at the source. Tests feed Firestore-shaped errors with two uids and an export id through `logDelivery`
  at WARN and ERROR levels.
- Limit: the edge-id pattern matches uids of 20+ characters (real Firebase uids). A short third-party uid outside a
  `documents/` path would not match.
- Live check: a search of dev logs for the throwaway uid found nothing; audit lines carried only the hash.

**M-3. Soft delete kept deleted export objects (full PII) recoverable for 7 days. FIXED.**
- Fix: `soft_delete_policy { retention_duration_seconds = 0 }` on the exports bucket (applied on dev, verified with
  gcloud). The `media-upload` bucket (no PII before moderation, 2-day lifecycle) and the public `media` bucket were left
  at the default; revisit `media` if right-to-delete must make deleted images unrecoverable.

### Low

| ID | Finding | Status |
|---|---|---|
| L-1 | The C2 confinement guard could be evaded (files not importing the auth package, method values, interface values, renamed variables). | **Fixed.** Replaced by one `go/packages` type-check that flags every use of the Auth admin methods (calls, method values, promoted calls through embedded types, `app.Auth`) outside `internal/identity`, `cmd/opsctl` and three builder files, with a closed-holes test. Residual: the allowlist covers all of `internal/identity`, not only `authadmin.go`; raw REST calls to Identity Toolkit are not detected (defence in depth only; IAM and C4 remain the real controls). |
| L-2 | The C4 metric counted 3 to 4 events per deletion, so about 3 deletions an hour tripped a threshold of 10. | **Fixed.** Metric counts only `auth_admin_op="delete"` with `outcome="ok"` plus ERROR refusals; threshold 5 per hour; alert is prod-only (about $0.40/month total). |
| L-3 | `DeleteUserDoc` was unconditional, so a late same-sequence delivery could delete a re-created profile. | **Fixed.** One transaction requiring `status == DELETING` and `deletionJob.seq == msg.seq`; a conflict acks as `duplicate`. |
| L-4 | Export replay amplification: each replay while PENDING re-publishes, and concurrent deliveries each recompose the export (about 60 full exports per day for one large account, bounded by `account_ops_daily`). | **Fixed (acc7aae).** A 35 s `leaseUntil` claim (write with `LastUpdateTime` precondition) before composing, so an export is composed once; a delivery that sees a live lease answers 429 `leased` (1 read, 0 writes). Replays re-publish only when `createdAt` is at least 2 minutes old. The status stays PENDING, so the backstop recovers a crashed run and Q6 NOT_FOUND is unchanged. Cost: a composing export job does 2 writes instead of 1. |
| L-5 | Accounts with no profile or an unverified email have no in-app deletion (`DeleteAccount` returns PROFILE_REQUIRED or fails the verified-identity gate), so the email stays in Firebase Auth. | **Fixed in the client (2f9c9db), not yet verified on a device.** After re-auth, only `ERROR_REASON_PROFILE_REQUIRED` from `DeleteAccount` falls back to `FirebaseAuth.currentUser.delete()` (no server or IAM change); no other error does. New "Delete account" entry points on `CreateProfileScreen` and `VerifyEmailView` (`/onboarding/delete-account`, no `AuthGate`). **Founder-accepted exception (2026-10-08):** these two entry points are not behind the `account_lifecycle` flag, because the flag arrives via `GetMe`, which fails for exactly these callers; the store rule 5.1.1(v) requirement outweighs flag gating here. On-device checks (Google, Apple, password `user.delete()`, sign-out ordering, web popup) remain open. |
| L-6 | The daily backstop uses an unordered `Limit(50)` and can starve stuck jobs beyond the first 50. | **Fixed (acc7aae, 1c3d2c2).** Filtered (`progressAt` / `createdAt` older than 1 h), ordered with a (timestamp, id) cursor, up to 4 pages of 50 per scan; fresh jobs are not read. New composite indexes on `users` and `exports` (must be deployed before the revision). `backstop_page_full` fires only after the 4th full page. Residual: more than 200 permanently failing jobs at once (each already a DLQ alert). |
| L-7 | The runtime SA had project-wide `roles/pubsub.publisher`. | **Fixed.** Binding is now on topic `jobs` only (`runtime_publisher_topics`); applied on dev. |

### Informational
- OIDC endpoints (`/internal/pubsub/jobs`, `/internal/cron/daily-maintenance`) return 401 for no or bad token and 403 for the wrong
  service account; there is no `/api` prefix, trailing-slash or encoding bypass. Verified again live: the unauthenticated job call
  returns 401 on the deployed service.
- Re-auth: `auth_time` is signed, maximum age 5 min, up to 30 s future skew. A Google or Apple re-auth can be a single click on an
  existing IdP session; that proves control of the IdP account, which is acceptable. `RequestAccountExport` has no recency check
  because the session holder can already read the same data.
- Sign in with Apple: revocation through the REST API is implemented for iOS/macOS. Apple users on Android or web should be told to
  revoke in Apple ID settings (the TN3194 manual fallback); on-device checks of native re-auth and revoke are still pending (T20 client part).
- `FEATURE_ACCOUNT_LIFECYCLE` defaults to `on` in the dev Terraform variables; the dev tfvars (gitignored) set `allowlist` with the
  founder uid only. Consider changing the variable default to `allowlist`.
- Checked and acceptable: C1 refusal paths are not attacker-triggerable; the 60 s cache bound keeps the 120 s gate valid; the export
  envelope excludes `status`, `deletionJob` and `blockedBy`; failed or erased exports clean up their objects; the exports bucket is
  private with no CORS.

## Live verification on dev (2026-10-08)

Throwaway user `p8livecheck01` (allowlisted), against the deployed Cloud Run revision, runtime SA `api-runtime`:

| Step | Result |
|---|---|
| `CreateProfile` | 200; audit line `auth_admin_op=get`, `account_job=signup`, `outcome=ok` |
| `DeleteAccount` | 200 with `deletionRequestedAt` |
| Job | `disable_revoke` (`update` permission) `ok`, then `delete` `ok`; Auth user gone about 3 min after the request |
| Same token, `CreateProfile` again | 403 `permission_denied` ("this account cannot be used to sign up"); audit line `get` / `not_found` |
| Logs | all audit lines carry `uid_hash` only; raw uid search returned nothing |

Not tested live: that the runtime SA is refused `create` (the role definition has only `get`, `update`, `delete`).

## Gating

- **Dev leaving the allowlist:** nothing blocks.
- **Before the prod flag leaves `off` or a founder-only allowlist:**
  1. The founder records acceptance of the residual risk (stolen runtime SA token bypasses C1 to C3; no Identity Toolkit audit logs at Stage 0).
  2. L-5 verified on devices (Google, Apple, password, web) before any store submission.
  3. The two backstop composite indexes are deployed and built in each environment before the revision that uses them.
  4. Prod Terraform applied from a reviewed saved plan with the real tfvars, then `production-reviewer` GO.
  5. Privacy policy rights section reworded and legally reviewed.
  6. On-device Apple/Google re-auth and revoke checks.
