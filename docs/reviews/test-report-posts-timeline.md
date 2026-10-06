# Test report: posts + timeline slice (T21)
Date: 2026-10-06 · Branch `claude/gracious-babbage-2barib` · PR #94 · Owner: tester
Verdict: **PASS** for the backend and the unit/integration/e2e suites that ran. Items not run are listed under "Gaps".

## Results
| Suite | Where | Result |
|---|---|---|
| `make ci` (gofmt, vet, unit + `-race`, golangci-lint, buf, `flutter analyze`, `flutter test`, govulncheck, osv-scanner) | GitHub Actions, PR head `955e0d2` | Green |
| `make test-int` (Firestore, Auth, Pub/Sub, Storage emulators; `-tags=integration`) | GitHub Actions, same head | Green; combined `internal/` coverage **92.2%** (gate 70%) |
| `make test-int`, repeated locally | this container, Go 1.24.7 | All packages `ok`. The local coverage total printed 63.3% because the local Go toolchain merges the cross-package coverage profile differently; per-package numbers are identical to CI. Treat the CI figure as the gate. |
| New e2e smoke `TestE2E_PostsSmoke_FollowPostTimelinesDelete` (`backend/e2e/posts_smoke_test.go`) | local emulators | PASS (1.0 s) |
| Flutter | CI | analyze clean; plan records 388 tests passing |

Per-package integration coverage (CI/local, `-coverpkg=./internal/...`): graph 47.2%, posts 32.0%, timeline/integration 33.3%,
timeline 12.1%, identity 16.7%, e2e 29.6%; these are per-package slices of the merged total, not individual gates.
Unit-only coverage on the new modules: `internal/timeline` 95.4%, `internal/posts` 71.4%, `internal/posts/text` 98.7%.

## Measured budgets (e2e smoke on emulators, cold caches, F = 1)
| RPC | Reads | Writes | Deletes | Ceiling (ADR-0010 D17) |
|---|---|---|---|---|
| CreatePost (no mentions) | 3 | 4 | 0 | ≤ 14 R cold, 4 W |
| GetHomeTimeline, cold | 3 | 0 | 0 | ≤ 2 + C + 2p |
| GetUserTimeline, cached first page | 1 | 0 | 0 | ≤ 3 + max(p, 20) |
| GetPost, warm | 0 | 0 | 0 | 0 warm |
| GetPost, deleted (NOT_FOUND) | 1 | 0 | 0 | ≤ 4 |
| DeletePost (own) | 0 | 1 | 1 | ≤ 2 R, 1 W, 1 D |

The integration tests assert the full per-RPC ceilings (including home at F = 5,000, the block/mute matrix, token tampering/expiry,
the read-budget cap and in-flight hold, quota exhaustion and replay/reused-key cases); they all passed in CI. A single smoke run
costs about 20 reads and 10 writes, matching the plan.

## Gaps (not covered by this report)
- **Flutter tests and `make test-int` cannot run in the authoring container** (no Flutter SDK); they were verified in CI only.
- **Load behaviour is unmeasured.** The k6 scripts (T22) are written but have not been run (k6 is not installed here).
- **Prod `candidate` smoke** has not run: `E2E_POSTS_BASE_URL`, `E2E_POSTS_ID_TOKEN_A/B` are required (T27).
- **Cost-model re-base (T25)** needs F = 60 and F = 5,000 measurements under load; only the F = 1 smoke numbers above are recorded.

## Defects
None open from testing. Review findings (code review, security review) are tracked in
`docs/reviews/code-review-posts-timeline.md` and `docs/reviews/security-review-posts-timeline.md`; all were fixed.
