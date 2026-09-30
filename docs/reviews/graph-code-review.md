# Code review: social graph slice (T19)

Reviewer: `code-reviewer` agent, 2026-09-30. Scope: `git diff v0.1.0..origin/main` for graph work (PRs #20-#36, #38, #30,
#31, #40) at `ee48c19`. Read-only review.

**VERDICT: APPROVE** for v0.2.0 at `FEATURE_GRAPH=allowlist`. **No blocker.** S1 and S2 are doc-only fixes that should
land before T24 (fixed in PR #42). S3 and S4 should land before T25 `percent`, together with T26 and T28.

## What was and was not run

- Run: `GOWORK=off go vet ./...` and `go vet -tags=integration ./...` (clean); `go test -shuffle=on -cover` for
  `internal/graph`, `internal/identity`, `pkg/platform/...`, `cmd/opsctl` (pass); `buf breaking --against v0.1.0`
  (clean; additive only: `ErrorReason` 13/14, `UserListItem.relationship=3`, `GetMeResponse.enabled_features=5`;
  the generated connect diff is comments only).
- Not run: `-race` (no cgo on the reviewer's Windows machine; CI on Linux runs it). Integration tests on the emulators
  were not re-run; the only integration numbers are from `test-report-graph.md` (722 pass, `internal/` coverage
  89.4%). Nothing was run against dev or prod.

## Security Mediums on main

| ID | Status | Evidence |
|---|---|---|
| M1 cursors | Closed | AES-256-GCM, HKDF key, AAD binding, 24 h TTL, v1 tokens rejected: `backend/pkg/platform/cursor/cursor.go:53-115`. Binding caller\|kind\|target for edge lists (`internal/graph/follows_list.go:100,107-133`) and caller\|own-kind for own lists (`internal/graph/lists.go:62,114-118`). Tests: `security_fixes_test.go:22`, `security_fixes_integration_test.go:200`. Residual (info): an empty page carrying a token still shows a hidden row exists, not whose. |
| M2 daily caps | Closed | One shared `graph_mutation_daily` DailyCap across all six mutations (`internal/apiserver/apiserver.go:155,194-199`), default 500 (`GRAPH_MUTATIONS_PER_DAY`), set in prod Terraform. L1 also fixed: no idle TTL, IST midnight is the only reset (`pkg/platform/ratelimit/daily_cap.go:37-46`). Test: `security_fixes_integration_test.go:29`. |
| M3 non-ACTIVE profiles | Closed | `internal/identity/service.go:188-190` returns NOT_FOUND to anyone but the owner, by id and handle, before the block check. Test: `identity/security_fixes_test.go:15`. |
| M4 deletion runbook | Closed (with S1, S2) | `docs/runbooks/account-deletion.md`: export-graph, DELETING gate + 120 s wait, purge-graph before deleting `users`, drill recorded. |

## D1 Unfollow retry, log fields, budgets

- Up to 6 attempts, Aborted only; each attempt counts into a scratch counter folded in only on success
  (`internal/graph/repo_firestore.go:307-352`). Exhausted retries become UNAVAILABLE with Retry-After 1 s, never
  INTERNAL (`internal/graph/service.go:209-222`, test `security_fixes_test.go:157`). Logic correct; gaps in S4.
- Log fields are enums, counts and bools (`internal/graph/observe.go:16-23`). Error wraps go through
  `logger.RedactErr`; purge and cap logs use `HashUID`. No raw uid found on any log path.
- Budget vs ADR-0008 A2/B1: ListFollowers cold is 1+1+50+50 = 102, as documented. Every query has a Limit
  (`repo_firestore.go:684`, `purge.go:83,340`). No N+1 (hydration is one `GetAll`). Follow is 4 cold / 2 warm.
- No new GCP resource (Terraform adds env vars only). Module boundaries respected (graph reaches `users/*` only
  through `identity.Counters` and `Directory`; identity reaches graph only through its own interfaces).

## Should-fix

- **S1 - CLAUDE.md rule 10: `quotas/{uid}` has no deletion path.** Graph is the first writer of `quotas/{uid}`
  (`repo_firestore.go:260/279` Follow, `:423/441` Block, `:562/578` Mute). Neither the purge nor the runbook deleted
  it, and the drill's residue check did not look for it, so every allowlisted account that followed, blocked or muted
  leaves a uid-keyed doc, including the T24 smoke accounts. Fix: delete `quotas/$UID_` in Step 2 and check it in the
  residue check; add `quotas/{uid}` to ADR-0003's delete-path note. **Runbook fixed in PR #42; ADR-0003 note and the
  residue check on the next drill still open.**
- **S2 - runbook described a clean-up that does not exist.** T27 (lazy `muted[]` removal) is not built:
  `internal/graph/lists.go:97-103` only skips missing uids. **Fixed in PRs #41 (`graph.md`) and #42
  (`account-deletion.md`); record as an accepted residual in the v0.2.0 readiness section 4.**
- **S3 - PR #38 weakened `TestT16a_Race_ConcurrentDuplicateBlocksAndMutes`**
  (`mutations_integration_test.go:893-930`). Every concurrent call may now return UNAVAILABLE and the sequential
  replay then creates the block and mute, so the test can pass without exercising concurrency; `len(...)==1` is
  trivially true because ArrayUnion cannot duplicate. Fix: count successes per kind, fail (or retry the concurrent
  phase once) if a kind had none, assert `quotas.blocks==2` before the sequential calls, and rename "replay".
  **Open; before T25 `percent`.**
- **S4 - Unfollow retry has no jitter and no deterministic test** (`repo_firestore.go:313-319`). Fixed 25...400 ms
  backoff; `ctx.Done()` returns the raw `ctx.Err()`, which `internalErr` turns into INTERNAL plus an ERROR line on
  client disconnect. Fix: full jitter, injectable commit with unit tests (Aborted x5 then OK; Aborted x6 ->
  UNAVAILABLE; cancel during backoff), map a cancelled context to `CodeCanceled`. **Open; before T25 `percent`.**

## Nits

- N1: stale budget comments (`rpcs.go:22` Follow replay "2/2" vs A2 4 cold / 2 warm; `rpcs.go:79-80` Unfollow lacks
  the +1 interceptor read; `config.go` GraphMutationsPerDay works out 500x3x3=4.5k, ADR says 500x4x3=6k). Fold into T29.
- N2: the `user_id` validation message is copied 7 times plus `validate.go:26`; extract one constant (T28 changes it).
- N3: `daily_cap.go:53-56` two concurrent first calls can each `Set` a counter and lose one count; the daily-cap
  rejection returns `rateLimited(0)`, send Retry-After = time until IST midnight.
- N4: `isPreconditionFailed` treats NotFound from any op in the Unfollow batch as "not following"
  (`repo_firestore.go:339-343,379-382`), including the `users/{target}` counter update, so an edge whose target doc is
  gone cannot be removed; consider a WARN (no uids) when the precondition fails but `following` still contains the
  target. **Closed 2026-09-30 by ADR-0009** (`docs/adr/0009-unfollow-noop-invariant.md`): the stuck states are
  unreachable through the API under the standing edge invariant, so no read or WARN was added. Pinned by T32 (PR #64,
  `unfollow_noop_invariant_integration_test.go`); the ops producers are closed by T33 (PR #63, `CACHE_TTL ≤ 60 s`) and
  T34 (`account-deletion.md` Step 2 precondition, one-way deletion, S2 repair).
- N5: Flutter `relationship_cubit.dart:54-67` shares one idempotency key between follow/unfollow (and block/unblock,
  mute/unmute); harmless while ADR-0008 does not store keys, wrong once rule-4 storage applies.
- N6: tracked, not v0.2.0 blockers: Mute has no target-existence check (T26, `repo_firestore.go:549-597`); uids still
  accept `_` (T28, `identity/validate.go:19`). Both block T25 `percent`.

Reuse: nothing duplicated that matters (DailyCap reuses `cache.LRU`; `CauseChain` moved from `mw` into `logger`; the
idempotency-key check merged into `pkg/platform/idempotency`). N2 is the only copy-paste.
