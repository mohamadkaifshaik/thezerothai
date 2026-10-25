# Code review: posts + timeline slice (T23)
Reviewer: `code-reviewer` agent · Date: 2026-10-05 · Scope: PR #94 (T6b, T6 D21 delta, T8–T13, Flutter T15–T18) · Verdict: **APPROVE**

Checked against CLAUDE.md rules 1–11, ADR-0004/0010 and `reuse-first`. Backend (`internal/posts`, `internal/timeline`, `pkg/platform`)
read in full; Flutter cubits, repositories and the feed view read. `go vet` clean; unit tests pass. Integration and Flutter tests
ran in CI (green on the PR head).

## Result
No Blockers or Majors; no CLAUDE.md rule 1–11 violations.

- **Read budgets:** every query has a `Limit`; home ceiling `C·k ≤ 2p + C` matches `2 + C + 2p`. Integration tests assert CreatePost
  warm 2R/4W, replay 1R/0W, home at F = 5,000 (268), user timeline cold and warm.
- **CreatePost:** id and `createdAt` drawn inside each transaction attempt (settle watermark stays correct); id collision or
  concurrent first call retried to a replay.
- **DeletePost:** `Exists` precondition plus `CommitWithRetry` (full jitter) decrements `postsCount` exactly once.
- **Merge and tokens:** exact-prefix merge, `NextSince`/`Watermark`, and caller/feed/tab-bound tokens correct; own-write log closes
  the slow-read vs write race.
- **Privacy/logging:** purge and export paths exist; logs carry counts only, IDs redacted.
- **Reuse:** `store.CommitWithRetry` replaced graph's copy; `pkg/platform/handle` shared by identity and `posts/text`; catalogs updated.

## Findings and disposition
| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | Minor | Plan cost row said `3 + p`; code says `3 + max(p, 20)` | Fixed (plan row) |
| 2 | Minor | Timeline cubit retried every 30 s on persistent errors | Fixed (throttle on last attempt) |
| 3 | Minor | Home screen captured `viewerUserId` once | Fixed (listener updates the cubit) |
| 4 | Minor | Whole feed rebuilt every 30 s for timestamps | Fixed |
| 5 | Nit | Reused-key test ceiling 2 vs documented 1 | Fixed (asserts 1) |
| 6 | Nit | `time.Sleep` in two tests | Fixed |
| 7 | Nit | Composer generated a new idempotency key after edit-and-revert | Fixed (text to key map) |
| 8 | Nit | `Limit(500)` on the purge ops path not listed as exempt from rule 5 | Fixed (`docs/code-map.md`) |
| 9 | Nit | Delete retry constants not in the runbook | Fixed (`docs/runbooks/posts.md`) |

Fixes landed in `a6357de`; CI green afterwards.
