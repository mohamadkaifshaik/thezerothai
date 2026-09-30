# Security review: social graph (T20, milestone M4), 2026-09-30

Auditor: security-auditor agent. Read-only static review of `main@5f8363a` (graph backend PR #21 and app PR #22 merged).
Rubric: the `security-checklist` skill, ADR-0006, ADR-0008 (D2, D6–D12), graph plan T3–T11 and T20. `go vet` is clean on
`internal/graph`, `internal/identity`, `cmd/opsctl` and `pkg/platform`. No emulator runs (other agents were using them),
so every claim below comes from code reading. Findings that depend on Firestore server behaviour say "verify on
emulator".

In scope: `backend/internal/graph/*`, the graph-facing parts of `backend/internal/identity/*` (GetProfile,
CheckHandleAvailability, Directory, Counters), `internal/apiserver`, `pkg/platform/{authn,ratelimit,quota,cursor,flags,
limits,mw,logger,cache}`, `proto/dzeroth/graph/v1/graph.proto`, `cmd/opsctl`, `firebase/firestore.rules` and
`firestore.indexes.json`, `docs/runbooks/account-deletion.md`, and `app/lib/features/{graph,profile}`, `app/lib/core/storage`.

**Summary: 0 Critical, 0 High, 4 Medium, 9 Low, 9 Info.** There is no authz bypass and no IDOR. The uid always comes from
the verified token, and no RPC can change another user's edges beyond Block's defined side effects. `blockedBy` is
never serialized, never exported, and never logged as an array. Quotas live in Firestore and run in transactions, so
extra Cloud Run instances don't multiply them. The Mediums are:

- page tokens leak the uid of hidden rows (M1);
- replayed mutations amplify reads without any daily bound (M2);
- GetProfile serves suspended and deleting profiles, which removes the ambiguity that the handle-availability residual
  depended on (M3);
- the deletion runbook on `main` bypasses the purge cascade (M4).

---

## 1. Threat model (STRIDE)

Assets:
- A1: the follow graph (`follows/*`, `graph.following`) and its counters.
- A2: block and mute state, especially **who blocked whom** (`blockedBy`, third-party data, ADR-0008 D2/D12).
- A3: the Firestore free quota (reads are the binding limit, cost-model §3). Abuse here is a **cost attack**.
- A4: the integrity of the deletion and export paths (DPDP Act / GDPR).
- A5: operator tooling (`opsctl` with the founder's ADC).

Actors:
- an authenticated user (verified email, App Check monitor-only per the v0.1.0 M6 acceptance);
- a blocked user trying to learn about, or reach, the blocker;
- a scraper or sybil farm;
- an operator mistake.

| STRIDE | Threat | Control on `main` | Residual / finding |
|---|---|---|---|
| **S**poofing | Act as another uid on graph RPCs | `authn.IDTokenInterceptor` → `callerUID` (`graph/server.go:32-39`); every service method takes `callerUID` from ctx only | None |
| | A forged `/internal/*` call triggers a purge | Purge is not exposed over HTTP; `opsctl` only (ADC) | L6 (opsctl hardening) |
| **T**ampering | Change another user's edges (IDOR) | Edge id = `{caller}_{target}`. Unfollow's `Exists` precondition. Unblock/Unmute act only if the caller's own array holds the target (`repo_firestore.go:297-324, 466-498, 552-581`) | None. See §3 |
| | Forge or replay page tokens | HMAC-SHA256, `hmac.Equal`, list-binding prefix/suffix check (`follows_list.go:101-117`) | M1 (tokens are signed, not confidential), I9 |
| | Counter drift through races | Follow txn reads the caller graph fresh; Block txn reads both graphs; `Exists` preconditions; purge `Exists` + same-batch decrement | L5 (dangling `blocked[]` entry after a purge race) |
| **R**epudiation | Can't reconstruct abuse | One request log line with `uid_hash`, `rpc`, `code`, `fs_*`, `limit_name` | L8 (`reason` and ADR-0008 graph fields missing) |
| **I**nformation disclosure | Learn that B blocked A | NOT_FOUND on GetProfile, Follow, List*; GetRelationships from the caller's own snapshot; own lists hide `blockedBy` | M1, M3, §4 residual (accepted with conditions), I5, I7 |
| | `blockedBy` leaves the server | No proto field; `relationshipFor` ignores it; `Export` struct has no field for it; index-exempt | None (verified, §3) |
| | Raw uids / block pairs in logs | `logger.HashUID` on explicit log lines | L4 (error wraps carry raw uids into ERROR logs) |
| **D**enial of service / cost | Read amplification, scraping, churn | Per-uid token buckets per instance, a shared daily list cap, Firestore quotas, max-instances 3, `FEATURE_GRAPH=off` kill switch, budget alerts | M2, L1, L3, L7 |
| | A victim is prevented from blocking | — | L5, L9 |
| **E**levation of privilege | Flag bypass; operator tool misuse | Flag checked before any Firestore access (`rpcs.go:13-18`); opsctl requires `--project` and a typed prod confirmation | L6 |

---

## 2. Findings

Severity follows the skill: Critical/High = release blocker. Each item gives evidence, the exploit (including the cost
angle), the fix, and new tests tagged **→ T16a** (mutations/quotas/races) or **→ T16b** (visibility/lists/cursors/purge).

### M1 — Medium: page tokens reveal the uid (and follow time) of rows hidden by the block filter
- **Evidence.** `pkg/platform/cursor/cursor.go:29-33`: a token is `base64(createdAtMicros|docId|HMAC)`. That's signed but
  plaintext. `graph/follows_list.go:81-95` filters rows (`snap.isBlockedBy`, `snap.isBlocked`, inactive), but
  `NextPageToken` encodes the **last scanned edge** `follows/{followerId}_{followeeId}`, whether or not that row was
  shown. `lists.go:109-111` does the same for own arrays (`arr[lastIdx]`).
- **Exploit.** C blocked A. C follows B. A calls `ListFollowers(B, page_size=1)` and walks the list. A page that comes
  back empty but carries a token is exactly a hidden row. A base64-decodes the token and reads `C_B|<micros>`, which gives
  C's uid and the moment C followed B. That defeats ADR-0008 D9 "C's row hidden" for any list A can page through. With
  `GetRelationships([C])` (blocking=false) plus `GetProfile(C)` = NOT_FOUND, A can tell "C blocked me" apart from "I
  blocked C". Cost to the attacker: about 3 reads per edge, within the list cap.
- **Fix.** Make cursors confidential and bound to context. Add `cursor.Seal`/`Open` using AES-256-GCM (Go stdlib, $0).
  Derive the key with HKDF-SHA256 from `CURSOR_HMAC_KEY` and a `"cursor-v2"` label, so no new secret version is needed.
  Put `(caller uid, procedure, target uid)` in the AAD and an issued-at in the payload (I9), and reject tokens older than
  24 h. Accept v1 tokens only for one release, or reject them as VALIDATION (clients restart the list). Every list RPC
  gains this for free, including future timelines.
- **Tests.**
  - → T16b: `ListFollowers` with page_size 1 over a list containing a row hidden by blocked-by. Assert that no
    `next_page_token` (raw, or base64-decoded) contains the hidden uid.
  - → T16b: a token issued to caller X is rejected (VALIDATION) when caller Y or another target presents it.
  - → T16b: a token older than the TTL is rejected.

### M2 — Medium: replayed and no-op mutations cost Firestore reads with no daily bound (cost amplification)
- **Evidence.** Replays reserve no quota, by design (ADR-0008 D7). They still read inside the transaction:
  - Follow replay costs 2 reads (`repo_firestore.go:234, 254, 263-267`, where `quota.Get` runs before the replay return);
  - Block replay costs 3 (`:362-385`);
  - Mute replay costs 2 (`:509-522`);
  - Unblock or Unmute no-op costs 1 each (`:471-478, 557-564`).

  The only bound is the per-minute, per-instance buckets (`apiserver.go:148-149, 173-178`: Follow/Unfollow 30/min;
  Block, Unblock, Mute and Unmute share 20/min). `DailyCaps` covers list RPCs only (`apiserver.go:184-189`).
- **Exploit.** One verified account loops `Follow(X)` (already following) and `Block(Y)` (already blocked):
  - Follow: 30/min × 1,440 × 2 reads = 86.4k reads/day.
  - Block: 20/min × 1,440 × 3 reads = 86.4k reads/day.
  - Total: **172.8k reads/day from one account on one instance**, which is 3.5× the whole 50k free read quota. With 3
    instances it is up to about 518k/day.
  - At $0.06/100k (cost-model §7) that's about $0.07–$0.31 per day per account, or $2–$9 a month. Five sybils exceed the
    $5 budget in days.
  - ADR-0008's abuse table put the worst per-account bound at 30.6k reads/day (list scraping). This is 5–17× that. The
    per-IP bucket (120/min) does not stop it: a single account needs only 50 calls/min.
  - The v0.1.0 baseline has a similar shape (GetProfile with random ids: about 1 read per call at 60/min). That's
    tracked here as context, not as a new graph finding.
- **Exposure.** It is zero while prod `FEATURE_GRAPH` is `off` or `allowlist`: `checkFlag` runs before any read, so only
  allowlisted testers can reach these paths. It opens at the T25 `percent` stage.
- **Fix.** Reuse the existing `ratelimit.DailyCap`; don't add a second limiter. Add one shared `graph_mutation_daily`
  cap (for example `GRAPH_MUTATIONS_PER_DAY=500` per uid per instance) across Follow, Unfollow, Block, Unblock, Mute and
  Unmute in `apiserver.go`'s `DailyCaps` map. Bound after the fix: ≤ 500 × 3 reads × 3 instances ≈ 4.5k reads/day
  per account. Legitimate use (200 follows plus 200 blocks/mutes a day, plus the undos) fits.
- **Tests.**
  - → T16a (unit, fake clock): the 501st graph mutation of the IST day on one instance returns `RATE_LIMITED` with
    `limit_name=graph_mutation_daily`.
  - → T16a (emulator): Follow replay × N and Block replay × N leave `quotas/{uid}` unchanged and are capped by the daily
    limit.

### M3 — Medium: GetProfile returns SUSPENDED and DELETING profiles, contradicting ADR-0008 D9
- **Evidence.** `identity/service.go:175-188` returns `getProfileCached` for any status; only the block check can turn
  it into NOT_FOUND. By contrast:
  - `Directory.GetProfiles` drops non-ACTIVE users (`service.go:290, 311`), so Follow and ListFollowers/Following
    return NOT_FOUND for them;
  - the graph proto says "not active ⇒ NOT_FOUND" (`graph.proto:28, 86`);
  - ADR-0008 D9 accepted the handle-availability residual *because* "it does not distinguish blocked-by from suspended
    or deleting accounts (also NOT_FOUND)".
- **Exploit.**
  1. **Block oracle.** Today "handle taken" + GetProfile NOT_FOUND means **blocked-by, deterministically**. Deleted
     accounts free their handle (runbook step 3b), and suspended or deleting accounts are *served*, so no other state
     produces that pair.
  2. **Moderation gap.** A suspended account's bio, display name and avatar stay publicly viewable by id or handle.
  3. **Privacy.** A user who asked for deletion stays visible for the whole DELETING window, which is at least 120 s
     under D10 and longer in a manual runbook.
- **Fix.** In `GetProfile`, when `profile.Status != ACTIVE && callerUID != uid`, return the same `notFoundErr()`
  (0 extra reads). That restores the ambiguity D9 relies on, and matches Follow and the lists.
- **Tests.**
  - → T16b: GetProfile of a SUSPENDED and of a DELETING target, by id and by handle, is byte-identical to the
    missing-user error (compare the serialized Connect error).
  - → T16b: GetProfile of one's own non-ACTIVE profile is unaffected. The account-status interceptor already rejects
    such a caller, so assert PERMISSION_DENIED `ACCOUNT_RESTRICTED`.

### M4 — Medium: the manual deletion runbook on `main` bypasses the graph purge; export omits graph data
- **Evidence.** `docs/runbooks/account-deletion.md:33-39` deletes `users/$UID_`, then `handles/…`, then `graph/$UID_`
  directly. It has no DELETING status, no 120 s gate and no `opsctl purge-graph`, and it runs in the reverse of the
  ADR-0008 D10 order ("purge graph **before** deleting `users/{uid}`"). Step 3a (export, `:27-30`) doesn't include
  `opsctl export-graph`. T22 owns the fix, but this is the runbook in force today.
- **Exploit / impact.** Once v0.2.0 is in prod, even at `allowlist`, allowlisted users can follow *any* user, because
  every profile has a graph doc from `InitGraph`. A deletion request handled with this runbook then leaves:
  - every `follows/{uid}_*` and `follows/*_{uid}` document (uid plus timestamp), indefinitely. That's an incomplete
    erasure under DPDP/GDPR;
  - permanently inflated `followersCount`/`followingCount` on counterparts;
  - the uid in other users' `following`, `blocked` and `blockedBy` arrays.

  A data-access request returns no graph data, even though ADR-0008 D12 defines one.
- **Fix (T22, before the v0.2.0 prod deploy).**
  1. Set `status=DELETING` **and `updatedAt=now`** (see L6b).
  2. Wait 120 s.
  3. Run `opsctl purge-graph --project $P --uid $UID_`.
  4. Delete `users`, `handles` and the Auth user.

  For export, add `opsctl export-graph --out` to 3a. Add a dev dry run of the whole runbook to T22's acceptance
  criteria.
- **Tests.** No code test. T22 AC: a dev rehearsal with a seeded user (3 following, 2 followers, 1 blocked,
  1 blockedBy) ends with the T16a invariant checker passing and no `follows` doc referencing the uid.

### L1 — Low: the "daily" in-memory caps reset 24 h after first use, so the list cap is about 2× leaky
- **Evidence.** `cache.LRU` sets the TTL on `Set` only (`pkg/platform/cache/lru.go:65-71`); `Get` never extends it.
  `DailyCap.Allow` calls `Set` once, when it creates the counter (`ratelimit/daily_cap.go:49-54`), with
  `idleTTL = 24h` (`apiserver.go:151`). The token-bucket `Limiter` has the same shape with a 10-minute TTL
  (`ratelimit.go:52-53`).
- **Exploit.** First list call at 12:00 IST on day 1. The counter resets at IST midnight (correct). Then at 12:00 on
  day 2 the *entry expires* and a fresh counter grants another 100 calls. The list cap becomes up to 200 per instance
  per day, so up to 600 × 102 ≈ 61k reads/day per account (122% of free reads), double ADR-0008's accepted 30.6k. Token
  buckets refill in full every 10 minutes, about +10% on the per-minute limits.
- **Fix.** Make the day boundary the only reset. Either re-`Set` the counter on every `Allow`, which refreshes the
  expiry, or give the entry a TTL that ends at the next IST midnight. For buckets, re-`Set` on use.
- **Tests.** → T16b (unit, fake clock): first call at 12:00 IST; 100 calls on day 2 before 12:00; the 101st at 12:05 on
  day 2 is still rejected.

### L2 — Low: Mute accepts nonexistent targets of up to 128 chars; the lazy clean-up of missing mutes is not implemented
- **Evidence.** `repo_firestore.go:500-548`: Mute never checks the target, and the validator allows 1–128 chars
  (`identity/validate.go:19`). ADR-0008 D2's document-size budget assumes 28-char uids. ADR-0008 D10 promises that
  hydration will `ArrayRemove` missing muted entries, but `lists.go:94-100` only skips them.
- **Exploit.**
  - An account can store 2,000 × 128-byte junk strings in `muted` (about 258 KB instead of 58 KB). That eats the 1 MiB
    headroom (worst total ≈ 766 KB) and grows the per-instance graph cache footprint (D8).
  - Uids of purged users stay in third parties' `muted[]` forever. That's pseudonymous residue after erasure.
- **Fix.** Either check existence in Mute through `Directory.GetProfiles` (cache-first, 0–1 read; return NOT_FOUND,
  which is not a leak because Mute is allowed on blockers and they still exist), or tighten graph target ids to the
  Firebase shape (see L3). Also implement the D10 lazy `ArrayRemove` (+1 write, rare) or amend the ADR.
- **Tests.**
  - → T16a: Mute of a nonexistent uid is rejected (whichever option is chosen).
  - → T16b: ListMutedUsers over a purged uid removes it from `muted[]` (if the lazy clean-up is implemented).

### L3 — Low: reserved Firestore ids (`__x__`) pass validation → 500s and ERROR logs on demand (verify on emulator)
- **Evidence.** `identity/validate.go:19` `^[A-Za-z0-9_-]{1,128}$` accepts `__x__`, which Firestore rejects as a
  reserved document id (INVALID_ARGUMENT). This path ends in `mw.ErrorMapping` → `reportError` → ERROR with a stack
  (`mw.go:67-73`):
  - `Block(__x__)` via `tx.Get(graph/__x__)`;
  - `Unfollow(__x__)` via its counter update on `users/__x__`;
  - `ListFollowers(__x__)` via `GetAll`;
  - the same in identity `GetProfile` (pre-existing).
- **Exploit.** An authenticated user produces about 30–60 Internal errors per minute per instance. That pollutes the
  `severity>=ERROR` query (the R-N1 substitute for Error Reporting) and pushes the Cloud Run 5xx ratio past the rollout
  rollback trigger (5xx > 2%) and the 5%-for-10-min alert. At Stage 0 traffic, one user can **force a canary rollback**
  during T25. It also adds about 3–4 KB of log per call.
- **Fix.** Reject `^__.*__$` in `ValidUserID`, or tighten to `^[A-Za-z0-9]{1,128}$`. Firebase-issued uids contain no
  `_`, which also removes the separator ambiguity in I2. Keep ≤ 128 as the ADR requires.
- **Tests.** → T16a: Follow, Unfollow, Block, Unblock, Mute, ListFollowers and GetProfile with `__x__` each return
  INVALID_ARGUMENT `VALIDATION` and log 0 ERROR lines.

### L4 — Low: raw uids and "A blocked B" pairs reach ERROR logs through error wrapping
- **Evidence.** `rpcs.go:40, 75, 96, 134, 166, 197, 222` wrap errors as `"graph: block %s -> %s"` with raw uids;
  `reportError` logs the full cause chain (`mw.go:52-73`). The Firestore error text also contains `graph/<uid>` paths.
  The observability skill allows only `uid_hash`. ADR-0008 says "never log the contents of graph arrays"; a failed
  Block logs the equivalent of one `blockedBy` entry.
- **Exploit.** Anyone with log read access sees block relationships. That includes the `tf-plan` SA's `roles/viewer`
  (v0.1.0 M4, accepted) and the 30-day retention.
- **Fix.** Wrap with `logger.HashUID(...)`. Do the same in identity's wraps, where the pattern already exists.
- **Tests.** → T16a (unit): with a failing fake repo, the error string returned by Block/Unblock/Follow/Unfollow doesn't
  contain either raw uid.

### L5 — Low: blocks racing a purge can leave an entry that Unblock can never remove; Block doesn't check ACTIVE
- **Evidence.**
  - Block's existence check is only "the target graph doc exists" (`repo_firestore.go:366-372`), so it succeeds on a
    DELETING target.
  - Unblock does `Update(graph/{target})` unconditionally (`:484-486`). When that doc is gone the transaction fails
    NOT_FOUND → Internal.
  - The purge re-checks only edges before deleting `graph/{uid}` (`purge.go:299-315`).
  - A blocker who was not recorded because of D2 overflow is never reached by purge step 4.
  - During purge step 1, `graph/{uid}.following` still lists followees whose edge docs are already deleted, so a
    Block by one of them fails the `Exists` delete (`:420-425`) → Internal.
- **Impact.** The caller is left with a `blocked[]` entry that the UI can't show (hydration drops it) and Unblock can't
  clear. There's a 500 on every attempt (see L3/L4), plus occasional failed Blocks against accounts being deleted. It's
  rare at Stage 0.
- **Fix.**
  - Block: reject non-ACTIVE targets through `Directory` (cache-first, 0–1 read; NOT_FOUND, consistent with M3).
  - Unblock: read the target graph in the transaction (+1 read). If it is missing, remove it from the caller only.
  - Optionally have purge step 5 remove stale `blocked[]` entries it can find.
- **Tests.**
  - → T16a (race): Block(X→U) concurrent with PurgeUser(U) ends with the invariant checker passing and U ∉ X.blocked,
    or Unblock(X→U) succeeding.
  - → T16b: Unblock of a purged target returns NONE with 0 errors.

### L6 — Low: `opsctl` safety gaps (meets T11's AC; hardening)
- **Evidence (`cmd/opsctl/main.go`).**
  - `--project` is required (`:103-106`) and a typed prod confirmation is required (`:115-118, 143-147`). Both OK.
  - **(a)** `--skip-start-gate` (`:91, 162`) bypasses the D10 gate with no extra confirmation.
  - **(b)** The gate measures `now - users.updatedAt` (`:206`), but the runbook sets DELETING by hand. If `updatedAt`
    isn't bumped, the gate passes instantly.
  - **(c)** Prod is detected by the `-prod` suffix only (`:140-141`).
  - **(d)** Nothing prints which backend or principal is in use. `FIRESTORE_EMULATOR_HOST` silently redirects, and
    "founder's ADC only" is enforced by IAM, not code. A `GOOGLE_APPLICATION_CREDENTIALS` SA key file would work too.
  - **(e)** The dry run prints `blocked_by=<n>` (`:157-158`). That's operator-only, but it's third-party data if the
    output is pasted into a record.
- **Fix.**
  - Print `target: <project> via <emulator host | ADC principal>` before confirming.
  - Require typing `SKIP-GATE` for `--skip-start-gate` on prod.
  - Make the runbook set `updatedAt`, or add a `deletingAt` field that the gate reads.
  - Refuse to run when `GOOGLE_APPLICATION_CREDENTIALS` points at a service-account key ("no SA keys anywhere").
  - Leave `blocked_by` out of the dry-run output (print "blockers: n (not exported)", or omit it).
- **Tests.** → T16b (opsctl unit): skip-gate on `*-prod` without the second confirmation exits 1; the banner shows the
  emulator host when `FIRESTORE_EMULATOR_HOST` is set; the start gate fails when `updatedAt` predates DELETING (if
  `deletingAt` is adopted).

### L7 — Low: the scraping lever from ADR-0008 D7 ("page_size 20 on other users' lists, config") isn't implemented
- **Evidence.** `limits.ClampPageSize` (max 50) is the only clamp (`follows_list.go:59`); `config.go` has no knob.
- **Impact.** Turning the lever during an incident needs a code change and a deploy, instead of the drilled env-update
  procedure.
- **Fix.** Add `GRAPH_OTHER_LIST_MAX_PAGE_SIZE` (default 50), applied when `targetUID != callerUID`.
- **Tests.** → T16b: with the env at 20, `ListFollowers(other, 50)` returns ≤ 20 rows and reads ≤ 42 cold.

### L8 — Low: observability. QUOTA_EXCEEDED can only be queried heuristically; ADR-0008's graph log fields are absent
- **Evidence.** The request line (`mw.go:152-170`) has `rpc, code, fs_*, limit_name` but no ErrorReason, so
  `QUOTA_EXCEEDED` and per-minute `RATE_LIMITED` both appear as `code="resource_exhausted"`. There is no emitter for
  the ADR-0008 "Required log fields": `graph_op`, `outcome`, `feature_disabled`, `txn_attempts`, `edges_removed`,
  `rows_filtered`, `confirmed_missing` and `graph_cache_hit` (grep finds 0 emitters).
- **Impact.** T25 rollout monitoring (`feature_disabled`) and M2 detection (`outcome=replay`) rely on proxies. See §6
  for the queries that work today.
- **Fix.** Add `reason` (from the `ErrorDetail` of the shaped `connect.Error`) to the request line. Add `GraphOp` and
  `Outcome` to `logger.RequestInfo` (the same mutable-pointer pattern as `LimitName`) and set them in `graph/rpcs.go`.
- **Tests.** → T16a (unit, `mw`): a handler returning `QUOTA_EXCEEDED` produces a request line with
  `reason="ERROR_REASON_QUOTA_EXCEEDED"`; a Follow replay logs `outcome="replay"`.

### L9 — Low: the safety controls (Block/Unblock/Mute/Unmute) are behind the same flag as Follow
- **Evidence.** `checkFlag` guards every GraphService RPC (`rpcs.go:13-18`), and the app hides block UI when the flag
  is off.
- **Impact.** During `percent` rollout, a flag-on user can follow a flag-off user who has no way to block them. With
  the kill switch off, nobody can unblock or unmute. At Stage 0 a follow only moves a counter (no notifications or DMs
  yet), so the harm is small. It grows with notifications.
- **Fix.** Before notifications ship, either un-gate Block/Unblock/Mute/Unmute/ListBlocked/ListMuted (server and
  client) once past `allowlist`, or have Follow require the flag on for *both* parties (0 reads: the flag is in-memory).
- **Tests.** → T16a: with `percent`, Follow(on → off) behaves as the chosen rule.

### Info
- **I1.** Own-list tokens expose `arr[lastIdx]`. That's the caller's own data; the M1 fix covers it.
- **I2.** Doc ids `{a}_{b}` and the list-binding `HasPrefix`/`HasSuffix` check (`follows_list.go:109-112`) are
  unambiguous only because Firebase uids contain no `_`. The L3 regex fix makes that explicit. No exploit exists with
  provider-issued uids.
- **I3. D8 staleness (60 s): accept.** Follow reads the caller graph fresh in its transaction (`repo_firestore.go:234`),
  so a blocked user can never create an edge. Only profile and row *visibility* may lag, by ≤ 60 s, on another
  instance.
- **I4. D2 overflow residual: accept.** It is unreachable below 10,000 blockers of one account. The fail-closed paths
  are tested (`TestFollow_Integration_BlockedByOverflowFallback`, `TestIsBlockedBy_OverflowFallback`), and the
  `blockedby_cap_reached` ERROR can be queried (§6). Mass-blocking a victim into overflow needs 10k verified accounts.
- **I5.** `opsctl export-graph` lists the subject's own `blocked` entries with handles, including users who blocked the
  subject back, while the app hides those (D9 own-list rule). A subject who compares the two learns what GetProfile
  NOT_FOUND already tells them, and the data is the subject's own. D12 is met.
- **I6.** Under a mutual block, A can't find B in the UI to unblock (GetProfile NOT_FOUND, own list hidden). A can only
  unblock by id through the API. That's a UX gap to note in T15 or the ADR, not a security gap.
- **I7.** Follow's two NOT_FOUND paths take different amounts of time. Missing or inactive returns from the Directory
  cache; blocked-by returns after a transaction. Timing can separate "blocked-by" from "suspended" even after M3. This
  is part of the accepted residual (§4).
- **I8. Client.** On NOT_FOUND the drift profile row isn't evicted, so the blocker's last-seen snapshot stays on the
  blocked user's device until sign-out. Otherwise the client is clean:
  - it never receives or stores `blockedBy`;
  - it never decodes page tokens;
  - it wipes drift and the relationship cache on sign-out (`bootstrap.dart:95-101`);
  - it uses the same NOT_FOUND wording for missing and blocked (`app_error_view.dart:52-57`).

  Suggest `deleteProfile(uid)` on NOT_FOUND.
- **I9.** Page tokens never expire. The M1 fix adds issued-at and a TTL.

---

## 3. Ticket checklist results

**Authz.** Every handler takes the uid from `authn.UIDFromContext` (`graph/server.go:32-39`). Service and repo methods
act on `callerUID` plus a validated `targetUID`. Writes to *another* user's documents are exactly these:

| RPC | Writes to the target's documents |
|---|---|
| Follow | `users/{target}.followersCount +1` |
| Unfollow | `followersCount −1`, only if `follows/{caller}_{target}` existed (`Exists`) |
| Block | `graph/{target}`: `blockedBy += caller` (or `blockedByOverflow`), `following −= caller`; deletes `follows/{target}_{caller}`; decrements the target's counters |
| Unblock | `graph/{target}.blockedBy −= caller`, only if `caller.blocked ∋ target` |

All of these are ADR-0008 side effects. Mute, Unmute and GetRelationships touch only the caller's data. **Pass.**

**IDOR on Unfollow/Unblock/Unmute with arbitrary ids.** The edge id is derived as `{caller}_{target}`, so a caller can
only name their own edges. The `Exists` precondition makes a never-followed target a 0-write no-op. Unblock and Unmute
branch on the caller's own fresh array. There is no id collision with provider uids (I2). The only side effect of an
arbitrary id is L3 (reserved ids → 500). **Pass.**

**`blockedBy` never serialized, logged or exported.**
- `Relationship` has 4 fields (`graph.proto:124-129`).
- `relationshipFor` reads only following, blocked and muted (`api.go:60-70`).
- The own lists filter `blockedBy` out before hydration (`lists.go:75-83`).
- The `Export` struct has no field for it (`export.go:22-28`), and `TestExport_NeverContainsBlockedBy` exists.
- The Firestore index is exempt (`firestore.indexes.json:78`).
- The only explicit log is `target_uid_hash` on `blockedby_cap_reached` (`rpcs.go:143`).
- Residue: L4 (error wraps) and L6e (the dry-run count). **Pass with Lows.**

**Block-existence leaks.** GetProfile, Follow and List* NOT_FOUND responses are identical *within each RPC*. Identity
says "profile not found" and graph says "user not found": consistent per RPC and not an oracle, but the T16b "same
error as GetProfile" assertion should compare within the RPC. GetRelationships is a stranger view. The own lists hide
blockers. Leaks found: M1 (tokens) and M3 (the ambiguity premise is broken). The handle residual is decided in §4.

**Scraping via lists (abuse bounds).**
- Per account: 20/min per instance, and 100/day per instance shared across the 4 list RPCs (`apiserver.go:151,
  184-189`).
- Documented bound: 300 calls × 102 reads = 30.6k reads/day (61%). Actual: **up to about 61k** because of L1.
- Firestore rules are deny-all (`firebase/firestore.rules`), so the API is the only path. With App Check in monitor
  mode, sybils scale linearly, bounded by email verification and Firebase's roughly 100 sign-ups/hour/IP.
- The lever is missing (L7). The kill switch `FEATURE_GRAPH=off` rejects before any read.
- Verdict: acceptable at Stage 0 once L1 is fixed.

**Follow-spam and churn; quota bypass across 3 instances.**
- Firestore quotas (`quotas/{uid}`, read and reserved in the same transaction, `quota.go:110-144`) are global, so
  **extra instances don't multiply them**. Follows are 200/day (50 new); Block+Mute are 200/day (50 new).
- Churn: re-following one target spends quota on each create, so ≤ 200 follow events/day per account.
  Unfollow/Unblock/Unmute undo only existing state. The write churn matches ADR-0008 (about 1.6k + 1.4k writes/day).
- What *is* multiplied (×3) are the in-memory buckets and the list cap (documented), and **replays have no daily bound
  at all** (M2).
- Note for the notifications plan: the D11 deterministic notification id is what keeps 200 re-follows/day from becoming
  200 notifications.

**Cursor tampering.**
- HMAC-SHA256 with a constant-time compare (`cursor.go:36-66`).
- A followers token can't be replayed against following, or against another user's list (`follows_list.go:101-117`).
- Own-array positions are clamped (`lists.go:118-142`); tests exist (`TestPageNewestFirst_ClampsOutOfRangePosition`).
- Integrity passes. Confidentiality and caller-binding fail (M1).

**`opsctl` safety.** It requires an explicit `--project`, has no default, and has a typed prod confirmation. It checks
the uid format and applies the start gate by default. It writes with `O_EXCL` and 0600, and it's never deployed. It
meets T11. Hardening is in L6.

**Export privacy (D12).** It holds following, followers, blocked and muted with handles, and **no `blockedBy`**. Pass
(I5 noted).

---

## 4. Decision: the `CheckHandleAvailability` "taken" vs GetProfile NOT_FOUND residual

**Recommendation: ACCEPT, on the condition that M3 is fixed.** Record it as an ADR-0008 D9 amendment and in v0.2.0
readiness §4.

Reasons:
1. **Every mitigation moves the oracle instead of removing it.** If CheckHandleAvailability answered "available" for a
   blocker's handle, CreateProfile or ChangeHandle would then fail `HANDLE_TAKEN`. That's the same bit one step later,
   and it breaks sign-up UX for honest users. Rate-limiting it further doesn't help, because one call suffices.
2. **The bit is available elsewhere anyway:**
   - a second free account sees B's profile;
   - Block(B) succeeds on an existing account (a graph doc exists);
   - Follow's NOT_FOUND timing differs (I7);
   - later, logged-out web views will show it too.

   Hiding "B blocked me" completely is not achievable at Stage 0 cost. X tells blocked users outright. Blocking's
   security goal here is to **stop interaction** (Follow is fail-closed in its transaction, rows are hidden, and later
   timeline and notification filters apply), and that holds.
3. **With M3 fixed, the server's answers are consistent.** "Taken + NOT_FOUND" then covers blocked-by, suspended and
   deleting alike, which is the premise the ADR states. Without M3 the ADR text is false and the oracle is
   deterministic.
4. **Condition:** product copy must never promise that a block is secret. Revisit if the private-accounts or DM plans
   raise the stakes (for example, if hiding the block becomes a safety feature for harassment victims).

---

## 5. Verified OK
- Interceptor order: logging → recover → App Check → ID token → rate limit (IP, then per-uid, then daily cap) →
  degraded → account status → errorMapping (`apiserver.go:164-196`). Graph RPCs inherit it all, with a 256 KiB
  `WithReadMaxBytes` (`:210`).
- The flag guard runs before any Firestore access. The `ListFollowRequests` and `RespondToFollowRequest` stubs cost
  0 reads (`server.go:226-240`). Prod defaults to `off` when `FEATURE_GRAPH` is unset (`config.go:313-317`). Invalid
  values fail startup (`flags.go:105-127`).
- Degraded `readonly` blocks every graph mutation, because none of them is `NO_SIDE_EFFECTS` (`graph.proto`,
  `degraded.go:43`).
- Follow and Block serialize on the caller's graph doc. Unfollow and Block edge deletes use `Exists`. The purge has
  crash-resume and concurrent-run tests.
- GetRelationships validates 1–50 ids and never reads targets' documents, so arbitrary ids don't reveal existence.
- L9 (v0.1.0) is closed: `UpdateProfile(is_private=true)` is rejected before any read (`identity/service.go:209-211`).
- Firestore rules are deny-all; `graph.blockedBy` is index-exempt; `blockedByOverflow` is indexed for moderation.
- `go vet` is clean.

---

## 6. Observability: can it be queried in Logs Explorer? (T20 item)

| Signal | Emitted where | Query | Status |
|---|---|---|---|
| `blockedby_cap_reached` | `slog.Default().Error` (`rpcs.go:143`); default = JSON logger (`cmd/api/main.go:37`) | `resource.type="cloud_run_revision" severity=ERROR jsonPayload.message="blockedby_cap_reached"` | **Yes** (has `target_uid_hash`; no stack, so it is not grouped by Error Reporting, which is disabled anyway per R-N1) |
| `graph_list_daily` rejections | `info.LimitName` → request line (`ratelimit/interceptor.go:86-94`, `mw.go:164-166`) | `jsonPayload.limit_name="graph_list_daily"` (group by `jsonPayload.uid_hash`) | **Yes** |
| `QUOTA_EXCEEDED` spikes | request line has only `code` | Heuristic: `jsonPayload.code="resource_exhausted" AND jsonPayload.fs_reads>0 AND NOT jsonPayload.limit_name:*` (quota rejections happen after the in-transaction reads; per-minute limits reject before any read). Filter by `jsonPayload.rpc` | **Partial.** L8 fix adds `reason` |
| Replay amplification (M2) | — | `jsonPayload.rpc=~"GraphService/(Follow\|Block\|Mute)" AND jsonPayload.fs_writes=0 AND jsonPayload.code="ok"`, grouped by `uid_hash` | Proxy only (L8) |
| `feature_disabled` (T25 rollout) | — | `jsonPayload.code="failed_precondition" AND jsonPayload.rpc=~"GraphService"` (this also catches `TARGET_BLOCKED` and `LIMIT_REACHED`) | Proxy only (L8) |

---

## 7. New test cases for T16

**→ T16a** (mutations/quotas/races):
1. M2: the mutation daily cap. The 501st mutation returns `RATE_LIMITED` with `limit_name=graph_mutation_daily`; replays
   leave `quotas/{uid}` unchanged.
2. L2: Mute of a nonexistent uid is rejected (per the chosen option).
3. L3: `__x__` on Follow, Unfollow, Block, Unblock, Mute, ListFollowers and GetProfile gives `VALIDATION` and 0 ERROR
   log lines.
4. L4: error strings from failing Block/Unblock/Follow/Unfollow contain no raw uid.
5. L5: Block racing PurgeUser on the same target passes the invariant checker, and no un-unblockable entry remains.
6. L8: a `QUOTA_EXCEEDED` request line carries `reason`; a Follow replay logs `outcome=replay`.
7. L9: Follow(flag-on → flag-off) follows the chosen rule.

**→ T16b** (visibility/lists/cursors/purge):
1. M1: a page_size=1 walk leaks no hidden uid in any token (raw or decoded).
2. M1: a token from caller X or target T is rejected for caller Y or target T′.
3. M1: an expired token is rejected.
4. M3: GetProfile of SUSPENDED and DELETING targets is byte-identical to missing, by id and by handle.
5. L1: the daily list cap does not reset 24 h after first use within an IST day (fake clock).
6. L2: hydration removes purged uids from `muted[]` (if implemented).
7. L5: Unblock of a purged target returns NONE with no error.
8. L6: opsctl rejects skip-gate on prod without the second confirmation, and the banner shows the emulator or ADC
   target.
9. L7: with `GRAPH_OTHER_LIST_MAX_PAGE_SIZE=20`, ListFollowers(other, 50) returns ≤ 20 rows and reads ≤ 42 cold.
10. Matrix note: assert NOT_FOUND byte-equality within each RPC (identity says "profile not found", graph says "user not
    found").

---

## 8. Summary

| ID | Sev | Title | Proposed disposition for v0.2.0 |
|---|---|---|---|
| M1 | Medium | Page tokens reveal the uid and follow time of hidden (blocked-by) rows | **Fix before v0.2.0** (AEAD cursor, about half a day). Or accept for the allowlist stage only (testers are trusted), and fix before T25 `percent` |
| M2 | Medium | Replays and no-ops amplify reads with no daily bound: 173k–518k reads/day per account | **Accept for v0.2.0 at `allowlist`** (not reachable by non-allowlisted uids). **Must fix before T25 `percent`**, where it would be High |
| M3 | Medium | GetProfile serves SUSPENDED/DELETING profiles; this breaks the D9 residual premise | **Fix before v0.2.0** (one `if`, 0 reads) |
| M4 | Medium | The deletion runbook bypasses the purge; export omits graph data | **Fix before v0.2.0 prod** (T22). No acceptance proposed: allowlisted users can follow anyone, so orphaned edges are reachable |
| L1 | Low | The daily caps reset 24 h after first use (the list cap is about 2× leaky) | Fix with M2 (same file) |
| L2 | Low | Mute accepts nonexistent 128-char ids; the D10 lazy clean-up is missing | Backlog or ADR amendment |
| L3 | Low | Reserved ids (`__x__`) cause 500s and can force a canary rollback | Fix before T25 (a regex change) |
| L4 | Low | Raw uids and block pairs in ERROR logs | Backlog (fix with L3) |
| L5 | Low | Dangling `blocked[]` after a purge race; Block doesn't check ACTIVE | Backlog |
| L6 | Low | opsctl hardening (skip-gate, `updatedAt` gate, banner, SA-key refusal, dry-run count) | Gate/`updatedAt` with T22; the rest in the backlog |
| L7 | Low | The page-size scraping lever isn't implemented | Backlog (before `percent`) |
| L8 | Low | No `reason` or ADR graph log fields; QUOTA_EXCEEDED only heuristic | Before T25 (rollout monitoring) |
| L9 | Low | Block/Mute are gated by the same flag as Follow | Before the notifications plan |
| I1–I9 | Info | See §2 Info | — |

## 9. Verdict against the T20 acceptance criteria

- **0 Critical, 0 High open: MET.**
- **Every Medium fixed or carrying a recorded risk acceptance: NOT YET MET.** All four Mediums are open on `main`. The
  AC is met when each of the following is either merged or signed in `release-v0.2.0-readiness.md` §4:
  - **M1:** fixed, or accepted for the allowlist stage only (expires at T25 `percent`);
  - **M2:** accepted for the allowlist stage only (expires at T25 `percent`; the fix is a precondition of T25);
  - **M3:** fixed. The §4 handle-availability acceptance depends on it;
  - **M4:** fixed through T22 before any v0.2.0 prod deploy.
- **Handle-availability residual (ADR-0008 D9):** accept, on the condition that M3 is fixed (§4). Record it as an
  ADR-0008 amendment.
- **D2 overflow and D8 staleness residuals:** accept (I3, I4).

**Security verdict for v0.2.0 (flag `off` → `allowlist`): CONDITIONAL. It is releasable once M3 and M4 are fixed and
the M1/M2 allowlist-stage acceptances are signed.** The `percent` stage (T25) additionally requires M2, L1 and L3 fixed
and M1 fixed if it was only accepted.
