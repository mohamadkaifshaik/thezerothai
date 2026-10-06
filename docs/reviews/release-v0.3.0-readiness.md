# Release readiness — v0.3.0 candidate (posts + timeline slice, `FEATURE_POSTS` off, then allowlist)

DRAFT input package, 2026-10-06 (tickets T26/T27, `docs/plans/posts-and-timeline.md`). **This is an input package, not a
verdict.** The `production-reviewer` runs the `production-readiness` checklist over it and owns the final line. Nothing
was tagged, applied or deployed, and no cloud state was read: the authoring container has no GCP credentials, so every
item that needs prod or dev facts is **OPEN**, not guessed.

Scope: the API (posts and timeline modules, P0 read budget) to Cloud Run `api` in `dzeroth-prod` as a
`--no-traffic --tag candidate` revision, then 10% → 100% with `FEATURE_POSTS=off`, then `allowlist` for 48 h (T27).
`percent` and `on` belong to a later addendum (they need P3 + P7 and your R1/R2 acceptance, below). **No store
submission** (UGC report/block flows are P7, in-app account deletion is P8).

Release candidate: head of the PR #94 branch (`claude/gracious-babbage-2barib`) once merged to `main`; record the merge
commit and the CI run on it here: **OPEN**.

Labels: **PASS**, **FAIL**, **ACCEPTED** (a risk you sign off), **GATED** (checked after the candidate is staged),
**N/A**, **OPEN** (input missing). The verdict is the last line and is `PENDING`.

## 1. Inputs
| Input | Status | Evidence |
|---|---|---|
| Plan with cost rows | PASS | `docs/plans/posts-and-timeline.md` (T1–T28, per-RPC budget table, rollout plan) |
| ADR | PASS | `docs/adr/0010-posts-and-timelines-slice.md`, Accepted on merge of #69; amendment (M2 mentions, L5 blank-looking code points) committed 2026-10-05 and recorded as a founder decision |
| CI on the release commit | PASS at the PR head `a292e25` (both jobs); **GATED at the merge commit** | `make ci` and `make test-int` success on run 37409092029. Later commits in this session are docs, Terraform and a loadtest helper: re-check on the final head |
| Test report | PASS (caveats) | `docs/reviews/test-report-posts-timeline.md`, `VERDICT: PASS`; gaps listed there. Note: local `make test-int` prints a combined coverage below 70% on Go 1.24; CI (Go 1.26) is the gate |
| Code review | PASS | `docs/reviews/code-review-posts-timeline.md`, APPROVE, no Blockers or Majors |
| Security review | PASS (conditional) | `docs/reviews/security-review-posts-timeline.md`: 0 Critical, 0 High open; see §3 |
| Cost report | PASS with one trigger | `docs/reviews/cost-report-posts-timeline.md`: 192.9 reads/DAU (ADR 182.6); 116% of the free read quota at 300 DAU; home older page 40–42 reads vs 30 planned (+33%, over the 1.4x trigger). See §4 |
| Load smoke (T22) | PARTLY | `posts_create` full scale PASS (p95 14.8 ms). `timeline_read` only at reduced scale: p95 75 ms, 0 failures, but 55% of refreshes still return a gap and refresh averages 4.9 reads (cause unexplained, see the T22 status). Full-scale run OPEN (needs a bigger machine) |
| No unapproved fixed-cost resource | PASS (repo) | T26 Terraform change is env vars only. Re-check with `cost-guard` on the plan output: **OPEN** |
| Terraform fmt/tflint on the T26 edits | PASS | PR #94 CI: `terraform fmt -check -recursive`, `tflint --recursive` and the dev plan job succeeded. The **prod plan job was skipped: "prod is not bootstrapped yet"** (CI log, 2026-10-06). Whether `dzeroth-prod` has a live `api` service is therefore **OPEN**; the v0.2.0 readiness report describes a prod `api` revision, so reconcile this before T27 |
| Terraform plan reviewed | OPEN | No `terraform` or credentials in the authoring container; plan must be produced and read before any apply (founder preference: plan-then-OK) |
| Firestore indexes READY (3 posts indexes) | GATED / OPEN | Must be READY in dev **and** prod before any traffic; the emulator does not enforce indexes |
| A2 pre-check (unverified password accounts owning a profile) | OPEN | Admin SDK `accounts:batchGet`; record the count only, never uids. Expected 0 |
| Dev validation (T21 smoke with the flag on) | OPEN | `backend/e2e/posts_smoke_test.go`; env `E2E_POSTS_BASE_URL`, `E2E_POSTS_ID_TOKEN_A/B` |
| Rollback target identified | OPEN | Record the current prod revision and image digest before staging the candidate |
| Runbooks | PASS (not re-audited) | `posts.md`, `abuse-spike.md`, `cost-spike.md`, `account-deletion.md`, `rollback.md` exist |
| Feature flag default | PASS (repo) | Prod Terraform sets `FEATURE_POSTS=off` explicitly (T26). Live value: OPEN |
| Mobile | N/A | Web only for this release |

## 2. Production-readiness checklist (pre-filled from the evidence above)
| Item | Status |
|---|---|
| CI green on release commit | GATED (merge commit) |
| Test report PASS; coverage gates | PASS (CI) |
| Code review APPROVE; no open Blockers | PASS |
| Security 0 Critical / 0 High open | PASS |
| `govulncheck` + `osv-scanner` clean; image built by CI from a tagged commit (digest) | OPEN (tag and digest do not exist yet). osv-scanner reads `app/pubspec.lock`, which includes the new `unorm_dart`; the CI job passed on the PR head |
| Firestore/Storage rules deny-all; App Check enforced | OPEN (live state); `app_check_mode` stays `monitor` per ADR-0006 |
| Cost report budgets and ≤ 80% of free quota at the DAU target | **FAIL at 300 DAU by design**: 116% of free reads at 300 DAU; the 80% line is ≈ 207 DAU. Allowlist rollout is negligible traffic; a public rollout needs your acceptance or the `k` lever (§4) |
| No new fixed-cost resource | PASS (repo), plan check OPEN |
| Budget alerts active; caps unchanged or justified; degraded mode tested on dev | OPEN (live state) |
| Candidate smoke-tested; rollback revision identified | OPEN |
| Indexes READY before traffic | OPEN |
| Pub/Sub handlers idempotent; DLQ | N/A (ADR-0010 adds no async handler; reviewer to confirm) |
| Data changes expand/contract | PASS (new collections only; `users` gains `postsCount`) |
| Error Reporting clean for the candidate; uptime check green | OPEN |
| Runbooks updated; release notes written | Runbooks PASS; release notes OPEN |
| Flags default OFF; rollout plan with rollback triggers | PASS (plan: 5xx > 2%, p95 > 2x baseline; flag back to `off` within 5 minutes) |
| Mobile TestFlight/Play; Crashlytics; bundle < 3 MB | N/A / OPEN (web bundle size not measured here) |
| Privacy review; delete/export covers new collections | PASS for posts (`posts.Eraser` + exporter + `opsctl`, T10). **In-app DeleteAccount/export RPCs are still Unimplemented (P8)**: store blocker only |
| Store policies: UGC report + block; deletion in-app | **FAIL for stores** (P7, P8 not built); N/A for the web allowlist |

## 3. Security: public-repo finding and residual risks
- **Public-repo read-amplification finding (P0):** closure is the read-budget interceptor (T3) plus the negative handle cache
  and the uncapped-read guard. Test-name evidence to cite when marking it Closed: **OPEN, to be filled from
  `docs/reviews/test-audit-posts-timeline-t19-t20.md` and the T20 integration tests by the reviewer** (not copied here to avoid
  citing names I did not re-verify in this pass).
- **ADR-0010 D5 R1/R2 (instance-cycling can exceed the per-uid read budget; ≈ 623k reads/day theoretical):** requires
  the **founder's recorded acceptance**: **OPEN**. Do not move past `allowlist` without it.
- L5 tag characters were deliberately left unchanged: re-check before any LLM or moderation feature reads post text.

## 4. Founder decisions this release depends on
1. Merge PR #94 (CI re-check on its head first).
2. P9 `k` lever: apply (`2p` → `1.5p`) or accept 40 reads per older page (+33% over plan, over the 1.4x trigger).
3. Record acceptance of D5 R1/R2.
4. Approve the Terraform plan, then any prod apply; approve the traffic shift after the production-reviewer GO.

## 5. Rollout and rollback
Staged per T27: candidate (no traffic) → T21 smoke → GO → 10% → 100% with `FEATURE_POSTS=off` → `allowlist` (founder +
internal testers) for 48 h watching `fs_reads` by `rpc`, 5xx and p95. Acceptance: 5xx < 1%, home refresh p95 < 400 ms warm,
reads per call ≤ budget. Rollback: set `FEATURE_POSTS=off` (config change, no code redeploy) within 5 minutes; previous
revision per `docs/runbooks/rollback.md`.

VERDICT: PENDING
