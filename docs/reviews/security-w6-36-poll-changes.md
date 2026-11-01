# Security review: W6-36, VotePoll block either way and vote changes (PR #555)

**Ticket:** W6-42, part 2 (part 1, the W6-40 review of #554, is `security-w6-40-attempt-cap.md`) · **Date:** 2026-10-31 · **Reviewer:** security-auditor (read only; committed by the orchestrating session) · **Branch:** `feat/polls-w6-36-block-and-change` at `58864230` (the W6-29 adaptation is in 789eaf51, then origin/main 2d59f4d1 was merged in), 39 files. CI green: `make ci`, `make test-int` (Firebase emulators) and the promotion scripts.

**Inputs:**
- ADR-0029 Amendment 1: A1, A2, A6, A7, Observability, "Tests to flip", and the as-built notes N5 (W6-36) and N6 (W6-29).
- Plan rows W6-36 and W6-42 in `docs/plans/ui-w6-composer-extras.md`.
- `docs/reviews/security-w6-composer-extras.md`: L-1, L-2, L-3, L-6 and "Founder decisions, 2026-10-31".
- The PR #555 body.
- The tester's results do not exist yet (W6-41 is open), so this review reads the developer's tests.

**Method:**
- Read only: the diff (`git diff origin/main...HEAD`) and the code around it on the branch (`engagement`, `posts`, `timeline`, `pkg/platform/{logger,store,config}`, `identity/lifecycle.go`), and the Terraform envs. No cloud calls.
- Unit tests run in the worktree (`GOWORK=off go test`), all green:
  - `./internal/engagement/` `TestVotePoll*` (26 top-level tests), `TestPollVoteExporter*`;
  - `./internal/posts/` `TestToViewAt_*`, `TestApplyWithheld_*`, `TestPollVoteBlocked*`, `TestServer_PollVoteBlocked*`, `TestPost_VoteChanged`, `TestCache_AdjustPollChange`, `TestPollConverterGuard*`, `TestViewerSet_*`;
  - `./internal/timeline/` `TestUserTimeline_PollVoteBlocked`, `TestTimelines_PollViewerRule`;
  - `./pkg/platform/config/`.
- Integration tests were **not** run, because another agent was using the emulators. This review relies on the PR's green `make test-int` for them.

## Scope and the founder's binding points

| Founder point (Amendment 1 header; review "Founder decisions, 2026-10-31") | Result |
|---|---|
| Blocking prevents new votes and vote changes, in either direction | **Holds.** Voter blocks author: `TARGET_BLOCKED` for a first vote, a replay and a change (`service_polls.go:128-135`). Author blocks voter: the one NOT_FOUND from `Viewable`, before any vote logic (`service_polls.go:107`, `service.go:225-229`). Staleness is at most the 60 s graph cache (A1.1, accepted) |
| Votes cast before a block are preserved | **Holds.** Block and Unblock write nothing to polls. `TestW636_VoterBlocksAuthor` checks the counts after the block, the kept check mark and the visible results, then a change after Unblock |
| Votes can be changed until the poll closes | **Holds.** The step-5 closed check (`service_polls.go:119-121`) and a close re-check on every decide round (`:166-169`). `POLL_CLOSED` for a change and a replay after close (`TestW636_ChangeBudgetCapAndClose`). The window is bounded in I-2 |
| Copy: "Individual choices are hidden from other users", never "anonymous" | **Holds in code.** No RPC returns another account's choice, and this PR adds no such path. The small-poll caveat now covers changes (L-4) |
| Votes retained until close + 30 days | **Holds.** A change writes only `choice`, `changes` and `changedAt` (`repo_polls.go:111-115`), so the vote doc's `expireAt` is unchanged (asserted in `TestRepoChangeVote_BatchBudgetAndEffects`). The entry keeps `closesAt`. The founder confirmed the period on 2026-10-31 (W6-47) |
| L-1 (voter list in logs), L-2 (per-account copy), L-6 (labels) | L-1: the keyed `post_hash` holds on the request line (`logger/convhash.go:81-86`); a leftover on error lines is L-2 here. Old L-2: still one entry per post after a change (item 5). L-6: not touched by this PR |

## STRIDE (the changed surface only)

| Threat | Where | Control | Finding |
|---|---|---|---|
| **S**poofing | VotePoll caller; another voter's vote | The uid comes from the Firebase ID token. The vote doc is `pollVotes/{postId}_{uid}` built from the token uid (`repo_polls.go:43-45`, `:191`). `expected_choice` cannot name another user's vote | none |
| **T**ampering | Count drift under racing changes; a late retry reverting a change | `LastUpdateTime` precondition on the vote doc (`repo_polls.go:115`). The compare-and-set `expected_choice` (`service_polls.go:209`). One atomic batch for the vote doc, the counters and both `userLikes` writes. The ABA residual is accepted (A2.2) and owned by the client (W6-37) | none (I-2, I-8) |
| **R**epudiation | Disputed change | `changes` and `changedAt` on the vote doc. No history by design (A2.6) | I-9 |
| **I**nformation disclosure | `TARGET_BLOCKED` as an oracle; NOT_FOUND identity; `expected_choice`; logs; count deltas | Only the caller's own outgoing `blocked` set. `Viewable` runs first. Error metadata carries only the caller's own stored choice. The request line has no error metadata. Hidden counts stay hidden from non-voters | **L-1**, **L-2**, **L-4**, I-1 |
| **D**enial of service / **cost** | Write amplification through changes; hot-poll flapping | `POLL_VOTE_CHANGES_MAX` (durable, 5 per voter per poll). The VotePoll bucket and daily caps count every change. 4 writes per change | L-3, I-8 |
| **E**levation | Voting after a block, or after close; the kill switch | Step 5e; the close re-check per round; `POLL_VOTE_CHANGES_MAX=0` | L-3, I-2 |

## Findings

| ID | Severity | Title | Blocks merge |
|---|---|---|---|
| L-1 | Low | The byte-identical NOT_FOUND for "the author blocks the voter" is proven only for a first vote with no `expected_choice` | no (W6-41) |
| L-2 | Low | Internal-error lines redact the post id with the unkeyed `HashUID`, which undoes the keyed `post_hash` (L-1) there | no (W6-52) |
| L-3 | Low | `POLL_VOTE_CHANGES_MAX` is env-only, against A7's "defaults in Terraform"; the change kill switch needs a Terraform PR first | no (folded into W6-51, #562) |
| L-4 | Low (copy) | The L-3 widening: a change shows both the old and the new choice to the author and to voters in a small poll | no (accepted residual; amend W6-46) |
| I-1 | Info | Stale comment: `post_hash` is called a plain SHA-256 | no (fixed with this review) |
| I-2 | Info | A change, like a vote, can commit up to `txTimeout` (5 s) after `closesAt` under contention | no |
| I-3 | Info | A retried change that had committed is answered as a replay, with this instance's counts from before the change, for up to 60 s | no |
| I-4 | Info | A `POLL_VOTE_TTL_AFTER_CLOSE` change between a cast and a change leaves an extra due day; the sweep corrects it | no |
| I-5 | Info | `Set`+`MergeAll` on `userLikes` could recreate a document the eraser deleted; closed by the 120 s start gate | no |
| I-6 | Info | For a protected author, blocking drops the follow edge, so the voter gets NOT_FOUND, never `TARGET_BLOCKED` | no |
| I-7 | Info | The new change by REPOST id in `TestW617_RepostIDVotesInTheOriginal` does not assert the single `userLikes` entry | no (W6-41) |
| I-8 | Info | Changes multiply a ring's writes to one hot poll's post doc by up to 6 | no |
| I-9 | Info | The export omits the `changes` count | no |

### L-1 (Low, test gap): NOT_FOUND byte identity is proven only for a first vote

**Where:**
- `TestW617_NotFoundBytesIdentical` (`w617_polls_chain_integration_test.go:192-266`) compares raw bodies through `rawVote`. Its JSON body (`:77`) has no `expectedChoice`, and every refused voter there had never voted.
- The unit case "the author blocks the voter" (`service_polls_change_test.go:93-106`) is also a first vote with `e = 0`, and it compares `Message`, `Reason` and the metadata length rather than bytes.
- ADR-0029 A1.1 promises byte identity for "cast, change, replay".

**Code verdict: it holds.**
- `resolveViewable` (`service_polls.go:107`) returns the one `notFound()` (`service.go:42-44`, `:225-229`) before any vote-doc read or any branch on `expected_choice`.
- Everything that runs before it is independent of the target:
  - the shape checks, including `expected_choice` 0..4 (`:83-89`), with fixed messages and no value echoed;
  - the verified-email gate;
  - the new-account cap.
- The NOT_FOUNDs inside `decideAndWrite` (`:179`, `:197`, `:219`, a deleted post) use the same helper.
- Moving from `TARGET_BLOCKED` to NOT_FOUND when the author blocks back reveals nothing that GetPost does not already reveal.

**Scenario the tests would miss:** a future refactor reads the vote doc before `Viewable` for the `e != 0` path (the A2.3 "read first"). A voter who voted and was then blocked by the author would get `ALREADY_VOTED` with their choice, or a different body. That tells them they were blocked.

**Fix (test only):**
- Give `rawVote` an `expectedChoice` parameter.
- In `TestW617_NotFoundBytesIdentical`, have a voter vote and only then be blocked by the author.
- Send replay (same choice, `e = c+1`), change (other choice, `e = c+1`) and stale (`e = 0`), each by post id and by REPOST id. Each body must equal `ref`.
- Mirror these at unit level in `TestVotePoll_BlockMatrix`.
- **Owner:** tester, W6-41.

### L-2 (Low): internal-error lines carry an unkeyed hash of the post id

**Where:**
- `mapVoteErr` (`service_polls.go:319`) and the `engagement_poll_vote_viewer_degraded` WARN (`:251`) call `logger.RedactErr(…, uid, postID)`.
- `RedactErr` (`logger/redact.go:26-37`) replaces **every** id with `HashUID`, which is a plain SHA-256 (`logger/logger.go:106-112`).
- The request line and the contention WARN use the keyed `HashPost` (`convhash.go:81-86`, the L-1 fix). Error lines do not.
- W6-36 sends more failures down this path: `ChangeVote` errors (`:223`) and the per-round `GetVote` errors (`:193`).

**Scenario:**
- A Firestore error that names `pollVotes/<postId>_<uid>` becomes `pollVotes/<sha256(postId)>_<sha256(uid)>`.
- Anyone with `logging.logEntries.list` can hash a public post id and a uid, and so rebuild "user U voted in poll P" from internal-error lines. That is the class L-1 closed for normal lines.
- No choice appears: errors never format a choice, and Firestore errors are not known to echo field values (unverified).
- `voterBlocksAuthor` (`:150`) pairs the voter's and the author's uid hashes the same way (the uid convention, but in a poll context).

**Fix:**
- A `RedactErr` variant that maps post ids through `HashPost`, as `RedactErrKeyed` does for conversation ids (`convhash.go:91-107`).
- Use it in `mapVoteErr` and in the degraded WARN.
- Drop `authorID` from the `voterBlocksAuthor` error text.
- Test `TestMapVoteErr_RedactsPostIDKeyed`: an error containing the post id and the uid yields `HashPost(postID)`, never `HashUID(postID)`, and neither raw id.
- **Owner:** backend-developer, XS (W6-52). Pre-existing on main. Recommended before `polls` leaves the dev allowlist, but not a gate.

### L-3 (Low, rule 11): `POLL_VOTE_CHANGES_MAX` is not in Terraform

**Where:**
- `config/composer.go:111-118` validates 0..20, default 5. `infra/terraform/envs/{dev,prod}/main.tf` set only `FEATURE_POLLS*` for polls.
- The A7 heading says "defaults in Terraform for dev and prod". The PR body says "env only".

**Effect:**
- Rule 11 is met by reviewed code defaults, but the value in force never shows in a plan.
- The A2.2 kill switch (`= 0`, "votes final again without touching `polls`") cannot be used without first adding the env entry to Terraform, because there is no click-ops. Today `FEATURE_POLLS=off` is the only fast lever.
- Same class as part 1's L-5.

**Fix:**
- Add the `POLL_VOTE_CHANGES_MAX` env entry (default 5, startup range 0..20) to both envs. Do not apply it.
- **Owner:** production-deployer, folded into W6-51 (#562, e9284623). Until it is applied, the runbook §10 kill-switch line says it needs a Terraform change.

### L-4 (Low, copy): the L-3 widening is accepted; the policy caveat must name changes

**What a change reveals:**
- A change moves one count down and another up, with `poll.total` fixed (`StagePollChange`, `repo_engagement.go:107-112`).
- Who can see it:
  - the author always;
  - every voter, since results are visible after voting;
  - not non-voters: they see only `total_votes`, which a change does not move, and their counts are sent as 0 (byte-identical, `convert.go`).
- In a small poll, for example a protected account with a handful of approved followers, the delta reveals both the old and the new choice of the person who just changed. It also marks the event as a change rather than a new vote.

**Bounds:**
- At most 5 changes per voter per poll (durable).
- Observers on other instances see counts that are up to 60 s stale (O-2), which blurs the timing.
- No other channel: `changedAt` is in the voter's own export only, no log line carries a choice, and a vote sends no notification.

**Verdict:**
- This is the residual the founder already accepted on 2026-10-31. The decision text reads "live totals can still reveal a choice (or a change, A2.9) in a very small poll", and the copy stays "Individual choices are hidden from other users" (W6-44).
- No new ticket.
- **Fix:** add one acceptance line to W6-46: the small-poll caveat says that a change can show the author and people who voted both your earlier and your new choice. W6-44's in-app line stays as decided. **Owner:** architect (draft) and founder (approval).

### Info

- **I-1:** `service_polls.go:80-81` said `post_hash` is "HashUID (plain SHA-256 …) … no key". The code uses the keyed `logger.HashPost`. The comment was inherited from main. Fixed with this review.
- **I-2:** The close re-check runs once per decide round (`service_polls.go:166`). Inside one round, `store.CommitWithRetry` retries Aborted up to `maxBatchAttempts` 4 with a 25 ms full-jitter backoff, within `txTimeout` 5 s (`repo_firestore.go:34`, `:41-42`; `store/retry.go:76-112`).
  - So a change that started before `closesAt` can commit up to about 1 s after it typically, and 5 s at most under contention.
  - A new vote has the same property (D6). Only an honest race can hit it. Accepted.
- **I-3:** `mapVoteErr` turns `DeadlineExceeded` into a retryable UNAVAILABLE (`:313-317`). If that commit had in fact landed, the client's retry (same key, same `e`) is a replay (`:206-208`).
  - The replay renders the post this instance cached before the change, because `PollVoteChanged` was never applied. The voter's response can show the new check mark with the old counts for up to 60 s.
  - Cosmetic. No data effect.
- **I-4:** A change unions `pollDueDay(closesAt + current TTL)` (`repo_polls.go:124`). If `POLL_VOTE_TTL_AFTER_CLOSE` changed since the cast, the old day stays as well.
  - On that day the sweep recomputes `pollVotesDueDays` from the live entries (`poll_retention.go:137-151`). Cost: one extra sweep write, no data harm.
- **I-5:** `ChangeVote`'s `userLikes` writes are `Set`+`MergeAll` (`repo_polls.go:118-125`), as `Vote`'s are. Run after the `engagement` eraser step, they would recreate the document.
  - This cannot happen. A VotePoll admitted on a stale ACTIVE status (60 s cache) finishes within its detached `txTimeout` (5 s per round), and the eraser starts only after `StartGateDuration` 120 s (`identity/lifecycle.go:27-29`).
- **I-6:** Block removes follow edges (ADR-0008). A voter who blocks a **protected** author therefore loses visibility, and both VotePoll and GetPost answer NOT_FOUND. `TARGET_BLOCKED` and `viewer_poll_vote_blocked` only occur for public authors.
  - Consistent, no oracle. Their earlier vote stays counted.
  - Copy note for W6-37: the "You blocked @handle" state appears only for public authors.
- **I-7:** The new REPOST-id change in `TestW617_RepostIDVotesInTheOriginal` (`w617_polls_chain_integration_test.go:735-746`) checks the vote doc and the counts but not `userLikes`. Add `onePollEntry(got, pid, 0)` after the change (W6-41).
- **I-8:** A ring of k accounts can write one poll's post doc 6k times over the poll's life (1 vote + 5 changes each), against k without changes. For example, 50 accounts add 300 writes to one doc.
  - That can cause `contention` UNAVAILABLE for honest voters on that poll. The stage-ladder signal already counts changes ("changes make a hot poll hotter").
  - Accepted.
- **I-9:** The `poll_votes` export lists `postId`, `choice`, `createdAt` and `changedAt` (A2.6) but not `changes`, the count of changes. GDPR Art. 15 and DPDP s.11 arguably cover it.
  - Optional, an architect call. It is a one-field addition, no read.

## Explicit verdicts on the nine items

1. **`TARGET_BLOCKED` reveals only the caller's own block: HOLDS.**
   - The decision is `snap.Blocked[target.AuthorID]`, the caller's own outgoing list (`service_polls.go:144-153`), evaluated after `Viewable` and the step-5 checks (`:107`, `:113-124`, `:128-135`).
   - It returns a fixed message and no metadata (asserted at `service_polls_change_test.go:59-61`).
   - Every path passes it before `decideAndWrite` (`:139`): cast, change, replay, and `e = 0` or `e != 0`. Covered by `TestVotePoll_BlockMatrix` (`e` 0, 1 and 3 before voting; replay, replay with `e`, change and old client after voting) and by `TestW636_VoterBlocksAuthor` (7-read ceiling, 0 writes, `:187-199`).
   - Author blocks voter: the one `notFound()` from `Viewable` on every path. This holds in code; the bytes are proven only for a first vote (**L-1**).
   - It fails closed with no graph or a graph error (`:145-151`; test `:144-159`).
   - `viewer_poll_vote_blocked` comes only from `snap.Blocked` in all three producers:
     - GetPost: `posts/server.go:169`, `service_thread.go:535`;
     - GetThread: `service_thread.go:146`, `server.go:274`;
     - GetUserTimeline: `timeline/service.go:489`, `:412`.
   - It is never derived from `blockedBy`. A user the author blocked never receives the post, so the field cannot signal "the author blocked you".
2. **`expected_choice` is not an oracle about other voters: HOLDS.**
   - The only vote doc read is the caller's own (`GetVote(ctx, uid, target.ID)`, `:191`, uid from the token).
   - `ALREADY_VOTED` and `LIMIT_REACHED` carry `cur.Choice`, the caller's own stored choice (`:211-216`).
   - The shape error echoes no value (`:87-89`). An `e` beyond the poll's options is just `ALREADY_VOTED`.
   - A success answers with this call's choice and the counts a voter may already see.
   - `UNAVAILABLE contention` reveals only poll activity, which the counts already show.
3. **Logs never carry a choice: HOLDS. No voter list on the request line: HOLDS (with L-2 on error lines).**
   - Outcomes are fixed strings (`service_polls.go:29-40`); `changes`, `expected_choice` and choices are never set as fields.
   - The request line carries no error metadata (`pkg/platform/mw/mw.go` has none).
   - FailedPrecondition answers do not reach Error Reporting.
   - The request line and the contention WARN carry `uid_hash` plus the **keyed** `post_hash` (`convhash.go:81-86`; runbook §10).
   - `RedactErr` on error paths uses the unkeyed hash for the post id (**L-2**). Stale comment: I-1.
4. **The L-3 widening: an accepted residual. No new ticket; amend W6-46 (L-4).**
5. **ArrayRemove exact match: HOLDS. No defect.**
   - **Cast:** `pollEntry(p.PostID, p.Choice, p.ClosesAt)` (`repo_polls.go:62`), with `ClosesAt: target.Poll.ClosesAt` (`service_polls.go:172`).
   - **Change:** `ArrayRemove(pollEntry(p.PostID, p.From, p.ClosesAt), pollEntry(p.PostID, p.From, time.Time{}))` (`repo_polls.go:119`), with `ClosesAt: target.Poll.ClosesAt` (`service_polls.go:221`).
   - **Same post id.** `target` is the original post for a REPOST id in both paths (`target.ID`, `:172`, `:221`).
   - **One source field.** `closesAt` is set once at create from the attempt's Snowflake milliseconds plus whole minutes (`posts/repo_create.go:186-200`, `poll.go:83-90`). It is stored as a Firestore timestamp (microseconds, so exact) and decoded with `.UTC()` (`posts/repo_firestore.go:171`).
   - `pollEntry` uses `closesAt.Unix()` (`poll_retention.go:46-52`), which is zone-independent and identical whether the post came from the creating instance's cache (`service_create.go:222`) or from Firestore. No writer changes `poll.closesAt` (A3, I-V4).
   - **`From` matches the stored entry.** `From` is the vote doc's choice at the version the batch is preconditioned on (`repo_polls.go:115`). Every writer of the vote doc and its entry is one atomic batch, so they agree.
   - **Legacy entries** are removed by the zero-`closesAt` argument.
   - **`pollVotesDueDays`:** same `closesAt` and same TTL give the same day, so the union is a no-op. A replaced legacy entry gains its day. A TTL change is corrected by the sweep (I-4).
   - **Tests proving exactly one entry:**
     - repo, three-part start: `TestRepoChangeVote_BatchBudgetAndEffects` (`repo_polls_integration_test.go:247`), exact list after two changes;
     - repo, legacy start: `TestRepoChangeVote_ReplacesLegacyEntry` (`:461`), exact list and due day;
     - chain: `TestW636_ChangeBudgetCapAndClose` (`w636_…:242`, `onePollEntry` requires `len == 1`);
     - chain, across sources: arm (b) (`w636_…:147`). The casts run on the creating instance (cached `closesAt`) and half the changes run on a cold instance (decoded `closesAt`), all 60 voters with exactly one entry.
   - **Not proven:** real Firestore, see the widening condition.
6. **`expireAt` and the new entry after a change: HOLDS.**
   - The change writes only `choice`, `changes` and `changedAt` (`repo_polls.go:111-115`). `expireAt` is unchanged (asserted in `TestRepoChangeVote_BatchBudgetAndEffects`).
   - The new entry keeps `closesAt`, so its expiry stays `closesAt + POLL_VOTE_TTL_AFTER_CLOSE` (`poll_retention.go:56-67`). Its due day is `pollDueDay(closesAt + TTL)` (`repo_polls.go:124`).
   - `changedAt` is exported only from the caller's own vote docs (`purge_polls.go:91` `uid ==`, `:107-110`). It is server time, the last change only, with nothing about other users. No history (A2.6). See I-9 for `changes`.
7. **The 0..60 loosening hides nothing: HOLDS.**
   - It applies only to the two busy instances' cached author views (`w617_…:569-581`, the O-2 lag).
   - The stored totals are asserted exactly, read straight from `posts/{id}` (`engagement_polls_chain_integration_test.go:98-110`):
     - `total == 60` is fatal (`w617_…:513`);
     - `counts[k] == tally of vote docs` (`:517`);
     - the cold instance's view equals the store (`:563`).
   - `sum == total` is still required of the cached views. Arm (b) asserts I-V1 to I-V3 exactly (`w636_…:113-149`).
8. **The change batch, the cap, the cost bound and idempotency: HOLDS.**
   - **Batch:** `LastUpdateTime(p.Version)` (`repo_polls.go:115`). On a failed precondition the vote doc is re-read: moved means decide again, unmoved means the post is gone (`service_polls.go:218-227`). The close re-check runs per round (`:166-169`). After 4 rounds the answer is contention (`:165`, `:236`). See I-2 for the in-round window.
   - **Cap:** `POLL_VOTE_CHANGES_MAX` is validated 0..20 at startup (`composer.go:111-118`, ceiling `:25`) and checked durably with `>=` (`:213`), so 0 refuses every change. It applies after the stale check, matching the A2.2 table. It is env-only (L-3).
   - **Idempotency:** the key is validated, not stored (the D7/A2.2 bend).
     - A retry of a committed change is a replay with 0 writes (`:206-208`).
     - A late retry of an older tap, with a stale `e`, gets `ALREADY_VOTED` (`:209-212`).
     - The ABA residual is accepted, and the client must drop superseded retries (W6-37).
   - **Cost bound:** see "Cost math".
9. **Eraser, export, `ApplyWithheld` and list surfaces: HOLDS.**
   - The eraser deletes vote docs. The anonymous counts it leaves behind already reflect the current choice (I-V2).
   - The export uses `d.Choice`, the current choice. `current_choices` comes from the live `userLikes` entries, one per post (item 5).
   - `ApplyWithheld` clears the field (`audience.go:291`; `TestApplyWithheld_ClearsPollVoteBlocked`).
   - Home and lists pass `nil` (`timeline/service.go:103`, `service_list.go:143`). Search, bookmarks and likes never call `WithBlockedAuthors`. `TestPollConverterGuard_Repo` pins the setters to `posts/server.go` and `timeline/service.go`, with self-test rows.
   - The VotePoll response never sets it, which is correct because a blocker is refused.

## Effective limits (per instance × 3 max instances)

| Limit | Per instance | Effective | Store |
|---|---|---|---|
| VotePoll bucket (`RATE_LIMIT_POLL_VOTE_PER_MIN`); changes count | 30/min | 90/min | memory |
| `poll_votes_daily` (`POLL_VOTES_PER_DAY`); every call counts | 300/day | 900/day | memory |
| New-account tier (`POLL_VOTES_PER_DAY_NEW_ACCOUNT`) | 50/day | 150/day | memory |
| Changes per voter per poll (`POLL_VOTE_CHANGES_MAX`) | — | 5 (ceiling 20), exact | `pollVotes.changes` (durable) |
| Read budget (`READ_BUDGET_PER_UID_PER_DAY`) | 2,000 | 6,000 reads/uid/day | memory |

## Cost math

The write price is the ADR's: INR 0.36 per 3,600 writes, about INR 0.0001 per write.

| Case | Writes | INR |
|---|---|---|
| One change | 4 (reads at most 9, typically 1 to 4) | negligible |
| One account, one poll, durable bound | 3 + 5 × 4 = **23** | negligible |
| One account, one day, every call a change (needs ≥ 180 open polls it can see; sockpuppets can create them within the posts quota) | 900 × 4 = **3,600** | 0.36/day, **≈ 11/month** (was ≈ 8 before changes) |
| New account, one day | 150 × 4 = 600 | ≈ 1.8/month |
| Ring of 100 accounts | 360,000/day | **≈ 1,100/month** |

- **Reads:** bounded by the read budget, at most 6,000 per uid per day, about INR 7 per account-month, shared with every other RPC.
- **The free quota:** about 6 accounts at this rate use up the 20k daily free writes; past that, billing is per use.
- **Scale against the credit:** a 100-account ring would take about 22 months to burn the INR 25,000 credit. Changes are not a credit-burning vector. Fixed cost added: INR 0.

## Verdict on #555: MERGE

Nothing is required before merge.

**Follow-ups:**
- L-1 and I-7: tester, W6-41.
- L-2: backend-developer, XS, W6-52, recommended before widening.
- L-3: production-deployer, folded into W6-51 (#562).
- L-4: architect, an acceptance line on W6-46.
- I-1: comment fixed with this review.
- I-9: architect, optional.

## Verdict on `polls` beyond the dev allowlist: GO from security, on these conditions

1. **The runbook §10 dev check passes on dev Firestore.** Extended by this review: after one change by a `w7smoke` account,
   - `userLikes/{uid}.pollVotes` holds **exactly one** entry for the post, in the three-part form with the new choice;
   - `poll.counts` moved −1 and +1 with `poll.total` unchanged;
   - the request line shows `outcome=changed` and `fs_writes=4`.
   - If dev rejects the two-write commit, the commit is atomic and fails closed: every change becomes an internal error with nothing written. Build the A2.3 transaction fallback before widening.
2. W6-37 is shipped: the client sends `expected_choice` and drops superseded retries.
3. W6-41 is green, including L-1's byte test and I-7.
4. The 100 % rule (L-1 of the W6-20 review): 100 % of traffic is on a revision with W6-36.
5. The W6-20 review's conditions still stand: the `pollVotes` TTL is applied in dev, and the keyed `post_hash` is in place. Dev beyond the allowlist also needs the founder's ceiling raise (`max_percent` 0).

**Prod:** unchanged from the W6-20 review, plus W6-44, W6-46 (with L-4's sentence) and W6-47 before release.

## What could not be verified

- Whether production Firestore (Native mode) accepts two writes to one document in one atomic commit. It is proven on the emulator only, and a documentation search was inconclusive. Hence widening condition 1.
- Whether any Firestore error text echoes a field value; this matters for L-2's "no choice".
- Integration tests were not run by the reviewer (emulators in use); this relies on the PR's green `make test-int`.
- The live flag values: every repo signal says `polls` is allowlist-only in dev and off in prod.

SECURITY: CLEAR
