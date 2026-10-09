# Code review: P8 account lifecycle (deletion and export)

Scope: origin/main `1d643a5..f87a615` (PRs #100–#106). ADR-0011, plan T19. Reviewer: code-reviewer (read-only, no tests run).

## Verdict: REQUEST CHANGES (small follow-up fix PR, not a revert)

Core design holds: seq dedupe, UpdateTime-precondition checkpoint, conditional final delete; C1 targets and C3 audit lines; every query has a Limit, no N+1; flag gates only RPCs, never jobs; per-RPC budgets asserted on emulator.

## Blocker

**B1. `CreateExport` uses a raw transaction with its own counter**, duplicating `store.RunTransaction` and the bug #102 fixed. `backend/internal/identity/repo_lifecycle_firestore.go:154-196`. Only `client.RunTransaction` left outside `store/txn.go`; scratch counter is shared across attempts, over-counting writes by 2 per Aborted retry; skips `txn_attempts`. Fix: use `store.RunTransaction`, drop the scratch/real folding, keep the `codes.AlreadyExists` branch.

## Major

**M1. Export that cannot finish in time is retried by Pub/Sub up to 10x (+~1 backstop).** `lifecycle_export.go:134-138`: any non-`errPermanent` compose error, including `context.DeadlineExceeded` from the 25 s `exportBudget`, becomes retry (500); `jobs` has `max_delivery_attempts = 10`. Each attempt re-claims the lease and re-reads everything reached (P posts + I followers + handles); P and I are uncapped (plan lists as OPEN). Cost: ~10-11x the reads reached in 25 s, repeatable daily. Fix options: (a) treat DeadlineExceeded as permanent -> `failExport(..., "too_large")`; (b) use `Delivery.Attempt` and fail from attempt >= 3; (c) config read cap `EXPORT_MAX_READS`. Add unit test with a blocking section.

**M2. DeleteAccount replay re-publishes the current seq every time**, so each replay can run a duplicate work slice concurrently. `lifecycle.go:273` publishes on `accepted` and `replay`; chain test expects two seq-0 messages (`account_lifecycle_integration_test.go:330-332`). Bound: `account_ops_daily` 20/uid/instance x 3 = up to 60 duplicate slices/day. Export got the throttle in L-4; delete did not. Fix: on `start.Replay`, publish only if `now - DeletionJob.ProgressAt >= exportRepublishAfter` (or ~2 min `deleteRepublishAfter`); 0 extra ops. Update chain test; add stale-progressAt replay test.

**M3. C2 guard misses calls through identity's exported `AuthClient` interface.** `authadmin_guard_test.go:64-72` flags only `*types.Func` from `firebase.google.com/go/v4/auth`; `lifecycle_types.go:163-172` exports `identity.AuthClient`. A call via the interface is not flagged; inside `internal/identity` every file is allowlisted, so e.g. `server.go` could call DeleteUser and skip C1/C3 with CI green. Fix: also flag methods of `identity.AuthClient` and SDK methods inside `internal/identity` outside `authadmin.go`; unexport or guard the interface; add both cases to `TestAuthAdminConfinement_ClosedHoles`.

## Minor

1. Budget comments wrong: `lifecycle.go:283-288` says replay reads 1 (actually 2; 3 cold with interceptor; first call is 1 read). `lifecycle_jobs.go:371` says identity step reads 3+max(E,1); code is 2+max(E,1). Plan `account-deletion-export.md:165-166` says export job 1 write; since L-4 it is 2. Job-state "OPEN" cells settled. T21 should fix.
2. `EXPORT_RETENTION` (config.go:577, up to 30 d) vs bucket lifecycle hard-coded `age = 7` (`media-buckets/main.tf:106`): READY export can 404. Cap at 7 d or drive both from one variable.
3. `handlerBudget` 27 s leaves ~nothing for save/publish (work 25 s incl. grace; Publish timeout 5 s). Start the work timer at handler start or stepGrace ~2 s.
4. DeleteAccount `idempotency_key` validated but never stored (`lifecycle.go:254`); natural idempotency via DELETING state. Rule 4 deviation not recorded in ADR-0011/proto comment.
5. `docs/code-map.md` lacks `store.RunTransaction`/`TxnRunner`, `logger.RedactErr`, `ScrubErr`, `CauseChain`, `store.Wait`.
6. `HashUID` is unkeyed SHA-256 cut to 64 bits (`logger.go:106-112`); uids are public so it is pseudonymous. Accepted by security review; record as known limit in privacy notes; env-var HMAC pepper is a $0 option.

## Nits

1. `pubsubpublish_integration_test.go:66` sleep poll loop; use shared `eventually` helper.
2. Export doc stays PENDING if Put succeeds but `SetExportStatus(READY)` fails; backstop sets FAILED without deleting object (`lifecycle_jobs.go:492`). Add `l.objects.Delete` there.
3. `deletionJob.checkpoint` (bytes) needs a `fieldOverrides` index exemption in `firebase/firestore.indexes.json`.
4. T19 names the report `account-lifecycle-code-review.md`; saved as `code-review-account-lifecycle.md`. Update the plan acceptance line.
5. `CronHandler` log (`lifecycle_jobs.go:539-543`) lacks `outcome` on error path and `fs_deletes`.

## Checks that passed

Rule 5 (all queries Limited: ListExports 50, DeletePrivate 500, ListDeleting/ListPendingExports 50 x up to 4 pages, posts export/purge 500/page; no offsets); Rule 6 (paged steps, batched `GetProfiles`); module boundaries via `StepEraser`/`ExportSection` in `apiserver/lifecycle_wiring.go`, opsctl reuses `identity.StartGate`; C1 (targets from fresh DELETING/PENDING docs, uid from token, no uid field in request); C3 (one NOTICE per Auth op with `uid_hash`, refusals ERROR, `ScrubErr` at every exit); tx write-count fix everywhere except B1 (`txn_test.go`); idempotency (export id = sha256(uid, rpc, key), replay writes 0, Q6 NOT_FOUND uniform); flag gating (checked at 0 reads; jobs/cron never gated; `AllowRestricted` = DeleteAccount only, guard-tested); resilience (deadlines everywhere, jittered retries, idempotent handlers); cost/infra (runtime SA publishes only to `jobs`, 3-permission custom Auth role, no fixed-cost resource beyond approved C4 ~$0.40/mo, private exports bucket, 7-day expiry); tests (`budgettest.Assert`, e2e chain with 14R/3W/8D ceiling, crash/conflict/redaction, C2 closed-holes).

## Budget numbers

| RPC / job | Reads cold/warm | Writes | Deletes | Notes |
|---|---|---|---|---|
| DeleteAccount | 2 / 1 | 1 | 0 | replay 2/1 R, 0 W; +1 publish (every replay, M2) |
| RequestAccountExport | 2 / 1 | 2 | 0 | replay 3 / 2 R, 0 W |
| GetAccountExport | 2 / 1 | 0 | 0 | +1 signBlob when READY; up to 120 R/account/day |
| Delete job per delivery | 1 | 1 checkpoint per non-final slice | 0 | +1 R per saveState conflict retry (<=3); gated delivery 1 R + 2 Auth calls |
| identity step | 2 + max(E,1) | 0 | 2 + E (+ private/*) | users_doc step 1 R + 1 D |
| reference account (P=300, O=I=100, E=1) | ~512 | ~300 | ~505 | one slice |
| Export job | 2 + sections; ref ~703 | 2 | 0 | x up to 10 on timeout (M1) |
| Backstop (daily) | 2 idle, <=400 worst | 0-N | 0 | republishes only |

At 300 DAU: ~1.22 R, 0.31 W, 0.51 D per DAU, under 1% of each free quota. Tail risks M1, M2 are bounded per account but uncapped in reads per job; T21 should add M1's worst case.

## Files for the fix PR

repo_lifecycle_firestore.go (B1); lifecycle_export.go (M1); lifecycle.go (M2, Minor 1, 4); authadmin_guard_test.go + lifecycle_types.go (M3); lifecycle_jobs.go (Minor 1, 3, Nits 2, 5); apiserver/account_lifecycle_integration_test.go (M2); config.go + media-buckets/main.tf (Minor 2); docs/code-map.md; plan doc.
