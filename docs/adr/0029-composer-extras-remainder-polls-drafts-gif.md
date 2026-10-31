# 0029. Composer extras remainder: polls, drafts on the device, GIFs from the device (W6)
Status: Accepted (founder, 2026-10-30: F1–F12 as written, including F2 the rule-4 natural-key bend and F11 sampled-frame GIF screening with its residual risk, the API reading the uploaded GIF, and GIFs rejected at the Vision cap); Amendment 1 Accepted in principle (founder, 2026-10-31; see the acceptance note in Amendment 1)
Date: 2026-10-30
Deciders: architect (proposal); founder (accepts by merging the PR). F2 was decided by the founder on 2026-10-27 (plan
header) and is restated here as a rule-4 bend; the merge confirms it. **F11 needs the founder's explicit acceptance**
(GIF moderation residual risk, and the API reading a whole uploaded object, below). Every other F is decided by the
plan's default, and the founder may override any of them at acceptance.

Plan: `docs/plans/ui-w6-composer-extras.md`, tickets W6-1 (this ADR), W6-2 (poll contract: `posts.proto`,
`engagement.proto`, `common.proto`) and W6-3 (GIF contract: `media.proto`, `common.proto` `MediaRef`), all in one PR.
The plan asked for "ADR-0028 or the next free number". ADR-0028 went to W4 search (#465), so this is 0029. W5 (lists,
communities) has not written its ADRs yet and takes the next free numbers after this one.

Related ADRs:
- ADR-0003: data model, natural keys. ADR-0010: D2 (sub-feature flag order), D5 (per-uid read budget), D9 (text
  rules), D13 (Snowflake `createdAt` drawn per attempt). ADR-0011: T11 guard, erasers, export sections.
- ADR-0005: media pipeline and SafeSearch. **A dated note in this PR** records `image/gif` and frame sampling.
- ADR-0018: engagement, natural-key likes, the rule-4 bend precedent, `posts.EngagementWriter`, `userLikes`.
- ADR-0021: D4 left "polls with a schedule" to this ADR; L-1 (the 100 % rule, the echo check). **A dated note in this
  PR** records F5.
- ADR-0022: credit mode. **Nothing here depends on a credit-mode item.**
- ADR-0023: `userLikes.bookmarks`, `ViewerSet.BookmarksOnly`. ADR-0024: D4 `posts.hasMedia`. ADR-0025: protected
  authors, `posts.Audience`, `withheld` rows and PROTECTED embeds (L-2). ADR-0028: the current cost baseline.

## Amendment 1 (2026-10-31, Accepted in principle): poll blocking, vote changes, drafts and the Vision attempt cap

**Status: Accepted in principle (founder, 2026-10-31).** The founder's acceptance, verbatim in substance:
- Blocking prevents new votes and vote changes, in either direction; votes cast before a block are preserved; votes can be
  changed until the poll closes (A1, A2, the interpretation below).
- Vision outages, timeouts and busy responses must not consume attempts (A5; a busy GIF slot takes no claim, A5.3).
- The busy-GIF defect (A5.1) is fixed and tested in W6-40 (acceptance criterion: a GIF that meets a busy slot any number
  of times is never REJECTED for attempts, and the busy path writes nothing).

Everything else in A1 to A7 stands as written ("in principle"); W6-42's security review and the implementation PRs may
refine details, and any change to an accepted point comes back to the founder. D1 to D13 and N1 to N4 stand except where
A1 to A5 revise them.

**Interpretation, read this first.** "Changes until closure" is read as: **each user holds exactly one vote at a time
and may change it to another choice until the poll closes.** This **reverses** D6 step 7 ("a different choice is
FAILED_PRECONDITION `ALREADY_VOTED`"), F4's "a vote is final", and the D7 argument that rested on it. If you meant
"one final vote, and voting stays open until closure", say so at acceptance: A2 then falls away, and A1, A3, A4 and A5
stand.

Two consequences you should check at the same time:
1. **`ALREADY_VOTED` is still emitted in one case** (A2.2): for a request that does not name the vote the caller
   currently holds. That covers an old app version, a second device with a stale view, and a late retry of an older
   tap. A change the caller asks for knowingly never gets it. The alternative (change unconditionally, never emit
   `ALREADY_VOTED`) is simpler, but lets old clients and late retries silently move a vote.
2. **A viewer who blocks the author, and has not voted, keeps hidden results until the poll closes** (A1.5).
   Otherwise blocking, looking and unblocking would show the results before voting, which F3 forbids.

**The decisions, quoted:**
1. "W6-17 - Poll blocking: prevent casting or changing votes if either user has blocked the other. Preserve votes
   cast before blocking. Enforce on the backend."
2. "W6-20 - Polls and drafts: Polls inherit post visibility and block rules; allow one vote per user, changes until
   closure, and lock options after the first vote. drafts are owner-only, may be incomplete, and require full
   validation and moderation before publishing. Prevent duplicate publication."
3. "W6-27 - Vision attempt cap: Count only completed, valid assessments toward the three attempts. Outages, timeouts
   and internal errors consume no attempts. Allow retrying the retained image without re-uploading, with bounded
   retries and separate rate limits."

**Sources, read on `main` 13b5080f.**
- Code: `engagement/{service_polls,repo_polls,service}.go`; `posts/{convert,audience,service_delete,poll}.go`;
  `media/{finalize,vision,gifscreen,repo_firestore}.go`, with #535 (W6-27) and #536 (W6-25) merged; the client files
  `drafts_repository.dart`, `composer_cubit.dart` and `drafts_screen.dart`.
- Reviews: `docs/reviews/test-report-w6-polls.md` O-1 and O-2; `docs/reviews/security-w6-composer-extras.md` H-3, L-3,
  L-5 and section 4.

Tickets W6-35 to W6-42 (the plan; W6-32 to W6-34 went to the W6-25 review follow-ups in #536). No proto, code,
index or Terraform file changes in this PR. A6 lists the contract changes for W6-35, and A7 the config.

### A1. Block either way (decision 1)
**A1.1 The rule.** Visibility is not changed ("polls inherit post visibility"). Only `VotePoll` changes.

| Who blocks whom | GetPost, GetThread, the author's profile | `VotePoll` (cast, change, replay) | Votes cast before the block |
|---|---|---|---|
| The author blocks the voter (or both block each other) | NOT_FOUND, as today | NOT_FOUND, **byte-identical** to a missing post, as today (`TestW617_NotFoundBytesIdentical` keeps this part) | kept and counted; the voter can no longer see the post |
| The voter blocks the author | visible, as today (ADR-0010 D6: `SurfaceDirect` shows a post by an author the viewer blocked) | **FAILED_PRECONDITION `ERROR_REASON_TARGET_BLOCKED` (13)**, 0 writes | kept and counted; the voter sees the results and their check mark |
| Neither | as today | as today, plus A2 | — |

- **The refusal reuses `TARGET_BLOCKED`.** Its proto comment already says "the caller blocks the target ... Unblock
  first; never auto-unblocked (ADR-0008)". It can be explicit because the voter knows they blocked: it tells them
  nothing they do not know. No new `ErrorReason`; only the comment gains `VotePoll` (A6).
- **Order in `VotePoll`.** The check becomes step 5e, after the existing step-5 checks: no poll, then caller is the
  author, then closed, then choice range, then **the viewer blocks the author**. It comes after `resolveViewable`, so
  an author who blocks the voter, and a mutual block, still answer the one NOT_FOUND first. It comes after the closed
  check, so a blocked voter on a closed poll gets `POLL_CLOSED` and refreshes to the final results.
- **A replay is refused too.** A blocked voter's replay of their own vote is also `TARGET_BLOCKED`, as N2 answers a
  replay after close with `POLL_CLOSED`. So the retry of a vote that committed just before the block, after a lost
  response, gets `TARGET_BLOCKED`. The client then refreshes (GetPost, once) and shows the vote, which is kept.
- **A REPOST id acts on its original** (D6 step 4), so the check is against the original's author. The reposter is not
  a party to the poll.
- **Mute is not a block.** A muted author's poll stays votable (mute only drops rows from lists).
- **Staleness.** The graph snapshot is cached for 60 s per instance. So for up to 60 s after a block, a vote served by
  another instance may still pass. This is the same bound `Viewable` already has for an author's block.

**A1.2 Where the rule lives: engagement `VotePoll`, not `posts.Viewable`.**
- `Viewable` is shared by GetPost, Like, Repost, AddBookmark and CreatePost's reply and quote targets.
- Moving the rule there would either hide the post from the voter or refuse their likes too. "Inherit post visibility"
  rules out the first, and decision 1 is about votes only.
- Engagement already holds the snapshot (`pollVoteView` reads it at 0 reads after `Viewable` cached it), so the rule
  is one line: `snap.Blocked[target.AuthorID]`.

**A1.3 Read cost: +0, not +1.**
- The voter's outgoing blocks are `graph/{voter}.blocked[]`, in the voter's own graph doc.
- `Viewable` already reads that doc for every non-author caller (`needSnap`), and `blocked[]` (≤ 2,000) never
  overflows.
- No second document and no `GetAll` are needed.
- The other direction (the author blocks the voter) stays as today: the voter's `blockedBy[]`, plus the author's graph
  doc on overflow, which is the +1 already in the 8-read ceiling.

**A1.4 No purge on block.**
- Block and Unblock write nothing to `pollVotes`, the counters or `userLikes`, and no event subscriber is added.
- Earlier votes stay and keep counting. After Unblock the voter can vote or change again, with no write.

**A1.5 What the client sees.**
- **New additive field `PostView.viewer_poll_vote_blocked = 9` (bool).** It is true when the post carries a live poll
  (`Post.poll` set, not closed), the viewer is not the author, and the author is in the viewer's `blocked` set.
- **Negative polarity on purpose.** A producer that does not set it, and every older revision, send `false`, which is
  today's behaviour. The server stays the authority (`TARGET_BLOCKED`). A positive `viewer_can_vote` would hide the
  buttons on every producer not yet wired.
- **Which producers need it.** Only the surfaces that show a post by an author the viewer blocked: GetPost, GetThread
  (`SurfaceDirect`) and GetUserTimeline of that author (`timeline/audience.go`, `SurfaceDirect`).
  - `Audience.Decide` with `SurfaceList` or `SurfaceOwnList` already drops such rows (`audience.go:127`). So Home,
    search, lists, Likes and Bookmarks never carry it.
  - Embedded polls are frozen definitions with no buttons (D5), so the field is never set on a REPOST row.
- **Converter seam.** `ViewerSet.WithBlockedAuthors(snap.Blocked)`, set at the producer from the snapshot that `Decide`
  already used (0 reads). Read only by `ToViewAt`, so the converter stays the one place that knows the poll rules (D4).
  `ApplyWithheld` clears it. The D4 guard test over every PostView producer is extended to it.
- **Results for a voter who blocks the author:**
  - Voted before the block: `results_visible` (they voted; D4 unchanged), with the check mark, and no change control.
  - Never voted: counts stay hidden until the poll closes (D4 unchanged). Revealing them would let anyone block, look,
    unblock and vote with the results in hand, which defeats F3. The total stays visible, as for everyone.
- **Copy on the card:** "You blocked @handle. Unblock to vote." The choices are shown disabled.

### A2. One vote at a time, changeable until closure (decision 2)
**A2.1 Invariants.**
- **I-V1:** at most one `pollVotes/{postId}_{uid}` per voter and poll (the natural key, unchanged).
- **I-V2:** for every choice `i`, `poll.counts[i]` = the number of vote docs with `choice == i`, plus the votes of
  erased voters that F6 keeps as anonymous totals. `poll.total` = Σ counts. A change moves one count down and one up
  and leaves `total` alone.
- **I-V3:** `userLikes/{uid}.pollVotes` holds **at most one** entry per post, equal to the vote doc's choice (no entry
  once trimmed, D3). W6-29's export of that list relies on it.
- **I-V4:** a poll's options never change after creation (A3).

**A2.2 Contract: a compare-and-set field, and the decision table.**
- **New additive field `VotePollRequest.expected_choice = 4` (int32).** 0 means "I hold no vote, as far as I know".
  1 to 4 means the choice the caller believes it holds, as index + 1: the value of `viewer_poll_choice` the client is
  rendering.
- Below, `S` is the vote doc (stored choice `cs`, change count `n`), and the request asks for choice `c` with
  `expected_choice` `e`:

| Vote doc | Request | Answer | Writes |
|---|---|---|---|
| none | any `e` | a new vote, today's blind batch (D6 step 6) | 3 |
| `cs == c` | any `e` | replay: the current view (D6 step 7) | 0 |
| `cs != c` | `e == cs + 1` and `n < POLL_VOTE_CHANGES_MAX` | **change** (A2.3) | 4 |
| `cs != c` | `e == cs + 1` and `n ≥ POLL_VOTE_CHANGES_MAX` | FAILED_PRECONDITION `LIMIT_REACHED` (9), `metadata["limit"] = "poll_vote_changes"`, `metadata["choice"]` = `cs` (0-based) | 0 |
| `cs != c` | `e != cs + 1`: `e = 0` (an old client, or a check mark lost to the D3 trim), or a stale `e` (a second device, or a late retry of an older tap) | FAILED_PRECONDITION `ALREADY_VOTED` with `metadata["choice"]` = `cs`, today's answer | 0 |

- **Why compare-and-set.**
  - D7 kept rule 4 bent safely because "there is no undo, so a late retry can never re-create something the user
    removed". With changes there is an undo.
  - Without `e`, a late retry of an older tap would silently revert a newer change.
  - Without `e`, an old app version, whose `ALREADY_VOTED` handler replays the stored choice, or a stale second
    device would silently move a vote.
  - With `e`, old clients keep exactly D6's behaviour, and a change applies only against the vote the caller saw.
- **ABA residual.** The sequence A → B → A, followed by a late retry of the A → B tap, still applies: its `e` matches
  again. This needs a retry from the client's own logic, because Connect and HTTP/2 do not duplicate requests. So the
  client rule (A2.8) is: drop the pending retries of a superseded tap before sending a new one.
- **Same key, different choice.**
  - The key is still validated and **not stored**. D7's rule-4 bend now covers changes too, and you accept that by
    merging.
  - The server cannot see that a key was reused. So such a request is decided by the table like any other: a change
    if `e` matches, otherwise `ALREADY_VOTED`. `IDEMPOTENCY_KEY_REUSED` is not used.
  - Same key and same choice stays a replay.
  - Rejected alternative: a ring of key hashes on the vote doc. It costs +0 writes, but adds an array that needs a
    fieldOverride (a founder-gated file), and it still leaves old clients to `e`.
- **`ALREADY_VOTED` (20) stays in the proto, and `buf breaking` stays clean.** It is no longer emitted for a change the
  caller asked for knowingly, only for the last row of the table. Its comment changes (A6).
- **Kill switch for changes.** `POLL_VOTE_CHANGES_MAX = 0` (config, a deploy) refuses every change with
  `LIMIT_REACHED` and leaves votes final, without touching `polls`.

**A2.3 The change write (Option C kept: the hot post doc is never read inside a transaction).**
1. **The read.** When `e != 0` the service reads the vote doc first (+1, the read D6 step 7 already makes). When
   `e == 0` it tries today's blind Create first, and reads the doc only on `AlreadyExists`. The read gives `cs`, `n`
   and the doc's `UpdateTime`.
2. **One blind batch, no transaction:**
   - `pollVotes/{postId}_{uid}`: `Update` with a **`LastUpdateTime` precondition** equal to the read's `UpdateTime`:
     `choice = c`, `changes = Increment(1)`, `changedAt = now`.
   - `posts.EngagementWriter.StagePollChange(b, postID, from, to)`, the sibling of `StagePollVote`: an `Update` with an
     `Exists` precondition, `Increment(poll.counts.<from>, -1)` and `Increment(poll.counts.<to>, +1)`. `poll.total` is
     not touched.
   - `userLikes/{uid}`: a field-level `ArrayRemove("<postId>:<from>")` and `ArrayUnion("<postId>:<to>")`. One write
     cannot carry two transforms on one field, so these are **two writes to `userLikes` in the same batch**, applied
     in order.
     - W6-36 must prove that the Go client, the emulator and dev Firestore accept two writes to one document in one
       commit.
     - **Fallback** if they do not: a transaction that reads `userLikes` (+1 read) and rewrites `pollVotes` with the
       entry replaced. The post doc is still only written, never read.
3. **Precondition failures.** `store.CommitWithRetry` maps NotFound and FailedPrecondition alike to "precondition
   failed". The service therefore re-reads the vote doc:
   - If it moved, the table decides again: a concurrent change won.
   - If it did not move, the post is gone: NOT_FOUND, 0 writes.
   - Bounded at 4 attempts, then UNAVAILABLE with `contention=true` (D6 step 9).
4. **Close.** Before every attempt the service re-checks `now < closesAt` (immutable and cached: 0 reads), so a
   retried change cannot commit seconds after close. D6's few-hundred-millisecond window stays.

**Why the counts stay right under concurrency.**
- Every change is applied against the exact vote-doc version it read. A concurrent change, by a second device or a
  racing tap, fails the precondition and is decided again against the new state.
- Two changes by one voter therefore never both decrement the same old choice.
- New votes by different users share only the post doc, which is written by `Increment`, never read. So I-V2 holds
  after any interleaving.
- **`TestW617_ConcurrencyManyVotersRacingThemselves`** (60 voters × 3 choices) is **flipped into two arms**:
  - **Arm (a), `e = 0`:** today's assertions. One vote per voter; the other two calls replay or get `ALREADY_VOTED`
    with the stored choice.
  - **Arm (b):** each voter votes `c0`, then races `c1` and `c2`, both with `e = c0 + 1`. Exactly one of the two
    changes commits and the other gets `ALREADY_VOTED` naming the winner. Afterwards there is exactly one vote doc
    per voter with `changes == 1`, `Σ counts == total == 60`, each count equal to the tally of vote docs, and exactly
    one `userLikes` entry per voter equal to the stored choice. Every success response's `viewer_poll_choice` is the
    choice that call committed.

**A2.4 Limits (abuse as cost).**
- **A change is a `VotePoll` call**, so it counts toward:
  - `RATE_LIMIT_POLL_VOTE_PER_MIN`: 30 per instance, 90 effective at 3 instances;
  - `POLL_VOTES_PER_DAY`: 300 per instance, 900 effective;
  - `POLL_VOTES_PER_DAY_NEW_ACCOUNT`: 50 per instance, 150 effective.
- **New `POLL_VOTE_CHANGES_MAX`** (ComposerConfig; default 5, range 0 to 20; ceiling enforced like
  `MEDIA_MAX_SCREEN_ATTEMPTS`).
  - It is **durable**: `changes` on the vote doc, written by the change itself (+0 writes), so an instance restart
    resets nothing.
  - One account can move a poll's counts at most 1 + 5 times over the poll's life. That is the count-flapping bound:
    moving a count by k needs k accounts.
- **Option D's write bound is corrected.**
  - Option D argued that "one vote per account per poll" bounds an account's writes at 3 × the open polls it can see,
    whatever the in-memory cap does after a restart. With changes that is no longer true on its own.
  - The durable `changes` counter restores a per-poll bound: 3 + 4 × 5 = 23 writes per account per poll.
  - The daily caps bound calls to 900 a day. So the worst account writes 4 × 900 = 3,600 a day (INR 0.36), about
    **INR 11 per account-month**, up from INR 8 (security review section 1).

**A2.5 After close.** Every `VotePoll` after `closesAt` answers `POLL_CLOSED` (N2), changes and replays included.

**A2.6 Lifecycle (D8).**
- **Eraser:** unchanged. It deletes each vote doc with its current choice, and the counts stay as anonymous totals
  (F6).
- **Export `poll_votes`:** `postId`, `choice` (the current one), `createdAt`, plus **`changedAt`** once a vote was
  changed.
- **No history of earlier choices is kept anywhere.** The vote doc is updated in place and no log line carries a
  choice (Observability), so there is no history to export or erase.
- **TTL:** unchanged. `expireAt = closesAt + 30 d`, and a change does not move it.
- **New vote-doc fields:** `changes` (int, absent = 0) and `changedAt` (timestamp, absent = never changed). They are
  small scalars on the automatic indexes, and need no fieldOverride.

**A2.7 Cache (the O-2 lag).**
- **New `posts.Engagement.PollVoteChanged(postID, from, to) *Post`**, the sibling of `PollVoted`: `AdjustPoll` with −1
  and +1, each count clamped at 0, total unchanged.
- **The engagement cache must replace the entry.** `withPollVote` today returns the list unchanged when the post
  already has an entry, which would keep the old choice. The change path replaces it instead (I-V3).
- **O-2 is unchanged.** Other instances lag by up to the 60 s post-cache TTL. The voter's own response shows the
  cached counts with this change applied.

**A2.8 Client UX (W6-37).**
- **What X offers.** Our X research (`docs/x_research/07_functionality_inventory.md`, git-ignored) records polls as
  "one vote/user, expiry", and names no change control. So this control is ours, drawn in the card's existing visual
  language.
- **After a vote,** the footer reads "N votes · 2 days left · Change vote". "Change vote" is an accent text button.
  - It is shown when the poll is open, the viewer voted, is not the author, and `viewer_poll_vote_blocked` is false.
  - It is hidden on embeds, which have no buttons.
- **Tapping "Change vote"** turns the bars back into the choice pills, with the current choice marked by its check,
  plus "Cancel". The results stay visible: the viewer has voted.
- **Tapping another pill** is optimistic: the bars move −1 and +1 locally and the check moves. Then `VotePoll` is sent
  with a **fresh key per tap** and `expected_choice` = the current `viewer_poll_choice`.
  - A retry of that tap reuses its key.
  - A new tap first drops the pending retries of an older tap (A2.2, ABA).
  - Tapping the current pill, or "Cancel", returns to the bars without a call.
- **Error answers:**
  - `ALREADY_VOTED`: render `metadata["choice"]` and refresh once with GetPost. No automatic replay any more for a
    change; the existing replay stays for a first vote (`e = 0`).
  - `LIMIT_REACHED` `poll_vote_changes`: "You can't change your vote again". Hide "Change vote" for that poll and
    render `metadata["choice"]`.
  - `TARGET_BLOCKED`: the disabled state of A1.5.
  - `POLL_CLOSED`: one GetPost, then the final results.
  - UNAVAILABLE: roll back. The retry reuses the key.
- **Accessibility:** the button's semantics label is "Change your vote".

**A2.9 L-3 gets worse. Your L-3 copy decision is now more pressing.**
- A new vote moves one count and the total. A change moves **one count down and another up, with the total fixed**.
- That shape tells anyone watching the counts (the author always, every voter after voting) that someone changed,
  **and from which choice to which**.
- In a small poll, for example from a protected account with a handful of approved followers, the person who just
  changed is often guessable. So a change reveals **both** their old and their new choice.
- The section 4 policy line the security review proposed ("you can vote only once") is now false. The revised wording
  is in that review, and its approval stays with you.

**A2.10 Cost.** See "Cost impact (Amendment 1)".

### A3. Options locked after the first vote (decision 2): confirmed, and recorded as an invariant
**Already true. Verified against the protos and the writers on 13b5080f:**
- `PostsService` has CreatePost, DeletePost, GetPost, GetThread, SchedulePost, ListScheduledPosts and
  CancelScheduledPost. There is no edit RPC.
- `SchedulePostRequest` carries no poll (F5). No RPC updates a scheduled item: Cancel only cancels.
- Engagement's only poll writer, `StagePollVote` (and A2's `StagePollChange`), touches `poll.counts.*` and
  `poll.total` only.
- The moderation writers set `moderation` and `moderatedAt`. The quote tombstone rewrites `embedded` on other posts
  (N2).
- So `poll.options`, `poll.durationMin` and `poll.closesAt` are written once, in the CreatePost write.

**I-V4, binding on any future feature.**
- An edit of posts or of scheduled posts (its own ADR) must refuse to change a poll's options, their order,
  `durationMin` or `closesAt` once `poll.total > 0`. The check runs in the same transaction as the edit.
- Reason: `pollVotes.choice` and `userLikes.pollVotes` store option **indexes**, so a reorder would silently move every
  vote.
- Recommended: a poll is never editable, even before its first vote.

### A4. Drafts (decision 2)
**Owner-only: holds.**
- Every `DraftsRepository` query filters by uid. A URL draft id is safe: I-1 in the security review, where
  `loadDraft` refuses another uid's row.
- W6-31 adds the `{uid, draftId}` key as defence in depth.
- Drafts live on the device only. That is device-local per uid, and no server path exists.

**May be incomplete: holds.**
- A draft can hold up to `kMaxDraftCodePoints` (2,000) code points, which is more than a post's 280, and a half-built
  poll.
- It never holds media (F8).
- **This does not answer the L-5 age-limit question, which stays open.**

**Full validation and moderation at publish: holds by construction.**
- The Drafts screen never sends anything itself: it opens the composer (`/compose?draft=<id>` or the pick-mode pop).
- So publishing a draft is a plain CreatePost or SchedulePost, with every check a new post gets:
  - D9 text and the 280 limit;
  - the poll rules (D1);
  - reply audience, labels and flags;
  - images uploaded fresh and screened by FinalizeUpload (A5);
  - for a scheduled post, a fresh validation by the publish sweep (`INVALID_CONTENT`).
- Text moderation at Stage 0 is report-driven (ADR-0016) for drafts, as for every post.
- No server draft store exists, so nothing can bypass these checks.

**Prevent duplicate publication: a gap exists.** Verified in `composer_cubit.dart` and `drafts_repository.dart`:

| Case | Today | Verdict |
|---|---|---|
| S1. A double tap on Post or Schedule | `submit()` returns unless `canSubmit`. `submitting` is emitted synchronously before any await, so the second tap sends nothing | **safe** |
| S2. A retry after a lost response, same session, same content | `_keyFor(intent)` returns the same key: `_fail` keeps it, and keys are per intent (text, media ids, alt texts, audience, poll; for a schedule also the time). The server replays: CreatePost's idempotency doc lives 24 h; the SchedulePost doc id is `hash(uid, key)` | **safe** |
| S3. When the row is deleted | only after success: `discardDraft()` after CreatePost returns, `_draftScheduled()` after SchedulePost returns; autosave stops while submitting | **correct order** |
| S4. The same images twice | CreatePost attaches media single-use (`media.postId`; `LoadForPost` refuses an attached doc), so a second post cannot carry the same images | **safe for media**, but see G1 |
| **G1. A crash, a kill or a closed tab after the request left and before the answer** | The key lives only in the cubit's memory (`_keys`, at most 8 entries). The row survives. Reopening the draft builds a new cubit and mints a fresh uuid, so a **second post** is created. The reopened draft has no images (F8), so the duplicate is text-only (plus the poll). The scheduled path is the same: a second scheduled item, and both publish if text-only. With images, the second fails at publish because the first took them | **gap** |
| **G2. Success, then a crash before the local delete** | `unawaited(discardDraft())` runs after success. A kill in that window leaves a postable row, and reopening it posts again | **gap** (small window) |
| **G3. A lost response, then an edit, then Post, in the same session** | The edited intent gets a new key, so a second post can appear while the first, whose optimistic row was rolled back, already exists | **gap** |
| **G4. The same draft open in two composers** (two web tabs, or a composer opened twice) | two in-memory keys, so two posts | **gap** |

**The fix (W6-39, client only, 0 server cost):** persist the send on the draft row.
- **New nullable columns,** in drift schema v10: `sendKey`, `sendKind` (post or schedule), `sendPublishAt` and
  `sendStartedAt`. W6-31 also bumps the schema, so the two PRs serialise.
- **Claim or reuse before the RPC.** In one local transaction, before sending: if the row already holds a `sendKey` of
  the same kind and inside its window (below), reuse it; otherwise write a fresh one. This closes G1, G2 (the replay
  returns the existing post) and G4 (the second composer reuses the first one's key).
- **Clear it only on a definitive answer:**
  - Success deletes the row.
  - A refusal that proves nothing was created clears `sendKey` and keeps the row: VALIDATION, FEATURE_DISABLED,
    EMAIL_NOT_VERIFIED and MEDIA_NOT_READY.
  - Every other answer keeps it: network errors, UNAVAILABLE, DEADLINE_EXCEEDED, CANCELED, unknown errors, and
    QUOTA_EXCEEDED and LIMIT_REACHED (the ADR-0021 review m1 note: they can follow a near-simultaneous success).
- **The next send of that row** (after a reopen, or after an edit that follows an ambiguous failure, G3) uses the
  stored key, whatever the content:
  - The same body replays and returns the existing post. The row is deleted, with a toast: "Already posted. View".
  - A different body gets `IDEMPOTENCY_KEY_REUSED`, which proves the earlier send landed. The composer says "An
    earlier version of this post was sent" with "View profile". "Post this version too" mints a new key, as an
    explicit choice.
  - If nothing landed, the stored key creates the post once.
- **The window.**
  - For `post`, the bound is CreatePost's idempotency TTL (24 h). The client reuses the key for at most 23 h.
  - After that the composer says "We couldn't confirm whether this was posted. Check your profile first", with "View
    profile", before minting a new key.
  - For `schedule`, the scheduled doc keeps the key (PENDING, then 7 d after a terminal state), so the window is the
    item's life.
  - A send of the other kind (scheduled first, then "Post now") cannot reuse the key: it warns the same way.
- **Out of scope:** replies and quotes have no draft row (drafts are root posts only), so G1 for them is not a drafts
  issue. Left as it is.

### A5. The Vision attempt cap (decision 3; revises #535)
**A5.1 What #535 does, and why it misses decision 3.**
- `ClaimScreening` increments `screenAttempts` in the claim write. At `MEDIA_MAX_SCREEN_ATTEMPTS` (3) the next
  FinalizeUpload REJECTS the doc (`reasonAttempts`) with no Vision call.
- Every claimed attempt counts, whatever its outcome. So three Vision outages in a row reject an honest image.
- **A busy GIF slot burns attempts.** `errGifBusy` is raised inside `screen` after the claim, and W6-16's client
  retries the same finalize after 2, 4 and 8 s. A GIF that meets a busy slot three times is REJECTED. That is a live
  defect under load.

**A5.2 Definitions.**
- **A valid assessment:** one Vision response, for one image of the doc in one attempt, that carries a
  `SafeSearchAnnotation` (a verdict, blocking or not).
- **A completed screening:** every image the doc needs (1, or 2 with the thumbnail) has a valid assessment in one
  attempt. A completed screening is **terminal**: READY when nothing blocks, REJECTED `policy` when anything does. The
  one exception: when publish or resolve fails afterwards, the doc stays PENDING.
- **Read literally** ("count only completed assessments"), the cap of 3 could therefore almost never bind: a completed
  screening ends the doc.
- **The reading proposed here:** an attempt **consumes one of the 3** when it produced **at least one valid
  assessment** (which was billed) and the doc did not end. That is the only reading under which the cap bounds
  anything, and it is exactly the H-3 loop shape: one image answered, the other failing.

**A5.3 (a) Which outcomes consume what.** These are per claimed attempt; the counters are in A5.4.

| Outcome of the attempt | Doc | Consumes |
|---|---|---|
| Completed, nothing blocks, publish and resolve succeed | READY (terminal) | nothing (the doc is done) |
| Any valid assessment blocks, **even if the other image failed** (**new:** today `screenAll` returns the other call's error and the doc retries) | REJECTED `policy` (terminal) | nothing |
| Vision INVALID_ARGUMENT on an image (#535, unchanged) | REJECTED `invalid` (terminal) | nothing |
| At least one valid assessment, nothing blocks, but another image got no valid assessment, or publish or resolve failed after a completed screening | PENDING | **1 attempt** (`screenAssessed`) |
| No valid assessment: an outage or transport error, our 10 s Vision deadline or the 20 s finalize deadline, Vision 5xx or RESOURCE_EXHAUSTED, a failed Vision-counter reserve, an internal error, **or a billed answer that is not valid** (a per-image error other than INVALID_ARGUMENT, an empty response, a response without an annotation) | PENDING | **no attempt**, 1 **retry** |
| Not claimed: verify refused or found the upload missing, another call holds the claim, **a busy GIF slot** (the slot wait moves **before** the claim) | unchanged | nothing (0 writes) |

**A5.4 (b) and (e) The counters, at +0 writes.**
- **`screenAttempts`** keeps its writer and is not renamed. The claim write increments it, so it now counts
  **claims**. It is the crash-safe ceiling: a claim is recorded before any Vision call, so a lost release write or a
  dead instance cannot escape it.
- **New `screenAssessed`**, incremented by `Increment(1)` in the **existing** `releaseClaim` write. That write already
  happens on every non-terminal path (1 write, `UpdateTime` precondition). It is incremented only when the attempt
  consumed an attempt (A5.3, row 4).
- **Retries** = `screenAttempts − screenAssessed`. This is exact at the pre-check, because the claim is exclusive.
- **Pre-check (step 0b):** REJECTED `attempts` when `screenAssessed ≥ MEDIA_MAX_SCREEN_ATTEMPTS` (3, its meaning
  revised to "attempts with a valid assessment"), or when `screenAttempts ≥ MEDIA_MAX_SCREEN_ATTEMPTS +
  MEDIA_MAX_SCREEN_RETRIES` (3 + 5 = 8).
- **A lost release write** after an assessed attempt counts it as a retry, not an attempt. That fails towards the
  larger, still bounded, total.
- **Write budget:** +0 writes and +0 reads. Terminal paths write `Resolve` or `reject` as today, and a busy slot now
  writes nothing (it used to cost a claim and a release).

**A5.5 (c) Separate rate limits, in Vision units.**
- **FinalizeUpload gets its own bucket.** Today CreateUpload and FinalizeUpload share `rlMedia` at
  `RATE_LIMIT_POST_CREATE_PER_MIN` (10 per minute per uid per instance). FinalizeUpload moves to the new
  **`RATE_LIMIT_MEDIA_FINALIZE_PER_MIN`** (default 10; 30 effective at 3 instances), so retries cannot starve new
  uploads, and the reverse.
- **New per-uid Vision-units daily cap `media_vision_units_daily`** (`ratelimit.DailyCap` in the media service):
  - **`MEDIA_VISION_UNITS_PER_DAY`**: default 60 per instance, 180 effective at 3 instances.
  - **`MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT`**: default 12, 36 effective. The account age comes cache-first from the
    profile the account-status interceptor read, so +0 reads (the N2 poll-cap pattern).
  - **When it is checked and charged:** with the doc's units (1 or 2), after verify and **before the claim**. A refusal
    therefore writes nothing: RESOURCE_EXHAUSTED, RATE_LIMITED, `limit = media_vision_units_daily`, `retry_after` to
    IST midnight.
  - **Refunds:** only when no Vision call was sent (a lost claim race, a reserve error, a pre-scan refusal), or when
    the call failed before any response.
  - **Never refunded:** timeouts and every answered call. A timed-out call may have been billed while
    `VISION_MONTHLY_CAP` returned its units (N1), so this cap is what bounds that class per user.
- **Honest headroom.** The heaviest honest use is 20 uploads × 2 units = 40, which leaves 20 units of retries even
  when every request lands on one instance (min-instances 0 means one instance most of the time).
- **Per instance, in memory, reset by a restart.** It is a cost control. The durable per-doc bound is A5.4 together
  with the uploads quota (`quotas.uploads`: 20 a day, 5 for new accounts).

**A5.6 (d) Retrying the retained image without re-uploading.**
- **How long the image is kept.**
  - The PENDING doc lives `PendingTTL` = 48 h (`expireAt`, TTL).
  - The private upload objects are deleted by the upload bucket's lifecycle rule `age = 2` days.
  - Both run asynchronously, and neither can remove the image before 48 h.
  - A failed attempt keeps both: `releaseClaim` deletes nothing, and only `reject` deletes the objects.
  - So the retry window is 48 h. In practice it is the composer session, because drafts keep no media ids (F8) and a
    reopened draft re-uploads.
- **A retry is the same FinalizeUpload, with the same media id.**
  - With W6-25 (#536) the signed PUT is create-only, so a second PUT answers 412 and the client treats it as stored.
  - Every attempt re-runs verify with the generation pin. The bytes screened are therefore always the bytes uploaded.
  - W6-16's "fall back to the re-PUT path" after repeated MEDIA_NOT_READY stays correct: the re-PUT gets 412, then
    the client finalizes again.
- **Server:** the screening UNAVAILABLE ("image checks are temporarily unavailable") gains `retry_after` 5 s. This is
  an existing field, so no proto change.
- **Client UX (W6-40's client part):**
  - The attachment tile shows "Checking…".
  - On that UNAVAILABLE it retries the same finalize after `retry_after` (2, 4 and 8 s with jitter if absent), at most
    3 times.
  - Then it shows "Couldn't check this image · Retry", a manual tap with the same media id and no upload.
  - Post stays disabled while a tile is unchecked.
  - `RATE_LIMITED` `media_vision_units_daily`: "You've reached today's image checks. Try again tomorrow", with no
    retry.
  - REJECTED `attempts`: "We couldn't check this image. Remove it and choose another" (its objects are deleted).

**A5.7 The H-3 bound is preserved.**
- **Unit accounting is unchanged from #535.** `VisionAnsweredError` and the answered count are what keep
  `VISION_MONTHLY_CAP` and its `reject` honest service-wide, so billed-but-invalid answers are still counted there.
- **Per doc:** at most `MEDIA_MAX_SCREEN_ATTEMPTS + MEDIA_MAX_SCREEN_RETRIES` = 8 claims × 2 = **16 billable units**
  (#535: 3 × 2 = 6).
- **Per account per day, effective at 3 instances:**

| Bound | Units per day | INR per day | INR per account-month |
|---|---|---|---|
| #535 (3 attempts × 2 units × 20 uploads) | 120 | 17.1 | ≈ 520 |
| This amendment without A5.5 (8 claims × 2 × 20) | 320 | 45.6 | ≈ 1,390 |
| **This amendment with A5.5** (60 per instance × 3) | **180** | **25.7** | **≈ 780** |
| New accounts with A5.5 (12 × 3; #535: 5 × 3 × 2 = 30) | 36 | 5.1 | ≈ 156 |

- At INR 0.1425 per unit ($1.50 per 1,000, INR 95 per USD).
- **The per-account bound is looser than #535's,** by INR 260 per account-month, in exchange for honest retries. The
  service-wide `VISION_MONTHLY_CAP` with `reject` still caps the total (10,000 units; 20,000 to 40,000 in credit
  mode). A ring that drains it denies uploads to everyone, as before.
- **This loosens a merged security fix,** so W6-40's PR needs a security-auditor review (W6-42) before merge.

### A6. Contract changes proposed for W6-35 (additive; `buf lint` and `buf breaking` clean)
| File | Change | Number |
|---|---|---|
| `posts/v1/posts.proto` | `PostView.viewer_poll_vote_blocked` (bool): true when the viewer blocks the author of this post's live poll; VotePoll answers TARGET_BLOCKED; false on every other row and on older revisions; cleared on a withheld row | **9** (8 is `viewer_poll_choice`) |
| `engagement/v1/engagement.proto` | `VotePollRequest.expected_choice` (int32): 0 = no vote known; 1-4 = the caller's current `viewer_poll_choice`; a change applies only when it equals the stored vote | **4** |
| | `VotePollRequest.idempotency_key` comment: "one key per tap; reuse it only to retry that tap". The `rpc VotePoll` comment: the A2.2 table, the change budget and TARGET_BLOCKED | comments |
| `common/v1/common.proto` | `ERROR_REASON_TARGET_BLOCKED` comment adds VotePoll (the caller blocks the poll's author). `ERROR_REASON_ALREADY_VOTED` comment: answered when `expected_choice` does not name the stored vote; `metadata["choice"]` unchanged. `ERROR_REASON_LIMIT_REACHED` comment adds `metadata["limit"] = "poll_vote_changes"` and `metadata["choice"]` | comments |
| `media/v1/media.proto` | FinalizeUpload comment: the screening UNAVAILABLE carries `retry_after`; RATE_LIMITED `media_vision_units_daily`; REJECTED `attempts` after 3 assessed attempts or 8 claims | comments |

- No field is reused or renumbered.
- No new `ErrorReason`.
- No new RPC.
- `make proto` regenerates the Go and Dart code.

### A7. Config changes (rule 11; ComposerConfig and the ratelimit config; defaults in Terraform for dev and prod)
| Var | Default | Range | Meaning |
|---|---|---|---|
| `POLL_VOTE_CHANGES_MAX` | 5 | 0–20 | changes per voter per poll, durable (`pollVotes.changes`); 0 = votes are final |
| `MEDIA_MAX_SCREEN_ATTEMPTS` | 3 (unchanged) | 1–10 (unchanged) | **revised meaning:** attempts that produced a valid assessment without ending the doc (`screenAssessed`) |
| `MEDIA_MAX_SCREEN_RETRIES` | 5 | 0–10 | attempts with no valid assessment; with the above it sets the claims ceiling on `screenAttempts` |
| `MEDIA_VISION_UNITS_PER_DAY` | 60 | 2–200 | per-uid Vision units a day, per instance (180 effective) |
| `MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT` | 12 | 2–60 | the same, for accounts younger than the new-account window (36 effective) |
| `RATE_LIMIT_MEDIA_FINALIZE_PER_MIN` | 10 | as the other buckets | FinalizeUpload's own bucket, split from CreateUpload's (30 effective) |

**Flags.**
- **No new flag.**
  - The vote change and the block rule ride `polls`, which has never left the dev allowlist (ceiling: allowlist 6,
    `max_percent` 0) and is `off` in prod.
  - The Vision revision rides `media` and `gif`, also allowlist only.
- **Kill switches:**
  - `POLL_VOTE_CHANGES_MAX = 0` for changes;
  - `FEATURE_POLLS = off` for polls;
  - `FEATURE_GIF = off`, `FEATURE_MEDIA = off` or `DEGRADED_MODE = nomedia` for media.
- **The 100 % rule (L-1) applies to `polls`:**
  - An old revision answers a change with `ALREADY_VOTED`, and a new client renders the stored choice. That is
    harmless.
  - An old revision does not refuse a blocked voter, which is acceptable on the dev allowlist.
  - So `polls` leaves the dev allowlist, and goes on in prod, only once 100 % of traffic is on a revision with W6-36.

### Cost impact (Amendment 1)
- **Fixed monthly cost added: INR 0.** No new service, index, fieldOverride, topic, Scheduler job or TTL policy.
  Nothing depends on ADR-0022.

**Per RPC.** Worst-case reads include the account-status interceptor; every call is charged to the ADR-0010 D5
budget.

| Path | Reads worst | Reads typical | Writes | Deletes |
|---|---|---|---|---|
| `VotePoll` change | **9**: the 8 of a new vote (D6 ceiling) + the vote doc 1; +1 per precondition retry, ≤ 3 more | 4 | **4**: vote doc, post counters, `userLikes` × 2 (fallback: 3 writes + 1 read) | 0 |
| `VotePoll` at the change cap, or `ALREADY_VOTED` for a stale `e` | 9 | 4 | 0 | 0 |
| `VotePoll` refused `TARGET_BLOCKED` | ≤ 7 (as the other step-5 refusals) | 2 | 0 | 0 |
| `viewer_poll_vote_blocked` on GetPost, GetThread and GetUserTimeline | **+0** (the snapshot `Decide` read) | 0 | 0 | 0 |
| Block or Unblock | +0 (no poll side effect) | | +0 | +0 |
| A resumed draft send (W6-39) | a CreatePost or SchedulePost replay: 14 cold / 1 warm, or the SchedulePost replay row | | 0 on a replay | 0 |
| FinalizeUpload, a retry with no valid assessment | 2n + 1 + interceptor, as today | as today | 2 (claim + release), as today | 0 |
| FinalizeUpload, a busy GIF slot | as today | | **0** (was 2) | 0 |
| FinalizeUpload refused by `media_vision_units_daily` or by its bucket | ≤ the reads before the claim | | 0 | 0 |

**Per DAU per day** (assumption: changes are 10 % of votes, so 0.03 a DAU a day; W6-41 measures it with the W6-21 harness):
- +0.12 reads and +0.12 writes;
- +0.03 Cloud Run requests;
- 0 Vision units on the honest path. An outage retry is not billed when unanswered; the units cap bounds the rest.

**INR per month** (Mumbai prices, INR 95 per USD, on ADR-0029's baseline; `sre-performance` re-bases on
`cost-model.md` §16):

| Line | 300 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|
| Firestore reads (+0.12 per DAU a day, all billed) | 0.04 | 0.12 | 0.36 |
| Firestore writes (+0.12 per DAU a day, billed past the free writes) | 0 | 0.36 | 1.08 |
| Vision, honest path | 0 | 0 | 0 |
| **Amendment 1 total** | **≈ 0.04** | **≈ 0.5** | **≈ 1.4** |

**Free quotas that move** (whole product):

| Quota | Runs out at (was) | Amendment delta at 2× that DAU | at 10× |
|---|---|---|---|
| Firestore writes 20k a day (40.70 per DAU, was 40.58) | ≈ 491 DAU (493) | 982 DAU: INR 0.35 | 4,910 DAU: INR 1.8 |
| Firestore reads 50k a day (358.77 per DAU, was 358.65) | ≈ 139 DAU (139) | 278 DAU: INR 0.03 | 1,390 DAU: INR 0.17 |
| Vision, Cloud Run, GCS | unchanged | — | — |

**Abuse as cost** (per instance × 3 max instances):
- `VotePoll`: 90 calls a minute and 900 a day per account (150 for new accounts). At most 4 writes a call and 23 per
  account per poll, so about INR 11 per account-month (A2.4).
- FinalizeUpload: 30 calls a minute, 180 Vision units a day per account (36 for new accounts), and 16 per media doc,
  so about INR 780 per account-month (A5.7).

**Trigger that justifies it:** none (no fixed cost).

### Stage ladder (Amendment 1)
| Concern | Stage 0 (this amendment) | Seam to protect now | Stage 2/3 target | Trigger (measured, 7 days) |
|---|---|---|---|---|
| Poll counters with changes | −1/+1 `Increment` on `posts/{id}.poll.counts.*` in a blind batch; one post write per change, as per vote | `StagePollVote` and `StagePollChange`, the only poll counter writers; `contention` and `outcome=changed` on the `poll_vote` line | sharded counters (the "Poll counters" row of the Stage ladder above), which take decrements unchanged | unchanged: sustained contention, or more than 1 vote or change per second on one poll for 5 minutes. Changes make a hot poll hotter: count them in the same signal |
| Per-uid Vision units | in-memory `DailyCap` per instance (× 3) plus the durable per-doc claims ceiling | the media service's `visionUnits` limiter interface | a shared limiter (Memorystore) or a `quotas` field (+1 read, +1 write per finalize) | abuse that spreads across instances: `media_vision_units_daily` refusals on all 3 instances for one uid, or monthly units above 1.5× the model with no matching uploads |
| Draft sends | the send key on the device's draft row | `DraftsRepository` (its only reader and writer) | synced drafts (the "Drafts" row of the Stage ladder above) carry the send key server-side | as the synced-drafts trigger |

No collection approaches 500 writes a second: a change updates an existing vote doc and adds no new key.

### Observability (Amendment 1)
- **`poll_vote` line:**
  - New outcomes: `changed`, `change_limit`, `stale_expected` (the `ALREADY_VOTED` row) and `voter_blocks_author`.
  - **Never** the old or the new choice, nor `expected_choice`. Logs still never pair a uid with a choice.
- **FinalizeUpload line:**
  - `screen_outcome` (terminal, assessed or unassessed), `screen_claims`, `screen_assessed`;
  - `units_daily_refused` (bool);
  - `attempts_exhausted` (`assessed` or `claims`).
- **No new log-based metric or alert policy.**

### Tests to flip (never delete)
**Backend:**
- `TestW617_NotFoundBytesIdentical`:
  - Keep the byte identity for "the author blocks the voter" (also by REPOST id), takedown, `SUSPENDED_AUTHOR` and
    another instance.
  - Flip the O-1 part: a voter who blocked the author now gets `TARGET_BLOCKED`, 0 vote docs, total unchanged, and the
    post is still visible through GetPost.
- `TestW617_RepostIDVotesInTheOriginal`: the different-choice call by REPOST id:
  - with `e = 0` it stays `ALREADY_VOTED`;
  - add `e = 3` (the stored choice + 1): a change on the original, counts −1 and +1, total 1.
- `TestW617_ConcurrencyManyVotersRacingThemselves`: two arms (A2.3).
- `TestVotePoll_ReplayAndAlreadyVoted` and `TestVotePoll_ConcurrentSameVoter`: the same two-arm split.
- `TestW627_AttemptCapStopsTheLoop` keeps passing: a thumbnail that fails while the full image answers is an
  assessed attempt. It gains companions:
  - both calls unanswered: no attempt consumed, stopped at 8 claims;
  - billed-invalid answers: units counted, retries consumed;
  - a busy GIF slot: no claim, no write.
- `TestFinalize_FailedAttemptReleasesTheClaim`: the release also carries `screenAssessed`.

**Client:**
- `poll_cubit_test` "ALREADY_VOTED re-reads the post once and keeps the server choice": keeps the first-vote case;
  for a change, no automatic replay.
- `poll_repository_test` "ALREADY_VOTED carries the server choice (0-based)".
- `poll_display_test` "a choice the server named (ALREADY_VOTED) before the re-read".
- The `poll_card_test`, `post_card_poll_test` and `w6_poll_flow_test` cases that assume no control after a vote:
  "results: percents total 100, check and bold on the leader", and "tap on choice 2: exactly one VotePoll, bars with
  the check". They now also expect "Change vote".

### Founder decisions on the open items (2026-10-31, second message)
1. **GDPR Art. 9 → no sensitive-data polls, initially.** Polls must not solicit sensitive personal information (health,
   religion or belief, political opinion, sex life or orientation, ethnicity, union membership, genetic or biometric
   data). Enforced as a content rule (Terms/community rules, a composer hint, a report reason and the moderation runbook),
   not by automated detection at Stage 0. W6-43. Because such polls are prohibited, L-2 (W6-29) is not promoted to an
   Art. 9 requirement, but W6-29 stays required before release for retention (item 4).
2. **L-3 copy → "Individual choices are hidden from other users"**, never "anonymous". This is accurate as built: no RPC
   returns another account's choice (D4; only the voter sees their own, and only the voter's export lists it). Because
   live totals can still reveal a choice (or a change, A2.9) in a very small poll, the Privacy Policy states that caveat
   in plain words. W6-44.
3. **L-5 → drafts expire 30 days after the user's last edit.** Device-local, enforced on the client (purge on open and on
   app start; a scheduled post is server-side and not a draft). "May be incomplete" still holds. W6-45 (serialise with
   W6-31 and W6-39, the same drafts table).
4. **Privacy Policy → disclose vote storage, visibility, retention and deletion; finalize vote retention before
   release.** As built: the vote doc expires `POLL_VOTE_TTL_AFTER_CLOSE` (default 30 days) after the poll closes, but the
   per-account copy `userLikes.pollVotes` has no expiry until W6-29. The release is blocked until W6-29 is merged and the
   founder confirms the period (proposed: 30 days after close for both). The policy text (`app/web/privacy.html`) is
   W6-46; finalizing retention is W6-47. The section 4 polls line is revised for vote changes ("vote only once" is no
   longer true).

### What the founder accepted (2026-10-31, in principle)
- The interpretation and its reversal of D6 step 7, F4 and D7's argument.
- `ALREADY_VOTED` kept for a stale `expected_choice` (or choose the unconditional change instead).
- `TARGET_BLOCKED` for a voter who blocks the author, hidden results until close for one who never voted, and
  `viewer_poll_vote_blocked`.
- `POLL_VOTE_CHANGES_MAX` 5.
- The drafts send-key fix.
- The reading of "completed, valid assessment" in A5.2, the 3 + 5 split, and the units cap at 60 / 12 per instance,
  with its per-account bound looser than #535's by about INR 260 a month.

### Handoff (Amendment 1)
- **architect:** W6-35 (the A6 protos, `make proto`). FU-7, in a `.claude/` PR the founder approves:
  - `firestore-data-model` rows: `pollVotes.changes` and `pollVotes.changedAt`, `media.screenAssessed`, and the
    revised meaning of `media.screenAttempts`;
  - operation rows from the Per RPC table above;
  - the stage-ladder rows above.
- **backend-developer:**
  - W6-36: A1 and A2, in one PR on `service_polls.go`, `repo_polls.go` and the converter.
  - W6-40: A5. It needs W6-42's review before merge.
  - Seams: `posts.EngagementWriter.StagePollChange`, `posts.Engagement.PollVoteChanged`,
    `ViewerSet.WithBlockedAuthors`, the media `visionUnits` limiter.
- **frontend-developer:**
  - W6-37: the poll card.
  - W6-39: the draft send key.
  - The W6-40 client part: the finalize retry tile.
- **tester:** W6-38 (drafts duplicate-publication matrix) and W6-41 (backend and client tests for A1, A2 and A5; the
  flips above).
- **security-auditor:** W6-42, a review of W6-36 (the `TARGET_BLOCKED` oracle check, `expected_choice` and logs) and of
  W6-40 (the H-3 bound, the units cap and refunds).
- **sre-performance** (`cost-model.md`, its own file): the rows above.
  - `VotePoll` change: 9 / 4 reads and 4 writes.
  - Changes at 0.03 per DAU a day: +0.12 reads and +0.12 writes per DAU a day.
  - The writes crossover moves to about 491 DAU.
  - The FinalizeUpload busy-slot row drops to 0 writes.
  - The abuse bounds: INR 11 (votes) and INR 780 (Vision) per account-month.
- **production-deployer:** W6-22's dev plan gains the A7 vars, which are config only.

## Context
X's composer offers three things ours lacks: a poll, an unsent draft that survives closing the composer, and a GIF that
moves. `CLAUDE.md` fixes the Stage 0 means: counters on the parent doc (rule 3), no write fan-out, client caches, media
uploaded straight to GCS (rule 7), SafeSearch on every image (ADR-0005), no new fixed cost, 3 free Scheduler jobs per
billing account.

**Cost baseline (ADR-0028, on `docs/reviews/cost-model.md`'s 2026-10-29 W7-23 block):** with W2, W3 Part A, W3 Part B,
W7 and W4 on, 357.6 reads, 39.56 writes, 8.5 deletes and 57.4 requests per DAU per day; 12.47 Vision units and 48.3 MB
of GCS egress per DAU-month. Free reads run out at about 140 DAU, writes at about 506, Cloud Run requests at about
1,145, vCPU-s at about 1,031, free Vision units at about 80 and the 10,000 Vision cap at about 802 DAU. The Stage 0 bill
is about **INR 494 / 1,805 / 4,480** a month at 300 / 1,000 / 3,000 DAU.

**What changed since the plan was written (plan "What exists already", `main` d2ff011).** Each one changes this ADR:
1. **`PostView` field 7 is taken** by `withheld` (W3-41a, ADR-0025 L-2), so `viewer_poll_choice` is **8**.
2. **`ErrorReason` 18 is taken** by `CANNOT_MESSAGE` (W7, ADR-0027), so `POLL_CLOSED` is **19** and
   `ALREADY_VOTED` **20**.
3. **Private accounts shipped (ADR-0025).** Poll data must follow the existing stripping rules: a `withheld` row and a
   PROTECTED embed lose their poll (D4).
4. **`MEDIA_PURPOSE_BANNER` is merged (W3-5)**, and the unguessable object names of the ADR-0005 note of 2026-10-28
   (`m/<mediaId>-<suffix>.<ext>`) apply to GIFs too.
5. **`FinalizeUpload` requires the thumbnail's GCS content type to equal the full image's** (`media/finalize.go`), and
   the published thumbnail takes the full image's content type. A GIF with a JPEG thumbnail therefore needs a stored
   thumbnail type (D10).
6. **`media.Moderator.SafeSearch` takes an object path only** (`media/api.go`). Screening a contact sheet built in
   memory needs a bytes method (D11).
7. **Nothing in a `MediaRef` tells a client that an item is animated**, apart from the `.gif` suffix of its URL. That
   is not a contract, so `MediaRef` gains `content_type` (D10).
8. **The plan's A9 misses `userLikes.pollVotes`.** Every array on `userLikes` (`recent`, `recentReposts`,
   `bookmarks`) is exempt from single-field indexing, and this one needs the same exemption (D9).
9. **The baseline moved** (above). The plan priced W6 on the W2-only baseline (248.7 reads per DAU). The W6 increment
   in INR barely changes, but every crossover moves (Cost impact).

## Founder decisions F1 to F12
INR are per month, the W6 increment, at 300 / 1,000 / 3,000 DAU (Cost impact). "Default" = applied by this ADR.

| # | Question | Options | Decision | INR 300 / 1,000 / 3,000 |
|---|---|---|---|---|
| F1 | How a poll closes | (A) read-time `now ≥ closesAt`; (B) a hop on `publish-scheduled` (needs a `poll.closesAt` index, clashes with D9); (C) a new Scheduler job | **A** (default). **Scheduler: no new job; 2 of the 3 free jobs on the billing account are spoken for** (`daily-maintenance` live in prod, `publish-scheduled` defined but not applied; ADR-0028 F1 B put trends inside `daily-maintenance`). C would spend the third | A: 0. B: +288 reads a day idle + 1 per closed poll, ≈ 0.3 / 0.3 / 0.3 |
| F2 | Rule 4 for `VotePoll` | (a) the natural-key vote doc `pollVotes/{postId}_{uid}` is the idempotency record (ADR-0018 bend); (b) also store a TTL'd `idempotency/*` doc | **(a): decided by the founder on 2026-10-27** (plan header). A **bend of `CLAUDE.md` rule 4**: see D7. The merge of this ADR is its formal acceptance | (a) 0. (b) +0.3 writes and +0.3 deletes per DAU per day: ≈ 0 / 1.0 / 3.0 |
| F3 | Who sees results | hidden until the viewer voted, the poll closed or the viewer is the author; total always shown; no voter list | **Default** (D4) | 0 (the viewer's choice rides on the `userLikes` read that happens anyway) |
| F4 | Poll shape | as the plan | **Default:** 2 to 4 choices of 1 to 25 code points, distinct after NFC and case folding; 5 min to 7 days, default 1 day; the post text is the question and is required; root posts only (no reply, quote, media, GIF or schedule); a vote is final | 0 |
| F5 | Polls and scheduled posts | not combined; a scheduled poll that starts at publish | **Not combined** (default). `SchedulePostRequest` is unchanged; dated note on ADR-0021 D4 | 0 |
| F6 | A voter deletes their account | vote docs deleted, counts kept as anonymous totals; decrement open polls | **Default:** counts kept | decrement: +1 write per open vote at deletion, ≈ 0 |
| F7 | Drafts and sign-out | kept on the device per uid; cleared with `AppDatabase.clearAll` on sign-out | **Kept per uid** (default), wiped on account deletion from the device, "Delete all" offered | 0 (no server path) |
| F8 | What a draft keeps | text, poll, reply audience, labels; or also image bytes; or uploaded media ids | **Text, poll, audience and labels only** (default) | 0 |
| F9 | Where GIFs come from | device upload now; a provider picker after written terms | **Device upload** (the founder's 2026-10-22 decision stands). The picker (W6-23, W6-24) stays conditional; a picked GIF would be copied through this pipeline | 0 now |
| F10 | GIF size and playback | ≤ 2 MiB, ≤ 1,280 px long edge, ≤ 300 frames; one per post; static thumbnail + tap to play; or autoplay | **Default** (static thumbnail, tap to play, "Reduce motion" respected) | autoplay instead: 3,000 DAU +≈ 1,350 (egress) |
| F11 | GIF moderation | (a) frame-sampled SafeSearch on the server; (b) first frame only, accounts older than 7 days, report-driven review; (c) no animation | **(a), needs your explicit acceptance** (D11): the residual risk and the rule-7 reading below | (a) = (b) in units: 2 per GIF, inside the GIF total |
| F12 | Flags | `polls`, `drafts` (client-only), `gif`; later `gif_search` | **Default** (D12) | 0 |

### F11 in detail (founder acceptance required)
**Verified 2026-10-30.** Google's "Supported files" page for Cloud Vision
(<https://docs.cloud.google.com/vision/docs/supported-files>; the old `https://cloud.google.com/vision/docs/supported-files`
redirects there with a 301), page dated "Last updated 2026-10-26 UTC", lists the supported image formats as a bulleted
list that contains **"GIF"** and **"Animated GIF (first frame only)"**. **So SafeSearch on an animated GIF screens its
first frame only.** The plan's belief is confirmed. The same page recommends **640x480** for `SAFE_SEARCH_DETECTION`,
caps image files at 20 MB and caps a JSON request at 10 MB ("host larger files on Cloud Storage ... rather than passing
them as base64-encoded content").

What (a) does, what it leaves, and what you accept by merging:
1. **The API reads the whole uploaded GIF** (≤ 2 MiB, one GCS Class B operation, us-central1 to asia-south1, inside the
   free GCS egress) in `FinalizeUpload`, instead of today's 512-byte magic-byte read. **This ADR reads `CLAUDE.md`
   rule 7 ("media never passes through the API") as a rule about client uploads**: clients still PUT straight to GCS
   with signed URLs, no media byte travels in an API request or response, and the server only reads a private object
   to moderate it. If you read rule 7 strictly, this is a bend and you should choose (b) instead.
2. **Frames between the samples are not screened.** Four points of the animation's display time are sampled (D11).
   Content shown for less than about a quarter of the loop can fall between them, and the client-made thumbnail only
   shows the first frame.
3. **A contact sheet is not four separate screens (unverified).** Four frames in one 2 × 2 image cost 1 unit instead
   of 4. Google does not document how SafeSearch scores a tiled image; an explicit region that covers a quarter of the
   sheet may score lower than it would alone. Each tile is sized up to Google's recommended 640 × 480, so the sheet is
   up to 1,280 × 960. W6-18 tests the verdict with the fake `Moderator` only; W6-22 checks a few known-bad fixtures on
   dev (a handful of units).
4. **At the Vision cap, GIFs are REJECTED for every account** (photos keep ADR-0005's READY_UNSCREENED policy for
   established accounts). That is stricter than ADR-0005 and costs nothing.
5. Report-driven review (ADR-0016) stays the backstop. A reported GIF bypass is a rollback trigger (`FEATURE_GIF=off`).

Option (b) instead: no full-object read and no decoder, but the first frame is the only content screened. It relies on
the 7-day account age and on reports. Option (c) is today's behaviour, so it would not be a GIF feature.

## Options
### A. Where poll data lives (plan A1)
- **(a) A `poll` map on `posts/{postId}` (chosen).** 0 extra reads on every feed, list and embed. The counts share the
  doc's rule-3 budget with `likeCount` and `replyCount` (Stage ladder: signal and fallback).
- (b) `polls/{postId}`: +1 read per poll row on every list, an N+1 under rule 6 unless batched and cached.

### B. Who owns votes (plan A2)
- **(a) engagement (chosen):** `VotePoll`, `pollVotes`, the choice in `userLikes`, the counters through
  `posts.EngagementWriter`. This is the Like path with one more field, and `userLikes` keeps one writer.
- (b) posts owns everything. Then posts would write `userLikes`, which only engagement writes today.

### C. The vote write (plan A5)
- **(a) One blind batch (chosen):** `Create` the vote doc, `Increment` the counters with an `Exists` precondition, and
  `ArrayUnion` the viewer's choice with a field-level `Set` + `MergeAll`. 0 reads in the write, so a hot post doc is
  never read inside a transaction.
- (b) A transaction that reads the post (closed? author?) and the quota. +1 read on the hottest doc, and transaction
  contention on exactly the doc a viral poll makes hot.

### D. Per-account vote cap (plan "Rate limits")
- **(a) `ratelimit.DailyCap` in memory (chosen), 0 Firestore operations.** ADR-0018 rejected an in-memory daily cap
  for likes, because it resets on an instance restart and one account could then like without bound. Votes differ: the
  natural key admits **one vote per account per poll**. An account's vote writes are therefore bounded by 3 × the
  number of open polls it can see, whatever the cap does after a restart. The read budget (ADR-0010 D5) bounds probing.
- (b) `quotas/{uid}.pollVotes`: +1 read and +1 write per vote, plus the ADR-0021 I-3 hazard (an older revision zeroes
  a field it does not know).

### E. GIF moderation
(a) frame-sampled contact sheet, 2 units; (b) first frame only, 2 units; (c) every frame, unbounded units; (d) four
frames as four images in one request, 5 units with the thumbnail. **(a) is chosen** (F11); (d) costs 2.5 × (a) for a
better score per frame and is the step up if a sheet proves to miss (Stage ladder).

## Decision
### D1. Poll model (`posts/{postId}.poll`, plan A1, F4)
- Stored on root posts only, in the CreatePost write (+0 writes):
  `poll {options: [label ...], durationMin, closesAt, counts: {"0": 0, "1": 0, ...}, total: 0}`.
  - `options`: 2 to `POLL_MAX_CHOICES` (4) labels, each 1 to `POLL_CHOICE_MAX_CODEPOINTS` (25) code points after the
    ADR-0010 D9 normalisation (NFC, no control or bidi formatting characters, trimmed), distinct after NFC + case
    folding. Mentions and hashtags in labels are **not** parsed: no notification, no hashtag entry.
  - `durationMin`: `POLL_MIN_DURATION` (5 min) to `POLL_MAX_DURATION` (7 days); the client default is 1 day.
  - `closesAt = createdAt + durationMin`, from the Snowflake `createdAt` drawn in the attempt (ADR-0010 D13), never
    from the client.
  - `counts` is a map keyed `"0".."3"` so a vote is `Increment("poll.counts.<i>")` plus `Increment("poll.total")`.
- Refused combinations, all VALIDATION `field=poll`, 0 writes: with media or a GIF, a reply, a quote, or empty text.
  SchedulePost has no poll field (F5).
- The question is the post text. Old app versions show a poll post as its text only; nothing else needs a server change.
- Validation lives in one `posts/poll.go`, mirrored by the client through the shared fixture
  `testdata/poll_rules.json`.

### D2. CreatePost order and `requestHash` (plan A8)
- `FEATURE_POLLS` is checked after `content_disclosure` in the ADR-0010 D2 order: a request with `poll` while `polls`
  is off for the caller is FAILED_PRECONDITION `FEATURE_DISABLED` `feature=polls`, 0 reads.
- `requestHash` (ADR-0021 pattern): when, and only when, a poll is present, append to the existing base, after `|ai=1`:
  `|poll=<n>:<hex SHA-256 of the normalised labels joined by U+001F>|dur=<minutes>`. A CreatePost without a poll
  hashes byte for byte as today, so retries across the deploy replay.

### D3. Viewer choice (`userLikes.pollVotes`, plan A3)
- `userLikes/{uid}.pollVotes`: strings `"<postId>:<index>"` (0-based), newest last. Written by the vote batch as a
  field-level `Set` + `MergeAll` `ArrayUnion` (0 reads; works when the user has no `userLikes` doc yet). Trimmed lazily
  to the newest `POLL_VIEWER_VOTES_KEPT` (500) on a later read, as `recent` is. The vote doc stays the one-vote
  authority. **Edge (more than 500 votes within one poll's life, at most 7 days):** a trimmed entry on a poll that is
  still open makes the feeds show it as not voted, so results are hidden again and the buttons return. Tapping any
  choice then recovers: the same choice is a replay, and another one answers `ALREADY_VOTED`, which the client
  follows with one `VotePoll` replay of `metadata["choice"]` (D6 steps 7 and 8). On a closed poll the trim only loses
  the check mark.
- `posts.ViewerSet` gains `PollChoice(p) (index int, voted bool)`, keyed by `viewerID(p)`, so a REPOST row resolves to
  the original. `HydrateViewer` keeps its shape: one cached `userLikes` read with `engagement` on.
- **`ViewerSet.BookmarksOnly()` drops the poll choices** (a viewer with only `bookmarks` on sees `viewer_poll_choice`
  0, like `liked_by_viewer`).

### D4. Results and redaction (plan A4, F3; ADR-0025)
In the posts converter (`ToView` with the `ViewerSet`), the only place that knows the rule:
- `closed = now ≥ closesAt` by server time.
- `results_visible = closed || viewer is the author || viewer voted || polls is globally off`.
- When not visible, every `PollChoice.votes` is 0 (hidden, so the bytes are the same whatever the real counts) and
  `total_votes` is the real total.
- `viewer_poll_choice` = index + 1 when the viewer voted, else 0.
- **ADR-0025 stripping:** a `withheld` row carries no `poll` and `viewer_poll_choice` 0; a PROTECTED embed carries no
  `embedded.poll`.
- Every PostView producer goes through the converter; a guard test names them: CreatePost, GetPost, GetThread, home
  and user timelines (every tab), ListBookmarks, ListLikedPosts, SearchPosts (ADR-0028) and the `VotePoll` response.

### D5. Repost and quote rows (plan A7)
`EmbeddedPost.poll` reuses the `Poll` message as a **frozen definition**: the labels and `closes_at`, with every count
0, `total_votes` 0 and `results_visible` false always, and `closed` computed by server time. Repost and quote rows
render the compact "Poll · N choices · ends ..." and open the original through GetPost for live counts. Hydrating the
original's live poll on these rows (+1 cached post read per row) is the later rung and changes no field.

### D6. `VotePoll` (engagement, plan A5, A6)
Order (each step's refusal writes nothing):
1. **Interceptors (0 Firestore reads beyond the account-status read):** the per-uid bucket `RATE_LIMIT_POLL_VOTE_PER_MIN`
   (30) and the `poll_votes_daily` `DailyCap` (`POLL_VOTES_PER_DAY` 300, `POLL_VOTES_PER_DAY_NEW_ACCOUNT` 50) run in the
   ratelimit interceptor before the handler, so a refused vote is also counted; `DEGRADED_MODE=readonly` refuses it
   (the RPC is not `NO_SIDE_EFFECTS`).
2. **Flags, 0 reads:** `engagement` on for the caller (as Like) and `polls` not globally off
   (`Registry.GloballyOff`, the ADR-0021 L-A pattern); else FEATURE_DISABLED `feature=engagement` or `polls`. A viewer
   outside a `polls` allowlist may therefore vote in an existing poll, and the viewer's choice is hydrated for exactly
   the callers who may vote.
3. **Shape, 0 reads:** `idempotency_key` format, verified identity, `choice_index` in 0..3; else VALIDATION.
4. **Target:** `posts.Engagement.Viewable` as Like (a REPOST id acts on its original; missing, deleted, hidden,
   protected for the caller, blocked either way or author not ACTIVE is the one NOT_FOUND "post not found").
5. **Poll checks on the (cached) post, server time:** no poll → VALIDATION `field=post_id`; caller is the author →
   VALIDATION `field=post_id`; `now ≥ closesAt` → FAILED_PRECONDITION `POLL_CLOSED`; `choice_index ≥ len(options)` →
   VALIDATION `field=choice_index`. These run after the visibility read, so a refusal tells nothing GetPost does not.
6. **One batch:** `Create pollVotes/{postId}_{uid}` `{postId, uid, choice, createdAt, expireAt}` with
   `expireAt = closesAt + POLL_VOTE_TTL_AFTER_CLOSE` (30 days); `posts.EngagementWriter.StagePollVote` (`Update` with
   an `Exists` precondition: `Increment(poll.counts.<i>)`, `Increment(poll.total)`); the `userLikes.pollVotes`
   `ArrayUnion` (D3). A post deleted in between fails the commit with NotFound: 0 writes, answered NOT_FOUND.
7. **AlreadyExists at commit** → read the vote doc (+1): the same choice is a replay (0 writes, the current view); a
   different choice is FAILED_PRECONDITION `ALREADY_VOTED` with `metadata["choice"]` = the stored 0-based index (the
   caller's own vote, never anyone else's).
8. **Response:** the original's PostView with the committed counts (the instance post cache is updated in place
   through a new `posts.Engagement` method, the `CountsChanged` pattern) and the like, repost and bookmark flags from
   the `userLikes` cache, which is updated in place with the new choice. **`viewer_poll_choice` and
   `results_visible` come from this call's vote (the new vote, or the vote doc read at step 7), never from
   `userLikes`**, so a replay shows the results even when the `userLikes` entry was trimmed (D3).
9. **Contention:** ABORTED, DEADLINE_EXCEEDED or "too much contention" on the commit after the store's bounded retry →
   UNAVAILABLE with `retry_after`, counted as `contention=true` on the `poll_vote` line (Stage ladder signal).

The race window is accepted and documented: the closed check reads `closesAt` (immutable) and the clock before the
batch, so a vote can commit a few hundred ms after `closesAt`.

### D7. Rule 4 (F2): bend of `CLAUDE.md` rule 4, as ADR-0018
`VotePoll` takes an `idempotency_key` and validates its format; **no `idempotency/*` doc is stored**. The natural key
`pollVotes/{postId}_{uid}` is the record: a replay with the same choice returns the current state with 0 writes, and a
different choice answers `ALREADY_VOTED`. Unlike ADR-0018's like/unlike pair there is no undo, so a late retry can never
re-create something the user removed. Saved: 0.3 writes and 0.3 TTL deletes per DAU per day (about INR 3 a month at
3,000 DAU). Founder decision 2026-10-27; this merge records it.

### D8. Lifecycle (plan W6-8, F6; ADR-0011)
- **Eraser step `poll_votes`** (engagement, `BeforeIdentity`, after `engagement`): `pollVotes where uid == X`, pages of
  ≤ 500, 1 read and 1 delete per doc, self-resuming. Counts are left as anonymous totals (F6).
- **Export section `poll_votes`:** `postId`, `choice`, `createdAt` per doc. The author's own **posts section gains
  `poll {choices, closesAt, counts, total}`** for poll posts (plain posts export byte for byte as before).
- **T11 row** `{Name: "pollVotes", Disposition: erasedByStep, Step: "poll_votes", Section: "poll_votes", Owner:
  "engagement", Cite: "ADR-0029"}`. `userLikes.pollVotes` goes with the existing `userLikes` row.
- **TTL** on `pollVotes.expireAt` (`closesAt + 30 d`): vote docs of other users on a deleted poll post hold no uid of
  its author and expire by TTL, so no residue outlives 37 days. The `post_delete` job does not touch `pollVotes`.
- **Moderation:** a hidden or taken-down post hides its poll with it (the converter never sees it). The POST report
  evidence gains `pollChoices[]` so the review shows them (follow-up for W6-5; `evidence` is already index-exempt).

### D9. Indexes and TTL (plan A9; gate files, founder review, follow-ups FU-1 and FU-2)
- `firebase/firestore.indexes.json` fieldOverrides, COLLECTION scope, `indexes: []`:
  `{"collectionGroup": "posts", "fieldPath": "poll", ...}` (counters churn; nothing queries them, and F1 A needs no
  `closesAt` index) and `{"collectionGroup": "userLikes", "fieldPath": "pollVotes", ...}` (an array of up to 500
  entries, like `recent`), each with its `firebase/field-overrides.ack` hash. **Both files are founder-gated.**
- `pollVotes`: the automatic `uid` index (eraser, export) and `postId` index (a repair recount with `count()` before the
  TTL). No composite index.
- TTL: Terraform `ttl_fields` entry `poll_votes_expire_at` (`collection = "pollVotes"`, `field = "expireAt"`) in
  `modules/firestore/variables.tf`, applied before `polls` leaves `off` in a project (otherwise vote docs simply stay).

### D10. GIF in media (plan A10, F10)
- `image/gif` is accepted for `MEDIA_PURPOSE_POST` only (AVATAR and BANNER refuse), extension `gif`, behind
  `FEATURE_GIF`: CreateUpload with `image/gif` while `gif` is off for the caller is FEATURE_DISABLED `feature=gif`,
  0 reads, before any Firestore access.
- **Exactly one item** in a CreateUpload that carries a GIF; full ≤ `MaxFullBytes` (2 MiB, so signed URLs do not
  change); declared logical screen ≤ `GIF_MAX_EDGE` (1,280) on each side.
- **`UploadItem.thumb_content_type = 8`.** Empty = the same as `content_type` (today's behaviour; an old client is
  unchanged). For `image/gif` it must be `image/jpeg` or `image/webp` (a still, ≤ 256 KiB), else VALIDATION
  `field=thumb_content_type`; for JPEG or WebP it must be empty or equal to `content_type`. Chosen over a fixed "a GIF's
  thumbnail is JPEG" rule because the client already encodes WebP (ADR-0005) and the field also serves the later MP4
  rung. The media doc stores `thumbContentType` (absent = `contentType`); FinalizeUpload checks the thumbnail's GCS
  type and magic bytes against it and publishes the thumbnail with it.
- `sniffImage` learns `GIF87a` / `GIF89a`.
- **`MediaRef.content_type = 8`** (common.proto) tells a client what the full object is, so it can badge and play a
  GIF without parsing the URL. CreatePost copies it into `posts.media[].contentType` from `LoadForPost`'s claim (the
  content-type table stays inside `media`; posts only copies the string), and `snapshotOf` copies it into embeds.
  Empty on refs stored before W6 = a still JPEG or WebP image. It is also the seam for a short-video rung (Stage ladder).
- **Gates in posts:** CreatePost refuses a GIF media doc while `gif` is not enabled for the caller (FEATURE_DISABLED
  `feature=gif`). The content type is known only from `LoadForPost`'s claim inside the transaction, so this refusal
  costs the ≤ 4 media reads an unready-media refusal costs today, and 0 writes. **This second gate is kept**: the
  rollback trigger "a GIF moderation bypass is reported" needs the kill switch to stop new GIF posts too, not only new
  uploads (a GIF uploaded before the switch would otherwise still post). A GIF must be the only media item, else
  VALIDATION `field=media_ids`; SchedulePost refuses GIF media with VALIDATION `field=media_ids` (F10).
- Purge and export of media cover the `gif` extension; the M-2 name suffix applies.

### D11. GIF screening (F11 a, plan W6-10)
In FinalizeUpload, for a GIF item, after the existing attrs, MD5 and magic-byte checks:
1. **Read the full object** from the private upload bucket (≤ 2 MiB, 1 Class B).
2. **Pre-scan** the header and frame descriptors without decoding pixels, and refuse (REJECTED "This GIF is too large
   or too long", objects deleted, 0 units) above `GIF_MAX_FRAMES` (300), a logical screen above `GIF_MAX_EDGE` (1,280)
   on either side, a frame outside the logical screen, or Σ frame areas above `GIF_MAX_FRAME_AREA_SUM` (50,000,000
   pixels). Anything the pre-scan cannot parse is REJECTED.
3. **Decode under guards:** a per-instance semaphore of 1 (a waiter that cannot start within 5 s answers
   `MEDIA_NOT_READY`, retryable, and releases its screening claim with no Vision spend), a 2 s decode deadline, a
   recover that turns a decoder panic into REJECTED plus an Error Reporting entry. Prefer a streaming decode that keeps
   at most 2 canvases; `gif.DecodeAll` is acceptable only after the pre-scan (paletted frames at 1 byte per pixel, so
   ≤ 50 MB peak, one at a time per instance).
4. **Sample 4 points of the display time** T (Σ frame delays, a 0 delay counted as 10 ms): the frame visible at
   t = 0, T/4, T/2 and 3T/4, composited onto the logical screen with the GIF disposal rules. A GIF with fewer frames
   samples each frame once.
5. **Tile** them 2 × 2, each scaled to fit 640 × 480 (Google's SafeSearch recommendation), into one JPEG (q 85) of up to
   1,280 × 960, typically 100 to 400 KB, far under the 10 MB request cap.
6. **Screen:** the sheet by bytes (`Image.Content`) and the thumbnail by URI, as today. The worse verdict wins. The
   Vision counter counts 2 units (1 with `VISION_SCREEN_THUMB=false`, sheet only).
7. **Seam:** `media.Moderator` gains `SafeSearchBytes(ctx, image []byte) (SafeSearch, error)`; the existing URI
   method is unchanged. Rejected alternative: write the sheet to the upload bucket and keep the URI-only signature
   (+1 Class A and +1 delete per GIF, and a server-written object). The sampler is a pure function
   (`[]byte` → sheet), so it can move to a separate job unchanged.
8. **At the cap:** REJECTED for every account (F11 point 4).

The original bytes are published unchanged (no server re-encode). A GIF comment extension can carry text; browsers do
not render it, and stripping it would mean rewriting the object on the server. Left to W6-20.

### D12. Flags (F12), ceilings, rollout
| Flag (wire) | Gates | `off` (kill switch) |
|---|---|---|
| `FEATURE_POLLS` (`polls`) | creating a poll (per caller, D2); voting needs `engagement` per caller and `polls` not globally off (D6) | no new polls, `VotePoll` refused, existing polls show their results to everyone |
| `FEATURE_DRAFTS` (`drafts`) | client only (no RPC guard): the Drafts button, "Save post?" Save, the Unsent tab, autosave; registered in config, `flags.NewRegistry` and Terraform so `GetMe` reports it (as `ui_shell`) | drafts UI hidden, the old leave prompt returns; rows on devices are kept |
| `FEATURE_GIF` (`gif`) | CreateUpload with `image/gif` (0 reads) and CreatePost with a GIF media doc (D10) | no new GIF uploads or GIF posts; existing GIF posts keep rendering |

- **Ceilings** (`scripts/promotion/flag-ceiling.json`, founder-gated, W6-4): `POLLS`, `DRAFTS`, `GIF` with dev
  `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}`, no prod raise.
- **Ramp order:** `polls` never ahead of `engagement`; `gif` never ahead of `media`; `drafts` needs `posts` only.
- **100 % rule (ADR-0021 L-1):** `polls` and `gif` leave `off`, even for an allowlist, only once 100 % of traffic is
  on a revision that stores and enforces them; otherwise an old revision drops `CreatePostRequest.poll` (proto3 unknown
  field) and posts the text alone. The client sends `poll` only when `enabled_features` lists `polls`, and after
  CreatePost runs the **echo check**: no `post.poll` in the response → "Your poll was not added", with delete and
  repost.
- **Roll forward only** once `polls` has left `off`: a revision without the converter's redaction would show hidden
  counts.

### D13. Contract (W6-2, W6-3; additive, `buf breaking` clean)
| File | Added | Number |
|---|---|---|
| `posts/v1/posts.proto` | `message PollChoice {label = 1; votes = 2}` | new |
| | `message Poll {choices = 1; closes_at = 2; total_votes = 3; results_visible = 4; closed = 5}` | new |
| | `message PollDraft {choices = 1; duration_minutes = 2}` | new |
| | `CreatePostRequest.poll` (PollDraft) | **10** |
| | `Post.poll` (Poll) | **21** |
| | `EmbeddedPost.poll` (Poll, frozen definition, D5) | **10** |
| | `PostView.viewer_poll_choice` (int32: 0 = none, 1..4 = index + 1) | **8** (7 is `withheld`) |
| `engagement/v1/engagement.proto` | `rpc VotePoll(VotePollRequest) returns (VotePollResponse)`; `VotePollRequest {idempotency_key = 1; post_id = 2; choice_index = 3}`; `VotePollResponse {posts.v1.PostView post = 1}` | new |
| `common/v1/common.proto` | `ERROR_REASON_POLL_CLOSED` | **19** |
| | `ERROR_REASON_ALREADY_VOTED` | **20** |
| | `MediaRef.content_type` | **8** |
| `media/v1/media.proto` | `UploadItem.thumb_content_type` | **8** |

No field is reused or renumbered. `SchedulePostRequest` is unchanged (F5). Generated code is W6-4 (`make proto`).

## Cost impact
- **Fixed monthly cost added: INR 0.** No new GCP service, Scheduler job (F1 A), topic or composite index. Two
  fieldOverrides (index exemptions, free) and one TTL policy (TTL deletes are billed per use). Nothing depends on
  ADR-0022.
- **Storage:** GIF objects about 0.63 MB per DAU-month (190 MB a month at 300 DAU); `pollVotes` about 200 bytes per
  doc with a TTL; drafts 0 server bytes.

**Per RPC** (worst reads include the account-status interceptor; every call is charged to the ADR-0010 D5 per-uid
budget, far under `ReadBudgetMaxCallReads` 269):
| RPC | Reads worst (cold) | Reads typical | Writes | Deletes | Notes |
|---|---|---|---|---|---|
| CreatePost, root with a poll | +0 (14) | +0 (2.5 planning) | +0 (4) | +0 | the poll is fields on the post doc |
| `VotePoll`, a new vote | **8**: interceptor 1, post 1, author `users` 1, caller graph 1, +2 for a REPOST id, +1 on `blockedBy` overflow, `userLikes` 1 for the response's viewer flags | 3 (planning; AddBookmark measured 3.06 for this shape) | 3 (vote doc, post counters, `userLikes.pollVotes`) | +1 TTL at `closesAt` + 30 d | one batch, no read in it |
| `VotePoll` replay / ALREADY_VOTED | 9 (+1 vote doc) | 4 | 0 | 0 | |
| `VotePoll` refused (POLL_CLOSED, author, no poll, choice range) | ≤ 7 | 2 | 0 | 0 | after the visibility read |
| `VotePoll` refused by flag, shape, bucket or cap | 1 (interceptor) | 0–1 | 0 | 0 | |
| Viewer choice and redaction on every PostView producer (D4) | **+0** (the `userLikes` read they already make with `engagement` on) | 0 | 0 | 0 | |
| GetPost of a closed poll with hidden counts (client, once per cached row) | 4 (as GetPost) | 1 | 0 | 0 | |
| CreateUpload with a GIF | unchanged: 2 | 1 | 6 / 3 | 1 (idempotency TTL) | |
| FinalizeUpload with a GIF | unchanged Firestore: 2n + 1 + interceptor | as today | as today | 0 | + 1 Class B full read (≤ 2 MiB), ≤ 0.5 s CPU, **2 Vision units** |
| CreatePost refused for a GIF with `gif` off | ≤ 4 media reads in the txn + the reads before | — | 0 | 0 | D10 second gate |
| Eraser step `poll_votes` | 1 per doc, min 1 | | 0 | 1 per doc | pages ≤ 500 |
| Export section `poll_votes` | 1 per doc, min 1 | | 0 | 0 | |
| Drafts | 0 | 0 | 0 | 0 | client only |

**Per DAU per day** (the plan's assumptions; W6-21 replaces them): `VotePoll` 0.3 × 3 = 0.9 reads, 0.9 writes, 0.3 TTL
deletes later; GetPost of a closed poll 0.1 × 1; GIF upload 0.02 GIFs (CreateUpload + FinalizeUpload) ≈ 0.05 reads,
0.12 writes, 0.02 deletes, 0.04 Class A × 2; GIF plays 0.3 a day at about 1 MB from GCS. **Total ≈ 1.05 reads, 1.02
writes, 0.32 deletes, 0.44 Cloud Run requests, 1.22 Vision units and 9.1 MB of GCS egress per DAU-month** (0.3 plays
× 1 MB × 30.42), plus about 0.8 KB of API egress a day.

**INR per month (W6 increment; Mumbai prices of `cost-model.md` §7, INR 95 per USD, 0.1 s of vCPU per request, Vision
cap 10,000):**
| Line | 300 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|
| Firestore reads (all billed: the product is past the free reads at about 140 DAU) | 0.3 | 1.1 | 3.2 |
| Firestore writes (billed once the product passes the free writes, now about 493 DAU) and deletes | 0 | 3.1 | 9.5 |
| Vision (GIFs: 1.22 units per DAU-month; the product passes the free 1,000 at about 73 DAU and the cap at about 730) | **52** (366 units) | 0 (the cap is already reached; GIFs bring it forward) | 0 (cap) |
| GCS egress (9.1 MB per DAU-month; the product passes the free 100 GB at about 1,742 DAU) + Class A/B | 0.5 | 1.5 | **315** (27 GB ≈ 311 + ops 4.5) |
| Cloud Run requests (+13.4 per DAU-month) and vCPU-s (+1.64 per DAU-month incl. GIF decode) | 0 | 0 | 13 |
| Egress to India, API JSON | 0 | 0.3 | 0.8 |
| **W6 total** | **≈ 53** | **≈ 6** | **≈ 342** |
| Polls alone | ≈ 0.3 | ≈ 4 | ≈ 22 |
| Upper bound: autoplay in feeds (F10) | ≈ 53 | ≈ 6 | ≈ 1,690 |
| **Stage 0 bill with W2, W3 A+B, W7, W4 and W6** | 494 → **≈ 547** | 1,805 → **≈ 1,811** | 4,480 → **≈ 4,822** |

**Free quotas that move** (whole product with W6 on for every DAU):
| Quota | Runs out at (was) | W6 increment at 2× that DAU | at 10× |
|---|---|---|---|
| Firestore reads 50k/day (358.65 per DAU) | ≈ 139 DAU (140) | 278 DAU: INR 0.3 | 1,390 DAU: INR 1.5 |
| Firestore writes 20k/day (40.58 per DAU) | ≈ 493 DAU (506) | 986 DAU: INR 3.0 | 4,930 DAU: INR 15 |
| Vision free 1,000 units (13.69 per DAU-month) | ≈ 73 DAU (80) | 146 DAU: INR 25 | 730 DAU: INR 127 (the 10,000 cap) |
| Vision cap 10,000 | ≈ 730 DAU (802) | — (capped) | — |
| GCS egress 100 GB (57.4 MB per DAU-month) | ≈ 1,742 DAU (2,069) | 3,484 DAU: INR 362 | 17,420 DAU: INR 1,808 |
| Cloud Run requests 2M (1,759 per DAU-month) | ≈ 1,137 DAU (1,145) | 2,274 DAU: INR 1.2 | 11,370 DAU: INR 5.8 |
| Cloud Run vCPU-s 180k (176.2 per DAU-month) | ≈ 1,021 DAU (1,031) | 2,042 DAU: INR 7.6 | 10,210 DAU: INR 38 |

- **Credit window (ADR-0022, Vision cap 20,000 with `reject` until 2026-12-22):** at 1,000 DAU the GIFs' 1,220 units
  a month are paid (about INR 174, credit-funded) instead of being squeezed out by the cap. Nothing here needs a
  credit-mode item after 2026-12-22.
- **Abuse as cost:** `VotePoll` 30/min per instance (90/min with 3 instances) and ≤ 300 a day per instance (≤ 900 a
  day) per account; one account's writes are further bounded by 3 × the open polls it can see (D6, Option D). At the
  cap: ≤ 2,700 writes a day (INR 0.27). GIF uploads stay inside the media quota (20 a day, 5 for new accounts) and the
  CreateUpload bucket; one GIF at the cap costs 2 Vision units, like a photo. Poll creation is inside the posts quota.
- **Trigger that justifies it:** none (no fixed cost). The scale-up triggers are in the Stage ladder.

## Stage ladder
| Concern | Stage 0 (this ADR) | Seam to protect now | Stage 2/3 target (ADR) | Trigger (measured, 7 days sustained) |
|---|---|---|---|---|
| Poll counters | `Increment` on `posts/{id}.poll.counts.<i>` and `poll.total` in the blind vote batch (rule 3) | `posts.EngagementWriter.StagePollVote` (the one counter helper); `contention` on the `poll_vote` line | sharded `posts/{id}/pollShards/{n}` summed on read, or Pub/Sub-batched increments; the vote docs allow a `count()` repair | sustained contention on one poll post, or > 1 vote a second on one poll for 5 minutes. Traffic shape, not DAU: a viral poll breaks rule 3 at tiny DAU |
| Poll closing | read-time `now ≥ closesAt` | `Poll.closes_at` and `closed` on the wire; the client never decides "closed" for the server | a closing event (Cloud Tasks or a sweep) feeding "poll ended" notifications through `notifications.Emitter` | tracked user requests for poll-ended notifications, or polls > 5 % of posts |
| Vote ids | `pollVotes/{postId}_{uid}`: one poll's votes share a key prefix, so a viral poll writes one narrow key range | ids are server-side only; nothing on the wire names a vote doc | hash-prefixed ids (`{hash8(postId)}_{postId}_{uid}`) with the sharded counters, one migration | the counter trigger above fires first (≈ 1 write/s per post); the 500/50/5 range limit needs ≈ 500 votes/s |
| Drafts | drift table on the device, per uid | `DraftsRepository` (the only reader and writer); the draft is composer state, not a proto | synced `users/{uid}/drafts/{id}` with an eraser and export (its own ADR) | > 20 % of weekly posters use drafts **and** > 25 cross-device sync requests in a month |
| GIFs | device upload through the photo pipeline, frame-sampled sheet, static thumbnail, tap to play | `media` content-type table, `Moderator` (URI and bytes), `MediaRef.content_type`, the client `GifSource` | (1) a provider picker (F9) behind `FEATURE_GIF_SEARCH`; (2) client conversion to MP4 or animated WebP (a short-video ADR; Transcoder stays on the not-used list); (3) four frames as four images (Option E d) | (1) the founder's written terms check; (2) GIF bytes > 25 % of GCS egress, or a median GIF > 1 MiB; (3) one confirmed sheet miss |

IDs and hot docs: no new collection approaches 500 writes/s at Stage 0; `posts` writes are unchanged.

## Proposed follow-ups (gate files and `.claude/` are not edited in this PR)
- **FU-1 (W6-4 or W6-22, founder-gated):** the two fieldOverrides of D9 in `firebase/firestore.indexes.json` with their
  `firebase/field-overrides.ack` hashes.
- **FU-2 (W6-4):** Terraform `ttl_fields` `poll_votes_expire_at`; `feature_polls*`, `feature_drafts*`, `feature_gif*`
  and the config vars, default `off`; the three `flag-ceiling.json` entries (founder-gated).
- **FU-3 `stage-ladder` skill:** add a "Composer extras (W6)" section with the five rows above.
- **FU-4 `firestore-data-model` skill:**
  - `posts` row: `poll {options, durationMin, closesAt, counts, total}` (root posts only, index-exempt);
    `media[].contentType` and `embedded.media[].contentType`; `embedded.poll {options, closesAt}`.
  - New row `pollVotes/{postId}_{uid}` [engagement, ADR-0029]: `postId, uid, choice, createdAt, expireAt`; written
    by `VotePoll` (`Create` in the vote batch; AlreadyExists = replay); erased by the `poll_votes` step, exported in
    the `poll_votes` section, TTL `expireAt`.
  - `userLikes` row: `pollVotes[]` (newest 500, `"<postId>:<index>"`, index-exempt).
  - `media` row: `thumbContentType` (absent = `contentType`). `reports.evidence.pollChoices[]`.
  - Operation rows: the Per RPC table above.
- **FU-5 `media-pipeline` skill:** `image/gif` for POST media, `thumb_content_type`, the D11 sampler and its guards.
- **FU-6 `docs/reviews/cost-model.md` (sre-performance, W6-21):** the W6 rows and the moved crossovers above.

## Observability
- `poll_vote` line: `outcome` (voted / replay / already_voted / closed / author / no_poll / not_found / contention),
  `uid_hash`, `fs_reads`, `fs_writes`, `contention`. **Never the choice**; logs never pair a uid with a choice.
- `gif_screen` line: `frames`, `sampled`, `units`, `decode_ms`, `sheet_bytes`, `refused_reason`.
- CreatePost: `has_poll`; media lines gain `content_type`. Error Reporting on internal errors and recovered decoder
  panics. No new log-based metric or alert policy.

## Consequences
**Positive.** Polls cost almost nothing (INR 0.3 / 4 / 22 a month) and add 0 reads to every feed. Drafts cost nothing
on the server. GIFs reuse the photo pipeline and move at 2 Vision units each, the same as a photo. Every Stage 2 move
(sharded counters, poll-ended events, synced drafts, a GIF provider, MP4) is a swap behind a named seam with a measured
trigger.

**Negative.** GIFs are the cost line (Vision at low DAU, egress at high DAU) and bring the Vision cap forward from about
802 to about 730 DAU. GIF moderation is sampled, not exhaustive (F11). The API now reads whole uploaded GIFs (F11
point 1). Votes and likes share one post doc's rule-3 budget. Drafts sit unencrypted on shared devices (F7). A vote
from a stale view gets ALREADY_VOTED, and the client then refreshes.

**Revisit when** a stage-ladder trigger fires; W6-21 measures reads per call more than 25 % off this table; a GIF
moderation bypass is reported; or the founder answers an F differently.

## Handoff
- **architect:** W6-2 and W6-3 in this PR. FU-3 to FU-5 in a `.claude/` PR the founder approves. W6-23 only if F9 unlocks.
- **backend-developer:** W6-4 (`make proto`, flags, config, ceilings, Terraform, FU-1 and FU-2); W6-5 (D1, D2, D5, D8
  export and evidence); W6-6 (D3, D4 and the guard test); W6-7 + W6-8 in one PR (D6, D7, D8); W6-9 (D10); W6-10 (D11).
  Seams: `posts.EngagementWriter.StagePollVote`, `posts.ViewerSet.PollChoice`, a `posts.Engagement` method that
  applies poll deltas to the instance copy, `engagement.Service.VotePoll`, `media.Moderator.SafeSearchBytes`.
- **frontend-developer:** W6-11 to W6-16. Badge and play a GIF from `MediaRef.content_type == "image/gif"`, never from
  the URL (the `MediaRef` in FinalizeUpload's result carries it too, so the attachment tile can badge before posting).
  Send `poll` only when `enabled_features` lists `polls`; run the echo check. Never render a poll's bars when
  `results_visible` is false, and never render bars for `EmbeddedPost.poll`. On `ALREADY_VOTED`, call `VotePoll` once
  more with `metadata["choice"]` (a replay, 0 writes) and render its response.
- **tester:** W6-17 to W6-19: the D6 order and refusal matrix, D4 byte identity of hidden counts, D4 stripping
  (`withheld`, PROTECTED, `BookmarksOnly`), concurrency (50 voters; one voter × 10 mixed), D11 pre-scan bombs and the
  sampled verdict, budgets above.
- **security-auditor:** W6-20: vote integrity and the in-memory cap argument (Option D), result oracle, logs, D11
  guards and polyglots, the comment extension, the F11 residual, drafts on shared devices.
- **sre-performance:** W6-21: the W6 rows and crossovers above (FU-6); a k6 `poll_vote` hot-poll scenario (50 votes/s
  on one poll, recording contention); GIF finalize CPU and memory on 10 fixtures.
- **production-deployer:** W6-22: a targeted dev plan (flags, config, TTL), the fieldOverrides deploy, allowlist 3,
  the smoke (vote race on real `OPTIMISTIC` dev Firestore, as #292; a few known-bad GIF fixtures). Prod: nothing until
  the held release (ADR-0019), and FU-1 and the TTL must be live before `polls` leaves `off` there.

## As-built notes, 2026-11-01: GIF screening (W6-10) and polls (W6-5, W6-6, W6-7)

These notes record where the merged or merging code differs from the text above. They are notes only: the decision text
stays as the record, F1 to F12 are unchanged, and no status changes. Sources:
- W6-10: PR #505, merged.
- W6-5 and W6-6: PRs #497 and #504, merged.
- W6-7 + W6-8: PR #515 (`feat/ui-w6-7-vote-poll`, head `b682cf34`), open when written. Its part of these notes holds
  once it merges.

Numbers marked **corrected** replace the figure in the section named.

### N1. GIF screening as built (W6-10, #505)

**Vision units: always 2 (deviates from D11 point 6).**
- A GIF costs 2 units, the sheet by bytes plus the thumbnail by URI, even with `VISION_SCREEN_THUMB=false`. D11 point 6
  said 1 unit (sheet only) in that case. **Corrected.**
- Reason: the thumbnail is a separate client upload. Lists show it, and nothing ties it to the GIF's frames, so it is
  always screened, as a BANNER's is (`screensThumb`).
- No cost table moves: dev and prod Terraform both set `VISION_SCREEN_THUMB=true`, and the Cost impact already counts
  2 units per GIF (the 1.22 units per DAU-month line).

**Guards as built (D11 points 1 to 3).**
- **Re-check after the read.** After reading the whole object (1 Class B), the API compares its length and MD5 with
  what verify approved. A mismatch is REJECTED (`changed_after_verify`), so the bytes sampled are the bytes verified.
  This is not in D11 point 1.
- **One GIF slot per instance.** A capacity-1 semaphore is held from the object read until the sheet is encoded.
  - A second GIF on the same instance waits up to **5 s**, then gets the retryable `MEDIA_NOT_READY` ("this GIF is
    being checked"). Its screening claim is released and the reserved units are returned, so nothing is spent.
  - Effective limit: one GIF screened at a time per instance, so 3 at once service-wide at max-instances 3.
- **Decode deadline: 2 s.** A GIF that cannot be sampled in time is REJECTED as "too large or too long"
  (`refused_reason=deadline`), with 0 units.
- **Memory, corrected.** D11 point 3 allowed `gif.DecodeAll` after the pre-scan, at "≤ 50 MB peak". As built, frames
  are decoded **one at a time** (each cut out as a one-frame GIF), never with `DecodeAll`.
  - Live working set at the limits: about **26 MiB**, whatever the frame count: the file 2 MiB, two 1,280 × 1,280 RGBA
    canvases 12.5 MiB, one decoded frame ≤ 1.6 MiB, four tiles 4.7 MiB, the sheet 4.7 MiB and its JPEG < 0.5 MiB.
  - Allocation churn per worst-case GIF: about 51 MiB `TotalAlloc`.
  - A request past the slot holds under 2 MiB while Vision runs.
  - A refused bomb never allocates beyond the frame list; the pre-scan test asserts under 20 MB.
- **Panics.** A decoder panic is recovered: the GIF is REJECTED (invalid) and Error Reporting gets `media/gif_screen`.

**FinalizeUpload CPU per GIF, corrected.**
- The Per RPC row's "≤ 0.5 s CPU" becomes: typically under 0.2 s; at the area cap (about 22 sampled 1,280 × 1,280
  frames) 0.65 s steady and 1.25 s measured once under load.
- These figures were measured on a laptop core, not on a Cloud Run vCPU.
- Cost effect: the vCPU line barely moves. Even at 1.25 s for every GIF it is +0.46 vCPU-s per DAU-month on the
  176.2 of the free-quota table, under 0.3 %. No INR row changes.

**Request deadline, corrected.**
- #505 put the worst case at about 22 s "under the 30 s Cloud Run request timeout": 5 s slot wait, 5 s object read, 2 s
  decode and 10 s for the two parallel Vision calls, plus the attrs, heads and copies.
- The binding limit is the media handler's own **`finalizeDeadline` of 20 s** (`internal/media/server.go`), not the
  30 s Cloud Run timeout. So the worst case cannot finish.
- What happens past 20 s, usually during the Vision calls:
  - the request fails retryable (UNAVAILABLE, or DEADLINE_EXCEEDED);
  - the deferred release frees the screening claim;
  - the Vision counter returns the 2 reserved units, even if Vision already billed the call. The counter can therefore
    run up to 2 units per such event under the real spend.
- The 30 s `screeningClaimTTL` is not reached.
- Typical finalizes (no slot wait, a read under 1 s, Vision in 1 to 2 s) are far inside 20 s. Raising the deadline or
  shortening the slot wait is listed for the founder below.

**Residual risks the developer named (not closed by #505).**
- **Publish swap (for W6-20).** The signed PUT pins no object generation (`if-generation-match`), and `Publish` copies
  whatever object exists at copy time.
  - The MD5 re-check closes a swap between verify and the read.
  - It does not close a swap after screening. GIF comment and application blocks make identical-prefix MD5 collision
    pairs cheap, so a client still holding a valid signed URL (10 min) could re-PUT an explicit twin after screening.
  - Fix: record the generation at verify and pass it as the precondition of the copy. This is pre-existing for photos;
    GIFs make it easier. It is a W6-20 security item, not a decision of this ADR.
- **Near-cap GIFs and the 2 s deadline.** A legitimate GIF near `GIF_MAX_FRAME_AREA_SUM` (50,000,000 pixels) may miss
  the 2 s decode deadline on a Cloud Run vCPU and be REJECTED as too large.
  - The runbook signal is many `gif_screen` lines with `refused_reason=deadline` (`docs/runbooks/media.md`, "GIFs").
  - Whether to lower the default is a config decision (rule 11), listed for the founder below.
- **Cancellation during sampling: a misleading log, not a lost GIF (checked while writing this note).** The sampler
  treats any end of its context as the decode deadline.
  - Nothing is lost when a client hangs up mid-sampling, or the 20 s handler deadline fires there. `reject` resolves
    the document on the same request context, so that write fails. The objects are deleted only after a successful
    resolve, and the deferred release frees the claim on a detached context. The document stays PENDING and the retry
    screens it again.
  - The only effect is that the request's `gif_screen` line says `refused_reason=deadline` although nothing was
    rejected. When reading the near-cap signal below, count only lines whose request did end REJECTED.
  - Fix, optional: tell the parent context's end apart from the 2 s deadline in the sampler (W6-18).

### N2. Polls as built (W6-5 #497, W6-6 #504, W6-7 #515)

**Stored shape (D1, D5): as written.**
- `posts/{id}.poll` = `{options: [string], durationMin: int, closesAt: timestamp, counts: {"0".."n-1": int}, total: int}`.
  It is absent on posts without a poll and built per transaction attempt from that attempt's Snowflake `createdAt`.
- A vote increments `firestore.FieldPath{"poll", "counts", "<i>"}` and `{"poll", "total"}`, not a dotted string,
  because the map keys are numeric strings.
- `embedded.poll` = `{options, closesAt}` (the frozen definition), copied by `snapshotOf`.
- One addition: the existing quote-tombstone writer replaces the whole `embedded` map, so a tombstoned quote loses
  `embedded.poll` along with the rest of the embed.
- The POST report evidence carries `pollChoices` (labels only). The author's export posts section carries
  `poll {choices, closesAt, counts, total}`.

**Wire values (D4, D13): as written.** Easy to get wrong in a client:
- `viewer_poll_choice` = index **+ 1** (0 = not voted). `ALREADY_VOTED` carries `metadata["choice"]` as the **0-based**
  index, and the follow-up `VotePoll` replay sends that 0-based index.
- When results are hidden, every `PollChoice.votes` is sent as **0** with `results_visible = false`, and `total_votes`
  is the real total. The bytes are therefore the same whatever the hidden counts.
- `results_visible = closed || polls globally off || viewer voted || viewer is the author`. `closed` uses server time
  through the `ToViewAt` clock seam.
- `EmbeddedPost.poll` always has counts 0, `total_votes` 0 and `results_visible` false.

**VotePoll order (D6), as built in #515.**
- **Flag gate.** It also requires `FEATURE_POSTS` first (the posts guard), then `engagement` on for the caller, then
  `polls` not globally off. Still 0 reads.
- **New-account cap moved.** D6 step 1 put both daily caps in the ratelimit interceptor. The interceptor has no
  account-age signal, so `POLL_VOTES_PER_DAY_NEW_ACCOUNT` (50) is enforced **in the service**.
  - Where: after the shape check and the verified-email gate (`authn.RequireVerifiedEmail`), before the target read.
  - How: it compares the interceptor's own `poll_votes_daily` counter (`DailyCap.Spent`, the same instance, wired in
    `apiserver.build`) with the lower limit.
  - Read cost: +0. The caller's profile comes cache-first from the identity cache that the account-status interceptor
    filled for this request.
  - The refusal is byte-shaped like the interceptor's own (RESOURCE_EXHAUSTED, RATE_LIMITED, `limit=poll_votes_daily`,
    `retry_after` to IST midnight), so a client cannot tell which cap refused.
  - Semantics: the counter is **per instance and in memory**. It resets when an instance restarts, and the effective
    limit is 50 × max-instances, so ≤ 150 a day for a new account and ≤ 900 for others at 3 instances.
  - The interceptor counts every call before the handler runs, so replays and refusals count towards both caps.
  - This is the Option D argument unchanged: the natural key still allows one vote per account per poll.
- **The vote batch** is `store.CommitWithRetry` with at most 4 attempts, on a context that survives the caller leaving
  and is bounded by the repo's transaction timeout.
  - Exhausted contention, or that timeout, is UNAVAILABLE with `retry_after` and `contention=true`.
  - A precondition failure (the post was deleted) is NOT_FOUND with 0 writes.
  - AlreadyExists followed by a vote doc that is already gone is UNAVAILABLE (retry).
- **The response's viewer flags.** If the `userLikes` read fails, the response is built without the like, repost and
  bookmark flags (logged `engagement_poll_vote_viewer_degraded`). A committed vote never fails for that reason.
  `viewer_poll_choice` and `results_visible` come from this call's vote, as D6 step 8 says.
- **When a replay meets a closed poll.** After `closesAt`, even a replay of the caller's own vote answers
  `POLL_CLOSED`, because the closed check (step 5) runs before the batch.

**Trim of `userLikes.pollVotes` (D3), corrected.**
- D3 says the list is "trimmed lazily ... on a later read". As built, the read side never trims.
- After a **committed** vote, if the cached list holds more than `POLL_VIEWER_VOTES_KEPT` + 100 (600) entries, one
  field-level `ArrayRemove` drops the oldest down to 500. This is the `TrimLikes` pattern: best effort, 0 reads.
- So VotePoll writes are **3, plus 1 trim write about once per 100 votes** for an account past 600 entries. At the
  modelled 0.3 votes per DAU per day this is effectively 0, and no cost row moves.

**Eraser step position (D8), corrected.**
- D8 says `poll_votes` runs "`BeforeIdentity`, after `engagement`". As built, it is **appended after `messaging`**,
  before `identity`.
- Reason: step names are persisted in `deletionJob.step`, so a step is never inserted mid-sequence (ADR-0011 Q1).
- It still runs after `engagement`, which has already deleted `userLikes`.
- A deletion job already past that position when the step deployed skips it. That job's vote docs expire by TTL within
  `closesAt` + 30 d, so at most 37 days. Prod polls are off, so this case has no prod data today.

**Budgets: the ceilings stand.** These are the request-line `fs_reads` / `fs_writes` that #515's chain test asserts.
`budgettest.Assert` checks "at most", so the tests prove the ceilings, not the measured values.

| Case | Reads ceiling (asserted) | Reads measured (developer's run, partly warm caches) | Writes |
|---|---|---|---|
| New vote | 8 | 3 | 3 (asserted exactly) |
| Replay, ALREADY_VOTED | 9 | 1 | 0 |
| Refused at step 5 (closed, author, no poll, choice range) | 7 | 3 | 0 |
| Refused by a flag | 1 | 0 | 0 |

- The developer's figures are right against the code. The 8-read ceiling is: the interceptor 1, the post 1, the
  author's `users` 1, the caller's graph 1, +2 for a REPOST id, +1 on `blockedBy` overflow, and `userLikes` 1 for the
  response. The new-account cap adds 0 (above).
- "Replay 1 read" is a warm measurement (only the vote doc is read). It is not a budget: the worst case is 9, as in the
  Cost impact table.
- The planning column (3 / 4 / 2) is unchanged until W6-21 measures it.
- The plan ticket's older "6 worst new, 7 replay" predates this ADR and is superseded by the Cost impact table.

### N3. Not edited here
- The `media-pipeline` skill still says "GIF: static first frame at Stage 0". FU-5 (a `.claude/` change the founder
  approves) is still owed and should describe N1.
- `docs/reviews/cost-model.md` (FU-6, W6-21) belongs to sre-performance. N1 and N2 add no cost row, and the CPU
  correction is under 0.3 % of the vCPU line.

### N4. For the founder (decided 2026-11-01)
- `GIF_MAX_FRAME_AREA_SUM`: keep 50,000,000 or lower it, so near-cap GIFs are not REJECTED by the 2 s decode deadline
  on a Cloud Run vCPU. Measure `refused_reason=deadline` in the W6-22 dev smoke first.
- The GIF worst case (about 22 s) against FinalizeUpload's 20 s `finalizeDeadline`. Options:
  - raise the deadline for a GIF finalize (it must stay under the 30 s Cloud Run timeout and the 30 s screening claim);
  - shorten `GifQueueWait` from 5 s;
  - accept a rare retryable failure, with the Vision counter running up to 2 units under the real spend each time.
- FU-5: the `media-pipeline` skill edit.

**Founder decisions (2026-11-01):**
1. `GIF_MAX_FRAME_AREA_SUM` stays 50,000,000 for now. The W6-22 dev smoke measures `refused_reason=deadline` on `gif_screen` lines; a non-zero share of legitimate GIFs refused by the deadline reopens this.
2. The about 22 s worst case against the 20 s `finalizeDeadline`: accept the rare retryable failure for now (no code change), and measure it in the same W6-22 smoke (a FinalizeUpload of a GIF ending DEADLINE_EXCEEDED or MEDIA_NOT_READY after the slot wait). If it shows up, the first lever is raising the deadline for a GIF finalize, kept under the 30 s Cloud Run timeout and the 30 s screening claim.
3. FU-5: the `media-pipeline` skill now describes sampled-frame GIF screening (this PR).

**Cost impact of these notes.** Fixed cost INR 0. No INR row of the Cost impact section changes.
