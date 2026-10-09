# Account deletion + data export (Phase 1 slice P8, store blocker M5)
Plan owner: planner · Date: 2026-10-06 · Target release: **v0.4.0** (store-ready core, `docs/plans/phase1.md` §4) ·
Stage: 0 (0 – ~300 DAU, $0)
Inputs: CLAUDE.md, `docs/plans/phase1.md` (P8 and "Contract drift"), ADR-0003 ("Deletes & privacy", 2026-09-30
amendment), ADR-0008 (D10, D12), ADR-0009, ADR-0010 (D5 A6, D10, D19 Q-E, budget table), `docs/runbooks/account-deletion.md`,
`proto/dzeroth/identity/v1/identity.proto`, `backend/internal/identity/server.go`, `backend/internal/graph/{api,purge,export}.go`,
`backend/internal/posts/{api,purge}.go`, `backend/cmd/opsctl/main.go`, `backend/pkg/platform/{authn,quota,idempotency,pubsubpush,config}`,
`backend/internal/apiserver/apiserver.go`, `infra/terraform/modules/{media-buckets,pubsub,scheduler,iam,firestore}`,
`app/lib/features/{settings,auth}`, `docs/reviews/cost-model.md`, `free-tier-budget` skill.

> **Update 2026-10-07: unblocked.** ADR-0011 is Accepted (see T1's status). The "[blocked: T1 accepted]" tags below
> are historical; the per-ticket "Blocked on the founder accepting T1" lines now mean "Open".
>
> **(Original note) Blocked on a founder decision.** Two architecture choices need an ADR with costs, and the founder must accept it
> before most of this plan can start (CLAUDE.md: "stop and ask the founder before accepting an ADR"):
> - **D-A: job orchestration mechanism** (Pub/Sub push self-chaining, Cloud Tasks, Scheduler sweep, or a hybrid).
> - **D-B: export storage** (prefix-scoped lifecycle in the existing private bucket, or a third private bucket).
>
> The planner does not choose either. T1 writes the ADR with every option and its cost. Every ticket marked
> **[blocked: T1 accepted]** waits for it. Tickets that can start now: **T2a, T4, T13, T14, T15** (Flutter against fakes
> and the existing proto; flag and recent-sign-in check on the server).

> **Questions with proposed defaults (the architect confirms or overrides each one in T1; work doesn't block on them):**
> - **Q1. Erase order.** `phase1.md` P8 lists graph before posts; ADR-0010 (line 1234), the runbook (§3b) and
>   `opsctl` usage (`main.go:98`, "run before purge-graph") say **posts before graph**. **Default: posts → graph**
>   (ADR-0010 is Accepted). Later slices insert their Erasers before the identity step.
> - **Q2. DeleteAccount replay vs the account-status interceptor.** `AccountStatusInterceptor` rejects every
>   non-exempt RPC from a DELETING caller with PERMISSION_DENIED `ACCOUNT_RESTRICTED` (`pkg/platform/authn/interceptor.go:217-219`).
>   A client that retries DeleteAccount after a lost response therefore gets an error, not a replay. **Default:** the
>   interceptor lets a DELETING caller through to DeleteAccount only (not SUSPENDED); the service returns the stored
>   `deletion_requested_at` with 0 writes.
> - **Q3. Can a SUSPENDED user delete their account?** **Default: yes** (right to delete, store rule). The P7
>   report snapshot keeps the evidence (founder decision D4). The interceptor exemption from Q2 then also covers
>   SUSPENDED for DeleteAccount only.
> - **Q4. When is the Firebase Auth user disabled?** The runbook disables it at Step 0. **Default:** the job's first
>   step disables it and revokes refresh tokens. DeleteAccount itself stays a 1-write Firestore call, and the
>   interceptor already rejects the DELETING uid on every other RPC.
> - **Q5. Stale sign-in error.** The proto says "requires a recent sign-in", but `common.proto` has no reason code for
>   it. **Default:** add `ERROR_REASON_REAUTH_REQUIRED = 15` (additive), returned as FAILED_PRECONDITION.
> - **Q6. Export after expiry.** `ExportStatus` has no EXPIRED value. Firestore TTL and GCS lifecycle both delete late.
>   **Default:** GetAccountExport returns NOT_FOUND once `now ≥ expireAt`. This is byte-identical to an unknown id, so
>   no enum change is needed.
> - **Q7. Sign in with Apple token revocation on deletion.** Apple expects account deletion to revoke the Sign in with
>   Apple token. Firebase's `deleteUser` does not do this. **Default:** after an Apple re-auth, the client calls
>   FirebaseAuth `revokeTokenWithAuthorizationCode` before DeleteAccount. OPEN: security-auditor re-checks the current
>   App Store requirement in T20 (it could not be checked from here).
> - **Q8. Degraded mode.** **Default:** DeleteAccount and RequestAccountExport are rejected under
>   `DEGRADED_MODE=readonly`, as today (both are mutating; the user gets the friendly error, and the email path still
>   works). Jobs that already started keep running, because an accepted deletion must finish within the privacy
>   policy's 30 days.
> - **Q9. Flag scope.** **Default:** one flag, `FEATURE_ACCOUNT_LIFECYCLE` (wire name `account_lifecycle`), gates the
>   three RPCs and both Settings entries. The job handlers are **never** gated, so turning the flag off can't strand a
>   DELETING account.
> - **Q10. Residue that a "no document references the uid" sweep cannot clear** (see T11). **Default:** a reviewed
>   allowlist:
>   - `idempotency/*` keeps a `uid` field until its 24 h TTL (`pkg/platform/idempotency/idempotency.go:36`);
>   - other users' `muted[]`/`blocked[]` arrays (cleaned lazily, ADR-0008 T27);
>   - mentions in other users' posts (kept, runbook §3b);
>   - prod backups (14 days).
>
>   Everything else is a defect.

---

## Goal & user value
- **Users can delete their account in the app**, with no email round trip. This is required for App Store and Play
  submission (security audit M5) and for DPDP/GDPR erasure. The deletion is irreversible and immediate (founder
  decision D5).
- **Users can download a copy of their data** (DPDP/GDPR access and portability) as one JSON file.
- **The founder stops running the manual runbook.** The runbook becomes a fallback that drives the same code.

## Scope
- **Contract (architect):**
  - ADR for orchestration, export storage, orchestrator placement and the Q1–Q10 semantics;
  - additive `ERROR_REASON_REAUTH_REQUIRED`;
  - comment and budget updates on the three identity RPCs.
- **Backend:**
  - **DeleteAccount:**
    - checks for a recent sign-in: `authn.Claims.AuthTime` (`pkg/platform/authn/authn.go:23`, filled from
      `auth_time` in `firebase.go:49-50`) must be < 5 min old;
    - sets `users.status = DELETING` in a transaction and enqueues the `account-delete` job (mechanism from the ADR).
  - **A transport-independent orchestrator.** It composes the Erasers in a fixed order, keeps an opaque checkpoint per
    step, enforces the 120 s start gate (ADR-0008 D10) and a time budget per invocation. The order is:
    1. Firebase Auth disable + revoke refresh tokens;
    2. `posts.Eraser`;
    3. `graph.Eraser`;
    4. registered later-slice Erasers (media P4, engagement P5, notifications/devices P6, reports-as-reporter P7);
    5. the identity Eraser (`exports` docs + objects, `users/{uid}/private/*`, `handles/{h}`, `quotas/{uid}`, then
       `users/{uid}`);
    6. finally, deleting the Firebase Auth user.
  - **RequestAccountExport / GetAccountExport:**
    - quota `exports` of 1/day (`quota.Exports`, `QUOTA_EXPORTS_PER_DAY` already exist);
    - doc id `hash(uid, idempotency_key)`;
    - an owner-only read;
    - a fresh 15-minute V4 signed GET URL on every call, never stored.
  - **An export composer.** It writes `account` (the Firebase Auth record), `profile`, `graph` (`graph.ExportUser`)
    and `posts` (`posts.Exporter`), plus registered later sections, into one private JSON object.
  - **A collection-coverage guard test**, so a later slice can't add a user-owned collection without an
    Eraser/Exporter.
  - **`opsctl delete-account` / `export-account`**, which drive the same orchestrator and composer for the manual
    path.
- **Infra:** whichever resources the ADR picks; `roles/firebaseauth.admin` (or a narrower role the ADR names) on the
  runtime SA; env vars.
- **Flutter:**
  - re-authentication in `AuthRepository` (Google, Apple, password);
  - Settings → **Delete account** (explanation, re-auth, typed handle confirmation);
  - Settings → **Download my data** (request, bounded polling, open the link).
- **Tests and ops:**
  - emulator chain tests (crash-resume, residue sweep, two concurrent deliveries);
  - export privacy tests, an e2e smoke and a cost report;
  - the runbook rewritten from manual-first to in-app-first;
  - a dev drill, the v0.4.0 readiness review and the flag rollout.

## Out of scope (explicit non-goals)
- **A grace period or undo** (founder decision D5: immediate). Restoring an account needs its own plan and ADR
  (runbook §3b, ADR-0009).
- **Erasers and exporters for modules that aren't built yet** (media, engagement, notifications, reports). Each slice
  ships its own Eraser + Exporter (rule in `phase1.md` P8). This plan provides the registry, the order constraint and
  the guard test that forces them in.
- **Scrubbing mentions of the deleted user from other people's posts.** Deferred to the P6 follow-up ADR (runbook §3b).
- **Admin-initiated deletion from a console.** No console at Stage 0; `opsctl delete-account` covers it.
- **Export formats other than one JSON file** (no ZIP, no media binaries; media URLs are listed once P4 exists).
- **Deleting backups early.** Prod weekly backups age out in 14 days (ADR-0007); the privacy policy says so.
- **Scale-up path (Stage 2+, ADR):**
  - a dedicated worker service for long purges;
  - rate-shaping big deletions across days;
  - sharded or async counter repair;
  - Workflows/Batch orchestration.

## Non-functional targets (Stage 0, ≤ 300 DAU)
| Path | p95 warm | Cold | Notes |
|---|---|---|---|
| DeleteAccount (sync part) | < 500 ms | < 1.5 s | 1 transaction + 1 enqueue |
| RequestAccountExport | < 500 ms | < 1.5 s | |
| GetAccountExport | < 300 ms | < 1.5 s | includes `signBlob` for the URL |
| Deletion completed (reference account, see Cost) | < 15 min after DeleteAccount | — | OPEN until the ADR picks the mechanism; option C in T1 is ≤ 24 h |
| Export READY (reference account) | < 5 min | — | OPEN, same reason |
| One job invocation | < 25 s | — | Cloud Run request timeout and Pub/Sub ack deadline are both 30 s (`pubsub/main.tf:44`); CPU only during requests (`cpu_idle = true`, `cloud-run-api/main.tf:35`), so no work happens after the response |

## Cost (required)
Method: `free-tier-budget` §2. Cold ceilings include the `AccountStatusInterceptor` read, as in ADR-0010 D17.
Prices: `docs/reviews/cost-model.md` §7 (upper bounds). This plan replaces cost-model rows 35–36 once T21 lands.
Notation for a user being deleted or exported:
- P = their posts;
- O = following (≤ 5,000);
- I = followers (no cap);
- B = blocked (≤ 2,000);
- Bb = blockedBy (≤ 10,000);
- M = muted (≤ 2,000);
- E = their export docs.

**Reference account** (from the phase1 P8 example, without the 1k likes because engagement does not exist yet):
P = 300, O = 100, I = 100, B = Bb = M = 0, E = 1.

### Per-RPC and per-job budget
| RPC / job | reads cold / warm / planning | writes | deletes | calls/DAU/day | reads/DAU | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|---|---|
| DeleteAccount (sync) | 2 / 1 / 2 (interceptor + fresh `users` read in the txn; ADR-0010 table row "DeleteAccount / …": 2 each) | 1 (`users`: status, `deletionRequestedAt`, `deletionJob`; no separate job doc, ADR-0011) | 0 | 0.001 (cost-model row 35) | 0.002 | 0.001–0.002 | 0 |
| ↳ replay (already DELETING, Q2) | 2 / 1 | 0 | 0 | — | — | — | — |
| `account-delete` job, general formula (normal path) | P + O + I + 2·⌈(max(B,Bb)+1)/500⌉ + 2 (finish queries) + ≤ 3 (empty last pages) + 1 (start gate) + 3 (identity: 2 + max(E, 1)) + E + job-state read (1 per delivery, +1 per save conflict retry, ≤ 3) | O + 2I + B + Bb + checkpoint writes (≤ 1 per non-final slice) | P + O + I + 1 (graph doc) + 3 (users, handles, quotas) + E (+ `private/*` docs, 0 at Stage 0) | 0.001 | see the reference row | | |
| ↳ worst path (a counterpart was already purged: the precondition fallback) | + up to 2O + 3I + B + Bb (re-query + `GetProfiles` + counterpart `graph` `GetAll`; `graph/purge.go:116-131,199-230,253`) | same | same | — | — | — | — |
| ↳ **reference account** | **≈ 512** (posts 300 + graph 204 + identity 3 + gate 1 + job-state 1 + users_doc 1 + slice overhead) | **≈ 300** + checkpoints | **≈ 505** | 0.001 | **0.51** | **0.30** | **0.51** |
| RequestAccountExport | 2 / 1 / 2 (interceptor + `quotas`; proto 1/1 + interceptor) | 2 (`exports` doc + `quotas`) | 0 (+1 TTL delete after 7 d) | 0.001 (**assumption**: cost-model row 36 says "~0") | 0.002 | 0.002 | 0.001 |
| ↳ replay (same key) | 3 (+1 `exports` read after `AlreadyExists`) | 0 | 0 | — | — | — | — |
| `account-export` job, general formula | 1 (`users`) + 1 (`exports`) + (P or 1) + (O or 1) + (I or 1) + 1 (`graph`) + distinct(O ∪ I ∪ B ∪ M) handle reads (`graph/export.go:30-32`, `posts/purge.go:107-108`) | 2 (lease claim, then `exports.status`; L-4) | 0 | 0.001 | | | |
| ↳ **reference account** | **≈ 703** | **2** | 0 | 0.001 | **0.70** | 0.001 | 0 |
| GetAccountExport | 2 / 1 / 1 (interceptor + `exports`, read fresh) | 0 | 0 | 0.003 (≈ 3 polls per export; capped by `account_ops_daily`) | 0.003 | 0 | 0 |
| **Slice total** | | | | **≈ 0.005 req** + job invocations | **≈ 1.22** | **≈ 0.31** | **≈ 0.51** |

Derivation notes, from the code:
- **Posts purge** (`posts/purge.go:51-75`): 1 read and 1 delete per post, 500 per batch; a short page ends it. If P is a
  multiple of 500, +1 read. 0 writes, because `postsCount` isn't decremented (the `users` doc is deleted afterwards).
- **Graph purge** (`graph/purge.go`):
  - step 1: 1 read, 1 write (followee counter) and 1 delete per outgoing edge, pages of 250;
  - step 2: 1 read, 2 writes (follower `following[]` + counter) and 1 delete per incoming edge, pages of 160;
  - steps 3–4: 1 `graph` read per call and 1 write per array entry, chunks of 500;
  - step 5: 2 queries (1 read each when empty) + 1 delete.
  - This matches the runbook's "100/100 ≈ 200 reads, 300 writes, 200 deletes".
- **Identity step** (new, T7):
  - reads: `users` 1 (for `handleLower`), `handles` 1 (check the owner), `private/*` query 1 (empty), `exports` query
    max(E, 1);
  - deletes: `users` + `handles` + `quotas` + E.
  - GCS object deletes are free operations (ADR-0005 "Deletes").
  - Firebase Auth admin calls cost 0 Firestore ops.
- **Export composer** (T10): the graph exporter resolves handles with `GetProfiles` in batches of 50. A job doesn't
  share the request instance cache, so the planning value assumes every handle is a miss.

### Daily totals at the Stage 0 target (300 DAU) vs free quota
| Quota | Per DAU | At 300 DAU | % of free | vs 80% line |
|---|---|---|---|---|
| Firestore reads (50k/day) | 1.22 | ≈ 370 | 0.7% | well under |
| Firestore writes (20k/day) | 0.31 | ≈ 93 | 0.5% | well under |
| Firestore deletes (20k/day) | 0.51 | ≈ 153 | 0.8% | well under |
| Cloud Run requests (2M/month, shared) | ≈ 0.005 RPC + job invocations | < 1k/month (OPEN: depends on invocations per job, ADR) | < 0.1% | well under |
| GCS (export objects) | 1 Class A per export, 1–2 Class B per download, KB–MB for ≤ 7 days | ≈ 9 Class A/month | < 0.2% of 5k | well under |
| Pub/Sub (if option A) | < 1 KB per message | KB/month | ≈ 0% of 10 GiB | well under |

- **Released scope after P8:** adds ≈ 1.2 reads, 0.3 writes and 0.5 deletes per DAU to the full Phase 1 model.
  cost-model row 35 has ≈ 0.1 reads/DAU; the derived value is ≈ 0.5 for deletion alone, so T21 corrects it. The
  Phase 1 read crossover (≈ 233 DAU, `phase1.md` §5) moves by < 2 DAU.
- **One large deletion.** With the caps that exist (O = 5,000, B = 2,000, Bb = 10,000), a single deletion costs
  **≥ 17,000 writes + 2I** (85% of one day's free writes, even with I = 0). At the cost-model §7 upper bound
  ($0.18/100k writes) that is ≈ $0.03 per such deletion. It is pay-per-use, with no fixed fee. Worst-case I and P
  have no cap and are **OPEN**: there is no follower cap, and posts are bounded only by 100/day × account age.
- **Cost line:** P8 is **$0/month at 300 DAU**. Every resource in every T1 option is pay-per-use. **New GCP service:**
  none for options A, C and D; **Cloud Tasks for option B**, which isn't in the `free-tier-budget` §1 table. The ADR
  must verify its free allowance and price before acceptance.

### Worst-case abuse bounds per account per day (inputs to T20)
| Vector | Control | Worst per account/day |
|---|---|---|
| Polling GetAccountExport | `account_ops_daily` 20 calls/uid/IST day per instance, shared by the three RPCs (ADR-0010 D5 A6) | 20 × 2 reads × 3 instances = **120 reads** |
| Repeated exports of a large account | quota `exports` 1/day | 1 export job (formula above) |
| Sybil create → delete churn | verified-identity gate (ADR-0010 D5 A2/A10); CreateProfile 2 R / 3 W + 1 Auth `users.get` (M2: refuses a deleted/disabled Auth user; 0 on replay); delete of an empty account ≈ 10 ops | ≈ 15 ops per cycle; bounded by sign-up throttles |
| Forged job request to `/internal/*` | OIDC verifier with an allowed-email list (`pubsubpush.go:31-51`) | 0 (rejected before any read) |

## Dependencies & open questions
- **Depends on (built):**
  - `graph.Eraser` and `graph.ExportUser`;
  - `posts.Eraser` and `posts.Exporter`;
  - `opsctl` `purgeLoop` and `checkStartGate`;
  - `quota.Exports` and `QUOTA_EXPORTS_PER_DAY`;
  - `ACCOUNT_OPS_CALLS_PER_DAY` and the charge-only set (ADR-0010 A6);
  - the `exports.expireAt` TTL policy (`modules/firestore/variables.tf:36-39`);
  - the OIDC verifier for `/internal/*`, which is still a placeholder handler (`pubsubpush.go:57`, `apiserver.go:221`);
  - the runtime SA's `iam.serviceAccountTokenCreator` on itself, for `signBlob` (`iam/main.tf:56-60`).
- **Depends on (later slices; registration only):** media (P4), engagement (P5), notifications/devices (P6), reports
  (P7). P8 can ship before they do: the guard test (T11) fails the build of whichever slice adds an unregistered
  collection.
- **Not built:**
  - re-authentication in the Flutter `AuthRepository` (no `reauthenticate` in `app/lib/features/auth/data/auth_repository.dart`);
  - any Firebase Auth admin role on the runtime SA (`iam/main.tf:7-60`);
  - a job/checkpoint document (ADR-0003:117 says "checkpoint progress in the job's doc", but no such collection is in
    the ADR-0003 table).
- **@architect (T1):**
  - **D-A** and **D-B** (founder decisions, with costs);
  - **D-C, orchestrator placement.** ADR-0008 D10 says "the orchestrator stays in identity and calls `graph.Eraser`
    through its interface". But `graph/purge.go:16` imports `internal/identity`, and `graph.Eraser` takes a
    `graph.Checkpoint`, so identity can't name it without an import cycle. Options:
    - identity declares a consumer-side `StepEraser` with an opaque, serialisable checkpoint, and `apiserver.Build`
      wraps graph/posts in adapters (the `BlockChecker` pattern);
    - or the orchestrator lives outside the module list, which would amend CLAUDE.md's module set and so needs the
      founder.
  - **D-D, the exporter interface.** `graph.ExportUser` returns a struct (`graph/export.go:33`); `posts.Exporter`
    streams to an `io.Writer` (`posts/api.go:215`). Pick one section interface for the composer and for later slices.
  - Q1–Q10 above.

---

## Milestones
| # | Milestone | Tickets | Exit |
|---|---|---|---|
| M1 | Decisions and contract | T1, T2a, T2b | ADR **Accepted by the founder**; `make proto` green; generated Go + Dart committed |
| M2 | Server seams (can start now) | T4 | Flag + recent-sign-in check merged; stubs replaced by FEATURE_DISABLED / Unimplemented-behind-flag |
| M3 | Infra | T3a, T3b | Dev `terraform plan` shows only the ADR's resources; `cost-guard` clean |
| M4 | Backend | T5, T6, T7, T8, T9, T10, T11, T12 | All RPCs and jobs behind the flag; opsctl uses the orchestrator |
| M4′ | Flutter (in parallel from day 1) | T13, T14, T15 | Screens built against fakes; reason mapping after T2a |
| M5 | Verification | T16, T17, T18, T19, T20, T21 | Test report PASS with budget assertions; reviews clean; cost report |
| M6 | Ops and release | T22, T23, T24, T25 | Dev drill done; v0.4.0 GO; flag allowlist → on |

Order:
- T1 → founder acceptance → T2b → (T3a ‖ T3b ‖ T6) → T7, T8 → T5 → T9 → T10 → T11, T12.
- T2a and T4 start now. T13–T15 start now against fakes.
- T16/T17 follow their backend tickets; T19–T21 follow M4; T22–T25 come last.

---

## Tickets

### T1 — ADR: account lifecycle (orchestration, export storage, placement, semantics)  [owner: architect] [size: M] [depends: —]
- **Status:** Done. ADR-0011 **Accepted 2026-10-07** (founder decisions relayed by the lead; branch `docs/p8-t1-adr`).
  D-A = D with Pub/Sub (shared `jobs` topic, self-chaining, `daily-maintenance` backstop; no Cloud Tasks);
  D-B = separate private bucket `<proj>-exports` (P4 upload prefixes unchanged); D-C = orchestrator in `identity`;
  Q3 SUSPENDED may delete; Q10 list accepted and published in `app/web/privacy.html`; IAM = custom role **plus**
  compensating controls C1–C4 (own-uid-only via DELETING check, narrow Auth-admin wrapper, audit line per Auth call,
  log-based volume alert ≈ $0.40/month); ≈ $0.03 per max-size deletion accepted, no spreading. CLAUDE.md unchanged
  (its "Async work" line already names Pub/Sub push). T2b, T3a, T3b and T5–T12 are unblocked.
- **Description.** Write `docs/adr/00NN-account-lifecycle.md` (next free number; 0011 today) using the `adr` template.
  Each option needs an idle cost, a cost at 300 DAU and at 3k DAU, and its quota use. The planner makes no
  recommendation; the architect recommends and the founder decides.
  - **D-A: job orchestration mechanism.** Constraints for every option:
    - Cloud Run 30 s request timeout and `cpu_idle = true` (work only inside a request);
    - the 120 s start gate (ADR-0008 D10);
    - resumable, with a checkpoint that survives redelivery (ADR-0003:116-118);
    - a reference deletion needs several bounded invocations (posts 1, graph 5, identity 1–2, Auth 2).

    The options:
    - **A. Pub/Sub push, self-chaining.** A new `account-jobs` topic, or the shared `jobs` topic that `phase1.md` §5
      recommends, with a DLQ and a push subscription through the existing `modules/pubsub` (3 resources + 2 IAM per
      topic). Each delivery does ≤ 20 s of work, saves the checkpoint, publishes a continuation, and acks.
      - The start gate has to be handled somehow. Nacking until 120 s have passed uses up
        `max_delivery_attempts = 5` with 10–600 s backoff (`pubsub/main.tf:59-67`). A per-subscription
        `minimum_backoff` of ≥ 60 s, or deferring the gate to the backstop, are the alternatives.
      - Cost: $0 fixed; Pub/Sub ≪ 10 GiB; +1 job-state read and +1 checkpoint write per invocation.
    - **B. Cloud Tasks queue.** `schedule_time` handles the 120 s gate natively; retry and backoff are set per queue
      with no 5-attempt DLQ cliff; OIDC to `/internal/*`.
      - This is a **new GCP API** (`cloudtasks.googleapis.com`), plus `google_cloud_tasks_queue` and IAM (enqueuer on
        the runtime SA, actAs on the push SA).
      - It deviates from CLAUDE.md's "Async work: Pub/Sub push".
      - Free allowance and price are **not in the `free-tier-budget` table: verify before acceptance**. No fixed fee
        is known.
    - **C. Scheduler sweep only.** Reuse `daily-maintenance` (prod only; 1 of the 3 per-billing-account jobs used;
      `envs/prod/main.tf:186-191`).
      - DeleteAccount only sets DELETING. Each daily run processes DELETING users and PENDING exports within one
        30 s request.
      - Deletion can take up to 24 h; a large account takes several days; an export can take up to 24 h (poor
        "Download my data" UX).
      - Dev has no scheduler job, so it needs a manual trigger.
      - $0, 0 new resources.
    - **D. Hybrid.** A or B for the fast path, plus C as a backstop: the daily sweep re-enqueues DELETING users and
      PENDING exports older than N hours, which recovers DLQ'd jobs.

    The ADR also decides where job state lives: on `users/{uid}` (deleted at the end) and `exports/{id}`, or a new
    `accountJobs/{uid}` collection (which then needs its own TTL and erasure).
  - **D-B: export storage.** The proto promises 7-day retention (`identity.proto:229`). The only private bucket deletes
    everything after 2 days (`media-buckets/main.tf:19-26`).
    - **A. Prefix-scoped lifecycle in `<proj>-media-upload`.**
      - Narrow the existing 2-day rule with `matches_prefix` to the upload prefix. P4 hasn't fixed that prefix yet,
        so it must be fixed now.
      - Add an `age = 7` rule for `exports/`.
      - Pros: no new bucket; the runtime SA is already `objectAdmin` there.
      - Cons: export retention is coupled to the media staging bucket; a mis-scoped rule deletes exports after 2 days
        or keeps uploads for 7; the bucket CORS is PUT-only (fine if the client opens the URL, not if it uses XHR).
      - $0: KB–MB objects inside the 5 GB free tier; 1 Class A per export.
    - **B. A third bucket `<proj>-exports`** in `us-central1`: private, `public_access_prevention = enforced`,
      uniform access, `age = 7` lifecycle, IAM scoped to the runtime SA, no CORS.
      - Pros: isolated IAM and lifecycle.
      - Cons: one more Terraform resource set and env var.
      - $0: the free tier is per billing account across US-region buckets. Confirm that the `cost-guard` hook doesn't
        list `google_storage_bucket`.

    Both options delete lifecycle objects asynchronously. GetAccountExport must enforce expiry itself (Q6).
  - **D-C: orchestrator placement** (the import-cycle problem in "Dependencies") and the step registry: order
    constraints, and "later slices insert before identity".
  - **D-D: the exporter section interface** and the JSON envelope (`exportVersion`, `generatedAt`, `account`,
    `profile`, `graph`, `posts`, …).
  - **Q1–Q10:** confirm each default or override it.
  - **IAM:** the narrowest Firebase Auth admin role that can disable, revoke, read and delete users.
- **Acceptance criteria.**
  - Given the ADR, when read, then D-A and D-B each list every option above with idle, 300 DAU and 3k DAU cost, new
    services, Terraform resources and quota use, plus a Decision paragraph.
  - Given option B for D-A, then its Cloud Tasks price and free allowance cite a pricing page checked on a stated date.
  - Given the Deciders line, then it records the founder's acceptance of D-A and D-B (CLAUDE.md "stop and ask").
  - Given Q1–Q10, then each is marked "default accepted" or replaced with a decision.
  - Given the Handoff, then backend, frontend, deployer, tester and security each have explicit items.
- **Test notes.** The ADR's residue allowlist (Q10) is the oracle for T11 and T16.
- **Observability.** The ADR lists the log fields: `account_job`, `step`, `checkpoint`, `fs_reads/writes/deletes`,
  `outcome`, `uid_hash` (never a raw uid or the download URL).
- **Budget.** Doc only. It must restate this plan's formulas with the chosen job-state reads and writes filled in
  (replacing the OPEN items).

### T2a — Proto: `ERROR_REASON_REAUTH_REQUIRED` + DeleteAccount comment  [owner: architect] [size: S] [depends: —]
- **Status:** Done (branch `feat/p8-t2a-reauth-reason`). Proto + generated Go/Dart; `buf lint`, `buf breaking` and
  `flutter analyze` clean. `connect_error_mapper.dart` has a stop-gap `REAUTH_REQUIRED` case that T13 replaces with a typed exception.
- **Description.**
  - Add `ERROR_REASON_REAUTH_REQUIRED = 15` to `common.proto` (FAILED_PRECONDITION: "sign in again to continue").
  - DeleteAccount comment: "auth_time older than ACCOUNT_DELETE_REAUTH_MAX_AGE (5 min) or missing => FAILED_PRECONDITION
    + REAUTH_REQUIRED, 0 writes".
  - Run `make proto` and commit the generated Go and Dart.
- **Acceptance criteria.**
  - Given CI, then `buf lint` and `buf breaking --against main` pass.
  - Given `flutter analyze`, then 0 new warnings.
  - Given the generated code, then the diff is the new enum value plus comments only.
- **Test notes.** T4 and T13 cover the reason end to end.
- **Observability.** —
- **Budget.** Not applicable.

### T2b — Proto comments: budgets and semantics from the ADR  [owner: architect] [size: S] [depends: T1 accepted] [blocked: T1 accepted]
- **Status:** Done (branch `docs/p8-t1-adr`, 2026-10-07). Comment-only changes to the three RPCs and `expires_at`;
  `make proto` (buf lint, buf breaking vs `main`, generate Go + Dart) clean; the generated diff is comments only. No
  job collection was added, so the header's "Collections owned" line is unchanged.
- **Description.** Comment-only updates in `identity.proto`:
  - DeleteAccount: reads 2/1 (interceptor + users), writes per ADR, the 120 s start gate, Auth disable in the first
    job step, replay semantics (Q2), the SUSPENDED rule (Q3), the job mechanism.
  - RequestAccountExport: reads 2/1, writes 2/2, replay 3/0.
  - GetAccountExport: reads 2/1; NOT_FOUND after `expireAt` or for another user's id (Q6).
  - `expires_at`: name the chosen storage (D-B).
  - Also fix the header's "Collections owned" line if the ADR adds a job collection.
- **Acceptance criteria.**
  - Given each changed comment, then its numbers equal this plan's table as amended by the ADR.
  - Given `buf breaking`, then it is clean, and the generated code diff is comments only.
- **Test notes.** —
- **Observability.** —
- **Budget.** Not applicable.

### T3a — Terraform: export storage (D-B), Firebase Auth IAM, env vars  [owner: production-deployer] [size: S] [depends: T1 accepted] [blocked: T1 accepted]
- **Status:** Done (code, not applied). `<proj>-exports` bucket (option B, PAP enforced, 7-day lifecycle, runtime SA objectAdmin) in `modules/media-buckets`; custom role `accountLifecycleAuth` + runtime SA binding in `modules/iam`; C4 log metric `auth_admin_mutations` + alert policy in `modules/monitoring` (`# cost-approved: ADR-0011`); `EXPORT_*`, `ACCOUNT_DELETE_REAUTH_MAX_AGE`, `JOBS_TOPIC` and the flag trio wired in dev (on) and prod (off). Dev `terraform plan`: 11 add, 2 change, 0 destroy. Not applied; awaiting plan review by the founder.
- **Description.**
  - Implement D-B as decided: either the prefix-scoped lifecycle rules in `modules/media-buckets`, or a new private
    `<proj>-exports` bucket in `us-central1` with an `age = 7` lifecycle and runtime-SA-only IAM.
  - Grant the runtime SA the Firebase Auth role the ADR names.
  - Add `api` env vars:
    - `EXPORT_BUCKET` (and `EXPORT_PREFIX` for option A);
    - `EXPORT_URL_TTL = 15m`, `EXPORT_RETENTION = 168h`;
    - `ACCOUNT_DELETE_REAUTH_MAX_AGE = 5m`;
    - `FEATURE_ACCOUNT_LIFECYCLE` (dev `on`, prod `off`), `_ALLOWLIST`, `_PERCENT`.
- **Acceptance criteria.**
  - Given `terraform plan` for dev and prod, then only the ADR-listed resources and env vars change, and `cost-guard`
    passes with no `# cost-approved` marker needed.
  - Given option A, then an object under the upload prefix older than 2 days is still deleted, and an object under
    `exports/` is not (checked on dev with a back-dated test object, or with the lifecycle simulator described in the PR).
  - Given the export storage, then `public_access_prevention = enforced` and no `allUsers` binding.
- **Test notes.** Record the `terraform plan` summaries in the PR.
- **Observability.** —
- **Budget.** $0. No new fixed-cost resource.

### T3b — Terraform: job transport (D-A)  [owner: production-deployer] [size: S] [depends: T1 accepted] [blocked: T1 accepted]
- **Status:** Done (code, not applied). `jobs` topic, DLQ and push subscription to `/internal/pubsub/jobs` added to the `modules/pubsub` default topics with new per-topic `minimum_backoff` (60s) and `max_delivery_attempts` (10); DLQ tile added to the existing dashboard. The OIDC allowlist already contains the push SA. The no-OIDC 401 / with-OIDC 2xx check on dev runs after apply.
- **Description.** Implement D-A as decided:
  - **A:** add `account-jobs` (or `jobs`) to `modules/pubsub` `topics`, with the push path the ADR names and any
    per-subscription backoff override.
  - **B:** enable `cloudtasks.googleapis.com`, a `google_cloud_tasks_queue` in `asia-south1` with the ADR's retry
    config, enqueuer IAM for the runtime SA, and actAs on the push SA.
  - **C/D:** route `daily-maintenance` to the sweep path. No new Scheduler job: 3 per billing account, 1 used.

  Add the push SA email to `INTERNAL_OIDC_ALLOWED_EMAILS` if it isn't there already.
- **Acceptance criteria.**
  - Given `terraform plan`, then only the ADR's resources are added, and `cost-guard` is clean.
  - Given dev, when a test message or task is sent to the endpoint without OIDC, then 401; with the push SA token,
    then 2xx.
- **Test notes.** Verify on dev with the placeholder handler before T8 lands.
- **Observability.** A DLQ or queue-depth signal visible in the existing dashboard. No new alert policy unless the ADR
  asks for one (check alert pricing first).
- **Budget.** $0 fixed. Pay-per-use as in the T1 option.

### T4 — Server flag, recent-sign-in check, stub replacement  [owner: backend-developer] [size: S] [depends: — (T2a for the reason constant)]
- **Status:** Done.
- **Description.**
  - Add `account_lifecycle` to `pkg/platform/flags` (`FEATURE_ACCOUNT_LIFECYCLE`, default `off`). GetMe's
    `enabled_features` reports it with 0 reads.
  - Add `authn.RequireRecentSignIn(ctx, maxAge, now) error`. It returns FAILED_PRECONDITION + `REAUTH_REQUIRED` when
    `Claims.AuthTime` is zero or older than `maxAge`. Allow 30 s of clock skew, so a future `auth_time` of up to 30 s
    passes. The config field is `ACCOUNT_DELETE_REAUTH_MAX_AGE` (default 5 m; startup fails if it is > 10 m or ≤ 0).
  - In `identity/server.go:142-163`, replace the three Unimplemented stubs:
    - flag off → `flags.Disabled` (FEATURE_DISABLED) at 0 reads;
    - flag on → Unimplemented until T5/T9.
  - Delete `TestServer_Phase1Stubs_ReturnUnimplemented` and `..._DoNotLeakInternalRoadmap`
    (`identity/server_test.go:282,309`) and replace them with flag tests.
  - Keep the three RPCs in the charge-only set and in `account_ops_daily` (ADR-0010 A6 guard test unchanged).
- **Acceptance criteria.**
  - Given the flag off, when any of the three RPCs is called, then FAILED_PRECONDITION + `FEATURE_DISABLED` with
    0 Firestore reads after the interceptor.
  - Given `auth_time` 4 min 59 s ago, then `RequireRecentSignIn` passes; at 5 min 01 s, then `REAUTH_REQUIRED`; with
    a missing claim, then `REAUTH_REQUIRED`.
  - Given `ACCOUNT_DELETE_REAUTH_MAX_AGE = 0`, then startup fails with a clear error.
  - Given the ADR-0010 guard test, then it still passes with the same charge-only set.
- **Test notes.** Unit tests with a fake clock and fake claims.
- **Observability.** `feature_disabled = true` on rejected calls; `reauth_required = true` on stale-token rejections.
- **Budget.** 0 reads and 0 writes added.

### T5 — DeleteAccount (sync part)  [owner: backend-developer] [size: M] [depends: T1 accepted, T2b, T4, T6, T8] [blocked: T1 accepted]
- **Status:** Done (local branch `docs/p8-t1-adr`, not pushed). `Lifecycle.DeleteAccount` + `identity.Server` (flag, `RequireRecentSignIn` with `config.AccountDeleteReauthMaxAge`), interceptor exemption `authn.AllowRestricted` / `apiserver.RestrictedAllowedProcedures` (DeleteAccount only, guard test). Budget: 1 read, 1 write (replay 1/0), asserted in `repo_lifecycle_integration_test.go` and through the real chain in `apiserver/account_lifecycle_integration_test.go`.
- **Description.**
  1. `RequireRecentSignIn` (T4); validate the idempotency key format.
  2. In a transaction, read `users/{uid}` fresh:
     - if already DELETING → replay, return the stored `deletion_requested_at`, 0 writes (Q2);
     - otherwise set `status = DELETING`, `updatedAt = now` (the start-gate clock, ADR-0008 D10) and
       `deletionRequestedAt = now`, plus job state per the ADR.
  3. After the commit, enqueue the job through the T8 enqueuer. If the enqueue fails, still return success: the
     backstop or the replay path re-enqueues (per the ADR). Log ERROR `account_delete_enqueue_failed`.
  4. Update the identity cache in place, so this instance rejects the uid at once.
  5. Apply the interceptor exemption from Q2/Q3: DeleteAccount only, for DELETING (and SUSPENDED if Q3 is accepted).
     Wire it in `apiserver.Build` from one exported set, covered by the guard test.
- **Acceptance criteria.**
  - Given an ACTIVE user with a fresh sign-in, when DeleteAccount is called, then `users.status = DELETING`, one job
    is enqueued, the response has `deletion_requested_at`, and reads ≤ 2 / writes ≤ the ADR value.
  - Given the same call replayed (same or new key), then the same `deletion_requested_at`, 0 writes, and no second
    job (or a duplicate the job dedupes, per the ADR).
  - Given a stale sign-in, then `REAUTH_REQUIRED` and 0 writes.
  - Given a DELETING caller, when any other RPC is called (for example GetMe), then `ACCOUNT_RESTRICTED` (unchanged).
  - Given a SUSPENDED caller, then the Q3 decision holds.
  - Given `DEGRADED_MODE = readonly`, then `DEGRADED_MODE` (Q8).
- **Test notes.** Emulator with `budgettest.Assert`. Fault-inject the enqueuer to prove the success-plus-recovery path.
- **Observability.** `account_op = delete_request`, `outcome = accepted|replay|rejected:<reason>`, `uid_hash`. ERROR
  `account_delete_enqueue_failed` reaches Error Reporting.
- **Budget.** 2/1 reads; 1 write (+1 if there is a job doc, per the ADR); 0 deletes.

### T6 — Orchestrator core: step registry, adapters, start gate, time budget  [owner: backend-developer] [size: M] [depends: T1 accepted] [blocked: T1 accepted]
- **Status:** Done (local). Orchestrator in `internal/identity` (`StepEraser`, `RegisterEraser(BeforeIdentity, ...)`, 20 s slices, 5-error policy, `StartGate` moved from opsctl and keyed on `deletionRequestedAt`); adapters in `apiserver/lifecycle_wiring.go`. Code-review fixes (2026-10-08): step errors are scrubbed (`logger.ScrubErr`: uid, `documents/...` paths, edge ids, 64-hex export ids) in one place, `retry()`, so no raw uid or export id reaches a log line (graph purge also hashes counterpart ids at the source); a step that fails because the work context ran out saves its checkpoint instead of burning retries, with jittered backoff between same-step retries and the whole delivery bounded at 27 s; the final `users/{uid}` delete is one transaction requiring DELETING and `deletionJob.seq == msg.seq` (ErrJobConflict acks as a duplicate); Jobs and Cron handlers recover panics into a 500 + Error Reporting entry; the delete line carries `step_calls`, `deleted_docs`, `deleted_objects`; `StepNames()`/`ExportSectionNames()` are pinned by the apiserver wiring test (step names are persisted in `deletionJob.step`). Known limit: the backstop queries are Limit(50) and unordered, so a stuck job can hide behind 50 fresh ones; a full page logs WARN `backstop_page_full` (`TestBackstop_FullPageIsLogged`).
- **Description.**
  - Build the transport-independent orchestrator, placed as D-C decides. An ordered registry of steps, each with
    `Run(ctx, uid, checkpoint []byte) (next []byte, done bool, err error)`.
  - Adapters, wired in `apiserver.Build` and in opsctl:
    - `posts.Eraser` (JSON `posts.Checkpoint`), then `graph.Eraser` (JSON `graph.Checkpoint`, needs `SetProfiles`
      wired, `graph/purge.go:202-204`), in the Q1 order;
    - then the identity step (T7), then the Auth step (T7).
  - `RunInvocation(ctx, uid, state, deadline)`:
    - refuses to start before DELETING has been committed for ≥ 120 s (reuse the `opsctl checkStartGate` logic and
      move it into the package; no copy);
    - loops steps until about 20 s have elapsed, then returns the new state;
    - after 5 consecutive errors on one step, returns an error (the same policy as `opsctl purgeLoop`, reused).
  - The registration API for later slices: `Register(name, position constraint "before identity", StepEraser)`.
    Registering after identity is a startup error.
  - Charge every step to a `budget.Counter`, and log per invocation.
- **Acceptance criteria.**
  - Given a fake step that needs 7 calls and a 3-call budget, then three invocations finish it with the checkpoints
    carried in between.
  - Given DELETING committed 60 s ago, then `RunInvocation` returns "not yet" with 0 writes.
  - Given a step registered after identity, then startup fails.
  - Given a crash after any step call (the state is not saved), when re-run from the last saved state, then it
    completes with no double counter decrement (relies on the Erasers' existing `Exists` preconditions).
- **Test notes.** Unit tests with fake steps and a fake clock; emulator chain tests in T16.
- **Observability.** `account_job = delete`, `step`, `step_calls`, `fs_reads/writes/deletes`, `elapsed_ms`,
  `uid_hash`.
- **Budget.** Orchestrator overhead: job-state reads and writes per the ADR (≤ 1 + ≤ 1 per invocation).

### T7 — Identity Eraser + Firebase Auth steps  [owner: backend-developer] [size: M] [depends: T6, T3a] [blocked: T1 accepted]
- **Status:** Done (local). **M2 (2026-10-08, ADR-0011 amendment, founder option (a)):** `CreateProfile` checks the caller's own Auth user (`authAdmin.checkSignup`, `signupTarget` from the token uid) on the not-found path only, before any create; deleted/disabled = PERMISSION_DENIED, outage = UNAVAILABLE, nothing written. Budget: 0 extra Firestore ops, 1 Auth `users.get` per real sign-up, 0 on replay. C4 filter tightened to `delete AND ok` OR `ERROR AND refused`. Identity step + Auth steps in the Q1 order (`users/{uid}` last) through the narrow wrapper `authadmin.go` (C1 fresh DELETING check, C3 NOTICE audit line, ERROR `auth_admin_refused`), CI guard `TestAuthAdminConfinement` (C2). The custom role, C4 metric/alert and `EXPORT_*` env vars are Terraform (T3a, not done here). Code-review fix: the C2 guard is now one type-based check (`golang.org/x/tools/go/packages`, test-only) that flags every use of an Auth admin method (calls, method values, promoted calls via `*baseClient`/`TenantClient`) and of `(*firebase.App).Auth` outside the allowed packages/files, with a closed-holes test over overlaid virtual files. The identity step logs `deleted_docs`/`deleted_objects`.
- **Description.**
  - **Auth step 1 (first in the chain):** disable the Firebase Auth user and revoke refresh tokens (Admin SDK).
    NotFound counts as done.
  - **Identity step**, all with `Limit` queries and batches ≤ 500:
    1. `exports where uid == U`: delete the objects (free op), then the docs.
    2. `users/{U}/private/*`: delete (empty at Stage 0).
    3. `handles/{users.handleLower}`: delete only if `handles.uid == U` (a precondition read).
    4. `quotas/{U}` (ADR-0003 amendment 2026-09-30).
    5. `users/{U}` last.
  - **Auth step 2 (final):** `DeleteUser`. NotFound counts as done.
  - Every step is idempotent: a missing doc or object is success.
- **Acceptance criteria.**
  - Given a user with 1 export (doc + object), a handle and a quotas doc, when the identity step runs, then none of
    them exist and reads ≤ 4 + E, deletes = 3 + E.
  - Given the handle doc is owned by another uid (corrupt data), then it is left alone and WARN
    `handle_owner_mismatch` is logged.
  - Given the Auth user is already deleted, then both Auth steps report done.
  - Given the step killed after deleting the export objects but before the docs, when re-run, then it completes.
- **Test notes.** Emulator (Firestore + Auth + Storage emulators). Auth emulator Admin calls.
- **Observability.** `step = identity|auth_disable|auth_delete`, `deleted_docs`, `deleted_objects`.
- **Budget.** Reads 4 + E; writes 0; deletes 3 + E (+ `private/*`); GCS deletes free; Auth 0 Firestore ops.

### T8 — Job transport handler on `/internal/*` (+ backstop if D)  [owner: backend-developer] [size: M] [depends: T6, T3b] [blocked: T1 accepted]
- **Status:** Done (local). `/internal/pubsub/jobs` (seq dedupe, `UpdateTime` precondition, re-publish of seq-1, 429 gate, no flag/degraded gate) and the `daily-maintenance` backstop (`/internal/cron/daily-maintenance`) in `lifecycle_jobs.go`, wired in `apiserver.Build` behind the OIDC verifier. Terraform for the `jobs` topic is T3b (not done here). See T6 for the review fixes (panic recovery, 27 s bound, backstop page-full WARN, `backstop_skipped` trace field).
- **Description.**
  - Replace the placeholder handler for the ADR's path(s) (`pubsubpush.PlaceholderHandler`, `apiserver.go:221`)
    with a real handler behind the existing OIDC verifier.
  - Decode `{kind: delete|export, uid, jobId}` and load the job state.
  - Call `RunInvocation` (delete) or the export runner (T10), then persist the state.
  - Continue as the transport requires: publish a continuation (A), enqueue the next task (B) or wait for the next
    sweep (C).
  - Return 2xx only after the state is saved. Dedupe redeliveries (the state carries the last processed message or
    task id).
  - If D is chosen, add the `daily-maintenance` sweep: DELETING users and PENDING exports older than N hours with
    no progress, `Limit(50)`, re-enqueued.
  - The handler ignores the feature flag (Q9).
- **Acceptance criteria.**
  - Given two concurrent deliveries of the same message, then the final state is complete and the counters are exact
    (the T16 invariant check).
  - Given a delivery without a valid OIDC token, then 401 and 0 reads.
  - Given the flag `off`, then an in-flight deletion still completes.
  - Given a job that has used up retries (DLQ), when the backstop runs (if D), then the job resumes from its
    checkpoint.
- **Test notes.** Emulator Pub/Sub, or a fake transport, plus an HTTP handler test with a fake verifier.
- **Observability.** `account_job`, `delivery_attempt`, `outcome = progressed|done|gated|error`. ERROR after the last
  retry. DLQ depth is checked in the runbook.
- **Budget.** Per invocation: job-state 1 read + 1 write (OPEN, per the ADR) + the steps' own ops.

### T9 — RequestAccountExport + GetAccountExport  [owner: backend-developer] [size: M] [depends: T2b, T4, T3a] [blocked: T1 accepted]
- **Status:** Done (local). RequestAccountExport (doc id hash(uid, key), quota `exports`, reads 1 + interceptor, writes 2; replay 2 reads, 0 writes) and GetAccountExport (fresh read, byte-identical NOT_FOUND incl. expiry, signed 15-minute GET per call via `pkg/platform/objstore`).
- **Description.**
  - **RequestAccountExport:**
    - `exportId = hash(uid, idempotency_key)` (ADR-0003:54);
    - a transaction reads `quotas/{uid}`; the `exports` quota is 1/day (`QUOTA_EXPORTS_PER_DAY`);
    - `Create(exports/{id} {uid, status: PENDING, objectPath, createdAt, expireAt = createdAt + 7 d})` + quota
      increment;
    - `AlreadyExists` → return the current status (replay);
    - after the commit, enqueue an export job (T8).
  - **GetAccountExport:**
    - read `exports/{id}` fresh;
    - if it is missing, `uid ≠ caller`, or `now ≥ expireAt`, return NOT_FOUND, byte-identical in all three cases;
    - if READY, sign a V4 GET URL for `EXPORT_URL_TTL` (15 min) with `response-content-disposition: attachment`
      through IAM `signBlob`, reusing P4's signer if it has landed (otherwise build it here in `pkg/platform` for P4
      to reuse);
    - never store the URL or log it.
- **Acceptance criteria.**
  - Given a first request today, then PENDING, 2 writes, ≤ 2 reads.
  - Given a second request with a new key on the same IST day, then `QUOTA_EXCEEDED` with `metadata.quota = "exports"`.
  - Given a replay with the same key, then the same `export_id` and 0 writes.
  - Given user B calls GetAccountExport with A's `export_id`, then NOT_FOUND identical to an unknown id.
  - Given READY, then `download_url_expires_at - now` ≤ 15 min and `expires_at = createdAt + 7 d`.
  - Given `now ≥ expireAt` with the doc still present (TTL lag), then NOT_FOUND.
- **Test notes.** Emulator. The signer is faked in tests (the Storage emulator can't validate V4 signatures); one dev
  smoke downloads a real URL (T23).
- **Observability.** `account_op = export_request|export_get`, `outcome`, `export_status`. Never the URL.
- **Budget.** Request 2/1 R, 2 W (replay 3 R, 0 W); Get 2/1 R, 0 W; 1 Class B per download.

### T10 — Export composer + export job  [owner: backend-developer] [size: M] [depends: T6, T8, T9] [blocked: T1 accepted]
- **Status:** Done (local). Streaming composer (`exportVersion:1`, account, profile, registered `graph` and `posts` sections) writing to the exports bucket through an aborting `Put`; READY/FAILED with precondition; DELETING or missing user = FAILED, no object. Code-review fixes: the export delivery is bounded at 25 s and logs `sections` and `bytes`; errors that could carry an export id are scrubbed.
- **Description.**
  - Implement the D-D section interface and stream one JSON object to a GCS writer at `objectPath`.
  - The envelope is `{exportVersion: 1, generatedAt, account, profile, graph, posts, …}`:
    - `account`: the Firebase Auth record (email, providers, `createdAt`, `lastSignInAt`);
    - `profile`: user-facing `users` fields only. No `status`, `snapshotVersion` or other internal fields (runbook
      §3a);
    - `graph`: `graph.ExportUser`, which by construction has no `blockedBy` (`graph/export.go:20-21`);
    - `posts`: `posts.Exporter` (mentions as handles only).
  - Later slices register sections the same way they register Erasers.
  - Before writing, if the user is DELETING, set FAILED and write no object.
  - On success, set READY. On a permanent error, delete any partial object and set FAILED.
  - The export must finish within one invocation for the reference account. If the composer can't finish inside the
    time budget it returns an error for a retry, and T21 measures the size at which that happens (OPEN).
- **Acceptance criteria.**
  - Given a user with posts, follows, followers, blocks and mutes, then the JSON parses, contains every section, and
    the totals match the emulator data.
  - Given the user is blocked by others, then no serialized field contains those blockers' uids (grep test, ADR-0008
    D12).
  - Given another user's private data (their `blocked`/`muted`, `blockedBy`, email), then it never appears.
  - Given a DELETING user, then the status is FAILED and no object exists.
  - Given a crash mid-write, when retried, then exactly one complete object exists (the partial one was overwritten or
    removed).
- **Test notes.** Golden JSON fixture with the uids normalized; the grep test reuses graph T16b's helper.
- **Observability.** `account_job = export`, `sections`, `bytes`, `fs_reads`, `elapsed_ms`.
- **Budget.** Reference account ≈ 703 R / 1 W / 0 D + job state (OPEN); 1 Class A.

### T11 — Collection-coverage guard + residue allowlist  [owner: tester] [size: S] [depends: T6, T7] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.**
  - Add a CI unit test (`make ci`, no emulator) with a table of every Firestore collection and GCS prefix in ADR-0003
    and later ADRs. Each row maps to a registered Eraser step, a registered export section, or an ADR-referenced
    residue allowlist entry (Q10).
  - The test fails when a module's path constants name a collection that's missing from the table. Each slice
    (P4–P7) adds its row in its own PR.
  - Add the emulator **residue sweep** helper for T16: after a deletion, scan every collection in the table for the
    uid (by known key, by indexed `uid`/`authorId`/`followerId`/`followeeId`/`reporterId` fields, and inside arrays
    for the graph docs of known counterparts) and fail on anything outside the allowlist.
- **Acceptance criteria.**
  - Given a new collection constant without a row, then `make ci` fails and names it.
  - Given the allowlist, then every entry cites its ADR or runbook line.
- **Test notes.** Put the helper in `docs/code-map.md` test helpers.
- **Observability.** —
- **Budget.** Not applicable (emulator / unit).

### T12 — `opsctl delete-account` and `export-account` on the orchestrator  [owner: backend-developer] [size: S] [depends: T7, T10] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.**
  - `delete-account --project P --uid U [--dry-run]` sets DELETING if needed, waits for the gate, then runs the
    T6 orchestrator to completion locally with the founder's ADC.
  - `export-account` writes the T10 JSON to `--out`.
  - Keep `purge-graph`/`purge-posts`/`export-*` (the S2 repair path, runbook §3b) and the existing guards (explicit
    project, typed prod confirmation, `--out` O_EXCL).
- **Acceptance criteria.**
  - Given a dev test account, when `delete-account` runs, then the T11 residue sweep (the cloud variant from the
    runbook drill) finds nothing outside the allowlist.
  - Given `--dry-run`, then it prints the counts per step and writes nothing.
- **Test notes.** Extend `cmd/opsctl/main_test.go` with fakes.
- **Observability.** Prints the ops per step and the final `purged: reads=.. writes=.. deletes=..`.
- **Budget.** Same as the job.

### T13 — Flutter: AccountRepository + re-authentication  [owner: frontend-developer] [size: M] [depends: — (T2a for the reason mapping)]
- **Status:** Done (repository, cubit, reauthenticate, mapper, flag accessor; analyze + tests green). Not blocked (built against the existing generated client and fakes). Deviations: no web redirect fallback (popup-only re-auth, founder decision 2026-10-07); Apple token revoke is delete-only and iOS/macOS-only; on-device checks of the native Google/Apple re-auth and revoke are deferred to T20.
- **Description.**
  - Check `docs/ui-catalog.md` first.
  - Add `features/account/data/account_repository.dart` (DeleteAccount, RequestAccountExport, GetAccountExport;
    one idempotency key per intent, reused on retry).
  - Add `AuthRepository.reauthenticate()`:
    - Google and Apple through the provider flow (web: popup);
    - password through a password prompt;
    - then `getIdToken(forceRefresh: true)`, so the next call carries the fresh `auth_time`.
  - Apple: `revokeTokenWithAuthorizationCode` per Q7.
  - Map `REAUTH_REQUIRED`, `QUOTA_EXCEEDED (exports)`, `RATE_LIMITED (account_ops_daily)`, `FEATURE_DISABLED` and
    `DEGRADED_MODE` in `mapConnectError`.
  - Add the `account_lifecycle` flag accessor.
- **Acceptance criteria.**
  - Given `REAUTH_REQUIRED`, then the cubit triggers re-auth once and retries once with the same key.
  - Given a re-auth that the user cancels, then nothing is sent.
  - Given a retry after a network error, then the same idempotency key is sent.
- **Test notes.** Bloc tests with fake repositories; a mapping test for the new reason.
- **Observability.** Crashlytics non-fatal on unexpected `AppException`. Never log the download URL.
- **Budget.** At most 1 DeleteAccount and 1 RequestAccountExport per intent.

### T14 — Flutter: Settings → Delete account  [owner: frontend-developer] [size: M] [depends: T13]
- **Status:** Done (screen, flag gate + redirect, final page, widget/router/settings tests; analyze + tests green). Merged with T15: the Download-my-data link pushes `AppRouter.exportDataPath` (T15's route); the password prompt is T15's shared `showPasswordPromptDialog`. The local-DB-cleared AC is met by the existing sign-out listener in bootstrap (`wipeSessionData`, covered by its own tests): the screen only dispatches `AuthSignOutRequested`.
- **Description.**
  - A Settings entry (flag on only) leading to `/settings/delete-account`. The screen explains:
    - what is deleted;
    - what remains (others' mentions, 14-day backups, Q10);
    - that it is irreversible.
  - Offer "Download my data first" (a link to T15).
  - The user types their handle to enable the button, then re-authenticates (T13), then DeleteAccount is called.
  - On success, sign out locally, clear the drift caches, and show a final "Your account is being deleted" page.
  - On a direct route visit with the flag off, redirect to `/settings` (the graph T15 precedent).
- **Acceptance criteria.**
  - Given a wrong typed handle, then the button stays disabled.
  - Given success, then the user is signed out, the local DB is cleared, and the confirmation is shown.
  - Given `REAUTH_REQUIRED` after a re-auth, then a clear error and no loop.
  - Given phone, tablet and desktop widths, then no overflow.
- **Test notes.** Widget tests: flag off, typed confirmation, success, re-auth cancel, error.
- **Observability.** As T13.
- **Budget.** 1 request per completed intent.

### T15 — Flutter: Settings → Download my data  [owner: frontend-developer] [size: S] [depends: T13]
- **Status:** Done (route `/settings/export`, flag-gated with redirect; `DataExportCubit` + screen; analyze + tests green). The `export_id` + lifetime are persisted in drift (`AccountExportEntries`, schema v4, wiped on sign-out, never the URL), so reopening the screen resumes polling with a fresh 10-poll budget and "check back later" works. T15 also owns the shared wiring T14 reuses: `showPasswordPromptDialog`, `UnexpectedErrorReporter`, account/auth repository providers.
- **Description.**
  - An entry leading to `/settings/export`.
  - "Request export" calls RequestAccountExport and keeps the `export_id` on the device.
  - Status polling: at most 10 polls per export, backing off 10 s → 60 s, then a "check back later" state. This stays
    under the 20-call `account_ops_daily` cap, which the three RPCs share.
  - When READY, "Download" opens `download_url` with `url_launcher` (no XHR, so no CORS dependency). After 15 min,
    re-fetch for a fresh URL.
  - NOT_FOUND shows "This export has expired"; `QUOTA_EXCEEDED` shows "You can request one export per day".
- **Acceptance criteria.**
  - Given PENDING → READY, then the Download button appears without a manual refresh.
  - Given 10 polls without READY, then polling stops.
  - Given NOT_FOUND, then the expired state is shown.
- **Test notes.** Widget tests with a fake repository and a fake clock.
- **Observability.** —
- **Budget.** ≤ 11 requests per export (1 request + ≤ 10 polls).

### T16 — Emulator integration: deletion chain  [owner: tester] [size: M] [depends: T5, T7, T8, T11] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.**
  - Seed U with posts, edges both ways, blocks both ways, mutes, an export, a handle and quotas.
  - DeleteAccount → drive the job to completion.
  - **Crash-resume:** kill after every step call in turn (fault-injected) and resume.
  - **Two concurrent deliveries.**
  - Run the graph invariant checker (graph T16a) and the posts invariants after every scenario. Run the T11 residue
    sweep at the end.
  - Budget assertions: the sync part with `budgettest.Assert`; the job total vs this plan's formula.
- **Acceptance criteria.**
  - Given every crash point, then the final state is identical and the counters are exact.
  - Given the sweep, then 0 references outside the allowlist.
  - Given the reference account, then measured ops are ≤ 509 R + job state, ≤ 300 W + checkpoints, ≤ 505 D.
  - Given `make test-int`, then the coverage of the new package is ≥ 70%.
- **Test notes.** Reuse the graph and posts fixtures; no second seeding helper.
- **Observability.** —
- **Budget.** Not applicable (emulator).

### T17 — Emulator integration: export privacy and access  [owner: tester] [size: M] [depends: T9, T10] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.**
  - Test the contents against a golden file, including the `blockedBy` grep and that no third party's email, `muted`
    or `blocked` data appears.
  - IDOR on `export_id`; expiry (fake clock); the quota rollover at IST midnight; replay; `account_ops_daily` at 21
    calls; the flag-off behaviour; an export while DELETING.
- **Acceptance criteria.**
  - Given every case, then the outcome matches T9/T10.
  - Given the budgets, then the measured values are ≤ the table.
- **Test notes.** Fake signer.
- **Observability.** —
- **Budget.** Not applicable.

### T18 — E2E smoke, Flutter test sweep, test report  [owner: tester] [size: S] [depends: T14, T15, T16, T17] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.**
  - Add `backend/e2e/account_smoke_test.go`, runnable against emulators and the `candidate` URL with throwaway
    accounts: create profile → follow → post → request export → READY → download → delete → poll until the Auth user
    is gone → residue check.
  - Run `flutter test`, and check that every new screen has widget tests.
  - Write `docs/reviews/test-report-account-lifecycle.md`.
- **Acceptance criteria.**
  - Given `make ci` and `make test-int`, then both are green.
  - Given the report, then PASS, with measured ≤ budget for each RPC and job.
- **Test notes.** The smoke creates and deletes its own accounts, so it is safe to re-run on prod `candidate`.
- **Observability.** —
- **Budget.** Per smoke run ≈ 30 reads, 15 writes, 15 deletes.

### T19 — Code review  [owner: code-reviewer] [size: S] [depends: T4–T15 (per PR)]
- **Status:** Open.
- **Description.** Review each PR against CLAUDE.md rules 1–11, the ADR and reuse-first:
  - no second limiter or signer;
  - the start gate is reused, not copied;
  - every query has a `Limit`;
  - no reads in a loop;
  - budget comments match the code;
  - the URL is never logged.
- **Acceptance criteria.** `docs/reviews/account-lifecycle-code-review.md` has 0 open Blockers.
- **Test notes.** —
- **Observability.** Every new path has `fs_*` fields and an Error Reporting-visible ERROR path.
- **Budget.** Verify the tables against the code.

### T20 — Security review: account lifecycle threat model  [owner: security-auditor] [size: M] [depends: T5, T7–T10, T13] [blocked: T1 accepted]
- **Status:** Done (2026-10-08), report in `docs/reviews/security-review-account-lifecycle.md`; M-1, M-2, M-3, L-1 to L-4, L-6, L-7 fixed; L-5 fixed in the client (founder-accepted flag exception). Still open: on-device checks of Apple/Google/password re-auth, revoke and client delete.
- **Description.** Write `docs/reviews/security-review-account-lifecycle.md`, covering:
  - re-auth bypass (missing, forged or future `auth_time`);
  - the Q2/Q3 interceptor exemption (scope exactly one procedure);
  - IDOR and enumeration on `export_id`;
  - signed URL leakage (logs, referrers, TTL);
  - export privacy (D12, third-party data);
  - the breadth of the Firebase Auth admin role on the runtime SA;
  - forged `/internal/*` calls;
  - the deletion race with in-flight writes (the 120 s gate);
  - the Apple revocation requirement (Q7, re-checked against Apple's current guidance);
  - residue vs the privacy policy wording.
- **Acceptance criteria.** 0 Critical and 0 High open; every Medium fixed or risk-accepted by the founder for the
  v0.4.0 readiness review. M5 is marked closed for stores.
- **Test notes.** Findings that need tests go back to T16/T17.
- **Observability.** Check that `account_delete_enqueue_failed`, job ERRORs and `reauth_required` spikes can be
  queried in Logs Explorer.
- **Budget.** Not applicable.

### T21 — Cost report + cost-model rows 35–36  [owner: sre-performance] [size: S] [depends: T16, T17] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.**
  - Replace cost-model rows 35–36 with the measured values and the ADR's job-state numbers.
  - Measure the time per invocation and find the account size at which the export needs more than one invocation
    (closes the T10 OPEN item).
  - Restate the Phase 1 crossover.
  - Confirm no fixed cost, and record Cloud Tasks pricing if option B was chosen.
- **Acceptance criteria.**
  - Given the report, then reads, writes and deletes at 300 DAU stay ≤ 80% of free *for this slice's share*.
  - Given the report, then the full-model crossover is restated.
  - Given the report, then every OPEN item in this plan's Cost section is resolved or carried as a named risk.
- **Test notes.** —
- **Observability.** Add a Logs Explorer query `jsonPayload.account_job!="" | sum fs_writes by step` to the dashboard
  notes.
- **Budget.** Not applicable.

### T22 — Runbooks: in-app first, manual fallback, new failure modes  [owner: production-deployer] [size: S] [depends: T12] [blocked: T1 accepted]
- **Status:** Partly done (2026-10-08): `docs/runbooks/account-deletion.md` section 6 covers the in-app flow, the C4 alert, stuck jobs, sign-up failures and exports. Still to do: the client-facing wording once T12 lands, and a drill record on dev.
- **Description.**
  - Rewrite `docs/runbooks/account-deletion.md`:
    - in-app is the primary path;
    - email requests are handled with `opsctl delete-account` / `export-account`;
    - keep the S2 repair section and the "one-way after the first purge" rule;
    - state the Q10 residue.
  - New failure-mode entries:
    - a job stuck or DLQ'd: find it, re-enqueue it, or finish it with opsctl;
    - an Auth delete failing;
    - an export stuck in PENDING;
    - `handle_owner_mismatch`.
- **Acceptance criteria.** Given a dev drill (T23) following the runbook, then it finishes in < 10 min of active work
  and the residue check passes.
- **Test notes.** Record the drill in the runbook (date, dev).
- **Observability.** —
- **Budget.** Drill ≈ tens of ops on dev.

### T23 — Dev deploy + drill  [owner: production-deployer] [size: S] [depends: T3a, T3b, T18, T22] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.**
  - Apply the dev Terraform and deploy to `dzeroth-dev` with the flag `on`.
  - Run the T18 smoke, one real signed-URL download, and one in-app deletion by a throwaway account.
  - Run the runbook drill.
- **Acceptance criteria.**
  - Given dev, then the smoke passes, the job completes within the NFR target, and there is 0 residue.
- **Test notes.** —
- **Observability.** Check that the startup log shows `feature_flags` with `account_lifecycle`.
- **Budget.** ≈ 100 ops.

### T24 — Release v0.4.0 readiness (flag off, then allowlist)  [owner: production-deployer] [size: M] [depends: T19, T20, T21, T23] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.**
  - Prepare the inputs for `docs/reviews/release-v0.4.0-readiness.md`: this plan's part of it.
  - production-reviewer must write `VERDICT: GO`.
  - Stage a `candidate` with `FEATURE_ACCOUNT_LIFECYCLE = allowlist` (the founder + 2 prod smoke accounts).
  - Smoke: run T18 on `candidate` with throwaway accounts.
  - Promote 10% → 100% traffic, asking the human before 100% and before any prod apply.
- **Acceptance criteria.**
  - Given the readiness doc, then `VERDICT: GO`.
  - Given the prod smoke, then the deletion completes and leaves 0 residue.
- **Test notes.** —
- **Observability.** The watch adds the `account_job` ERROR count and DLQ/queue depth.
- **Budget.** Smoke ≈ 60 ops.

### T25 — Flag rollout in prod: allowlist → 10% → on  [owner: production-deployer] [size: S] [depends: T24] [blocked: T1 accepted]
- **Status:** Open (T1 is Accepted; unblocked).
- **Description.** Run the flag stages below with the pinned-traffic env procedure, then reconcile Terraform. Write
  `docs/reviews/release-v0.4.0-postrelease.md` (this slice's section).
- **Acceptance criteria.**
  - Given each stage, then the rollback-trigger checks are recorded.
  - Given `on`, then `terraform plan` shows no drift.
- **Test notes.** —
- **Observability.** As T24.
- **Budget.** Not applicable.

---

## Rollout plan
- **Flag:** `FEATURE_ACCOUNT_LIFECYCLE` (server env var, mirrored through `GetMe.enabled_features` as
  `account_lifecycle`).
  - Defaults: **off** in prod, **on** in dev and local.
  - When off, the three RPCs return `FEATURE_DISABLED` at 0 reads, and the Settings entries are hidden. The manual
    email runbook (now driving `opsctl delete-account`) stays the path.
  - **The job handlers are never gated.** Turning the flag off never strands a DELETING account.
- **Stages:**
  1. dev `on` (T23);
  2. prod `candidate` with `allowlist`, then smoke, then traffic 10% → 100% (T24);
  3. flag allowlist (≥ 48 h) → `percent = 10` (≥ 72 h; deletions are rare, so wait for at least one real deletion
     or run a smoke deletion) → `on` (T25).
  4. Store submission follows `on`.
- **Rollback triggers (any one):**
  - any residue found by a smoke deletion or a reported deletion;
  - any message in the job DLQ, or a job without progress for > 1 h;
  - an Auth delete failure;
  - any `severity >= ERROR` from `account_job`;
  - a counter or edge invariant violation;
  - an export containing third-party data;
  - any budget alert.
- **Rollback actions (lightest first):**
  1. `FEATURE_ACCOUNT_LIFECYCLE = off` (in-flight jobs still complete; finish stuck ones with `opsctl delete-account`).
  2. Route traffic to the previous revision (before 100%).
  3. `DEGRADED_MODE = readonly`.

  Data needs no rollback: deletion is one-way by design (ADR-0009). A half-finished deletion is completed, never
  reverted.

## Risks
| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| Founder decision on T1 delays the store submission | Medium / high (M5 stays open) | Unblocked tickets (T2a, T4, T13–T15) proceed now; the ADR is the first ticket; the manual runbook keeps the web launch compliant |
| A job is DLQ'd or stuck, so the account sits in DELETING, unusable and not deleted | Medium / medium | Backstop sweep (option D), runbook entry, `opsctl delete-account` resumes from the saved state |
| One large deletion uses most of a day's free writes (≥ 17k writes with capped arrays) | Low at Stage 0 / cents | Pay-per-use (≈ $0.03); the ADR may choose to spread it across days; the 80% write alert is a planned signal |
| The export job exceeds one 30 s invocation for big accounts | Medium / low | Retries; T21 measures the threshold; a chunked composer is a follow-up if hit |
| A later slice ships a user-owned collection without an Eraser | Medium / high (privacy) | T11 guard fails `make ci` |
| The runtime SA's Firebase Auth admin role lets an RCE delete any user | Low / high | Narrowest role (T1), security review T20, no Auth admin call path reachable from public RPCs except via the DELETING job |
| A re-auth UX failure on web (popup blocked) prevents deletion | Medium / medium | Popup opened synchronously from the tap; `popup-blocked` shows the allow-pop-ups message; redirect fallback dropped (founder decision 2026-10-07); the email path stays documented in the app's privacy policy |
| Residue in `idempotency/*` or others' arrays is read as a privacy failure | Low / medium | Q10 allowlist in the ADR, the privacy policy and the runbook |
| A deletion racing in-flight writes recreates docs | Low / medium | 120 s gate after DELETING (ADR-0008 D10), the interceptor rejects DELETING, Erasers use `Exists` preconditions |
| Lifecycle edit (option A for D-B) deletes exports early or keeps uploads too long | Low / low | T3a acceptance test on dev |
