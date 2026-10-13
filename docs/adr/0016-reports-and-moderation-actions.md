# 0016. Reports, takedown and suspension (moderation.v1, P7)
Status: Proposed
Date: 2026-10-10
Deciders: architect (proposed by the P7 slice agent), founder (decisions delegated to the lead 2026-10-10, recorded in
`docs/plans/reports.md` "Decisions (delegated 2026-10-10)"). Not Accepted: needs the founder's acceptance.

Plan: `docs/plans/reports.md` (P7). Builds on ADR-0003 (`reports` row), ADR-0005 (moderation), ADR-0008 (block UI,
D9), ADR-0010 (D6 visibility matrix, **D10 suspension obligation**, D19 Q-E) and ADR-0011 (Q1 eraser order, Q10 residue).

## Context
- App Store 1.2 and Play UGC policy require a way to report objectionable content, block abusers, act on reports and
  publish a response time. Block already ships (ADR-0008). Reports, takedown and suspension do not.
- Stage 0 has no admin console (phase1 P7). The founder acts through `opsctl` (ADR-0008 T11) on their own machine.
- ADR-0010 D10: Home does not filter suspended authors (it would cost a `users` read per author per page), so
  suspending a user must take their posts out of every feed within 60 s some other way.
- `AccountStatusSuspended` exists. The status interceptor already answers `ACCOUNT_RESTRICTED` to a suspended caller
  and `identity.Directory` drops suspended users, but nothing writes the status.

## Options
### A. Where a taken-down post is hidden
1. **Delete the post doc** and keep a copy in `reports`. Loses author-visible history, breaks counters
   (`postsCount`), and cannot be undone. Rejected.
2. **A `moderation` field on the post doc, filtered on read (chosen).** Reversible, 0 extra reads (the field arrives
   with the doc every read path already fetches), and one filter point already exists in the timeline.
3. A deny-list collection read on every request. +1 read per page; rejected (rule 6).

### B. How suspension hides posts
1. Filter by author status on Home: a `users` read per distinct author per page. Rejected (ADR-0010 D10).
2. **Mark every post of the suspended user hidden, once, by `opsctl suspend-user` (chosen).** O(posts) writes once per
   suspension, resumable, reversible by `unsuspend-user` (only the posts the suspension hid).

### C. Report dedupe and idempotency
1. A `idempotency/{hash}` doc per call (+1 read, +1 write, TTL doc).
2. **A deterministic report id from (reporter, target type, target id) (chosen).** The natural key makes a second
   report by the same reporter on the same target a read-only no-op that is not charged to the quota. This is the
   graph pattern (`follows/{a}_{b}`). The request still carries `idempotency_key` (rule 4) and validates it.

## Cost impact
$0 at Stage 0. Detail in the plan's cost line. Summary:
- `ReportContent`: 2-6 reads, 2 writes (planning 3 / 2) at ~0.02 calls/DAU: ~0 per DAU. At 300 DAU about 6 calls/day.
- Read-path filtering: **0 additional reads** on GetPost, GetUserTimeline and Home. The filter runs on documents the
  query already returns. The cost is one extra byte-sized field per post doc and, for a hidden post, the read of a
  document the page then drops (one page may return fewer items; the timeline merge already handles filtered rows).
- `opsctl suspend-user`: reads = writes = P (user's posts), once, in batches of 500, run by the founder from a laptop.
  A 5,000-post account is 5,000 reads + 5,000 writes (25% of the 20k/day free writes and 10% of the 50k reads;
  run it off-peak). Typical: under 500.
- Reports retention: Firestore TTL on `reports.expireAt` (free, ADR-0003 pattern) deletes 90 days after resolution.
  Open reports have no `expireAt`. Storage: ~1 KB per report; 1 GiB free holds 1M reports.
- No new GCP resource, no fixed cost. One composite index (`reports`: status ASC, createdAt ASC) is $0.

## Decision
### D1. API: `dzeroth.moderation.v1.ModerationService.ReportContent` (one RPC)
Request: `idempotency_key`, `target_type` (POST | ACCOUNT), `target_id`, `reason` (enum), optional `note` <= 500
code points. Response: `report_id`, `already_reported`. Flag `FEATURE_REPORTS` (wire name `reports`), default OFF
in every environment's Terraform variable. Per-procedure rate limit like the other mutating RPCs, quota `reports`
(20/day, 5/day for accounts < 24 h) via `pkg/platform/quota`. No RPC for moderator actions (opsctl only).

Target visibility is resolved by the same code paths the clients already use (`posts.Service.GetForViewer`,
`identity.Service.GetProfile`), so a reporter cannot probe for hidden, blocked or suspended targets: every failure
is the same NOT_FOUND. Reporting your own post/account is `VALIDATION target_id`.

### D2. Data model: `reports/{reportId}`
`reportId` = first 32 hex chars of SHA-256(`reporterId` + `|` + `targetType` + `|` + `targetId`).

| Field | Type | Notes |
|---|---|---|
| `reporterId` | string | uid; cleared to `""` by the reports Eraser when the reporter deletes their account |
| `targetType`, `targetId` | string | `POST` or `ACCOUNT`; post id or uid |
| `targetOwnerId` | string | the post's author, or the account's uid |
| `reason`, `note` | string | enum name; <= 500 code points |
| `status` | string | `OPEN` or `RESOLVED` |
| `evidence` | map | POST only: `text`, `authorHandle`, `mediaIds[]` (the post's image ids at report time, copied from the post already read: 0 reads), `postCreatedAt`. Copied at report time |
| `createdAt` | timestamp | the first filing; a reopen keeps it, so a re-reported case is as old in the queue as its first report |
| `resolvedAt`, `resolution`, `resolutionNote` | | `resolution`: `NO_ACTION`, `TAKEDOWN`, `SUSPENDED`, `DISMISSED` |
| `expireAt` | timestamp | set at resolution: `resolvedAt + 90 d`. Firestore TTL deletes the doc. Absent while OPEN |

**Re-reporting after RESOLVED reopens the report.** The id is deterministic, so a second filing by the same reporter of
the same target finds the document. If it is `OPEN` the call is the plain no-op repeat (1 read, 0 writes, not charged).
If it is `RESOLVED` the same transaction reopens it: `status = OPEN`, `reason`, `note` and `evidence`
replaced (the original `createdAt` is kept), `resolvedAt`/`resolution`/`resolutionNote`/`expireAt` deleted (so the TTL cannot delete a live report), the
`reports` quota charged. 2 reads, 2 writes, like a first report; `already_reported` is false. The new filing is the
signal that the earlier decision may be wrong or the problem recurred; silently dropping it (the original behaviour)
hid exactly the reports that matter.

A reporter whose daily quota is spent is remembered per instance until the next IST midnight (or until the
new-account window ends and the limit rises), so retries cost 0 Firestore reads; a replay of an existing report by
such a reporter gets the quota error rather than `already_reported` until then.

Rules: deny-all to clients (existing). Index: `(status ASC, createdAt ASC)` for `opsctl reports list`. The
`reporterId == uid` and `targetOwnerId == uid` queries use single-field indexes.

### D3. Post doc: `moderation` field
`posts/{id}.moderation` is absent (visible), `"TAKEN_DOWN"` (a moderator removed this post) or
`"SUSPENDED_AUTHOR"` (hidden because the author is suspended), plus `moderatedAt`. Additive, no migration.
- `posts.Post.Moderation` carries it, `Post.Hidden()` is `Moderation != ""`. `Post.Visible()` helper for callers.
- **Every read path drops hidden posts:**
  - `GetPost` (`GetForViewer`): same `post not found` NOT_FOUND as for a missing post, for everyone including the author
    (no ghost post, no existence oracle). Stage 0 has no appeal UI; the runbook covers handling by email.
  - `GetUserTimeline` and `GetHomeTimeline`: the existing `keep` predicate (`isPublic`) becomes `isVisible` and also
    drops `Hidden()`. The merge already counts and skips filtered rows, so there are no extra reads.
  - `posts.Reader` documents the rule: **every consumer must drop `Hidden()` posts** (P3 replies, P6 notifications,
    P5 engagement counts must follow). `GetMany` and `Get` still return them, with the flag, so a consumer can decide.
- **60 s bound.** opsctl writes the doc from another process. Running instances serve the old value until their post
  cache entry or author-recent entry expires: `CACHE_TTL` (default 60 s, ADR-0010 D15) after the data was read. The
  `since` refresh watermark does not add delay (a taken-down post is not "new"). The client's own cache keeps a
  hidden post until it next refreshes the page (GetPost -> NOT_FOUND; the client drops the card). This is the stated
  bound: <= CACHE_TTL on the server, then the next client refresh.
- `postsCount` on `users` is NOT decremented (a takedown is reversible, and the count is not a visibility signal).

### D4. Moderator actions: `opsctl`
All commands require `--project`, ask for a typed confirmation on a `-prod` project (existing `confirmed`) and print
reads/writes. Flags marked (W) write.
- `reports list [--status OPEN|RESOLVED] [--limit N]`: oldest-first (FIFO) by createdAt (status, createdAt index);
  `--limit` default 20, max 50 (rule 5).
- `reports show --id R`: one report, with evidence.
- `reports resolve --id R --resolution NO_ACTION|DISMISSED [--note ...]` (W): sets RESOLVED + `expireAt`. TAKEDOWN and
  SUSPENDED are only set by `takedown-post` / `suspend-user --report`, so a resolution always matches an action.
- `--report R` on `takedown-post` / `suspend-user` is checked against the target first (1 read, before any write):
  the report must be about that post (takedown) or about that user or one of their posts (suspend), else the command
  refuses with nothing written. An already RESOLVED report only prints a warning; the action still applies.
- `takedown-post --post P [--report R] [--dry-run]` (W): `moderation = TAKEN_DOWN`; with `--report`, resolves it as
  TAKEDOWN. `restore-post --post P` (W) clears `TAKEN_DOWN` only.
- `suspend-user --uid U [--report R] [--dry-run]` (W): one transaction sets `users/{uid}.status =
  SUSPENDED` through a new identity repo method (`SetAccountStatus`, status + updatedAt only, from ACTIVE only), then
  hides the user's posts with a resumable loop (below), waits out the instance cache and runs a settle pass, then
  (optionally) resolves the report as SUSPENDED. (`--skip-hide` was proposed and is not built: a suspension that
  leaves posts visible is the failure D10 forbids.)
  `unsuspend-user --uid U` (W): status SUSPENDED -> ACTIVE, then restores posts whose `moderation` is
  `SUSPENDED_AUTHOR`. A post that was `TAKEN_DOWN` stays hidden through suspend and unsuspend.
- The suspension hide loop (`posts.Moderator.HideAuthor`): query Q-E (`authorId == uid` ordered `createdAt DESC,
  __name__ DESC`, existing index) in pages of 500 with a `StartAfter` position as checkpoint; one batch `Update` per
  post whose `moderation` is empty. A re-run re-queries from the start, skips already-hidden posts (0 writes for
  them, 1 read each), so it is resumable and idempotent. Order: status first, then posts, so a crash leaves a
  suspended user with some visible posts, never the reverse; re-running `suspend-user` finishes the job (the
  command accepts an already-SUSPENDED account for exactly that reason). Every update carries the `LastUpdateTime`
  of the snapshot it was decided from (the same for `RestoreAuthor`), so a post a concurrent takedown or author
  delete changed fails the batch and is re-read instead of overwritten.
- **Settle pass (posts created in the cache window).** Warm instances cache the account status for up to `CACHE_TTL`
  (<= 60 s, `config.MaxCacheTTL`), so a suspended user can still create posts on them after the loop read its
  pages. After the loop, opsctl waits `CACHE_TTL + 15 s`, then runs `HideAuthor` once more restricted to
  `createdAt >= suspensionStart - 2 min` (Q-E with a range on its first order field: the existing index, reads only
  that window, 1 when empty). After the wait no instance accepts a post from the account, so nothing can be created
  behind the pass. The command takes about 75 s longer; the clock and the wait are injected in tests.
- Suspension never touches Firebase Auth (IAM control C2, `authadmin_guard_test.go` untouched): the Firestore status
  is what the interceptor reads. Cache bound: the identity cache TTL, 60 s.

### D5. Retention, SLA and privacy (founder decisions delegated 2026-10-10)
- Evidence is kept **90 days after resolution**, then TTL-deleted. Unresolved reports are kept until resolved.
- Response SLA: acknowledge and triage within 48 hours; clearly illegal content removed as soon as seen
  (`docs/runbooks/moderation.md`).
- The reporter's identity is never returned by any RPC and never shown to the reported user. Reporting yourself is
  rejected.
- Right to delete: reports **as reporter**: the reports Eraser (step `reports`, before identity) sets
  `reporterId = ""` on the user's reports (resumable pages of 500, self-resuming because updated docs leave the
  query). The report itself stays: it describes third-party content and is safety evidence. Reports **about** the
  user: kept until resolved + 90 d, then TTL. This is a Q10 residue: allowlist entries `reports.targetOwnerId` and
  `reports.targetId` (+ `evidence`) with this ADR as the citation. **The privacy policy must say that reports about
  an account are retained for safety until 90 days after resolution** (founder action; flagged in the plan).
- Export: the `reports` export section lists the reports the user **filed** (id, target, reason, note, status,
  createdAt). Reports about them are not exported (they would reveal reporters).

### D6. Out of scope
Appeals, a moderator UI, automated actions, per-reason rate analytics, copying media bytes (only media ids are
copied into `evidence.mediaIds`; GCS object retention is the media slice's).

**Media on takedown (known gap, follow-up).** `takedown-post` hides the post document; it does not touch the
post's image objects, which stay public in the media bucket until someone deletes them. P4's `post_delete` job
destroys the objects when the author deletes the post (or the account), so image evidence is lost at that moment;
only the ids in `evidence.mediaIds` and the text survive. For now the runbook (`docs/runbooks/moderation.md`, "Media
on takedown") has the moderator delete or make private the objects by hand, and the plan carries ticket T14
(`takedown-post --purge-media`). It is not built in this PR.

## Consequences
- Positive: store requirement met at $0; every read path filtered with 0 extra reads; reversible actions; the D10
  obligation is closed.
- Negative: takedown/suspension are visible for up to CACHE_TTL on other instances; a post doc read of a hidden
  post is wasted; `Reader` consumers must remember to drop `Hidden()` (mitigated by a doc comment and by exposing
  `Visible()`); report evidence retention is a privacy-policy item.
- Risks: a 5,000-post suspension is 5,000 writes in one run (mitigated by resumability; it is the founder's own call and prints the plan with `--dry-run` first);
  founder is the only moderator and the single point of response SLA.
- Revisit when: reports exceed ~50/day (build a console and a queue), or the first appeal, or a second moderator.

## Open founder decision (not decided; the ADR stays Proposed)
**D10 client bound.** D3 states the bound for a hidden post as "<= CACHE_TTL on the server, then the next client
refresh". The client side is not bounded by anything the server can enforce: a `since` refresh returns only *new*
posts, so a card the client already holds stays on screen until the user does a full reload or the timeline token
expires. Two ways to close it; the founder has not chosen:
1. **Server-only bound (current, no proto change).** Document that a hidden post leaves a client's feed on its next
   full page load, and that GetPost on the hidden id answers NOT_FOUND. Cheapest; a taken-down post can linger on a
   device that never does a full reload.
2. **Additive `removed_ids` field on the timeline `since` response** (a new repeated field on
   `GetHomeTimelineResponse` / `GetUserTimelineResponse`; backwards compatible, `buf breaking` clean). The server
   needs to know which ids to remove, which costs a read per hidden post in the window (a `moderatedAt >= since`
   query and one more index) or a bounded moderation-event log; the client drops those ids on refresh.
`timeline.proto` is deliberately not changed here. Decision owner: founder, with the architect for option 2's read
cost. Until then this ADR cannot be Accepted.

## Handoff
- Backend: `internal/moderation` (service, repo, server, Eraser, exporter), `posts` moderation seam, identity
  `SetAccountStatus`, opsctl commands, config + flag + quota, lifecycle wiring and guard rows.
- Frontend: report sheet, entries in PostCard overflow and profile menu; reuse RelationshipCubit and
  showBlockConfirmationDialog.
- Infra: `FEATURE_REPORTS` env var in Terraform (default off, no apply), TTL field `reports.expireAt` added to
  the firestore module's `ttl_fields`, index in `firebase/firestore.indexes.json`.
- Founder: privacy-policy line (D5), accept this ADR, set the flag allowlist when ready.

## Implementation notes (P7 backend PR)
Recorded so the contract and the code agree; none of them changes D1-D6.
- **Rate limit.** `ReportContent` has its own 5/min per-user bucket (`RATE_LIMIT_REPORT_PER_MIN`, default 5); the daily
  bound is the `reports` quota (`QUOTA_REPORTS_PER_DAY` 20, `QUOTA_NEW_ACCOUNT_REPORTS_PER_DAY` 5).
- **Exports and deletion budget.** The `reports` export section costs one read per filed report (minimum 1, the empty
  page). With P4's own `media` export section the reference export row is **705** reads (703 + 1 media + 1 reports,
  was 704 before P4 merged); the `reports` Eraser step costs one read for the empty page on the reference account.
  Delete job: the account-deletion plan's T16 acceptance criterion (`docs/plans/account-deletion-export.md`, 509 reads + job state) becomes 511, which needs sign-off from that plan's owner (+1 P4 media step, +1 P7 reports step, each one read for an empty page); measured on the reference account: 511 reads in one delivery, against 511 + D (the ADR-0011 formula's per-delivery job-state allowance). Asserted in `account_lifecycle_reference_integration_test.go`.
  Both are asserted in `account_lifecycle_reference_integration_test.go`.
- **Residue allowlist.** `reports.targetOwnerId` and `reports.targetId` are the two new T11 entries (5 to 7). The
  privacy policy line is a founder action and a gate for turning `FEATURE_REPORTS` on.
- **Infra.** Env vars `FEATURE_REPORTS*` (default off), the two quota vars, and one Firestore TTL policy on
  `reports.expireAt` in the firestore module's `ttl_fields`. TTL policies and the one composite index are $0.

