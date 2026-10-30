# 0029. Composer extras remainder: polls, drafts on the device, GIFs from the device (W6)
Status: Proposed
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
