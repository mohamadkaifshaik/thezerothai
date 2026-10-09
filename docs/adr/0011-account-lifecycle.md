# 0011. Account lifecycle: deletion and export jobs, export storage, orchestrator placement
Status: Accepted
Date: 2026-10-07 (proposed and accepted)
Deciders: architect, founder (Kaif Mohamad Shaik). Founder decisions dated 2026-10-07, relayed to the architect by the
lead agent and recorded in §"Founder decisions (2026-10-07)". They answer every question in §"Founder questions". The
founder rejected the unrestricted form of the IAM grant and accepted it only with compensating controls (§"IAM").

Plan: `docs/plans/account-deletion-export.md` (P8, ticket T1). Builds on ADR-0003 ("Deletes & privacy" and the
2026-09-30 amendment), ADR-0007 (backups), ADR-0008 D10/D12, ADR-0009 (follow-edge invariant) and ADR-0010 (D5 A6, D19 Q-E).

## Context
- **Why now:** in-app account deletion is a store blocker (security audit M5), and DPDP/GDPR need erasure and access.
  The founder decided deletion is immediate and irreversible (phase1 D5). Today it is a manual runbook
  (`docs/runbooks/account-deletion.md`) driving `opsctl purge-posts` and `purge-graph`.
- **Stage 0.** 0 to ~300 DAU, $0/month. There are no live usage numbers yet, so every figure below is from the plan's
  formulas (derived from `graph/purge.go` and `posts/purge.go`), not from measurement.
- **What exists:**
  - `posts.Eraser` and `graph.Eraser`: resumable, bounded batches of ≤ 500 ops, `Exists` preconditions, so two
    concurrent runs never decrement a counter twice;
  - `graph.ExportUser` (returns a struct) and `posts.Exporter` (streams to an `io.Writer`);
  - the opsctl `checkStartGate` (120 s after DELETING, ADR-0008 D10) and `purgeLoop`;
  - the OIDC verifier for `/internal/*`, still wired to a 202 placeholder (`apiserver.go:221`);
  - the `modules/pubsub` topic set. Envs use the module default: `media-processing` and `notifications-fanout`. Every
    topic gets a DLQ, `ack_deadline_seconds = 30`, backoff 10–600 s and `max_delivery_attempts = 5`;
  - one Cloud Scheduler job, `daily-maintenance` (prod only; 1 of the 3 per billing account);
  - one private bucket, `<proj>-media-upload`. It deletes every object at age 2 days and allows only PUT through CORS.
- **Constraints for any job design:**
  - Cloud Run's request timeout is 30 s, and with `cpu_idle = true` no work runs after the response. So a job does
    its work in ≤ 25 s HTTP invocations.
  - Erasers must start ≥ 120 s after `DELETING` is committed (ADR-0008 D10).
  - Delivery is at least once: two concurrent deliveries and a crash after any step must both converge.
  - A reference deletion (P = 300 posts, O = I = 100) needs about 7 eraser calls (posts 1, graph 5, identity 1) plus
    2 Auth calls. One invocation fits them. A maximum-size account (O = 5,000, B = 2,000, Bb = 10,000, large I and P)
    needs about 60–100 calls, so 3–8 invocations.

## Options

### D-A. Job orchestration mechanism
All four options share the same orchestrator (D-C), state model and handler. They differ only in how the next
invocation is triggered.

**Shared job-state model (recommended for every option):**
- **Deletion state lives on `users/{uid}`**, not in a new collection:
  - fields `deletionRequestedAt` and `deletionJob {seq, step, checkpoint (opaque bytes), progressAt}`;
  - the doc is DELETING and the interceptor rejects the user, so it has no other writer of its own (counter
    decrements from other purges are ≤ 1 write/s);
  - the doc is deleted **last**, so it stays the marker the backstop (D-A option D) can find until every other trace
    is gone.
  - The rejected alternative was a new `accountJobs/{uid}` collection. It costs +1 write and +1 delete per deletion,
    and it would be one more collection to erase, TTL and guard.
- **Export state lives on `exports/{exportId}`** (`status` PENDING/READY/FAILED). It already exists in ADR-0003.
- **The start-gate clock is `deletionRequestedAt`**, not `updatedAt`. Checkpoint writes and `identity.Counters`
  increments must not move the gate. opsctl falls back to `updatedAt` for accounts set to DELETING by hand.
- **Per invocation:** 1 job-state read (`users/{uid}`; it also serves the gate and the identity step's `handleLower`)
  and 1 checkpoint write, except on the last invocation, whose final `users/{uid}` delete replaces it.
- **Dedupe:**
  - Every message or task carries `seq`. The handler acts only when `msg.seq == deletionJob.seq`.
  - It saves `seq + 1` with an `UpdateTime` precondition from its own read, so of two concurrent same-seq deliveries
    exactly one wins. The loser acks and does nothing else; its eraser work was precondition-safe.
  - A redelivered `seq == state.seq − 1` means the state was saved but the continuation may not have been
    published. The handler re-publishes `state.seq` and acks.
  - Anything older is acked and dropped (1 read, 0 writes).

#### A. Pub/Sub push, self-chaining
- **How it works:**
  - DeleteAccount commits DELETING, then publishes `{kind: account_delete, uid, seq: 0}`.
  - Each delivery runs the orchestrator for ≤ 20 s, saves the state, publishes `seq + 1` unless done, and returns 2xx.
  - Exports: RequestAccountExport publishes `{kind: account_export, exportId}`. One delivery composes the file and
    sets READY. A redelivery that finds status ≠ PENDING acks at 1 read and 0 writes.
- **The start gate:**
  - A delivery before 120 s does the Auth disable and token revoke (idempotent, 0 Firestore ops) and then **nacks with
    HTTP 429**. 429 is not 5xx, so it doesn't pollute the error charts, and it is logged INFO `outcome=gated`.
  - The subscription's `minimum_backoff = 60s` brings the next delivery ≥ 60 s later. With exponential growth
    (60 s, then about 120 s), the gate passes on delivery 2 or 3.
  - `max_delivery_attempts` is raised to 10, so at most 2 gated nacks leave ≥ 7 attempts for real errors (about
    55 minutes of retries at the 600 s cap) before the DLQ.
- **Topic:** the shared `jobs` topic recommended by `phase1.md` §7 (typed messages, push path
  `/internal/pubsub/jobs`), so P2's snapshot-refresh job reuses it.
- **Terraform:**
  - `modules/pubsub` gets optional per-topic `minimum_backoff` and `max_delivery_attempts` fields, defaulting to
    today's values;
  - add `jobs` to both envs' `topics`. That is 3 resources + 2 IAM members, created by the existing `for_each`;
  - no new API.
- **Pros:**
  - It is the async mechanism CLAUDE.md already names ("Pub/Sub push to `api` `/internal/*`").
  - The Firebase Emulator Suite emulates Pub/Sub, so the T16 chain tests run locally.
  - The publisher role is already on the runtime SA.
- **Cons:**
  - There is no delayed delivery, so the gate costs 1–2 nacks.
  - The 10-attempt DLQ is a cliff: after it, a job sits in the DLQ until a human or a backstop acts.
  - Committing and then publishing is not atomic. A crash between them strands a DELETING account unless something
    re-enqueues it.
  - Push subscriptions slow delivery after nacks for the whole subscription. That is irrelevant at Stage 0 volumes,
    but it is shared with other `jobs` kinds.
- **Cost:**
  - Idle: $0.
  - 300 DAU (≈ 9 deletions + 9 exports/month, about 3 + 1 deliveries each): ≈ 40 messages, billed at the 1 KB minimum
    on publish and on delivery, so ≈ 80 KB/month of 10 GiB. $0.
  - 3k DAU: ≈ 800 KB/month. $0.
  - Topic retention (1 day) and DLQ retention (7 days) storage is $0.27/GiB-month on KB. $0.00.

#### B. Cloud Tasks queue
- **How it works:**
  - DeleteAccount creates an HTTP task with `schedule_time = deletionRequestedAt + 120 s` and an OIDC token for the
    `pubsub-push` SA. The task name is `del-<hash(uid)>-<seq>`, so a re-enqueue of the same seq is deduped by Cloud
    Tasks (`ALREADY_EXISTS`).
  - Each invocation enqueues the next seq.
  - Exports create a task with no delay.
- **Terraform and code:**
  - enable `cloudtasks.googleapis.com` (a **new GCP API**);
  - `google_cloud_tasks_queue` in `asia-south1`: `max_concurrent_dispatches = 1`, `max_attempts = -1` (unlimited) or
    100, backoff 10–600 s;
  - `roles/cloudtasks.enqueuer` (queue-level) for the runtime SA;
  - `roles/iam.serviceAccountUser` on the `pubsub-push` SA for the runtime SA, so it can mint task OIDC tokens. This
    broadens the runtime SA, which can then call `/internal/*` as the push identity;
  - a new Go dependency (`cloud.google.com/go/cloudtasks`).
- **Pros:**
  - The 120 s gate is native, so there are no gated nacks.
  - Retries can be unlimited, with no DLQ cliff.
  - Queue concurrency 1 means two deliveries of the same job never run concurrently.
  - Named tasks dedupe enqueues.
- **Cons:**
  - It is a **deviation from CLAUDE.md's reference architecture** ("Async work: Pub/Sub push"), so it needs a
    CLAUDE.md amendment, which is the founder's call.
  - The Firebase Emulator Suite has no Cloud Tasks emulator. T16 would run against a fake transport, and the real
    path would be tested only on dev.
  - It still needs a backstop for the commit → enqueue gap.
  - It adds one more service to verify each quarter.
- **Cost** (verified 2026-10-07, cloud.google.com/tasks/pricing):
  - First **1,000,000 billable operations per month per billing account free**, then **$0.40 per million**. A billable
    operation is an API call or a push delivery attempt, chunked at 32 KB. There is no fixed fee and no per-queue fee.
  - Idle: $0.
  - 300 DAU: about 4 creates + 4 attempts per job × 18 jobs ≈ 150 ops/month (0.015% of free). $0.
  - 3k DAU: ≈ 1,500 ops. $0.

#### C. Scheduler sweep only
- **How it works:**
  - DeleteAccount only sets DELETING. RequestAccountExport only creates a PENDING doc.
  - The existing `daily-maintenance` run (03:00 UTC, prod) processes DELETING users and PENDING exports within one
    30 s request.
- **Pros:** 0 new resources, no transport code, no dedupe beyond the precondition.
- **Cons:**
  - Deletion takes up to 24 h, and a maximum-size account takes several days.
  - An export takes up to 24 h, which misses the plan's 5-minute NFR and makes "Download my data" poor UX.
  - Dev has no Scheduler job (the 3-job limit is per billing account), so every dev test needs a manual trigger.
  - A user who is DELETING but not yet erased stays visible in other users' follower lists for up to a day.
- **Cost:** idle $0. At 300 DAU and at 3k DAU: 1 request/day plus the job's own Firestore ops. $0.

#### D. Hybrid: A or B for the fast path, plus C as a backstop
- **The backstop:** `daily-maintenance` runs two queries:
  - `users where status == DELETING` with `Limit(50)`, filtering in memory for `deletionJob.progressAt` older than 1 h;
  - `exports where status == PENDING` with `Limit(50)`, filtering in memory for `createdAt` older than 1 h.

  It then re-publishes or re-enqueues the stored seq, which the dedupe makes harmless. An export still PENDING after
  24 h is set to FAILED instead, and the user can request again.
- **Indexes:** both queries use the automatic single-field indexes (`users.status` and `exports.status` are not
  exempted in `firestore.indexes.json`), so **no index change** is needed.
- **What it recovers:**
  - the commit → enqueue gap;
  - a job that went to the DLQ (A) or exhausted its retries (B);
  - a deploy that lost a message.
- **Cost:** A or B's cost, plus 2 reads/day when nothing is stuck. 0 new resources: it reuses `daily-maintenance`,
  which T8 turns from a placeholder into a small dispatcher.
- **Dev:** trigger the sweep by hand (`opsctl` or an authenticated curl), as for any other cron path in dev.

### D-B. Export storage
The proto promises a 7-day lifetime (`identity.proto:230`). The only private bucket deletes everything after 2 days.

#### A. Prefix-scoped lifecycle in `<proj>-media-upload`
- **Changes:**
  - narrow the 2-day rule with `matches_prefix` to the upload prefix, which P4 then has to fix now (for example
    `u/`);
  - add an `age = 7` rule on `exports/`;
  - `EXPORT_BUCKET` and `EXPORT_PREFIX` env vars.
- **Pros:** no new bucket; the runtime SA is already `objectAdmin` there.
- **Cons:**
  - Export retention is coupled to media staging.
  - A mis-scoped rule either deletes exports after 2 days or keeps abandoned uploads for 7 days.
  - P4 has to commit to its object layout before its ADR exists.
  - The bucket is the target of client-signed PUTs. The URLs are path-scoped, but it is the one bucket clients
    write into.
- **Cost:** $0. KB–MB objects for ≤ 7 days inside the 5 GB-month free tier; 1 Class A per export; 1–2 Class B per
  download; lifecycle and API deletes are free.

#### B. A third private bucket, `<proj>-exports` (us-central1)
- **Configuration:** `public_access_prevention = enforced`, uniform access, an `age = 7` Delete lifecycle, no CORS
  (the client opens the signed URL with `url_launcher` and never uses XHR, T15), and `roles/storage.objectAdmin` for
  the runtime SA only.
- **Pros:**
  - Isolated IAM and lifecycle; nothing P4 does can change export retention.
  - `firebase/storage.rules` only grants on `.*-media$`, so this name never matches.
- **Cons:** one more bucket and IAM member, and the `EXPORT_BUCKET` env var.
- **Cost:**
  - $0. The GCS free tier is per billing account across US-region buckets, so a third bucket adds nothing fixed.
    Same operation counts as option A.
  - `cost-guard` does not list `google_storage_bucket` (checked in `.claude/hooks/cost-guard.sh`).

**Both options:**
- Lifecycle deletion is asynchronous, so GetAccountExport enforces `now ≥ expireAt` itself (Q6).
- Writing from Cloud Run in `asia-south1` to a `us-central1` bucket is inter-region transfer, at about $0.08/GB upper
  bound. A reference export is ≈ 0.5 MB, so at 3k DAU that is ≈ 45 MB/month, or < $0.01.

### D-C. Orchestrator placement
`graph/purge.go` and `graph/api.go` import `internal/identity`, and `graph.Eraser` takes a `graph.Checkpoint`. So
identity can't name `graph.Eraser` without an import cycle.

#### A. In `identity`, with consumer-side interfaces and adapters in `apiserver` (the `BlockChecker` pattern)
- **Interfaces:** identity declares
  - `StepEraser { Name() string; Run(ctx, uid string, checkpoint []byte) (next []byte, done bool, err error) }`;
  - `ExportSection { Name() string; WriteSection(ctx, uid string, w io.Writer) error }`.
- **Adapters:** a small `apiserver/lifecycle_wiring.go` holds the adapters that JSON-encode `posts.Checkpoint` and
  `graph.Checkpoint`. `cmd/opsctl` uses the same constructor.
- **Moves:** `checkStartGate` becomes an identity function (`identity.StartGate(profile, now) (wait time.Duration,
  err error)`). opsctl calls it, so there is no copy.
- **Pros:**
  - It matches ADR-0008 D10 ("the orchestrator stays in identity").
  - It needs no new module.
  - identity imports nothing from graph or posts.
- **Cons:** identity grows a lifecycle file and two interfaces.
- **Cost:** none.

#### B. A new package outside the module list (for example `internal/accountlifecycle`)
- **Pros:** a cleaner name, and identity stays focused on profiles.
- **Cons:** it amends CLAUDE.md's module list (founder), and it adds a top-level owner for a single feature.
- **Cost:** none.

**The step registry (either option):**
- Steps are ordered by explicit position constants. Later slices call `Register(name, BeforeIdentity, step)`;
  registering at or after identity is a startup error.
- The time budget per invocation is 20 s. After 5 consecutive errors on one step the invocation fails (opsctl's
  policy, moved here).
- Every step is charged to a `budget.Counter`.

### D-D. Exporter section interface and envelope
- **One streaming interface**, `ExportSection.WriteSection(ctx, uid, w)`, which writes exactly one JSON value.
  - Streaming suits unbounded P without buffering in a 512 MiB instance.
  - `posts.Exporter` already has this shape. `graph.ExportUser` is wrapped by an adapter that JSON-encodes its struct.
- **The composer** streams the envelope to a GCS object writer in this order:
  `{"exportVersion":1,"generatedAt":…,"account":…,"profile":…,"graph":…,"posts":…, <later sections>}`.
  - `account`: the Firebase Auth record (email, providers, `createdAt`, `lastSignInAt`).
  - `profile`: user-facing fields only, never `status`, `snapshotVersion` or `deletionJob`.
  - `graph`: never `blockedBy` (ADR-0008 D12).
- **Retries:** a retry overwrites the same `objectPath`, so a crash mid-write leaves at most one complete object
  after the retry.

## Q1–Q10 (plan defaults)
| # | Decision | Notes |
|---|---|---|
| Q1 Erase order | **Default accepted (posts → graph), with one change at the end.** Full order: (1) Auth disable + revoke refresh tokens; (2) `posts.Eraser`; (3) `graph.Eraser`; (4) later-slice steps; (5) identity step: `exports` objects then docs, `users/{uid}/private/*`, `handles/{h}` (owner-checked), `quotas/{uid}`; (6) **Auth `DeleteUser`**; (7) **`users/{uid}` last**. | **Changed vs plan:** the plan deleted `users/{uid}` before the Auth user. Deleting it last keeps the DELETING marker (and the job state) until the Auth record, which holds the email, is gone. The backstop can therefore always find an unfinished deletion. ADR-0009's rule (`users/{uid}` only after 0/0 edges) still holds |
| Q2 Replay vs interceptor | **Default accepted, plus one rule.** `AccountStatusInterceptor` lets a DELETING (and SUSPENDED, Q3) caller through to `IdentityService/DeleteAccount` only, from one exported set covered by the guard test. A DELETING caller gets the stored `deletion_requested_at` with 0 Firestore writes, **and the replay re-publishes the current `deletionJob.seq`** (deduped), so a client retry also recovers an enqueue failure | Recent sign-in is still required on replay (T4 runs first) |
| Q3 SUSPENDED can delete | **Default accepted, founder-confirmed 2026-10-07** (right to erasure; the P7 report snapshot keeps the evidence, D4). A SUSPENDED caller passes the same checks as an ACTIVE one: recent sign-in, and the token's own uid only | The interceptor exemption is DeleteAccount only; every other RPC still rejects SUSPENDED |
| Q4 Auth disable timing | **Default accepted.** Job step 1. Under D-A option A it runs on the first, gated delivery, so the account is disabled within seconds, not after 120 s. DeleteAccount stays 1 Firestore write | Existing ID tokens remain valid up to 1 h; the interceptor rejects them |
| Q5 Stale sign-in reason | **Default accepted and done** (T2a: `ERROR_REASON_REAUTH_REQUIRED = 15`, FAILED_PRECONDITION) | |
| Q6 Export after expiry | **Default accepted.** NOT_FOUND once `now ≥ expireAt`, byte-identical to an unknown or foreign id; no enum change | |
| Q7 Apple token revocation | **Default accepted, OPEN for T20.** The client revokes with `revokeTokenWithAuthorizationCode` after an Apple re-auth (T13: iOS/macOS). Fallback if T20 finds this insufficient: a server-side call to Apple's REST revoke, with the Apple key in Secret Manager (1 version, within the 6 free) | Needs its own small amendment if used |
| Q8 Degraded mode | **Default accepted.** The two mutating RPCs are rejected under `readonly`. `/internal/*` job handlers ignore `DEGRADED_MODE`, so started jobs finish within the privacy policy's 30 days | A maximum-size deletion is ≈ 17k writes, bounded and pay-per-use |
| Q9 Flag scope | **Default accepted.** One flag, `FEATURE_ACCOUNT_LIFECYCLE`. Job handlers and the backstop are never gated | |
| Q10 Residue allowlist | **Default accepted, plus 2 entries.** (a) `idempotency/*` `uid` until its 24 h TTL; (b) other users' `muted[]`/`blocked[]` (lazy clean-up, ADR-0008 T27); (c) mentions in others' posts (runbook §3b, P6 ADR); (d) prod backups ≤ 14 days (ADR-0007); **(e) the raw uid in Pub/Sub job messages: ≤ 1 day in topic retention, ≤ 7 days in the DLQ** (or Cloud Tasks task bodies until they run); **(f) Firebase Crashlytics and Analytics data keyed to the device, not the uid** (T20 verifies that the app never sets a user identifier) | Founder-accepted 2026-10-07; published in `app/web/privacy.html` ("When your account is deleted"). Logs never hold a raw uid (`uid_hash` only) or the download URL. Everything else found by the T11 sweep is a defect. A new entry needs an ADR amendment **and** a policy update in the same PR |

## IAM
**The role (the narrowest Auth role):**
- Use a project **custom role** `accountLifecycleAuth` with only `firebaseauth.users.get`, `firebaseauth.users.update`
  (disable, revoke) and `firebaseauth.users.delete`, granted to the runtime SA.
- The predefined `roles/firebaseauth.admin` also grants `configs.*` (including `configs.getSecret`), `users.create`,
  `users.createSession` and `users.sendEmail`, so it is rejected.
- Custom roles are free. T3a verifies the three permissions on dev against the Admin SDK calls.

**The founder's condition (2026-10-07).** The founder **rejected an unrestricted runtime permission to disable or delete
any Firebase Auth user**. IAM can't scope `firebaseauth.users.*` to one user, so the custom role is accepted only
together with four compensating controls. All four are part of this decision; T7 and T3a are not done without them.

- **C1. Only the authenticated caller's own uid can be mutated.**
  - The only API path that starts a deletion is DeleteAccount. It sets `DELETING` on the **token's** uid. There is no
    uid field in `DeleteAccountRequest`, and none may ever be added.
  - The job never acts on a message's word. The message `uid` is only a lookup key. Before any Auth mutation, the
    invocation reads `users/{uid}` fresh (the job-state read it already does) and requires `status == DELETING` and
    a set `deletionRequestedAt`. Otherwise it refuses: 0 Auth calls, ERROR `auth_admin_refused`, ack.
  - So every Auth mutation traces back to an authenticated DeleteAccount by that same uid. The one exception is
    `opsctl delete-account`, which runs with the founder's own credentials (not the runtime SA) for email requests.
  - `users.get` (the export's `account` section) follows the same rule: only for the `uid` on an `exports` doc that
    RequestAccountExport created for the authenticated caller. **Amended 2026-10-08 (M2):** `get` is also allowed for
    the caller's own token uid at the CreateProfile boundary (see the M2 amendment below).
- **C2. One dedicated, narrow Auth-admin wrapper.**
  - `internal/identity/authadmin.go` holds an **unexported** wrapper with exactly four operations:
    `disableAndRevoke`, `deleteUser`, `getUserRecord` and (M2, 2026-10-08) `checkSignup`. Each takes a target type that
    only identity can construct, and only from the fresh `users`/`exports` read in C1 (or, for `checkSignup`, the
    verified token's own uid). No method takes a bare uid string.
  - The Firebase `*auth.Client` is built in `apiserver.Build` and passed **only** to identity's constructor, behind a
    four-method interface (`GetUser`, `UpdateUser`, `RevokeRefreshTokens`, `DeleteUser`).
  - A CI guard test fails if any other package outside `cmd/opsctl` calls those four methods. `pkg/platform/authn`
    keeps token verification only (`VerifyIDToken`), which needs no IAM permission.
- **C3. One audit log line per Auth call.**
  - Severity NOTICE, after the call returns:
    `auth_admin_op = disable_revoke|delete|get`, `outcome = ok|not_found|error|refused` (plus `disabled` for the M2
    sign-up check), `uid_hash`, `account_job = delete|export|signup`, `seq`, `actor = job|opsctl|caller`, `trace`.
  - Never a raw uid, email or provider data (the Q10 logging rule).
  - A refusal (C1) is ERROR `auth_admin_refused` (logged through `mw.ReportError`, severity ERROR, with
    `outcome = refused`), so Error Reporting emails the founder at $0. The M2 sign-up refusals (deleted or disabled
    user) are expected user behaviour, not C1 refusals: they are NOTICE with outcome `not_found`/`disabled`.
- **C4. A log-based alert on unexpected volume.**
  - A user-defined, label-free log-based counter metric `auth_admin_mutations` that counts only successful Auth
    deletes (`jsonPayload.auth_admin_op="delete" AND jsonPayload.outcome="ok"`: exactly one per deletion;
    `disable_revoke` repeats on every gated delivery, a `not_found`/`error` delete is not a mutation, and `get` is
    read-only, so all three are excluded) plus C1 refusals (`severity=ERROR AND jsonPayload.outcome="refused"`).
    Amended 2026-10-08: the filter was `auth_admin_op="delete"` alone, which also counted failed deletes and retries.
  - **One** alert policy: the sum over a rolling 1 h > `auth_admin_alert_per_hour` (Terraform variable, default
    **5**; amended 2026-10-08 from 10 after the audit found the original filter over-counted ~3-4 events per
    deletion), email to the founders. The expected rate is about 9 deletions per month, so 5 in an hour is abnormal
    at Stage 0.
  - The runbook (T22) entry for this alert: set `FEATURE_ACCOUNT_LIFECYCLE = off`, remove the custom-role binding
    (stops all Auth mutations at once), then investigate.
- **What the controls do not cover.** C1–C3 bind our code, not a stolen runtime SA token or code execution inside the
  container. Such an attacker can call the Auth API directly and skip our log line. Identity Platform logs
  `DeleteAccount`/`SetAccountInfo` as **Data Access** (`DATA_WRITE`) audit logs on `identitytoolkit.googleapis.com`,
  which are off by default. Turning them on would give an alert source that the attacker can't skip, but it also logs
  end-user sign-in calls (more PII in logs). T20 decides; it is not enabled by this ADR.
- **Cost of the controls:**
  - C1–C3: $0 (code and logs; a few hundred bytes per call).
  - C4 is the **only recurring charge in this ADR**:
    - Cloud Monitoring bills alerting policies (from no sooner than 1 May 2026). The pricing examples page lists
      **$0.35 per metric reference per month** plus **$0.50 per million points returned**. A secondary source quoted
      $0.10 per condition per month. We plan with the higher figure.
    - 1 condition × 1 time series, evaluated about every 30 s ≈ 86k points/month ≈ $0.04.
    - The log-based metric falls in the Monitoring chargeable-metric free allotment (150 MiB per billing account per
      month); one label-free series is KB/month, so $0.
    - **Total ≈ $0.40/month**, independent of DAU, **prod only** (founder, 2026-10-08). The alert policy is created
      only where `enable_auth_admin_alert = true` (prod); dev has no alert and relies on log inspection of the C3
      audit lines. The free log-based metric exists in both envs. The founder asked for this alert, so its fixed fee
      is accepted here. T3a confirms the current price on the pricing page before apply.

## Budget (free-tier-budget §2)
Notation as in the plan: P posts, O following, I followers, B blocked, Bb blockedBy, E export docs.
- **D** = deliveries per deletion. With A it is 1–2 gated deliveries + W work invocations; with B it is W.
- **W** = work invocations: 1 for the reference account, about 3–8 at maximum size.

| RPC / job | Firestore reads | writes | deletes | Cloud Run req / vCPU-s | calls/DAU/day |
|---|---|---|---|---|---|
| DeleteAccount (sync) | 2 cold / 1 warm (interceptor + fresh `users` in the txn) | **1** (`status`, `updatedAt`, `deletionRequestedAt`, `deletionJob{seq:0}` in one update; no job doc) | 0 | 1 / < 0.2 | 0.001 |
| ↳ replay (already DELETING) | 2 / 1 | 0 (+1 publish) | 0 | 1 | — |
| `account-delete` job | P + O + I + 2·⌈(max(B,Bb)+1)/500⌉ + 2 + ≤ 3 + 2 (identity: `handles`, `private/*`) + max(E, 1) (`exports` query; the identity step's `users` read is the job-state read) + **D** (job-state) | O + 2I + B + Bb + **(W − 1)** checkpoints | P + O + I + 1 + 3 + E | D / ≤ 20 per work invocation | 0.001 |
| ↳ reference (P 300, O = I = 100, E 1) | **≈ 510** (A: D = 3) / ≈ 508 (B: D = 1) | **300** (W = 1) | **505** | 3 / ≈ 10 | 0.001 |
| RequestAccountExport | 2 / 1 | 2 (`exports` + `quotas`) | 0 (+1 TTL delete after 7 days) | 1 | 0.001 |
| `account-export` job (1 invocation) | 1 (`users`) + 1 (`exports`, = job state) + (P or 1) + (O or 1) + (I or 1) + 1 + distinct handles | 2 (lease claim, `status`; L-4 amendment) | 0 | 1 / ≤ 20 | 0.001 |
| ↳ reference | **≈ 703** | 1 | 0 | 1 | 0.001 |
| GetAccountExport | 2 / 1 | 0 | 0 | 1 (+ `signBlob`) | 0.003 |
| Backstop sweep (D) | 2/day when nothing is stuck (+1 per stuck doc, <= 400; L-6 amendment) | 0 | 0 | shares the 1 daily cron request | — |

**Per DAU and against the free quota:**

| Quota | Per DAU/day | 300 DAU | % of free | 3k DAU | DAU at which this slice alone would use the quota |
|---|---|---|---|---|---|
| Firestore reads (50k/day) | ≈ 1.22 | ≈ 370 | 0.7% | ≈ 3,660 | ≈ 41k |
| Firestore writes (20k/day) | ≈ 0.31 | ≈ 93 | 0.5% | ≈ 930 | ≈ 64k |
| Firestore deletes (20k/day) | ≈ 0.51 | ≈ 153 | 0.8% | ≈ 1,530 | ≈ 39k |
| Cloud Run requests (2M/month) | ≈ 0.009 (RPCs + job deliveries) | ≈ 80/month | < 0.01% | ≈ 800/month | ≫ 1M |
| Cloud Run vCPU-s (180k/month) | ≈ 0.03 (≈ 10 per deletion, ≤ 20 per export) | ≈ 270/month | 0.15% | ≈ 2,700/month | ≫ 100k |
| Pub/Sub (10 GiB/month), A or D | ≈ 2 KB per delivery | ≈ 80 KB/month | ≈ 0% | ≈ 0.8 MB | never in practice |
| Cloud Tasks (1M ops/month), B only | ≈ 8 ops per job | ≈ 150/month | 0.015% | ≈ 1,500 | ≫ 1M |
| GCS (5 GB, 5k A, 50k B) | 1 A per export, 1–2 B per download, ≤ 7 days of MB | ≈ 9 A, ≈ 20 B | < 0.2% | ≈ 90 A | ≫ 100k |

**When the full model leaves the free tier:**
- The binding quota is Firestore reads, at the full-model crossover of **≈ 233 DAU** (`phase1.md` §5). This slice moves
  it by < 2 DAU.
- This slice's own overage share, at the cost-model §7 upper-bound prices:
  - at 2× the crossover (≈ 470 DAU): ≈ 17k reads, 4.4k writes and 7.2k deletes per month ≈ **$0.02/month**;
  - at 10× (≈ 2,330 DAU): ≈ 85k reads, 22k writes and 36k deletes per month ≈ **$0.10/month**;
  - at 3k DAU: ≈ **$0.13/month**.
- The transport is $0 in every option at all three sizes.

**One maximum-size deletion:**
- It costs ≥ 17,000 writes + 2I. That is 85% of one day's free writes, so it is billed overage the day it runs:
  ≈ $0.03 at $0.18/100k.
- **Recommendation:** no rate shaping at Stage 0. Spreading the work across days would add a state machine and delay
  erasure for cents.
- Revisit if the 80% write alert fires because of deletions.

## Cost impact
- **Fixed monthly cost added:**
  - **$0** for every transport and storage option. No `cost-approved` marker is needed (`cost-guard` lists neither
    `google_storage_bucket` nor the Pub/Sub resources).
  - **≈ $0.40/month total, prod only,** for the one alert policy of IAM control C4, at the planning price above (dev
    has no alert policy, so it is not doubled). The founder asked for it (2026-10-07) and limited it to prod
    (2026-10-08). `cost-guard` doesn't list `google_monitoring_alert_policy`; the T3a resource still carries the
    comment `# cost-approved: ADR-0011` so the fee is traceable.
- **Free-tier quota consumed at 300 DAU:** < 1% of Firestore reads, writes and deletes; < 0.2% of GCS operations;
  ≈ 0% of Pub/Sub.
- **New services:**
  - none for D-A options A, C or D-with-A;
  - Cloud Tasks for options B and D-with-B (1M ops/month free, then $0.40/M; verified 2026-10-07).
- **New Terraform resources (recommended set):**
  - the `jobs` topic, its DLQ, its push subscription and 2 IAM members (the existing module);
  - a per-topic retry override (a module variable);
  - the `<proj>-exports` bucket and 1 IAM member;
  - 1 custom IAM role and 1 binding;
  - 1 log-based metric and 1 alert policy (IAM control C4).
- **Trigger that justifies it:** none is needed; there is no fixed fee. For a later move to a dedicated worker or
  Workflows, the trigger is a deletion that needs more than 50 invocations, or a sustained DLQ (`free-tier-budget` §6:
  measured, via ADR).

## Founder decisions (2026-10-07)
| Question | Founder decision |
|---|---|
| 1. D-A | **Option D with Pub/Sub**: self-chaining on the shared `jobs` topic plus the daily backstop. **No Cloud Tasks.** CLAUDE.md's "Async work" line already names Pub/Sub push to `/internal/*`, so it needs no change |
| 2. D-B | **Option B**: a separate private bucket `<proj>-exports`. P4's upload bucket and its prefixes are **not** changed |
| 3. D-C | **Option A**: the orchestrator stays in `identity`. No `accountlifecycle` module; CLAUDE.md's module list is unchanged |
| 4. Q3 | **Yes**: a SUSPENDED user may delete their own account, after the same auth and ownership checks (recent sign-in, token uid only) |
| 5. Q10 | **Accepted**, including additions (e) and (f). The retained-data list must be in the Privacy Policy (`app/web/privacy.html`) |
| 6. IAM | **The unrestricted form is rejected.** The custom role (`firebaseauth.users.get/update/delete` only) is accepted **with** the compensating controls C1–C4 in §"IAM" |
| 7. Cost | **Accepted**: ≈ $0.03 of pay-per-use writes per maximum-size deletion. No spreading across days |

**Founder confirmation, 2026-10-08:** ADR-0011 is Accepted as decided (T3a/T3b/T5 may merge), and the C4 alert
(>5 Auth delete/refusal events/hour, ≈ $0.40/month total, the first recurring fee) is explicitly approved. **Amended
2026-10-08:** the alert policy exists in **prod only** (`enable_auth_admin_alert`: dev false, prod true), so the total is
≈ $0.40/month; dev has no alert and relies on log inspection. The exports bucket also disables GCS soft delete
(`retention_duration_seconds = 0`) so deleted export objects (full PII) are not recoverable for 7 days.

## Amendment 2026-10-08 (M2): CreateProfile must check the Auth user
**Problem.** The ID-token verifier (`pkg/platform/authn/firebase.go`) does not check revocation or deletion outside the
emulators (that would cost an Auth call per request). `CreateProfile` is profile-exempt. So after Q1 deletes the Auth
user and `users/{uid}`, the deleted user's still-valid token (up to ~50 min) can call `CreateProfile` and recreate an
orphan ACTIVE profile and handle. A SUSPENDED user can do the same to shed the suspension, and a second device holding a
fresh token hits it without malice.

**Decision (founder, option (a)): enforce authorization at the CreateProfile boundary.**
- Only on the not-found path (`users/{uid}` does not exist) and before any create, `CreateProfile` reads the caller's
  own Auth record through the audited wrapper (`authAdmin.checkSignup`, a new `signupTarget` built from the verified
  token uid only, never request data). A missing or disabled Auth user is refused with PERMISSION_DENIED and the same
  stable message for both ("this account cannot be used to sign up", no uid). Any other failure (outage, timeout) fails
  closed as UNAVAILABLE (retryable); nothing is written in either case.
- The check runs inside the existing profile transaction, right after its `users/{uid}` read, so it adds **0 Firestore
  operations**. An idempotent replay (profile exists) never reaches it: **0 Auth calls**. A refused or failed attempt
  rolls the transaction back.
- **C1 change:** `get` is allowed for the caller's own token uid on this path. **No IAM change:** `firebaseauth.users.get`
  is already in the custom role. C2 holds (the call lives in `authadmin.go`; `TestAuthAdminConfinement` now expects
  `authAdminClient` handed to identity twice: `WithSignupAuth` and `NewLifecycle`). C3: one NOTICE line per check
  (`auth_admin_op=get`, `account_job=signup`, `actor=caller`, `outcome=ok|not_found|disabled|error`, `uid_hash`).
  C4 is unaffected (see its amended filter, which excludes `get`).
- **Cost:** 1 `users.get` per real sign-up (only when the profile does not exist), within the Identity Toolkit free
  quota; 0 extra Firestore reads/writes; a 3 s deadline on the call.

**Why not a tombstone (option (b)).** A `deleted/{uidHash}` marker written at the end of deletion would also block the
token, but it adds a write and a read per sign-up, a new collection with its own retention and right-to-delete question,
and a second source of truth for "this uid is gone". The security-auditor preferred (b); the founder chose (a) because
Auth is already the source of truth for the uid's existence and disabled state, it needs no new collection, and it also
covers the SUSPENDED/disabled case with no extra state. Residual: while Auth is down, new sign-ups return UNAVAILABLE
(existing users are unaffected).

## Amendment 2026-10-08 (L-4, L-6): export lease, ordered backstop scans
Closes the two Low findings of `docs/reviews/security-review-account-lifecycle.md`. No new resource and no change to the
proto or to Q1-Q10. **Cost: none** (the new composite indexes store a few bytes per `DELETING` user and `PENDING`
export; the one added write per export is inside the free quota).

**L-4. One delivery composes an export.**
- `exports/{id}` gets an optional `leaseUntil` (timestamp). Before streaming, the delivery writes `leaseUntil = now + 35 s`
  with a `LastUpdateTime` precondition (the claim). The status **stays PENDING**, so `GetAccountExport`, the proto
  status mapping, `exportTarget`, the identity step and both backstop queries are unchanged, and the byte-identical
  NOT_FOUND (Q6) is untouched. Chosen over a PENDING to RUNNING status because that would need a new enum mapping and
  an `in` query for the backstop for no benefit: a crashed run is just a PENDING doc whose lease has expired.
- A delivery that reads a live lease, or loses the claim, answers 429 (a nack that is not a 5xx). The subscription's 60 s
  minimum backoff exceeds the 35 s lease, which exceeds the 27 s handler budget, so a live run is never overlapped and
  a crashed or nacked run is retried by the next redelivery; the daily backstop still re-publishes a PENDING export older
  than 1 h whatever its lease.
- `RequestAccountExport` re-publishes a replayed PENDING export only when `createdAt` is at least 2 minutes old. It uses
  the doc the replay already read: **no new reads or writes**. A lost first publish is recovered by the client's retry
  after 2 minutes or by the backstop.
- **Budget change.** `RequestAccountExport`: unchanged (reads 2/1, writes 2; replay 0 writes). `account-export` job:
  writes **2** (claim, then `status`; was 1); reads unchanged (1 `exports` + 1 `users` + sections). A delivery that
  finds a live lease: 1 read, 0 writes; one that loses the claim race: 2 reads, 0 writes. Worst case for one large
  account is now 1 compose per export instead of about 60 concurrent ones.

**L-6. Backstop scans are ordered and paged.**
- `users where status == DELETING and deletionJob.progressAt <= now-1h order by deletionJob.progressAt, __name__` and
  `exports where status == PENDING and createdAt <= now-1h order by createdAt, __name__`, each `Limit(50)`, continued
  with `StartAfter(lastTimestamp, lastId)` for at most 4 pages per scan. The age filter moved into the query, so fresh
  jobs are never read and cannot hide stuck ones.
- **Composite indexes** (added to `firebase/firestore.indexes.json`): `users(status ASC, deletionJob.progressAt ASC)` and
  `exports(status ASC, createdAt ASC)`. This supersedes the "automatic single-field indexes, no index change" line of
  option D and the handoff note. Deploy the indexes before (or with) the revision: until they are built, the backstop scan
  fails with FAILED_PRECONDITION and the cron returns 500 (Scheduler retries; nothing else depends on it).
- **Budget change.** Reads per backstop run: 2 when nothing is stuck (unchanged), otherwise 1 per stuck document, at most
  **50 per page, 4 pages per scan, 400 per run** (was at most 100 with the unordered scan, 50 of them possibly fresh).
  Writes: 0, plus 1 per export given up after 24 h (unchanged).
- A `DELETING` flag set by hand without `deletionJob.progressAt` is no longer matched (it never was actionable: the
  founder's tool drives those, runbook 3b); `backstop_skipped` is gone. Republishing does not move `progressAt`, so a job
  that stays stuck stays at the head of the next run; more than 200 such jobs (each a DLQ alert) log WARN
  `backstop_page_full` with `cursor_at`.

## Decision (Accepted 2026-10-07)
- **D-A: option D with A.** A shared `jobs` Pub/Sub topic with push to `/internal/pubsub/jobs`. Its subscription has
  `minimum_backoff = 60s` and `max_delivery_attempts = 10`. Each invocation self-chains, saves the seq-deduped state
  on `users/{uid}`, and gates with 429 nacks. The `daily-maintenance` backstop re-publishes stuck jobs. Why:
  - it costs the same $0 as Cloud Tasks;
  - it stays inside CLAUDE.md's named async mechanism;
  - it runs end to end on the Firebase emulators;
  - it needs no new API or IAM broadening;
  - its two weaknesses (no delayed delivery, the DLQ cliff) are covered by 1–2 cheap nacks and the backstop.

  Cloud Tasks is the better tool on paper. It loses here only on stack fit and testability. Revisit it if a second
  feature needs delayed delivery.
- **D-B: option B, a third private bucket `<proj>-exports`.** It is $0 like option A, and it removes the coupling to
  P4's not-yet-decided upload layout and the risk of a mis-scoped lifecycle rule.
- **D-C: option A, orchestrator in `identity`** with consumer-side `StepEraser`/`ExportSection` interfaces and the
  adapters in `apiserver`. No module-list change.
- **D-D: the streaming `ExportSection` and the envelope above.**
- **Q1–Q10:** as in the table. Q1 has one ordering change (`users/{uid}` last); Q2 and Q10 get one addition each.
  Q3 (SUSPENDED may delete) and Q10 (the retained-data list, published in the Privacy Policy) are founder-confirmed.
- **IAM:** the custom role `accountLifecycleAuth` on the runtime SA, **only together with controls C1–C4**.
- **Cost:** no rate shaping. A maximum-size deletion is billed the day it runs (≈ $0.03).

## Consequences
- **Positive:**
  - Deletion completes within about 3–5 minutes for the reference account (120 s gate + one invocation), and within
    an hour or so at maximum size.
  - Exports are READY within about a minute.
  - Zero fixed cost. One code path serves the in-app job and opsctl.
- **Negative:**
  - The gate costs 1–2 nacked deliveries per deletion.
  - The `jobs` subscription's slower retry (≥ 60 s) also applies to P2 snapshot refresh.
  - A job in the DLQ waits up to 24 h for the backstop (or a human, per the runbook).
  - Dev has no backstop cron.
  - At the IAM level the runtime SA can still disable and delete any Firebase Auth user. C1–C3 confine our code,
    and C4 detects misuse after the fact. Neither stops a stolen SA token (see §"IAM", "What the controls do not
    cover"; T20).
  - ≈ $0.40/month (prod only) for the C4 alert policy, the first recurring fee in the product.
- **Follow-up work:**
  - Done with this acceptance (2026-10-07): the `firestore-data-model` skill (`users.deletionRequestedAt`,
    `users.deletionJob`, the `exports` row), T2b (proto comments) and the retained-data list in `app/web/privacy.html`.
  - `cost-model.md` rows 35–36 are replaced by sre-performance (T21), not edited here.
- **Revisit when:**
  - a deletion needs more than 50 invocations;
  - DLQ messages appear more than once a month;
  - a second feature needs delayed delivery (Cloud Tasks);
  - the 80% write alert fires because of deletions (rate shaping);
  - Apple guidance requires server-side revocation (Q7).

## Founder questions (answered 2026-10-07; see §"Founder decisions")
1. **D-A:** accept **option D with Pub/Sub** (shared `jobs` topic, self-chaining, daily backstop)? Or prefer Cloud
   Tasks (D with B), which also needs a CLAUDE.md "Async work" amendment?
2. **D-B:** accept a **third private bucket `<proj>-exports`** (7-day lifecycle, $0)? Or keep exports in the upload
   bucket with prefix-scoped rules, which forces P4's upload prefix now?
3. **D-C:** accept the **orchestrator inside `identity`** (no module-list change)? Or create a new
   `accountlifecycle` module, which amends CLAUDE.md?
4. **Q3:** may a **SUSPENDED** user delete their own account? (Default yes; the report snapshot is kept as evidence.)
5. **Q10:** accept the **residue allowlist**, including the 2 additions (the raw uid in Pub/Sub messages for ≤ 7 days;
   Crashlytics and Analytics not keyed to the uid), and state it in the privacy policy?
6. **IAM:** accept that the runtime SA gets a **custom role able to disable and delete any Firebase Auth user**
   (`users.get/update/delete` only)?
7. **Cost:** accept **≈ $0.03 of pay-per-use writes per maximum-size deletion**, with no rate shaping across days?

## Handoff
- **architect:** done 2026-10-07: T2b proto comments (the budget numbers above; the job mechanism; the Q2/Q3/Q6
  semantics; `expires_at` names `<proj>-exports`), the `firestore-data-model` skill (`users` job-state fields,
  `exports` row) and the Privacy Policy retained-data list. No index change: both backstop queries use automatic
  single-field indexes.
- **backend-developer:**
  - **T6:** the orchestrator in `internal/identity` (StepEraser/ExportSection, `Register`, `StartGate` moved from
    opsctl and keyed on `deletionRequestedAt`, 20 s budget, the 5-error policy) and the adapters in `apiserver`.
  - **T7:** the identity step plus the Auth steps in the Q1 order (`users/{uid}` last), **through the C2 wrapper
    only**: the C1 fresh `status == DELETING` check before every Auth mutation, the C3 NOTICE line per call, ERROR
    `auth_admin_refused` on refusal, and the CI guard test that no package outside `internal/identity` and
    `cmd/opsctl` calls `GetUser`/`UpdateUser`/`RevokeRefreshTokens`/`DeleteUser`.
  - **T8:**
    - `/internal/pubsub/jobs` with the seq dedupe, the `UpdateTime` precondition and the re-publish rule;
    - 429 for gated deliveries;
    - the `daily-maintenance` dispatcher with the backstop;
    - no flag or degraded-mode gate on the handlers.
  - **T5:** one update, then publish. On a publish failure, still return success and log ERROR
    `account_delete_enqueue_failed`. A replay re-publishes.
  - **T9/T10:** `EXPORT_BUCKET`; the streaming composer; READY/FAILED with a precondition.
  - **Log fields:** `account_job`, `step`, `checkpoint` (step name and counts only), `seq`, `delivery_attempt`,
    `fs_reads/writes/deletes`, `outcome = progressed|done|gated|duplicate|error`, `uid_hash`. Never a raw uid or the
    download URL.
- **frontend-developer:** no change from T13–T15. Copy for the "what remains" text comes from Q10 (a)–(f).
- **production-deployer:**
  - **T3b:** optional `minimum_backoff` and `max_delivery_attempts` per topic in `modules/pubsub`; add
    `jobs = { push_path = "/internal/pubsub/jobs", minimum_backoff = "60s", max_delivery_attempts = 10 }` to dev and
    prod `topics` (keeping the two defaults). `daily-maintenance` is unchanged.
  - **T3a:** `<proj>-exports` in `us-central1` (enforced PAP, uniform access, `age = 7`, no CORS, runtime-SA
    `objectAdmin`); custom role `accountLifecycleAuth` + binding; env vars `EXPORT_BUCKET`, `EXPORT_URL_TTL=15m`,
    `EXPORT_RETENTION=168h`, `ACCOUNT_DELETE_REAUTH_MAX_AGE=5m`, the flag trio.
  - **T3a (IAM control C4):** in `modules/monitoring`, the label-free log-based metric `auth_admin_mutations` and one
    alert policy (sum over 1 h > `auth_admin_alert_per_hour`, default 5, to the existing founder email channel),
    marked `# cost-approved: ADR-0011`. Re-check the alerting price on the pricing page and put it in the PR.
  - DLQ depth goes on the existing dashboard (no further alert policy).
- **tester:**
  - **T16:**
    - crash after every step call;
    - two concurrent same-seq deliveries (exactly one state advance);
    - redelivery of seq − 1 (re-publish) and of older seqs (drop at 1 read);
    - a gated delivery (429, 0 writes);
    - the backstop recovering a DLQ'd job;
    - `users/{uid}` existing until after Auth delete;
    - a job message naming an ACTIVE or SUSPENDED uid (never set DELETING): 0 Auth calls, `auth_admin_refused`, ack
      (control C1);
    - exactly one C3 audit line per Auth call, with no raw uid or email.
  - **T11:** the residue oracle is Q10 (a)–(f).
  - **T17:** an export retry overwrites the object.
- **security-auditor (T20):**
  - the custom role's breadth and controls C1–C4. Decide whether to enable `identitytoolkit.googleapis.com`
    `DATA_WRITE` audit logs as an alert source a stolen SA token can't bypass (weigh the extra PII in logs);
  - the interceptor exemption, which must be exactly one procedure;
  - the `/internal/pubsub/jobs` OIDC check;
  - whether a forged or replayed job message can delete a non-DELETING user. The handler must require
    `status == DELETING` and must never act on the message's word alone;
  - the Apple revocation requirement (Q7);
  - Crashlytics and Analytics identifiers (Q10 f).
- **sre-performance (T21):** replace cost-model rows 35–36 from these formulas plus measurement. Cloud Tasks was not
  chosen, so it is not recorded. Add the C4 alert policy (≈ $0.40/month, prod only) as a fixed line, and re-check the existing
  alert policies (uptime, 5xx, Firestore reads), which are billable under the same 2026 alerting pricing.

## Sources (checked 2026-10-07)
- Cloud Tasks pricing: https://cloud.google.com/tasks/pricing (1M billable operations/month/account free, then $0.40/M;
  32 KB chunks; an operation is an API call or a push delivery attempt).
- Pub/Sub pricing: https://cloud.google.com/pubsub/pricing (first 10 GiB/month per billing account free, then $40/TiB;
  1 KB minimum per request; retention storage $0.27/GiB-month).
- Firebase Authentication IAM roles: https://cloud.google.com/iam/docs/roles-permissions/firebaseauth
- Alerting pricing: https://cloud.google.com/stackdriver/observability-pricing-examples (alerting policies:
  $0.35 per metric reference per month, $0.50 per million points returned; log-based alert policies return no points)
  and https://cloud.google.com/products/observability/pricing (charging starts no sooner than 1 May 2026).
- Identity Platform audit logging: https://docs.cloud.google.com/identity-platform/docs/audit-logging
  (`DeleteAccount` and `SetAccountInfo` are `DATA_WRITE`, so Data Access logs, off by default).
