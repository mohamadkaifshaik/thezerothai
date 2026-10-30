# 0016. Reports, takedown and suspension (moderation.v1, P7)
Status: Accepted (founder, 2026-10-17; includes the rule-4 bend in option C and the D10 decision below)
Date: 2026-10-10 (amended 2026-10-17: D10 decided, D2/D3 corrections; founder approval 2026-10-17; D10 cost text amended 2026-10-18, founder approval 2026-10-18)
Deciders: architect (proposed by the P7 slice agent), founder (decisions delegated to the lead 2026-10-10, recorded in
`docs/plans/reports.md` "Decisions (delegated 2026-10-10)"; ADR accepted 2026-10-17).

> Note (2026-10-26): the "$0 at Stage 0" figures below are the planning assumption of the time and are kept as
> history. The measured model (ADR-0022, `docs/reviews/cost-model.md`) puts Stage 0 as configured at about
> INR 434 / 1,626 / 3,396 per month at 300 / 1,000 / 3,000 DAU (egress to India, Vision past 1,000 units, Firestore
> reads past about 215 DAU). The prime directive forbids a fixed monthly fee, not a per-use bill. No decision changes.

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
   This bends CLAUDE.md rule 4 (the key is validated, not stored); **explicitly approved by the founder 2026-10-17**.

## Cost impact
$0 at Stage 0. Detail in the plan's cost line. Summary:
- `ReportContent`: 2-6 reads, 2 writes (planning 3 / 2) at ~0.02 calls/DAU: ~0 per DAU. At 300 DAU about 6 calls/day.
- Read-path filtering: **0 additional reads** on GetPost, GetUserTimeline and Home. The filter runs on documents the
  query already returns. The cost is one extra byte-sized field per post doc and, for a hidden post, the read of a
  document the page then drops (one page may return fewer items; the timeline merge already handles filtered rows).
- `opsctl suspend-user`: reads = writes = P (user's posts), once, in batches of 250, run by the founder from a laptop.
  A 5,000-post account is 5,000 reads + 5,000 writes (10,000 with the D10 removal-log entries; 25% of the 20k/day free writes before D10 and 10% of the 50k reads;
  run it off-peak). Typical: under 500.
- Reports retention: Firestore TTL on `reports.expireAt` (free, ADR-0003 pattern) deletes 90 days after resolution.
  Open reports have no `expireAt`. Storage: ~1 KB per report; 1 GiB free holds 1M reports.
- No new GCP resource, no fixed cost. One composite index (`reports`: status ASC, createdAt ASC) is $0.
- D10 `removed_ids` (decided 2026-10-17, not built): ~1 read per instance per TTL warm (incremental; at most ~4.3k
  reads/day, ~9% of free, with 3 instances busy all day), + the live entries once per cold start; writes +1 per
  hidden post (a suspension of P posts adds P); one more TTL policy ($0).
  **Superseded 2026-10-18** by the Implementation notes and the Amendment 2026-10-18 at the end of this ADR: the cold load
  is bounded to 50 reads, and a hide or restore costs 2 writes (the post and its log entry).

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
| `evidence` | map | POST only: `text`, `authorHandle`, `mediaIds[]` (the post's image ids at report time, copied from the post already read: 0 reads), `postCreatedAt`; B2 adds optional `originalPostId` on repost reports, where the other fields are the original's (see docs/plans/reports.md T16). Copied at report time |
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
new-account window ends and the limit rises), so a retry costs 1 Firestore read (a point read of the deterministic
report id) and no transaction: a replay of a report that is `OPEN` is answered `already_reported` (it needs no
quota); a new or reopening filing gets QUOTA_EXCEEDED until then. (Corrected 2026-10-17 to match
`moderation/service.go` and `TestReport_ExhaustedQuotaIsRememberedUntilMidnight`; same as the Implementation notes.)

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
  `since` refresh watermark does not add delay (a taken-down post is not "new"). The bound is <= CACHE_TTL on the
  server. On the client there is **no bound yet**: a `since` refresh returns only new posts, so a card the client
  already holds stays on screen (opening it answers GetPost NOT_FOUND) until `removed_ids` (D10 below, plan T15)
  ships. (Corrected 2026-10-17: the earlier "until it next refreshes the page" / "leaves on its next full page
  load" is not true of the current client.)
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
- `takedown-post --post P [--report R]` (W; no dry run): `moderation = TAKEN_DOWN`; with `--report`, resolves it as
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
  `reports.targetId` with this ADR as the citation (the embedded `evidence` copy holds text, `authorHandle` and media ids, no uid, so it needs no entry; `authorHandle` is a snapshot of the handle at report time, kept deliberately for safety evidence so it survives a rename or deletion). **The privacy policy must say that reports about
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

## D10. Client bound for hidden posts: DECIDED 2026-10-17 (option 2), NOT YET IMPLEMENTED
Founder approval 2026-10-17. (This ADR's D10; not to be confused with ADR-0010 D10, the suspension obligation that
D3/D4 close.) Problem: a `since` refresh returns only *new* posts, so a card the client already holds
stays on screen after a takedown or suspension (D3). Options were:
1. Server-only bound (no proto change): a taken-down post can linger on a device indefinitely. Rejected.
2. **Additive `removed_ids` on the timeline responses (chosen).** A new `repeated string removed_ids` on
   `GetHomeTimelineResponse` and `GetUserTimelineResponse` (new field numbers, backwards compatible, `buf breaking`
   clean). Backed by **a single global moderation-event log**: a new small collection written only by opsctl
   (`takedown-post`, `suspend-user`; entries TTL-bounded), read by the API incrementally (`createdAt > lastSeen`) once
   per instance per CACHE_TTL and held in the instance cache, so a refresh costs ~0 extra reads. The client drops
   those ids from its cache on refresh. Rejected variant: a per-request `moderatedAt >= since` query (+1 read per
   refresh and one more index).
- Cost: warm, ~1 read per instance per CACHE_TTL (incremental; an empty query still bills 1 read): at most 3 x 1,440
  = ~4.3k reads/day (~9% of the free 50k) if all 3 instances serve timelines all day, far lower typically. Plus the
  live entries once per cold start (a non-empty query bills 1 read per returned doc). Writes: +1 per hidden post, so
  a suspension of P posts adds P log writes on top of its P hide writes (a 5,000-post account: ~10k writes, 50% of
  the free daily writes; run off-peak, as D4). $0 fixed.
  **The two cost sentences above ("the live entries once per cold start", "+1 per hidden post ... adds P") are superseded
  2026-10-18 (founder approval); see the Amendment 2026-10-18 at the end of this ADR.**
- Not built until these tickets land (plan T15): (a) proto field on both responses; (b) opsctl writer, with the
  collection's TTL policy and its ADR-0011 T11 lifecycle-guard row (`make ci` fails without it); the log's live
  window is bounded and its retention is set against the 30-day `since` token TTL (an entry must outlive any token
  that could still hold the card); (c) server read-count test: the read is incremental (~1 read per instance per
  TTL warm, the live window once cold, 0 on a warm cache hit); (d) Flutter drop-on-refresh plus a client test; (e)
  warm-instance fake-clock test (an entry written after the cache filled is served once the TTL expires).
- Until it ships, D3's client side stays unbounded.

## Gates before `FEATURE_REPORTS` leaves off (founder approval 2026-10-17)
- The privacy-policy line of D5 is published.
- The media-public gap of D6 is known and handled by the runbook until T14 (`takedown-post --purge-media`) is built.

## Handoff
- Backend: `internal/moderation` (service, repo, server, Eraser, exporter), `posts` moderation seam, identity
  `SetAccountStatus`, opsctl commands, config + flag + quota, lifecycle wiring and guard rows.
- Frontend: report sheet, entries in PostCard overflow and profile menu; reuse RelationshipCubit and
  showBlockConfirmationDialog.
- Infra: `FEATURE_REPORTS` env var in Terraform (default off, no apply), TTL field `reports.expireAt` added to
  the firestore module's `ttl_fields`, index in `firebase/firestore.indexes.json`.
- Founder: privacy-policy line (D5), set the flag allowlist when ready (ADR accepted 2026-10-17).
- D10 (`removed_ids`): backend (proto, opsctl writer, read-count tests), frontend (drop on refresh), infra (TTL
  policy for the log collection); tickets in `docs/plans/reports.md` T15.

## Implementation notes (P7 backend PR)
Recorded so the contract and the code agree; none of them changes D1-D6.
- **Rate limit.** `ReportContent` has its own 5/min per-user bucket (`RATE_LIMIT_REPORT_PER_MIN`, default 5); the daily
  bound is the `reports` quota (`QUOTA_REPORTS_PER_DAY` 20, `QUOTA_NEW_ACCOUNT_REPORTS_PER_DAY` 5).
- **Exports and deletion budget.** The `reports` export section costs one read per filed report (minimum 1, the empty
  page). On the reference account the export row is **707** reads: 703 + 1 P4 `media` section + 2 P6
  `notifications` section + 1 P7 `reports` section (it was 703 before P4, 705 with P4 and P7). The `reports` Eraser
  step costs one read for the empty page.
  Delete job: the account-deletion plan's T16 criterion (`docs/plans/account-deletion-export.md`, 509 reads + job
  state) gains +1 for the `reports` step's empty page and +3 for P6's `notifications` step (ADR-0017 D10), so the
  plan criterion is 509 + 3 + 1 = 513 + D at this point (with P5's +3 and amendment (b)'s +1 it is 517 + D, `planDeleteReads`); the ADR-0011 formula constant is 510 + 3 + 1 = 514 + D at this point (518 + D with the same two additions, `refDeleteReadsBase`, corrected 2026-10-18)
  (`refDeleteReadsBase`); ADR-0017's 512 / 513 are the P6-only values. P4's media step read was already absorbed by main's 509 + D. The amendment is
  the P8 plan owner's to sign off (the T16 amendment was approved by the founder 2026-10-18). Both are asserted in `account_lifecycle_reference_integration_test.go`.
- **Re-report and replay.** A report resolved earlier is reopened by a new filing (D2). A reporter whose quota is
  spent is remembered per instance until IST midnight; a call then costs one point read of the report: an OPEN report
  is answered `already_reported` (the replay needed no quota), anything else is QUOTA_EXCEEDED.
- **Dry run.** Only `purge-graph`, `purge-posts` and `suspend-user` have a dry run. `takedown-post`, `restore-post`,
  `unsuspend-user` and `reports ...` reject `--dry-run` with exit 2 (accepting and ignoring it would write).
- **Deleted reporters' notes.** The Eraser also clears `note` on RESOLVED reports it anonymises (open ones keep it
  until a moderator has read it).
- **Residue allowlist.** `reports.targetOwnerId` and `reports.targetId` are the two new T11 entries (5 to 7). The
  privacy policy line is a founder action and a gate for turning `FEATURE_REPORTS` on.
- **Infra.** Env vars `FEATURE_REPORTS*` (default off), the two quota vars, and one Firestore TTL policy on
  `reports.expireAt` in the firestore module's `ttl_fields`. TTL policies and the one composite index are $0.


## Implementation notes (D10 server half, `feat/removed-ids`; for architect review)
Where the build differs from the D10 text, and why. Client work (ticket d) is still open.
- **Cold read is bounded to the newest 50 entries, not "the live entries".** After a 5,000-post suspension "the live
  entries once per cold start" would be thousands of reads on every cold start for 30 days. The instance loads the newest
  50 (`Limit` 50, rule 5); a client whose since token is older than the oldest loaded entry, or who would need more than 50
  ids, gets the truncation signal below. Worst warm refresh: 1 read (empty or unchanged log), 50 (changed), 100 (a full
  incremental page reloads the newest 50 instead of paging forward).
- **Truncation signal reuses the since_token rejection** (INVALID_ARGUMENT + VALIDATION, `field = since_token`, decided before
  any post read) instead of a new proto field. The existing client merges the cold open, which keeps the stale cards, so
  ticket (d) must make a rejected `since_token` a replacing cold open. No existing path does that for a refresh today. This amends ADR-0010 D14, which says a rejected since_token is followed by a cold open that fills down to the cached items; the proto comment now says every rejected since_token is replaced (the client cannot tell truncation from expiry).
- **Comparison uses the since token's issue time, not its position.** The token position is a post time (`NextSince`) and can
  be months old on a quiet feed; comparing with it would make every refresh after a big suspension truncate again. The
  server compares log `createdAt` with `issuedAt - (2 x CACHE_TTL + 15 s)`; the lag covers a card served from a stale post
  cache plus an instance log cache that is itself up to one TTL stale. Needs `cursor.DecodeIssuedAtTTL` (additive).
- **Retention is 32 days** (`posts.RemovalRetention`) against the 30-day token; a configured token TTL longer than that is
  safe because the reader refuses (truncated) any cutoff below its coverage floor.
- **Writes are +1 per hidden post and also +1 per restored post.** An un-hide cannot delete the entry (an incremental
  `createdAt` query never sees deletes, so warm instances would keep the stale id): `restore-post` and `unsuspend-user`
  overwrite the same doc id with `RESTORED` and a new `createdAt`. A suspension of P posts is 2P writes (post + entry), an
  unsuspend another 2P. `createdAt` is a server timestamp; the log write shares the transaction or batch with the
  `moderation` update (crash-safe resume), so `HideAuthor`/`RestoreAuthor` pages are 250 posts (2 operations each, 500 max).
- Terraform: `ttl_fields.post_removals_expire_at` added to `infra/terraform/modules/firestore/variables.tf` (edited, not applied).

## Amendment 2026-10-18 (D10 cost text; founder approval 2026-10-18)
Review of the D10 server half (`feat/removed-ids`) corrected the D10 cost text. The decision (option 2, `removed_ids` backed by
one global log) is unchanged. These numbers replace the D10 and Cost impact numbers above and refine the Implementation notes:
- **Cold start:** one query for the newest 50 entries (1 read when the log is empty, never more than 50). The text "the live
  entries once per cold start" is superseded.
- **Warm:** 0 reads on a cache hit. After the TTL one incremental query ordered by `(createdAt, doc id)` and started strictly
  after the last entry seen: 1 read when nothing changed, and it never re-reads an entry the instance holds, so a burst of
  250 entries sharing one commit timestamp costs the 50-read cold load once and 1 read per TTL afterwards. (The first build
  re-read 10 s behind `lastSeen` and cost about 100 reads per TTL after such a burst; fixed.)
- **Worst case per refresh:** 100 reads (a full incremental page of 50, then the reload of the newest 50), once per instance
  per TTL and only when 50 or more entries are new within one TTL. It was part of `config.ReadBudgetMaxCallReads` (269 + 100 = 369); superseded by amendment 2026-10-18 (b): detached, 269.
- **Writes:** a hide or restore of one post is 2 writes (the `moderation` update and its log entry). `+P` writes is replaced by
  suspend-user 2P + 1, unsuspend-user 2 P_hidden + 1, takedown-post and restore-post 2 each; batches are 250 posts (2 operations
  each, 500 max). A 5,000-post account is 10,000 writes (50% of the free daily writes), as already stated under Cost impact.
- **Reset cost of a large suspension:** with P >= 50, every client that refreshes has its since_token rejected once and replaces
  its cached feeds with cold opens (about DAU x 30 reads); tokens issued up to `removalLag` (135 s) after the burst are rejected
  too. `opsctl suspend-user --dry-run` warns; run it off-peak (`docs/runbooks/moderation.md` section 3b).
- **Failure and rollout:** the log query has its own 2 s timeout, a waiting request gives up on its own context, and a failed
  refresh on an instance that holds data serves the stale cache (ERROR log). The read is behind `FEATURE_REMOVED_IDS` (default
  off; off means no log reads and no resets; the log is still written).
- `removed_ids` is global (<= 50 ids per response, not per feed); it reveals the timing of moderator removals to every client
  (security-auditor follow-up).

## Amendment 2026-10-18 (b): per-author scoping of the removal log (founder approval 2026-10-18; security audit RID-2 (a), RID-3, RID-4, N-4)
The decision of D10 (option 2: `removed_ids` backed by a TTL'd log, instance-cached, behind `FEATURE_REMOVED_IDS`) is unchanged.
This amendment **supersedes the "global log, global broadcast" text** of D10, of the Implementation notes ("`removed_ids` is global,
not per feed") and of the 2026-10-18 cost amendment above, where they differ.

**What changes**
- **Scope (RID-2/RID-3).** Every `postRemovals/{postId}` entry now carries `authorId` (the post's author; written by every writer,
  RESTORED entries included). `RemovedSince(cutoff, scope)` answers for one feed: Home = `homeAuthors(snapshot)` (the caller plus the
  followees the caller neither blocks nor mutes), user timeline = the profile's author. A removal by anyone else is neither listed in
  `removed_ids` nor a reason to reject the token. A suspension therefore resets only the feeds that show the suspended account (its
  followers' Home and its own profile), usually about zero for a spam account, and ids are no longer broadcast to every client.
- **Truncation per feed, conservative.** The instance cache is still the global newest-50 view (complete for entries newer than its
  `coverFrom`). A feed is rejected (token invalid, client cold-opens) only when it cannot be answered exactly:
  1. the cutoff is older than the retention floor (32 d);
  2. more than 50 matching REMOVED ids for this feed;
  3. the cutoff is older than the cache's coverage **and** the window `(cutoff, coverFrom]` cannot be queried for this feed: the feed
     has more than 180 authors (6 chunks of 30), the window starts before authorId existed (`defaultRemovalAuthorScopedFrom`,
     2026-10-25, moved from 2026-10-18 by the founder on 2026-10-18; delete the check 32 days after the release), or the window query itself returns more than the response can hold.

  Otherwise the window is read with one query per 30 authors, `authorId in [...] AND createdAt > cutoff AND createdAt <= coverFrom`
  ordered `createdAt DESC, __name__ DESC`, `Limit` = what is left of 51 (+ ties at `coverFrom`, which both views return), merged
  with the cached entries by post id (the cached entry wins). This is what makes a cold instance exact right after a burst: its
  cache only holds the newest 50 entries, which are the spammer's, and the followed author's older removals come from the window.
  Reasoning for "correct over clever": the cache never claims coverage it lacks; whatever the cache or the window cannot prove
  complete for the feed becomes a reset, never a silently shortened list. Entries without `authorId` (written before this
  amendment, no backfill; they expire within 32 d) are treated as visible to every feed in the cached view, and any window that
  could contain them is rejected rather than queried.
- **Index.** New composite `postRemovals (authorId ASC, createdAt DESC)` in `firebase/firestore.indexes.json` (the same single-field
  `authorId` serves the erase query). The `postRemovals.state` exemption stays. Every query keeps its `Limit`.
- **Charging (RID-4).** The shared refresh (cold load 1-50 reads, incremental 1 read per TTL, 100 worst) runs under a detached
  `budget.WithCounter` and is logged as `removal_log_reads`; it is **not** charged to the triggering user's 2,000/day budget.
  `config.ReadBudgetMaxCallReads` goes **369 -> 269**. The window query is per viewer and is charged to them: at most
  `RemovalWindowWorstReads` = 107 reads (51 new documents across chunks + 50 boundary entries returned twice + 1 per empty chunk),
  only for feeds of at most 180 authors, so such a call is at most 2 + 7 + 100 + 107 = 216 reads, below 269. Pinned by
  `config.RemovalWindowMaxReads` and the config test.
- **Steady state is unchanged:** 0 reads on a warm hit, 1 read per instance per CACHE_TTL.
- **Right to delete (rule 10).** `authorId` is a pseudonymous link to a uid, so `postRemovals` is no longer `notPersonal`: the lifecycle
  guard row is `erasedByStep "posts"`. `posts.Eraser.PurgeUser` has a new phase 2 (after the copies phase) that deletes the entries with
  `authorId == uid` (Limit 500, one read per entry, minimum 1, one delete per entry). Account deletion therefore costs **+1 read**
  (the empty page): the reference account is 21 reads (was 20) and the plan T16 delete criterion 517 + D (was 516 + D). No residue
  allowlist entry is needed; the 32-day TTL is only the backstop.
- **opsctl (N-4, RID-3).** `suspend-user` now sweeps the notification rows other users hold about the actor after the settle pass
  (`collectionGroup("notifications").where(actorIds array-contains uid)`, the existing `purgeActorRows` step through the new
  `notifications.ActorSweeper` seam: 1 read + 1 delete or update per row, 500 per page, 1 read when none; index already
  deployed). `suspend-user --dry-run` and `unsuspend-user --dry-run` print the P >= 50 reset warning, reworded for the new
  scope (only followers of the account and viewers of its profile are reset).

**Cost.** Writes unchanged (2 per hide or restore; `authorId` is one more field). Reads per Home refresh: unchanged on a warm
instance; the shared refresh no longer counts against any user. Worst reset cost of a P >= 50 suspension: followers x 30 reads
instead of DAU x 30.

**Trade-offs accepted by the founder.** (1) A removal by an author the viewer just unfollowed, muted or blocked is not listed (tokens
are not bound to the follow set): a cached card of that author can stay until the next cold open. (2) A viewer who holds a suspended
author's post only as a repost or quote copy inside another account's post is not told: copies carry their own ids, are removed only by
`takedown-post`'s clean-up (ADR-0018 D6), and the read-path embed filter handles block and mute only. This is unchanged by this amendment
(the log never listed copies). (3) Legacy entries without `authorId` are global until they expire.

**Legacy-entry guarantee and the cutover date.** Entries written by an opsctl built before this change have no `authorId`. The cached view
treats them as visible to every feed (exact, only less precise). The window query cannot find them, so a window that starts before
`defaultRemovalAuthorScopedFrom` is rejected, never queried. That constant (2026-10-25, `backend/internal/posts/removals.go`) is only
correct if **no moderation action runs with an old opsctl after that date**: rebuild opsctl from this change before any `takedown-post`,
`suspend-user` or `restore-post`. Moving the date later is always safe (windows reaching before it reset the feed instead of being queried; `FEATURE_REMOVED_IDS` is off, so no cost today). Rule: bump it to the release-tag date when tagging; delete the constant 32 days after the release.

**Flutter client contract: unchanged.** The client still drops each `removed_ids` id from every cached feed that holds it and
replaces the feed with the cold open on a rejected `since_token`. No proto field changes (`buf breaking` clean; only comments).

## Note (2026-10-28): message reports carry private text (ADR-0027 D12, W7)
ADR-0027 (Messaging v1, Proposed) adds `REPORT_TARGET_TYPE_MESSAGE = 3` with `target_id = "<convId>:<msgId>"`
(32 hex each). It takes effect when ADR-0027 is accepted and W7-12 merges.
- Only a participant may report, and only the peer's message. `evidence` holds **that one message's text**, the
  sender's handle and its time, nothing else from the conversation. This is private content that an operator reads
  in `opsctl reports`; the founder accepted it with F11 on 2026-10-28.
- Retention and privacy are D5's: the existing `expireAt` (resolved + 90 d) and the `reporterId` erasure apply.
- Moderation reaches the message only through a consumer-side `moderation.MessageLookup` implemented by messaging.
- `opsctl` gains "take down a message" (tombstone, `state = REMOVED`) next to the existing suspend.
No decision of this ADR changes.

Addendum (2026-10-29, founder, W7-12): a MESSAGE report's `targetId` holds `<conversation id>:<message id>`, and the
conversation id is a hash of both participants' uids. It stays after `PurgeReporter` (the T11 `reports.targetId` entry),
and, like every report's document id, it can confirm a guessed reporter uid. Accepted. Also confirmed: a message takedown
cannot be undone; a message stays reportable when its sender is no longer ACTIVE, after the reporter's delete-for-me, and
when the peer is blocked. The privacy policy line (D5) now also covers a copy of one private message kept until 90 days
after resolution, even after the sender deletes their account (`docs/plans/roadmap.md` section 9, item 3.18).
