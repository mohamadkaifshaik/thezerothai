# Security review: posts + timeline (T24)
Reviewer: `security-auditor` agent · Date: 2026-10-05 · Scope: PR #94 (posts/timeline backend, Flutter rich text, `.claude` hooks)
Verdict: **0 Critical, 0 High open.** All Medium and Low findings addressed or accepted by decision (below).

## What held up
- **Auth and flag:** every PostService/TimelineService handler runs `GuardFeature` (uid + `FEATURE_POSTS`) before Firestore access;
  `WithAllowAnonymous` is tied to `cfg.AuthEmulator`, which `config.Load` refuses in dev/prod.
- **Ownership / IDOR:** DeletePost checks the author against the stored post and returns identical success for not-owner, unknown and
  already-deleted ids (no oracle, ADR-0010 D4). Idempotency keys are scoped per user; a request-hash mismatch is `KEY_REUSED`.
- **Tokens:** since/page tokens are sealed and bound to caller, feed, target and tab, TTL capped at 90 days; `checkVisible` re-runs
  on every page, so a token held from before a block cannot bypass it.
- **Visibility:** GetPost and GetUserTimeline return byte-identical NOT_FOUND for blocked-by callers (incl. overflow); home removes
  blocked/muted/blocked-by authors before querying and filters again after the merge.
- **Input:** NFC, bidi controls and control characters rejected; 280 code points / 10 lines; mention and hashtag grammar bounded, deduped, capped at 10.
- **Logging:** counts, enums and booleans only; errors via `RedactErr`; purge logs use `HashUID`. No post text in logs.
- **Flutter:** only http(s) links with ASCII host and no userinfo are tappable, opened externally; posts with bidi controls get no links;
  no HTML rendering; sign-out wipes local data.
- **Read amplification (P0 closure):** per-procedure buckets plus the 2,000-read daily budget and the posts quota bound read and write
  amplification; the read-budget guard test fails if a `NO_SIDE_EFFECTS` RPC ships uncovered.

## Findings and disposition
| # | Sev | Finding | Disposition |
|---|---|---|---|
| M1 | Medium | Added Bash allow-rules (`cat`, `grep`, `rg`, `gofmt`, `git branch`) undercut the `Read` deny list | Fixed `a24367d`: dropped `rg`, narrowed `gofmt`/`git branch`, added Bash deny rules for secret files |
| M2 | Medium | Dropped mentions of users who blocked the author revealed "who blocked me" | Fixed `a6357de`; ADR-0010 D6/D7 amended (founder decision 2026-10-05) |
| L1 | Low | `bash-guard` missed leading `cp`/`mv`, `perl -pi`, `dd of=`, `sed --in-place` | Fixed `a24367d` (best-effort heuristic, documented) |
| L2 | Low | `commit-gate` missed `git -C . commit` / `git -c … commit` | Fixed `a24367d` |
| L3 | Low | `session-start` ran `apt-get install` without `update`; no warning when `jq` missing | Fixed `a24367d` |
| L4 | Low | Deleted posts readable on other instances up to 60 s | Accepted; runbook states the 60 s user-facing SLA |
| L5 | Low | Blank-looking posts and tag characters | Blank-looking set fixed `a6357de` (ADR amendment, Go + Dart + fixture). Tag characters unchanged: they are `Cf` and needed for subdivision flags; rejecting them needs a flag-sequence parser (out of scope, recorded in ADR-0010 D21 G4) |
| L6 | Low | Timelines did not filter `Visibility` | Fixed `a24367d` (fail closed, unit test) |

## Accepted by ADR (not findings)
Suspended authors stay in followers' Home until P7 (D10); mentions of a deleted user remain in other users' posts (runbook); residual
risks R1 (verified sybils) and R2 (instance churn) of ADR-0010 D5 accepted by the founder 2026-10-01.

## Follow-ups
- Make sure `osv-scanner` covers the new pub dependency `unorm_dart` (it scans `app/pubspec.lock`; CI is green).
- Re-check tag-character handling before any LLM or moderation feature consumes post text (hidden-payload channel).
