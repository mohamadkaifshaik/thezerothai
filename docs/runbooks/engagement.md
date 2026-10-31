# Runbook: engagement failure modes (likes, reposts, quotes, post_delete job)

Owner module: `backend/internal/engagement` (ADR-0018, plan `docs/plans/engagement.md`). Data: `likes/{postId}_{uid}`,
`reposts/{postId}_{uid}`, `userLikes/{uid}`, `quotas/{uid}.likes`, `posts/{id}.{likeCount,repostCount,quoteCount,embedded}`.
Everything user-visible is behind `FEATURE_ENGAGEMENT` (off | allowlist | percent | on, FEATURE_POSTS still required).
Cleanup (the `post_delete` job, Eraser, export) is never flag-gated. Kill switch: `FEATURE_ENGAGEMENT=off`.

| Flag (wire name) | Env vars / Terraform | Gates | Default |
|---|---|---|---|
| `engagement` | `FEATURE_ENGAGEMENT[_ALLOWLIST\|_PERCENT]` / `feature_engagement*` | LikePost, UnlikePost, RepostPost, UndoRepost, viewer flags; required by `quotes` | off |
| `quotes` | `FEATURE_QUOTES[_ALLOWLIST\|_PERCENT]` / `feature_quotes*` | `CreatePost.quote_of_post_id` only (needs `engagement` on too; ADR-0018 amendment 2026-10-18) | off |
| `bookmarks` | `FEATURE_BOOKMARKS[_ALLOWLIST\|_PERCENT]` / `feature_bookmarks*` | AddBookmark needs it on for the caller; ListBookmarks and RemoveBookmark only need it not globally off (ADR-0023 D5); needs FEATURE_POSTS, not `engagement`. All three RPCs are live behind it (W2-3, W2-4). The runbook is `docs/runbooks/bookmarks.md` | off |
| `likes_list` | `FEATURE_LIKES_LIST[_ALLOWLIST|_PERCENT]` / `feature_likes_list*` | ListLikedPosts needs it on for the caller (ADR-0024 D6, D9); needs FEATURE_POSTS, not `engagement`. Without it: `FEATURE_DISABLED` `feature=likes_list`, 0 reads. W3-10 implemented the handler (section 9); a Server built without a LikesList answers Unimplemented behind the gate. Rate limit `RATE_LIMIT_LIKES_LIST_PER_MIN` (10/min per instance). Kill switch: set it to `off` and deploy, nothing stored changes | off |

Quote rollback: set `FEATURE_QUOTES=off` (or lower the percent) and deploy. New quotes are refused with `FEATURE_DISABLED`
`feature=quotes`; existing quotes keep displaying (display never consults the flag), likes and reposts are unaffected.
`enabled_features` lists `quotes` only for callers it is on for; clients treat the refusal as the sub-feature being off.

## 1. Likes or reposts of a deleted post remain (orphans)
**What it is.** DeletePost publishes `post_delete` best effort. If the publish failed
(`post_delete_job_publish_failed` in Error Reporting) the post is gone but its `likes/*`, `reposts/*` and REPOST posts
stay, and quotes still show the frozen text. There is no reconciliation sweep at Stage 0 (plan "Risks").
**Find it:** `likes` where `postId == <id>` returns docs while `posts/<id>` does not exist.
**Fix:** publish by hand to the jobs topic
`{"kind":"post_delete","uid":"<author uid>","postId":"<postId>","mediaIds":[]}`. The job refuses while the post exists
(`refused`), is idempotent, and converges on a redelivery. The same message re-runs the media step.

**Expected orphans, no action (ADR-0018 "Orphaned likes", founder approval 2026-10-17).** After an *account* deletion,
likes that other users left on the deleted user's posts (`likes/{postId}_{otherUid}`, and those ids in their
`userLikes`) remain by design. They hold only the liker's uid and a dead post id, counts are unaffected, ids are never
reused, and they are erased with the liker's account. They are not ADR-0011 Q10 residue. Tell them apart from the
failed-publish case above by Error Reporting: if there is no `post_delete_job_publish_failed` for that postId, treat
the orphans as expected; no action needed.

## 2. `engagement_post_delete_continued` appears repeatedly for one post
**What it is.** A post with thousands of likes/reposts: one delivery handles at most 10 pages of 100, then republishes
the same message and acks (D11), so it never dead-letters. Each continuation is normal; the job finishes when a page
is not full. A loop that never ends means the deletes fail silently: check `fs_writes`/errors on the `/internal` line.
**Cost:** 1 read + 1 delete per like; a post with 5,000 likes is ~5k reads and 5k deletes spread over 50 deliveries.

## 3. Users report "daily limit reached" when liking
`QUOTA_EXCEEDED` with `quota=likes`: 500 per IST day, 100 for an account younger than `QUOTA_NEW_ACCOUNT_WINDOW`
(`QUOTA_LIKES_PER_DAY`, `QUOTA_NEW_ACCOUNT_LIKES_PER_DAY`). Reposts count against the posts quota (`quota=posts`).
A spike across many accounts is spam: `docs/runbooks/abuse-spike.md`.

## 4. A like or repost count looks wrong
Counters are exact in Firestore; a viewer can see a count up to 60 s stale (instance cache). If `likeCount !=` the
number of `likes` docs, the cause is a write path that bypassed the transaction; repair with
`likeCount := count(likes where postId == id)` for that one post and file a bug. Quote and reply counters drift by
design when the quoting account is deleted (D16).

## 5. Liked state missing for old likes
`userLikes.recent` keeps the last 1,000 likes (500 reposts): older likes render as not liked (D7). Tapping like on such
a post is a replay (0 writes) and re-adds it to the set. Not a bug; raise the cap only through an ADR.

## 6. Account deletion stalls on the `engagement` step
The step pages 100 likes/reposts per invocation (each an atomic delete + counter -1) and falls back to one batch per
doc when a post in the page is gone. Resumable via the checkpoint; see `docs/runbooks/account-deletion.md` Step 2.

## 7. `posts_purge_copies_stuck` (Error) during an account deletion
The posts purge's copy phase (ADR-0018 D14) removes the deleted user's text from other users' REPOST docs and
tombstones their QUOTE docs. A full page that made no progress would repeat forever, so the job stops and logs
`posts_purge_copies_stuck` at Error (it reaches Error Reporting) with `uid_hash` and `docs`.
- Cause: copy docs the batch and the per-doc fallback both reject (typically a reposter's `users` doc in an unexpected
  state, or a malformed `kind`).
- Check: `opsctl purge-posts --dry-run` for the uid, then query `posts where embeddedAuthorId == <uid> limit 20` in
  the Firestore console and look at the first doc's `kind`, `authorId` and `repostOfId`.
- Fix: repair or delete the named doc by hand (write budget: a handful), then re-deliver the deletion job; the phase
  resumes from the first full page. The account-deletion backstop does not delete `users/{uid}` while a residue
  remains, so nothing is lost by waiting.
- Related, same shape for a post deletion: `engagement_post_delete_no_progress` (Error) means a full page of likes,
  reposts or quotes of a deleted post made no progress; the step is skipped for that delivery instead of
  re-publishing forever. Same check on `repostOfId` / `quoteOfId` / `postId`.

### Deploying while deletions are in progress
A deletion whose posts step is still running at deploy time re-enters at its stored checkpoint (`Phase` 0 is the post
purge), finishes it and then runs the copy phase once, so copies are cleaned. A deletion that had already left the
posts step before the deploy never runs the copy phase: its copies (other users' REPOST and QUOTE docs of the
deleted user) remain until `opsctl purge-posts` is run for that uid. Check the account-deletion jobs in flight at
deploy time and re-run the posts purge for any that were past the posts step.

### Concurrent likes: abandoned follower
A LikePost that joined another request's in-flight like of the same post (same instance, same user) and whose client
then left returns CANCELED / DEADLINE_EXCEEDED (not INTERNAL, not in Error Reporting). Its request log does not
carry the transaction's `fs_reads` / `fs_writes`: the leader's request owns them. The leader never abandons its
flight, so a committed like always updates the counter hook, the cache and the notification.

## 8. Bookmarks: AddBookmark and RemoveBookmark (ADR-0023, W2-3)
Data: `users/{uid}/bookmarks/{postId}` = `{createdAt}` (a thin doc, no copy of the post), `userLikes/{uid}.bookmarks` (the
complete set, at most `BOOKMARKS_MAX_PER_USER` = 1,000), `quotas/{uid}.bookmarks`, `idempotency/{hash}` (24 h TTL). Nothing
is emitted or notified; a bookmark is private to its owner. **Kill switch: `FEATURE_BOOKMARKS=off` and deploy** (Add and
Remove then answer `FEATURE_DISABLED feature=bookmarks`, 0 reads); no data migration is needed and existing bookmarks stay.
Taking a user off the allowlist stops their Add only, they can still Remove. The request line carries `engagement_op`
(`add_bookmark` / `remove_bookmark`), `outcome` (`done`, `replay`, `noop`, `not_found`, `rejected:limit_reached`,
`rejected:quota_exceeded`, `rejected:key_reused`, `contention`), `fs_reads`, `fs_writes`, `fs_deletes` and `txn_attempts`.

| Symptom | Cause and action |
|---|---|
| `LIMIT_REACHED limit=bookmarks` | The user holds 1,000 bookmarks (exact: counted from `userLikes.bookmarks` inside the transaction). Expected; they remove some. Raising `BOOKMARKS_MAX_PER_USER` past 2,000 needs ADR-0023 D7's maths redone |
| `QUOTA_EXCEEDED quota=bookmarks` | 200 adds per IST day, 50 for an account younger than `QUOTA_NEW_ACCOUNT_WINDOW` (`QUOTA_BOOKMARKS_PER_DAY`, `QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY`). A replay or an already bookmarked post is not charged. A spike across many accounts is spam: `docs/runbooks/abuse-spike.md` |
| Add returns `NOT_FOUND "post not found"` for a post the user saw | The post is deleted, taken down, or its author (or a quoted author) blocks the user: the same answer and bytes as GetPost, by design (no block oracle) |
| `UNAVAILABLE` (retry after 1 s) from Add or Remove, `outcome=contention`, WARN `engagement_bookmark_contention`, `txn_attempts` at 4+ or a deadline | Contention (W2-14 L-3, no longer INTERNAL): one user's concurrent adds all lock their `quotas` and `userLikes` docs and serialise; the transaction retries 4 times inside 5 s and then gives up without writing. The client retries (same key). Sustained = a client bug or a script; the 30/min per-instance rate limit and the `bookmark_mutation_daily` cap bound it |
| `RESOURCE_EXHAUSTED` with `limit_name=bookmark_mutation_daily` | The user made more than `BOOKMARK_MUTATIONS_PER_DAY` (1,500) Add + Remove calls on this instance today (W2-14 M-1). A legitimate heavy day is about 1,200; see `docs/runbooks/bookmarks.md` quick reference for the sum. Many hashes at once = a script farm: `docs/runbooks/abuse-spike.md` |
| Bookmarked state missing on a card | Viewer state comes from `userLikes.bookmarks`, cached 60 s per instance. The wire field `PostView.bookmarked_by_viewer` does not exist yet (architect follow-up), so clients keep a local set until it ships |
| Bookmark exists in the subcollection but not in the array (or the reverse) | Not expected: every writer changes both in one transaction. Add then answers success and writes only its idempotency doc (it cannot heal it); the ListBookmarks prune (it removes the id from the array too, for a missing post only) and the account eraser delete by doc. File a bug with the uid hash |

Replays: a replayed Add returns its stored `bookmarked: true` even if the bookmark was removed since, and a replayed
Remove returns `false` even if it was added again; neither writes, so a late retry never undoes a newer toggle. The two no-op paths (Add of an
already bookmarked post, Remove of a missing bookmark) also store their idempotency doc, so they cost 1 write, not 0, and a late retry
of their key replays too. Account deletion and export of the `users/{uid}/bookmarks` subcollection, the prune and the residue are in
`docs/runbooks/bookmarks.md`.

## 9. Likes list: ListLikedPosts (ADR-0024 D6, W3-10)
Read only. The ids are `userLikes/{uid}.recent` (the last 1,000 liked post ids, newest last, owned by the like path); the posts are
live reads through the posts cache. Nothing is written, pruned or emitted. **Kill switch: `FEATURE_LIKES_LIST=off` and deploy**
(`FEATURE_DISABLED feature=likes_list`, 0 reads); percent 0 or an empty allowlist is a rollout, not a kill. It needs `posts`, not
`engagement`. The request line carries `engagement_op=list_liked_posts`, `outcome` (`done`, `rejected:invalid_argument`),
`rows_returned`, `rows_dropped`, `rows_dropped_{missing,hidden,blocked,muted,protected}`, `userlikes_cache_hit` and `fs_reads` (23 at page 20
cold, 53 at page 50, 2 for an empty array, 20 warm at page 20); there is no `rows_pruned`.

| Symptom | Cause and action |
|---|---|
| Old likes are missing from the list, or the list stops at about 1,000 | By design: `recent` keeps the 1,000 most recent likes (`MaxRecentLikes`), the same limit as the liked state on cards (section 5). A longer history needs the Stage 2/3 `likes (uid, createdAt)` index or a SQL table (ADR-0024 D6, out of scope), not a bigger array (document size and write cost) |
| Short or empty pages while `next_page_token` is non-empty | Expected. Rows whose post is deleted, taken down, hidden, by a blocked or muted author, by an author who blocks the viewer, or by a protected account the viewer does not follow (W3-41a: a post by such an author is kept as a stripped placeholder with `withheld = true`, counted in `rows_withheld`, so Unlike works; a REPOST of such a post is dropped and counted in `rows_dropped_protected`, a QUOTE stays with the stripped embed; never pruned, the full row is back after a follow or an unprotect) are dropped or stripped after the read and the page is not refilled; the client keeps following the token. Many `rows_dropped_missing` for one user means their liked posts were deleted (section 1 removes the like docs; the array entry stays until the user unlikes it or it ages out of the 1,000). Nothing to repair: the list never prunes, on purpose |
| A like made just now is missing | `recent` is cached 60 s per instance. The instance that served the like updates its cache in place; another instance shows it within 60 s. Only a like still missing after that is a bug: check the like's `userLikes` write (section 5) |
| `INVALID_ARGUMENT VALIDATION page_token` | The token is older than 24 h, another user's, hand-edited, from another list (a ListBookmarks token does not open here) or of another payload version. 0 reads; the client drops it and reloads the first page. A spike across many users right after a deploy means `CURSOR_HMAC_KEY` or the token payload changed |
| A row repeats or is skipped between two scrolls | Only a row changed at the page boundary can (the ADR-0024 D6 residual: both anchors unliked, or the last row unliked and the next one re-liked). A re-liked row moves to the top and is not shown twice. Anything larger is a bug: keep the token's issue time and the user's unlike times and check `likesResume` |
| `UNIMPLEMENTED` "ListLikedPosts is not wired" | The Server was built without a `LikesList`. `apiserver.Build` cannot do this (`NewServer` takes it from the Module); a test or a split-out wiring left `WithLikesList` out |
| `RESOURCE_EXHAUSTED` | The per-instance bucket `RATE_LIMIT_LIKES_LIST_PER_MIN` (10/min; it multiplies by max-instances) |

## 10. Polls: VotePoll (ADR-0029 D6, W6-7 and W6-8)

One vote per account per poll, changeable until the poll closes (Amendment 1 A2, W6-36). The vote doc `pollVotes/{postId}_{uid}` is the idempotency record (ADR-0029 D7, the F2 bend of rule 4): no `idempotency/*` doc. One batch writes the vote doc, `posts.poll.counts.<i>` + `poll.total` (one Update, by `firestore.FieldPath`) and `userLikes.pollVotes`. A change is one more blind batch of 4 writes (below).

**Request line** `poll_vote`: `outcome` (`voted`, `changed`, `replay`, `stale_expected` (the ALREADY_VOTED answer, was `already_voted`), `change_limit`, `voter_blocks_author`, `closed`, `author`, `not_found`, `contention`), `uid_hash`, `fs_reads`, `fs_writes`, `contention`. The choice is never logged.

**Hot poll and `poll_vote_contention`.** A WARN `poll_vote_contention` (and `contention=true`, UNAVAILABLE with `retry_after`) means the batch kept losing the lock race on one post doc after 4 attempts. A handful is normal on a viral poll; a sustained rate is the Stage ladder trigger for sharded poll counters (new ADR, `StagePollVote` is the one body to replace). Both the WARN and the `VotePoll` request line carry `post_hash`, a KEYED pseudonym: the first 16 hex characters of HMAC-SHA256 over `"post|" + post id` (`logger.HashPost`, same HKDF-derived key as `conversation_hash`, from `CURSOR_HMAC_KEY`; security review L-1: an unkeyed hash beside `uid_hash` would let a log reader rebuild who voted in which poll). Count per post: `gcloud logging read 'jsonPayload.message="poll_vote_contention"' --format="value(jsonPayload.post_hash)" | sort | uniq -c | sort -rn | head`. The sharding trigger (one poll above 1 vote a second for 5 minutes) is `jsonPayload.engagement_op="poll_vote" AND jsonPayload.outcome="voted" AND jsonPayload.post_hash="<h>"` counted per minute (300 in 5 minutes). To map a post id to its hash: `CURSOR_HMAC_KEY=$(gcloud secrets versions access latest --secret=cursor-hmac-key --project=<project> | tr -d '') go run ./cmd/opsctl polls loghash POST_ID` (no Firestore, no project; use the secret version that was live when the lines were written). A hash cannot be reversed: to find the post behind a hash, hash the candidate ids with the same command. Count by time and post, never by uid.

**Kill switch.** `FEATURE_POLLS=off` refuses VotePoll (FEATURE_DISABLED `feature=polls`, 0 reads), stops new polls and shows every existing poll's results to everyone. An allowlist or `percent 0` is a rollout, not a kill switch: callers outside it may still vote. `FEATURE_ENGAGEMENT` off for a caller refuses their vote (`feature=engagement`).

**ALREADY_VOTED support questions.** A vote can be changed until the poll closes, by a request that names the stored vote (`expected_choice` = stored index + 1). `ALREADY_VOTED` now means the request did not name it (an old app, a second device with a stale view, a late retry): it carries `metadata["choice"]` (the caller's own stored 0-based index); the app shows it and refreshes once. A change past `POLL_VOTE_CHANGES_MAX` is `LIMIT_REACHED` with `metadata["limit"] = "poll_vote_changes"` and `metadata["choice"]`. After the poll closes even a replay answers `POLL_CLOSED`. A vote can land a few hundred ms after `closesAt` (accepted race). The vote doc is found with `pollVotes/{postId}_{uid}`; operators do not edit it.

**Vote changes (ADR-0029 Amendment 1 A2, W6-36).**
- *Write.* The service reads the vote doc (+1), then commits ONE blind batch, no transaction on the hot post doc: the vote doc `Update` under a `LastUpdateTime` precondition (`choice`, `changes` +1, `changedAt`), `posts.poll.counts.<from>` -1 and `<to>` +1 (`StagePollChange`, `poll.total` untouched), and two field-level merges of `userLikes` (`ArrayRemove` of the old entry, `ArrayUnion` of the new one: two writes to one document in one commit). 4 writes, 9 reads worst (the 8 of a new vote plus the vote doc), 4 typical.
- *Precondition failed.* The service reads the vote doc again: moved = a concurrent change won and the answer is decided again (`ALREADY_VOTED` naming the winner, or a replay); unmoved = the post is gone (NOT_FOUND, 0 writes). At most 4 rounds, then UNAVAILABLE with `contention=true` (`poll_vote_contention`, the same hot-poll signal as a new vote). Each round re-checks `closesAt`.
- *Cap.* `POLL_VOTE_CHANGES_MAX` (env, default 5, 0..20; the Terraform env entry is W6-51, #562, edited but not applied: until a dev or prod apply carries it, using the kill switch needs that apply first, no click-ops). `0` makes votes final again (every change is `LIMIT_REACHED`, no write) without touching `FEATURE_POLLS`: the kill switch for changes. The count is the vote doc's `changes`, so an instance restart resets nothing. A change also counts toward `RATE_LIMIT_POLL_VOTE_PER_MIN`, `POLL_VOTES_PER_DAY` and the new-account cap.
- *Counts look wrong?* `poll.counts[i]` must equal the number of `pollVotes` docs with `choice == i` plus erased voters' anonymous totals, and `poll.total` their sum. A drift after a change would mean the vote-doc precondition was bypassed; compare `pollVotes where postId == X` with the post's `poll`. Other instances show a change after at most the 60 s post-cache TTL (O-2).
- *History.* No earlier choice is stored or logged anywhere (the export lists the current choice and `changedAt`); the `poll_vote` line never carries a choice or `expected_choice`.
- *Dev check owed after merge, before `polls` widens.* The two-writes-to-one-document commit is proven on the emulator (`TestRepoChangeVote_BatchBudgetAndEffects`), not yet on dev Firestore: change a vote with a dev test account and check: the request line has `outcome=changed`, `fs_writes=4` and no error; `posts/{id}.poll.counts` moved -1 and +1 with `poll.total` unchanged; `userLikes/{uid}.pollVotes` holds **exactly one** entry for the post, in the three-part form with the new choice (W6-42 part 2, `docs/reviews/security-w6-36-poll-changes.md`). If dev rejects the commit, switch `FirestoreRepo.ChangeVote` to the transaction fallback (read `userLikes`, rewrite `pollVotes` with the entry replaced; +1 read, 3 writes).

**Voter blocks the author (Amendment 1 A1, W6-36).** The voter blocking the author is `FAILED_PRECONDITION TARGET_BLOCKED`, 0 writes, for a first vote, a replay and a change alike; it is decided from the caller's cached graph snapshot (0 extra reads; the 60 s graph cache bounds how soon another instance sees a new block). The author blocking the voter stays the byte-identical NOT_FOUND. Earlier votes are kept and counted; Block and Unblock write nothing to polls. `PostView.viewer_poll_vote_blocked` is true on GetPost, GetThread and the blocked author's profile timeline while the poll is open; a blocker who never voted still sees hidden counts until close. `outcome=voter_blocks_author` counts the refusals; a spike right after a client release means the card does not yet disable the buttons (W6-37).

**New-account cap.** `POLL_VOTES_PER_DAY_NEW_ACCOUNT` (50) is enforced in the service by comparing the interceptor's `poll_votes_daily` counter (per instance, in memory, so it multiplies by max-instances and resets with the instance); the answer is the interceptor's RATE_LIMITED `limit=poll_votes_daily`.

**TTL must be applied before prod polls.** Vote docs expire at `closesAt + POLL_VOTE_TTL_AFTER_CLOSE` (30 d) through the Terraform TTL policy `poll_votes_expire_at` on `pollVotes.expireAt`. Until it is applied in a project the docs simply stay (cost: storage only).

**Account deletion and export.** Step `poll_votes` (after `messaging`, before `identity`) deletes `pollVotes where uid == X` in pages of 500 (1 read + 1 delete per doc); counts stay as anonymous totals (F6). Export section `poll_votes` lists postId, choice, createdAt and, once the vote was changed, changedAt. A deletion job already past the position of the step when it deployed skips it; its vote docs then expire by TTL.

**Retention of the per-account copy `userLikes.pollVotes` (security L-2, W6-29).** The one-sentence statement (quote it in the Privacy Policy and W6-47): *a poll vote and the copy kept on your account are kept until the poll closes plus 30 days (`POLL_VOTE_TTL_AFTER_CLOSE`); both are removed within about a day of that time (the copy sooner when you open the app; the vote record by Firestore's TTL, the copy by the daily cleanup run), and both go at once when you delete your account.*
- Entry format: `"<postId>:<choice>:<closesAtUnix>"` (two-part `"<postId>:<choice>"` before W6-29, dev only). Expiry = closesAt + the TTL in force. `userLikes.pollVotesDueDays` (ints, UTC day numbers of each entry's expiry, `ArrayUnion` in the same Set as the entry) lets the sweep find documents without scanning.
- Three removers: (1) display: an expired entry is never shown or cached; (2) lazy prune: the first load of `userLikes` that sees one removes it (one field-level `Update` with an Exists precondition, once; skipped under `DEGRADED_MODE=readonly`; a failure logs `engagement_poll_prune_failed` and is retried at the next load); (3) the daily sweep, a step of `/internal/cron/daily-maintenance` before the trends refresh (log lines `poll_vote_sweep` / `poll_vote_sweep_failed` with `docs`, `pruned`, `entries`, `skipped`, `more`, `fs_reads`, `fs_writes`). It is not behind `FEATURE_POLLS` (documents outlive the flag) and does not run under `DEGRADED_MODE=readonly`.
- Cost: idle sweep 1 read a day; a run touches at most 50 documents (50 reads, 50 writes); `more=true` means a backlog that the next day continues. The vote itself costs the same as before (3 writes, one more field on the existing `userLikes` Set).
- Failure modes. `poll_vote_sweep_failed` repeating: expired copies linger in dormant accounts only (never shown); check the Firestore error, the next run retries. No `poll_vote_sweep` line for more than 2 days: the daily-maintenance job is not running (see the account-deletion backstop runbook); the sweep window is the last 30 due days, so an outage over 30 days leaves older entries to the lazy prune. `skipped>0` is a document that changed or was erased during the run; it is picked up next day. Entries written before W6-29 have no due day and are only removed by the lazy prune or at account deletion (dev only: polls are off in prod).
- Staleness: a cached copy can still show the check mark of an entry that expired in the last `CACHE_TTL` (60 s).
- A vote change (W6-36) rewrites the account's entry for that post in the same batch: it removes both forms of the old entry (three-part and the legacy two-part) and adds the new three-part one, and unions the expiry day into `pollVotesDueDays` (a no-op unless a legacy entry was replaced). The expiry is unchanged by a change, since closesAt is immutable.
- Export: the `poll_votes` section carries `current_choices` (`{postId, choice}` rows, no time, live entries only) beside the vote docs; it reads `userLikes` fresh (+1 read). Account deletion removes `userLikes` (step `engagement`) and the vote docs (step `poll_votes`); a prune or sweep never recreates a deleted document.
- Worst case for the read RPCs that load `userLikes` (GetPost, timelines, lists, GetMe viewer state): **+1 write, once, on the load that finds an expired poll entry** (charged to that request's `fs_writes`); 0 otherwise. The sweep leaves a document alone (no write) when only same-day entries remain. Scale trigger: `poll_vote_sweep` with `more=true` on 3 consecutive days means more than 50 documents a day are due; raise `PollSweepLimit`/page the sweep (new ticket) before the backlog grows. The sweep runs under a 3 s cap and its own Error Reporting op `cron/daily-maintenance/poll-vote-sweep`; the trends refresh keeps whatever is left of the 10 s window.
