# Security review: UI wave W2 (bookmarks, share, shared-link routing, composer basics)

Ticket W2-14 of `docs/plans/ui-w2-engagement-composer-basics.md`. Reviewed by the security-auditor agent on `main`
d2ff011 (2026-10-26), read-only, after every W2 ticket had merged (#306 to #319). Verdict: **CLEAR**, no Critical or
High finding; one Medium (M-1) to land before `FEATURE_BOOKMARKS` leaves `off` in any project. Fixes are tracked in
the two W2-14 fix PRs (backend: M-1, L-1, L-2, L-3, I-4; client: L-4, L-5, L-6, I-1).

## Scope

New owner-only reads and writes: `users/{uid}/bookmarks/{postId}`, `userLikes.bookmarks[]`, the three bookmark RPCs,
the bookmarks eraser and export, `PostView.bookmarked_by_viewer`; the share URL and `PUBLIC_WEB_ORIGIN`; the
shared-link allowlist and redirect chain; the quote gate; the push opt-in store. Threat model per the
`security-checklist` skill (STRIDE over the new surface), the ADR-0023 D4 abuse arithmetic, and the tester's W2-13
observations.

## Findings

| ID | Severity | Component | Where | Finding | Fix | Blocks W2-16 |
|---|---|---|---|---|---|---|
| M-1 | Medium | Add/Remove no-op writes | `engagement/repo_bookmarks.go` no-op paths; `apiserver/ratelimit_config.go` `DailyCaps` | Since the ADR-0023 dated note, both no-op paths store the idempotency doc (1 write + 1 TTL delete) with no quota charge, and RemoveBookmark is open to every authenticated user whenever the flag is not globally off. Only the 30/min bucket and the per-instance read budget bound it: about 7,100 writes and 7,100 deletes per account per day steady (about INR 23/month per account), far more with idle-cycling instances (about INR 430/month per account); a 10-account ring would be about 17% of the credit cap. | Shared `bookmark_mutation_daily` cap over Add + Remove (`BOOKMARK_MUTATIONS_PER_DAY`, default 1,500), guard test, runbook row. 0 Firestore cost. | Yes |
| L-1 | Low | ListBookmarks block filter | `service_bookmarks_list.go` `blockCause` | With the caller's `blockedBy` overflowed, the direct author is not failed closed (the embedded author is). GetThread fails closed. Needs 10k blockers, so not reachable at Stage 0 scale. | Fail closed for a foreign direct author on overflow (0 reads). | No |
| L-2 | Low | ListBookmarks visibility | `service_bookmarks_list.go` | The list drops moderated posts but never checks `Visibility != Public && !Following[author]`; today every post is public, so nothing leaks yet. | Add the 0-read check now so followers-only posts cannot leak through Bookmarks once private accounts ship. | No |
| L-3 | Low | Add contention error class | `repo_bookmarks.go`, `service_bookmarks.go` `mapBookmarkErr` | Exhausted transaction retries or the 5 s timeout surface as INTERNAL, reach Error Reporting and would count toward the rollback trigger. Consistency holds. | Map to a retryable code at WARN, keep out of the rollback metric. | No |
| L-4 | Low | `PUBLIC_WEB_ORIGIN` validation | `app/lib/app/app_config.dart` `resolveShareOrigin` | Accepts newline, space, `%23`, upper-case, trailing dot, raw IDN, IP literal, any port; returns the raw input. Only CI or the founder set it, so the risk is misconfiguration. | Canonical `uri.origin`, ASCII host grammar, probe cases in the test. | No |
| L-5 | Low | Undo after sign-out | `bookmarks_list_cubit.dart` `restore` | No session guard; a stale Undo could send AddBookmark under the next account's token when the captured row carried `bookmarked_by_viewer = false`. Needs a shared device and specific cohorts; harm is one unwanted bookmark. | Session-generation guard in `restore`; clear app-level snackbars on sign-out. | No |
| L-6 | Low | `push_opt_in_not_now:<uid>` | `push_opt_in_store.dart`, `app_database.dart` `clearAll` | A Firebase uid plus a timestamp survives account deletion on the device (DPDP / GDPR erasure point). | Delete the key on the DeleteAccount success path; keep it across a plain sign-out. | No |
| I-1 | Info | `deepLinkTarget` | `app_router.dart` | Accepts `%2F` and `%0D%0A` inside `/u/` segments. Not an open redirect: the target always starts with an allowlisted prefix and only feeds go_router; the server rejects the value. | Tighten `/u/` and `/profile/` to the uid and handle charsets. | No |
| I-2 | Info | Blocked-author bookmark | `posts/service_delete.go` vs the list filter | A post whose author the caller blocked can still be bookmarked (parity with GetPost, which answers 200); the list hides it; it counts toward the 1,000 cap. | Accept as parity; optional later product ticket to hide the icon on such rows. | No |
| I-3 | Info | RemoveBookmark timing | `repo_bookmarks.go` | A Remove of an already pruned row takes about one extra RTT versus a kept row; block status is already observable through the profile, so no new oracle. Bytes identical. | None. | No |
| I-4 | Info | Post ids in error logs | `purge_bookmarks.go`, `service_bookmarks*.go` | Error chains can carry a post id next to the uid hash at ERROR. | Pass the post ids to `RedactErr`. | No |
| I-5 | Info | Recreate-after-delete window | `purge_bookmarks.go`, lifecycle start gate | Prune, Remove and Add use field-level merges that could recreate `userLikes`, but the 120 s deletion start gate exceeds cache TTL plus RPC deadline, so no in-flight request can reach the eraser window. | Optional hardening: blind `Delete` of `userLikes` in the step's last call. | No |
| I-6 | Info | Rollout precondition | `posts/api.go` `HydrateViewer` | With `bookmarks` on and `engagement` off the server hydrates the flag but the client has no toggle. No leak (`BookmarksOnly` strips liked and reposted). | W2-16: bookmarks cohort must be a subset of the engagement cohort; the `userLikes.bookmarks` fieldOverride must be deployed first. | Precondition |
| I-7 | Info | REPOST-id Add cost | `engagement/service.go` | Measured 8 cold reads against the documented 9. | Optional ADR note. | No |
| I-8 | Info | Deep-link replay | `app_router.dart` | An email-unverified user who signs out lets the next account land on the pending view-only target under its own authz. | None. | No |
| I-9 | Info | Quota record across a traffic split | `pkg/platform/quota/quota.go` | A revision without `quota.Bookmarks` serving quota writes during a split would zero the field (ADR-0021 I-3 class); not an issue as shipped. | Never turn the flag on in the same rollout that first introduces the field. | No |

## Verified sound

- Every bookmark path is built from the token uid; no collection-group query; `post_id` validated (19 ASCII digits) before any path or read.
- The list cursor is AES-GCM sealed with AAD `bookmarks|<uid>` and a 24 h TTL; foreign, expired or tampered tokens fail at 0 reads.
- Idempotency keys are scoped per uid and RPC with a 24 h TTL policy; request-hash reuse is refused.
- AddBookmark uses the same visibility path as GetPost and its NOT_FOUND bytes are identical for every invisible case; cap and quota are checked only after visibility; RemoveBookmark reads no post.
- Every `userLikes` write is field-level (merge with ArrayUnion/ArrayRemove, or a field delete); no other module writes `userLikes`.
- The cap is exact (array length inside the transaction); the quota kind is complete; limits live in config and Terraform and are reviewed like logic; the per-uid read budget covers List (429 at about 2,000 reads measured).
- Prune touches only rows the batch load confirmed missing, is bounded to 50 ids, is skipped under readonly, and costs 1 write + 1 delete per row once.
- Erasure: step `bookmarks` after `scheduled`, self-resuming pages of 500, then the field clear; T11 row present; never flag-gated. Export carries ids and times only.
- Firestore rules remain deny-all; the `userLikes.bookmarks` override is `indexes: []`.
- Flag gates behave as ADR-0023 D5 states; `engagement` off plus `bookmarks` on strips liked and reposted; the quote gate is enforced server-side before any read.
- Bookmark RPCs require a profile and therefore a verified email.
- Request lines carry counts only; internal errors reach clients as a generic message.
- Share: origin + `/post/<id>` only, no token, uid, query or fragment; the clipboard gets exactly the URL; the native sheet gets the URI only with mailto and download fallbacks off.
- Deep links: scheme and authority rejected; only view routes allowlisted; the landed latch stops re-stashing; `/__/*` is served by Hosting before the rewrite; drift assets load from the root; CSP has `base-uri 'self'` and `object-src 'none'`.
- Client bookmark state is memory-only and wiped on the session epoch; one idempotency key per intent.

## Not performed

A real-browser cold open on the dev Hosting site (W2-13 manual item); cloud state (idempotency TTL policy enabled, fieldOverride deployed) which is a W2-16 precondition; `govulncheck` and `osv-scanner` beyond the CI job (confirm it is green on #315 and #318 for `share_plus` and `flutter_web_plugins`).
