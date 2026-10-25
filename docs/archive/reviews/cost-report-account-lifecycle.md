# Cost report: account lifecycle (P8: account deletion and data export)
Owner: sre-performance. Date: 2026-10-09. Ticket: T21 in `docs/plans/account-deletion-export.md`. Method: `free-tier-budget` §2.
Sources: ADR-0011 (Accepted 2026-10-07, amended 2026-10-08), `backend/internal/identity/lifecycle*.go`,
`repo_lifecycle_firestore.go`, `authadmin.go`, `backend/internal/{posts,graph}/purge.go`, `infra/terraform/{modules,envs}`.
Prices: `docs/reviews/cost-model.md` §7 (upper bounds). **Pricing pages were not re-fetched in this session.**

## 0. Verdict
- **PASS for this slice's share of the free tier.** At 300 DAU, the ADR's volume (0.3 deletions and 0.3 exports per day)
  uses 0.7% of daily reads, 0.5% of writes and 0.8% of deletes. The stress volume asked for (1 deletion + 2 exports per
  day, about 5x the ADR) uses 3.9% / 1.5% / 2.5%. Every figure is far below the 80% line (40k reads, 16k writes, 16k deletes).
- **Fixed cost: one line, about $0.39 to $0.40/month, prod only** (C4 alert policy; founder approved 2026-10-08). Everything
  else in the slice is pay-per-use and $0 inside the free tier. The slice's variable cost is about $0.0125/month at 300 DAU,
  so the alert is the dominant cost until about 10k DAU.
- **The binding free quota is still Firestore reads, and the slice does not change that.** The whole product is already over
  the daily read quota at 300 DAU (`cost-model.md` §3). The slice moves the released-scope crossover by 1.6 DAU.
- **Measured vs derived.** All numbers below are derived from the code and from the ADR/plan formulas. This session
  did not start the emulators, so the emulator `BUDGET` log line (`account_lifecycle_integration_test.go:406`) was not
  re-run. `GOWORK=off go test ./internal/identity/` passes (27.8 s), including the fake-repo read/write assertions
  (`lifecycle_export_test.go:47,84,174`; `lifecycle_delete_test.go:60,241`; `lifecycle_l4l6_test.go:52,220,245,308`).
  Time per invocation and the export size ceiling are **not measured** and are carried as named risks (§9).
- **Not FAIL-listed:** no RPC exceeds its documented budget in the code reviewed. The caveats are R1 to R4 in §9.

## 1. Reference account and notation
P posts, O following (cap 5,000), I followers (no cap), B blocked (cap 2,000), Bb blockedBy (cap 10,000), E export docs.
Reference: P = 300, O = 100, I = 100, B = Bb = M = 0, E = 1 (plan §Cost). Page sizes from code: posts 500
(`posts/purge.go:25`), graph outgoing 250 and incoming 160 per call, array chunks 500 (`graph/purge.go:34-36`), identity
exports page 50 and private page 500 (`lifecycle_jobs.go:37-38`).

## 2. Deletion job: Firestore ops per step and per delivery
Deliveries for the reference account, D = 3 (ADR-0011 D-A): the first delivery runs right after the DeleteAccount commit
and is gated; Pub/Sub redelivers after `minimum_backoff = 60s` (still gated, under 120 s); the third (about 180 s) passes
the gate and does all the work in one go (`lifecycle_jobs.go:208-218`, `lifecycle.go:29`; the 60 s backoff is in
`modules/pubsub/variables.tf`).

| Step / delivery (reference account) | reads | writes | deletes | Auth admin calls | Source |
|---|---|---|---|---|---|
| DeleteAccount RPC (cold / warm) | 2 / 1 | 1 | 0 | 0 | interceptor + fresh `users` read; one update (`BeginDeletion`) |
| Gated delivery x2 (`outcome=gated`, 429) | 1 each (`GetJobState`) | 0 | 0 | 2 each (`UpdateUser` disable + `RevokeRefreshTokens`) | `lifecycle_jobs.go:183,213`; `authadmin.go` `disableAndRevoke` |
| Work delivery: job-state read / gate | 1 | 0 | 0 | 0 | `GetJobState` |
| step `auth-disable` | 0 | 0 | 0 | 2 | repeated once more in the work delivery (the step list starts at index 0) |
| step posts (1 call, short page ends it) | 300 | 0 | 300 | 0 | `posts/purge.go:51-75` |
| step graph (5 calls) | 204 (100 out + 100 in + 2 array reads + 2 empty final queries) | 300 (100 followee counters + 2 x 100 follower array/counter) | 201 (100 + 100 edges + graph doc) | 0 | `graph/purge.go`; plan derivation notes |
| step identity | 4 (`ListExports` 1, `DeletePrivate` 1 (empty), `DeleteHandleIfOwned` 1, `DeleteUserDoc` txn read 1) | 0 | 3 (export doc, handle, quotas) | 0 | `lifecycle_jobs.go:372-420`; `repo_lifecycle_firestore.go` |
| step `auth-delete` | 0 | 0 | 0 | 1 (`DeleteUser`) | `authadmin.go` `deleteUser` |
| step user doc (last) | (counted in identity row) | 0 | 1 | 0 | conditional delete at this seq |
| Checkpoint writes | 0 | 0 (W = 1, so no `SaveJobState`) | 0 | 0 | `lifecycle_jobs.go:236` only on `progressed` |
| **Total, one reference deletion** | **513** (2 + 2 gated + 509 work) | **301** | **505** | **7** | |

Notes:
- The ADR's reference line says "about 510" reads for the whole job. Counting the code path step by step gives 511 for the
  job (2 gated + 509 for the work delivery, which includes the handle-owner read and the `DeleteUserDoc` txn read). This
  report uses the step-by-step count.
- Pub/Sub for one reference deletion: 1 publish (DeleteAccount) and 3 push deliveries, each billed at the 1 KB minimum
  (messages are `{kind, uid, seq}`, about 100 bytes) = **about 4 KB**. W = 1 means no self-chain publish.
- Cloud Run: 1 RPC + 3 job requests = 4 requests per deletion. vCPU-s: ADR planning value about 10 per deletion (gated
  deliveries are short; the work delivery is the bulk). **Unmeasured.**

### 2.1 General formula
- reads = 2 (RPC) + D (one job-state read per delivery) + P + O + I + 2 * ceil((max(B, Bb) + 1) / 500) + up to 3 (empty
  final pages) + 2 (finish queries) + about 3 + max(E, 1) (identity step). The reference table above is the exact count.
- writes = 1 + O + 2I + B + Bb + (W - 1) checkpoints.
- deletes = P + O + I + 1 (graph doc) + 3 (handle, quotas, user) + E.
- Each work invocation adds 1 read (`GetJobState`) and, unless it is the last, 1 write (`SaveJobState`, with an
  `UpdateTime` precondition) and 1 publish. Budget per work invocation: 20 s soft + 5 s grace inside a 27 s handler budget
  (`lifecycle.go:30-34`, `lifecycle_jobs.go:53`).
- Worst path (a counterpart already purged: precondition fallback re-queries): up to + 2O + 3I + B + Bb reads
  (`graph/purge.go:116-131`, as in the plan).

### 2.2 Maximum-size deletion (allowed by the caps that exist)
O = 5,000, B = 2,000, Bb = 10,000 (caps); P = 10,000 and I = 10,000 are **illustrative** (no cap exists, plan OPEN).

| Quantity | Formula | Value |
|---|---|---|
| Writes | O + 2I + B + Bb + checkpoints | 5,000 + 20,000 + 2,000 + 10,000 + ~10 = **~37,000** (floor with I = 0: 17,000 = 85% of a day's free writes) |
| Reads | P + O + I + 42 + ~10 + invocations | **~25,000** (50% of the daily quota); fallback path adds up to 52k |
| Deletes | P + O + I + 5 | **~25,000** |
| Step calls | P/500 + O/250 + I/160 + (B + Bb)/500 + ~5 | 20 + 20 + 63 + 24 + 5 = **~130** calls |
| Invocations W | calls x seconds-per-call / 20 s | 4 at 0.5 s per call, 14 at 2 s per call (**unmeasured**). ADR revisit trigger: more than 50 |
| Marginal $ at §7 upper bounds | 25k reads + 37k writes + 25k deletes | 0.015 + 0.067 + 0.005 = **about $0.09**, billed the day it runs |
| Pub/Sub | (W + 2 gated) x 2 KB | under 50 KB |

The founder accepted about $0.03 for the 17k-write floor (ADR-0011 decision 7). With uncapped I and P the cost is
still cents; the risk is the daily quota for that day, not dollars (R2).

## 3. Export job: Firestore ops per RPC and per job
| Item | reads | writes | deletes | Notes / source |
|---|---|---|---|---|
| RequestAccountExport (cold / warm) | 2 / 1 (+1 on `AlreadyExists` replay) | 2 (`exports` doc + `quotas`) | 0 (+1 TTL delete after 7 days) | `repo_lifecycle_firestore.go:151` (`CreateExport`) |
| `account-export` job, reference account | 1 (`exports`, also the job state) + 1 (`users`) + 300 (posts) + 100 + 100 (edges) + 1 (`graph`) + up to 200 (handle profiles, batches of 50, all cache misses) = **703** | **2** (lease claim, then `status`) | 0 | `lifecycle_export.go:83-170`; ADR L-4. The plan table still says 1 write; the code and ADR amendment say 2 |
| Delivery that finds a live lease | 1 | 0 | 0 | 429, redelivery after 60 s |
| Delivery that loses the claim race | 2 | 0 | 0 | 429 |
| Redelivery of a READY/FAILED export | 1 | 0 | 0 | ack |
| GetAccountExport (per poll) | 2 / 1 | 0 | 0 | about 3 polls per export, planning 1 read each = 3 |
| **Total, one reference export** | **708** (2 + 703 + 3) | **4** | **1** (TTL, 7 days later) | |
| GCS, per export | 1 Class A (object insert) | | | 1 to 2 Class B (download); object about 0.5 MB (ADR); delete by lifecycle (free) |
| Auth admin, per export | 1 `GetUser` (`getUserRecord`) | | | read-only; repeated on a retried compose |
| Pub/Sub, per export | 1 publish + 1 delivery = 2 KB | | | |
| Cloud Run, per export | 1 RPC + 1 job + 3 polls = 5 requests; about 20 vCPU-s at most (ADR) | | | unmeasured |

Export has **no checkpointing**: one delivery composes the whole file within `exportBudget = 25 s`
(`lifecycle_export.go:22`). A timeout or error nacks and the next delivery redoes the entire read (R1).

## 4. Backstop (`daily-maintenance`, prod only)
- Two ordered queries, `Limit(50)`, up to 4 pages each (`lifecycle_jobs.go:44-50,441-525`).
- **2 reads/day when nothing is stuck** (1 per query; an empty query still costs 1 read), 0 writes, 1 Cloud Run request,
  1 of the 3 free Scheduler jobs (prod only; dev has none). That is 60 reads, 30 requests per month.
- With stuck work: 1 read per stuck document, at most 50 per page and 400 per run. Writes: 1 per export given up after 24 h.
- Composite indexes `users(status, deletionJob.progressAt)` and `exports(status, createdAt)` add index storage of a few
  bytes per DELETING/PENDING doc. Negligible.

## 5. Other resources
| Resource | Volume per reference event | Billing result at Stage 0 | Source |
|---|---|---|---|
| Pub/Sub `jobs` topic (self-chaining) | deletion: 1 publish + 3 deliveries (4 KB); large: (W + 2) x 2 KB; export 2 KB | 10 GiB/month free; 8 KB/day in the stress case = 240 KB/month = 0.002%. DLQ/retention storage on KB is $0.00 | `modules/pubsub`, ADR §D-A |
| GCS `<proj>-exports` (us-central1, 7-day lifecycle, soft delete off) | 0.5 MB object, 1 Class A, 1 to 2 Class B | Stress case: 2 exports/day = 60 Class A/month (1.2% of 5,000), about 120 Class B (0.2% of 50,000), standing storage about 14 objects x 0.5 MB = 7 MB (0.1% of 5 GB). Egress to India downloads and the asia-south1 to us-central1 write: about 30 MB/month each way = about $0.006/month at $0.12 and $0.08 per GB | `media-buckets/main.tf:88-120`, ADR §D-B |
| Firebase Auth admin calls | deletion 7, export 1, sign-up check 1 (`checkSignup`, new-profile path only) | No per-call fee at no-cost tier (ADR-0011 cost of controls). Stress case: 9 per day plus about 15/day sign-up checks at 300 DAU (0.05 new profiles per DAU). Not verified against current Identity Toolkit quotas in this session | `authadmin.go` |
| Firestore TTL on `exports.expireAt` | 1 delete per export, 7 days later | TTL deletes are billed as deletes (`free-tier-budget` §1). Included in the delete counts above | `modules/firestore/variables.tf` |
| Signed GET URL (`signBlob`) | up to 1 per poll that sees READY | $0 in `cost-model` §7; not separately priced here | |
| Cloud Run vCPU-s / GiB-s | about 10 per deletion, at most 20 per export | Stress case: about 50 vCPU-s/day = 1.5k/month = 0.8% of 180k; GiB-s about 0.2% of 360k. Large deletion worst: W x 25 s (about 100 to 350 vCPU-s) | ADR budget table; unmeasured |

## 6. C4 alert and the other fixed lines
- **C4** (`modules/monitoring/main.tf:268-300`): one log-based counter metric (free allotment: label-free, KB/month) and one
  alert policy `auth_admin_mutations` (sum over 1 h, threshold 5), created only where `enable_auth_admin_alert = true`
  (prod; dev passes false, `envs/dev/main.tf:232`). Cost: $0.35 per metric reference + about 86k points x $0.50/M =
  **about $0.39/month**, independent of DAU. Founder approved 2026-10-08. The resource carries `# cost-approved: ADR-0011`.
  At the expected 9 deletions/month a 5-per-hour threshold cannot fire by normal use. In the stress case (1 deletion/day)
  it also cannot, so no tuning is needed until about 5 deletions in a single hour.
- **Existing alert policies are billable under the same 2026 alerting pricing and are not in `cost-model` §5, which says
  "nothing in this table is a fixed fee".** `modules/monitoring/main.tf` creates 3 policies (uptime, 5xx rate, Firestore
  reads) with no `count` gate, so they exist in both dev and prod: 6 policies x about $0.35 to $0.40 = **about $2.1 to
  $2.4/month**, plus uptime-check execution pricing that I could not check. These predate P8 and are **not caused by it**,
  but the handoff in ADR-0011 asked T21 to re-check them. Recommendation: verify on the Cloud Monitoring pricing page
  before the next release, decide whether dev needs its own alert policies (halves the line), and add a "fixed monitoring"
  row to `cost-model.md` §5. This is a founder-visible cost, not an architecture change (R4).
- Scheduler: 1 of 3 free jobs. Custom IAM role, `jobs` topic, exports bucket: $0.

## 7. Expected volume at Stage 0 and against the free tier
Two scenarios. **ADR rate** = 0.001 deletions and 0.001 exports per DAU per day = 0.3 + 0.3 per day at 300 DAU (about 9 + 9
per month). **Stress** = 1 deletion + 2 exports per day at 300 DAU, as requested (3.3x and 6.7x the ADR rate).

| Per day at 300 DAU | ADR rate (0.3 del + 0.3 exp) | % of free | Stress (1 del + 2 exp + backstop) | % of free | % of 80% line | Free per day |
|---|---|---|---|---|---|---|
| Firestore reads | 0.3 x 513 + 0.3 x 708 + 2 = **~368** | 0.7% | 513 + 1,416 + 2 = **1,931** | 3.9% | 4.8% | 50,000 |
| Firestore writes | 0.3 x 301 + 0.3 x 4 = **~92** | 0.5% | 301 + 8 = **309** | 1.5% | 1.9% | 20,000 |
| Firestore deletes | 0.3 x 505 + 0.3 x 1 = **~152** | 0.8% | 505 + 2 = **507** | 2.5% | 3.2% | 20,000 |
| Cloud Run requests per month | about 140 | 0.007% | about 450 | 0.02% | | 2,000,000 |
| Cloud Run vCPU-s per month | about 400 | 0.2% | about 1,500 | 0.8% | | 180,000 |
| Pub/Sub per month | about 75 KB | 0.0007% | about 240 KB | 0.002% | | 10 GiB |
| GCS Class A / B per month | about 18 / 36 | 0.4% / 0.1% | about 60 / 120 | 1.2% / 0.2% | | 5,000 / 50,000 |
| Auth admin calls per day | about 3 | | about 9 (+ about 15 sign-up checks) | | | no quota concern |

Per DAU (ADR rate): **1.22 reads, 0.31 writes, 0.51 deletes** (the plan's figure; the deletion row alone is 0.51 reads
and the export row 0.71 reads). Cost-model row 35's old 0.1 reads/DAU understated the deletion alone by 5x.

### Marginal dollars
Once the whole product is over the free read quota (it is, above about 217 to 259 DAU), every slice read is billed at the
margin. The slice's variable cost per DAU-month at §7 upper bounds: 36.6 reads x $0.06/100k + 9.3 writes x $0.18/100k + 15.3
deletes x $0.02/100k = **$0.0000417 per DAU per month**.

| DAU | Slice variable $/month | Fixed C4 (prod) | Slice total |
|---|---|---|---|
| 300 (ADR rate) | $0.0125 | $0.39 | **~$0.40** |
| 300 (stress) | $0.055 (reads 0.035 + writes 0.017 + deletes 0.003) + about $0.006 GCS | $0.39 | **~$0.45** |
| 3,000 | $0.125 | $0.39 | ~$0.52 |
| 10,000 | $0.42 | $0.39 | ~$0.81 |
| 20,000 (Stage 1 ceiling) | $0.83 | $0.39 | ~$1.22 |

## 8. Crossover and quotas: DAU at which the slice alone would exhaust each quota
| Quota | Slice per DAU (ADR rate) | Slice alone reaches 80% line | Slice alone reaches 100% |
|---|---|---|---|
| Reads (50k/day) | 1.22 | ~32.8k DAU | ~41.0k DAU |
| Writes (20k/day) | 0.31 | ~51.6k DAU | ~64.5k DAU |
| Deletes (20k/day) | 0.51 | ~31.4k DAU | ~39.2k DAU |

These are far above Stage 1 (20k DAU). The binding constraint stays the product's other reads. Cost at 2x and 10x the
100% DAU of the reads row (82k and 410k DAU) is linear at $0.0000417 per DAU-month: about $3.4 and $17 per month for the slice.

**Restated whole-product crossover (acceptance criterion 2).** `cost-model.md` released scope (identity + graph + posts)
is 192.9 reads/DAU. Adding the full slice 1.22 (conservative, without netting out the old 0.1):

| | Before (`cost-model` §3) | With the slice (this report) | Delta |
|---|---|---|---|
| Released scope reads/DAU | 192.9 | **194.1** | +0.6% |
| Free quota exhausted at | ~259 DAU | **~258 DAU** | -1.6 DAU |
| 80% line (40k) crossed at | ~207 DAU | **~206 DAU** | -1.3 DAU |
| Whole product reads/DAU (row 69) | 230.0 | **231.1** (230.0 - 0.1 + 1.22) | |
| Whole product free quota exhausted | ~217 DAU | **~216 DAU** | -1 DAU |
| Whole product writes/DAU / deletes/DAU | 31.8 / 7.65 | 32.1 / 7.66 | writes free to ~620 DAU; deletes to ~2,600 |

At the ADR rate the slice moves the crossovers by under 2 DAU (the plan's claim holds). At the stress rate (a fixed
1 deletion + 2 exports per day, 1,931 reads/day) the released-scope crossover is (50,000 - 1,931) / 192.9 = about 249 DAU,
10 DAU earlier. The Phase 1 conclusion does not change: reads exceed the free quota near 250 DAU, by cents per month.

## 9. Open items, risks and what could break the budget
OPEN items from the plan's Cost section:

| Plan OPEN item | Resolution |
|---|---|
| Job-state reads | Resolved: 1 read per delivery (`GetJobState`), on every delivery including gated, duplicate and refused ones |
| Checkpoint writes | Resolved: 1 write per non-final work delivery (`SaveJobState`); 0 for the reference account (W = 1) |
| Separate job doc for DeleteAccount | Resolved: no. State lives on `users/{uid}`; DeleteAccount is 1 write |
| Invocations per job | Resolved for the reference account: 3 deliveries (2 gated + 1 work). Large: formula in §2.2, unmeasured |
| Cloud Tasks pricing | Not applicable: option B was not chosen (ADR-0011 D-A = option D with Pub/Sub). Not recorded |
| Export calls/DAU (assumed 0.001) | Carried as an assumption; no traffic to measure. The stress scenario covers 6.7x |
| Worst-case I and P (no cap) | **Carried, R2** |
| Time per invocation and export size ceiling (T10 OPEN) | **Carried, R1** (not measured; needs the dev drill, T22) |

Named risks:
- **R1. Export single-invocation ceiling is unmeasured.** The composer streams in one delivery of at most 25 s with no
  checkpoint. If it cannot finish, it nacks and the next delivery re-reads everything, up to 10 deliveries per publish,
  and the backstop re-publishes once per day until the 24 h FAILED cut-off. Failed-export cost is therefore up to about
  10 x (documents read before the timeout) per publish. Illustration only (not a measurement): an account with 5,000
  documents that times out would cost up to 50k reads (about $0.03 and the whole daily free quota). Action: measure
  seconds per 1,000 documents in the dev drill, record the document count where 25 s is exceeded, and decide between a
  document cap and checkpointing. Per-user quota (1 export per day) bounds the rate.
- **R2. No follower or post cap.** Cost of a large deletion scales with I and P (writes 2I, deletes I + P). Dollars stay
  in cents (§2.2), but one celebrity-sized account can use 100% of a day's free writes. Handled by pay-per-use; revisit if
  the 80% write alert fires because of a deletion (ADR rate-shaping trigger).
- **R3. Retry amplification.** A step that fails persistently is retried 5 times within a delivery (`maxStepErrors`,
  `lifecycle.go:37`) and for 10 deliveries (`maxDeliveryAttempts`). If it reads a 500-document page before each failure
  that is about 25k reads (50% of a day's free reads, about $0.015) per stuck deletion before the DLQ, and the daily
  backstop can restart it once per day. The attempt-10 ERROR (Error Reporting email) and the DLQ widget on the dashboard
  are the detection. Bounded by cents.
- **R4. Fixed monitoring cost outside P8** (§6). About $2.1 to $2.4/month for the three existing policies in two projects,
  not in the cost model; needs a pricing check and a founder decision on dev.
- **R5. Unverified prices and quotas.** This session had no pricing-page access. §7 prices are the upper bounds in
  `cost-model.md` §7, and C4's $0.39 is the ADR's planning figure (checked 2026-10-07). Re-verify before the prod apply.
- **R6. Measurements pending.** Re-run `make test-int` with the emulators and record the `BUDGET` log line for the
  reference account (P = 300, O = I = 100) to confirm 509 work-delivery reads, 300 writes and 505 deletes; the tests so far
  only prove the P = O = I = 1 case (reads at most 14, writes at most 3, deletes at most 8).

## 10. Scale-up triggers for this slice
These are in addition to the product-wide triggers in `free-tier-budget` §6. Any one sustained 7 days needs an ADR.

| Signal | Threshold | Next step |
|---|---|---|
| Deletion needs many invocations | more than 50 invocations per job (ADR-0011 "Revisit when") | Dedicated worker or Cloud Workflows; or cap I and P |
| Dead letters | `jobs-dlq` messages more than once a month | Investigate the failing step; consider Cloud Tasks if delayed delivery is needed |
| Write alert fires because of deletions | daily writes above 16k with a deletion as the cause | Rate-shape: spread a large deletion over days (founder declined at Stage 0) |
| Export does not finish in 25 s | any export FAILED with `permanent` or exhausted retries on an account under 10k documents | Checkpointed export or a document cap (R1) |
| Deletions per hour | C4 fires (more than 5 Auth deletes or refusals in an hour) | Runbook: flag off, remove the custom-role binding, investigate |
| Slice share of reads | above 5% of total daily reads for 7 days | Cache handle profiles in the export composer; revisit the 1 export/day quota |
| Sustained load | more than 50 deletions/day (about 15k writes) | The slice alone approaches the 80% write line; that is the signal for the shared Stage 1 review, not a new design |
| Need for delayed delivery by another feature | any | Reconsider Cloud Tasks (ADR-0011 "Revisit when") |
| Apple guidance | server-side revocation required (Q7) | Apple key in Secret Manager (1 of 6 versions) |

## 11. Changes made and follow-ups
- Added this report. Replaced `docs/reviews/cost-model.md` rows 35 and 36 with the derived values. The whole-product totals,
  §3 percentages and §4/§5 tables were **not** rewritten in this change: the delta is +1.1 reads, +0.3 writes and 0.0
  deletes per DAU (§8). Regenerate them at the next weekly update.
- Dashboard query for the observability note (T21): `jsonPayload.account_job!="" | sum fs_writes by step`. Request lines
  also carry `fs_reads`, `fs_deletes`, `outcome` and `delivery_attempt` (`lifecycle_jobs.go:159-179`); the backstop line carries
  `fs_reads` and `fs_writes`. No new log-based metric or alert policy beyond C4.
- Follow-ups: R1 measurement in the T22 dev drill; R4 pricing check and a "fixed monitoring" row in `cost-model.md` §5;
  R6 emulator `BUDGET` run for the reference account; weekly actuals once there is traffic (`cost-model.md` §8).
