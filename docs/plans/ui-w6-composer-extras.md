# UI W6: composer extras remainder (polls, drafts on the device, GIFs from the device)
Plan owner: planner · Date: 2026-10-26 · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **New backend surface:**

> **Decision (founder, 2026-10-27):** F2 = yes (the natural-key vote doc is the idempotency record). GIFs stay in W6: a same-day deferral was withdrawn; F9 to F11 proceed on their stated defaults, with F11 (server-side frame-sampled SafeSearch, which has the API read the uploaded GIF) to be confirmed in ADR W6-1.
- a poll definition and its counters on `posts/{postId}` (posts module);
- one write RPC, `VotePoll`, and one new collection, `pollVotes` (engagement module, the ADR-0018 likes pattern);
- `image/gif` in the media pipeline (media module).

Drafts are client-only (drift): 0 RPCs and 0 server data. No new GCP service, no new Cloud Scheduler job, no fixed cost. · Flags: new `FEATURE_POLLS`, `FEATURE_DRAFTS` (client-only, like `ui_shell`) and `FEATURE_GIF`; existing `posts`, `engagement`, `media`, `scheduled_posts`, `reply_audience`, `content_disclosure` and `ui_shell`.

Sources:
- the W6 row of `docs/plans/roadmap.md` and its founder decision of 2026-10-22: "GIF = device upload now, Klipy picker only after terms are verified";
- `docs/plans/composer-w15-w6.md` (what W6 already shipped);
- ADR-0021 (D4 leaves "polls with a schedule" to this wave; L-1; the rule-4 bend);
- ADR-0018 (natural-key engagement, `userLikes`) and ADR-0023 (bookmarks on `userLikes`);
- ADR-0005 (media, SafeSearch), ADR-0010 (D2 sub-feature order, D5 read budget, D9 text rules) and ADR-0011 (T11 guard, erasers);
- `docs/x_research/screens/composer.md` §1a–§1h, §2 and §6, `14_mvp_structured_plan.md` §6 and `07_functionality_inventory.md`. These are local and git-ignored; what this plan needs from them is restated here.

Branches: `feat/ui-w6-N-<slug>` off `main` (not stacked); one ticket per PR unless a ticket says otherwise; merge `origin/main` into the branch.

**Already shipped in W6, not in this plan:**
- reply audience (CMP-B, UI done);
- content disclosure (CMP-C: backend done; the CMP-C3 UI is on hold by the founder);
- scheduled posts end to end (CMP-D), with the single `publish-scheduled` sweep.

They are tracked in `docs/plans/composer-w15-w6.md` (its Open items section). The composer conformance tickets CMP-1 and CMP-2 also stay there; W6-15 takes over the "Save post?" prompt from CMP-2 (see that ticket).

## Questions for the founder (proposed default in bold; nothing blocks the ADR ticket)
- **F1. How a poll closes.**
  - **(A) Read-time check on `closesAt` (default).** It costs 0 reads, 0 writes and no job. `VotePoll` refuses once `now ≥ closesAt` by server time, and the converter shows the final results from then on.
  - (B) A hop on the existing `publish-scheduled` tick. It needs an index on `poll.closesAt`, which clashes with the A9 exemption. It costs 1 read per tick while idle (288/day at `*/5`) plus 1 per closed poll. It only pays off for "poll ended" notifications, which are a fan-out and out of scope at Stage 0. It also ties polls to a job that is not applied in prod (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.18).
  - (C) A new Scheduler job. That is the third and last free slot, and W4's option A wants it too.

  **Default: (A).** "Poll ended" notifications are the Stage 2 version, with their trigger under Out of scope.
- **F2. Rule 4 for `VotePoll` (a bend, needs your explicit OK).** **Use the natural-key vote doc `pollVotes/{postId}_{uid}` as the idempotency record, as `likes/{postId}_{uid}` does (ADR-0018 bend, approved 2026-10-17; `docs/code-map.md`, `idempotency` row).** **Decided: yes (founder, 2026-10-27).**
  - `idempotency_key` stays required and format-validated.
  - A replay with the same choice returns the current state with 0 writes.
  - A different choice answers ALREADY_VOTED.

  Alternative: also store the TTL'd `idempotency/*` doc. That costs +1 write and +1 TTL delete per vote (under INR 1/month at 3,000 DAU) and changes no behaviour.
- **F3. Who sees results, and when.** **Per-choice counts and percentages stay hidden until the viewer has voted, the poll has closed, or the viewer is the author. The total ("N votes") is always shown. The author cannot vote in their own poll. Nobody, the author included, can see who voted for what: there is no voter-list RPC.** Alternative: show counts to everyone at all times. It saves no reads (the viewer's choice is needed for the check mark anyway) and lets people see the results before deciding.
- **F4. Poll shape.**
  - **2 to 4 choices, each 1 to 25 code points (X's "0 / 25" counter, `composer.md` §2), distinct after NFC and case folding.**
  - **Duration from 5 minutes to 7 days, default 1 day (X's Days 0–7 / Hours / Minutes).**
  - **The question is the post text and is required.**
  - **Polls go on new root posts only:** not on replies or quotes, not with photos or a GIF, and not with a schedule (F5).
  - **A vote cannot be changed or withdrawn.**

  Out of scope: image choices (X's per-choice "Add media").
- **F5. Polls together with scheduled posts.** **Not combined.** ADR-0021 D4 left this to this ADR:
  - `SchedulePostRequest` keeps no poll field (no proto or sweep change).
  - The composer disables Add poll while a time is set and Schedule while a poll is attached, as X does (`composer.md` §1b).

  Alternative: a scheduled poll whose length starts at publish. That needs scheduled-doc `schemaVersion: 2` and a sweep change; it would be a later ticket.
- **F6. A voter deletes their account.** **The eraser deletes their vote docs and leaves the counts as anonymous totals (they hold no uid).** Alternative: decrement open polls on deletion, at +1 post-doc write per open vote in the eraser path.
- **F7. Drafts and sign-out.** **Keep them on the device, per uid.**
  - Another account on the same device never sees them.
  - They are wiped when the account is deleted from this device.
  - The Drafts screen has "Delete all".

  Alternative: clear them on sign-out with the other caches (`AppDatabase.clearAll`). That is safest on shared devices and matches W4's recent searches, but a user who signs out loses unsent posts.
- **F8. What a draft keeps.** **Text, poll, reply audience and disclosure labels. Photos and GIFs are not kept in v1:** the "Save post?" prompt says "Photos aren't saved in drafts" when photos are attached. Alternatives, both rejected for v1:
  - compressed image bytes on the device: up to about 9 MiB per draft, plus a draft cap and private photos at rest on shared devices;
  - uploaded media ids: READY images are public by link (ADR-0021 L-9), and PENDING ones expire after 2 days.
- **F9. Where GIFs come from (🔒 roadmap gate "GIF provider terms").** **Your 2026-10-22 decision stands: v1 is a GIF file picked from the device, uploaded through our media pipeline (this plan). A provider picker comes only after Klipy's production terms are verified in writing.**
  - The 2026-10-22 research, not re-verified here: Tenor's API shut down on 2026-06-30, and GIPHY is not free for production (its free keys are capped at about 100 calls an hour).
  - The brief for this plan proposed a client-side picker with a restricted key. That is the deferred picker design, W6-23 and W6-24, both conditional.
  - When the picker unlocks, **default (a): copy the chosen GIF through our pipeline.** SafeSearch and the caps apply, no third-party URL appears in posts, and the CSP does not change. This is allowed only if the terms permit re-hosting.
  - (b) Linking the provider's URL costs 0 Vision units, but it needs its own ADR, because:
    - it adds a third-party host to `img-src` (the CSP is enforced on dev);
    - viewers' IP addresses go to the provider;
    - content can change after posting;
    - moderation becomes the provider's rating filter instead of SafeSearch.
  - A key used straight from the client at about 100 calls an hour is exhausted by a handful of users. Any picker therefore needs a production key or a server-side cache; W6-23 decides.
- **F10. GIF size and playback.**
  - **At most 2 MiB (the existing `MaxFullBytes`, so the signed URLs do not change), at most 1,280 px on the long edge, at most 300 frames.**
  - **One GIF per post, not mixed with photos or a poll, and not in scheduled posts (v1).**
  - **Feeds show a static first-frame thumbnail with a "GIF" badge; a tap plays the full file.** "Reduce motion" is respected.

  Alternative: autoplay in feeds. It moves about 5× more bytes: GIF egress is about INR 1,660/month at 3,000 DAU instead of about 311 (Cost).
- **F11. GIF moderation (an architect proposal; you accept the residual risk).** Cloud Vision's list of supported formats is believed to say that an animated GIF is screened on its **first frame only**. **UNVERIFIED: W6-1 must confirm it.** If so, a harmless first frame can carry explicit later frames. Options:
  - **(a) Default: sample frames on the server in FinalizeUpload.**
    1. Read the GIF from the private upload bucket (at most 2 MiB, 1 Class B operation, inside the existing free GCS egress).
    2. Decode it under hard guards (A10).
    3. Tile up to 4 evenly spaced frames into one JPEG contact sheet and send it to SafeSearch as image bytes. That is 1 unit, replacing the full-image screen.
    4. With the thumbnail, a GIF costs 2 units, the same as a photo.

    Clients still upload straight to GCS. **But the API would now read a whole uploaded object (up to 2 MiB) instead of today's 512-byte magic-byte check.** Whether that is consistent with `CLAUDE.md` rule 7 ("media never passes through the API") is **your call, part of accepting F11 (a)**: this plan reads the rule as being about client uploads, not about the server reading an object to moderate it. If you read it strictly, choose (b).
  - (b) Screen the first frame only, accept GIFs only from accounts older than 7 days, and rely on report-driven review.
  - (c) No animation: flatten every GIF to a still. That is today's behaviour, not a GIF feature.
- **F12. Flags.** **Three: `FEATURE_POLLS` (server), `FEATURE_DRAFTS` (client-only, registered so `GetMe` reports it) and `FEATURE_GIF` (server).** The later picker gets `FEATURE_GIF_SEARCH`, registered only when W6-24 lands.

## What exists already (verified on `main` d2ff011)
| Piece | State | W6 delta |
|---|---|---|
| Composer | `/compose` (`composer_screen.dart`): text 280, photos (`_AddPhotoButton`, ≤ 4), alt text (W2-10), reply audience link, Schedule button and "Will send on" line (CMP-D6). Leaving with photos asks "Your photos will not be saved." There is no Drafts button and no "Save post?" prompt; Poll and GIF buttons exist behind `polls`/`gif` (W6-11) (Poll opens the builder, W6-12; GIF is inert until W6-16) | Poll and GIF buttons; a Drafts header button; the "Save post?" prompt (W6-11, W6-12, W6-15, W6-16) |
| `posts.proto` | Next free field numbers: `CreatePostRequest` 10, `Post` 21, `EmbeddedPost` 10, `PostView` 7. `SchedulePostRequest` has no poll field (ADR-0021 D4) | `poll` fields, `viewer_poll_choice` (W6-2) |
| `common.proto` | The highest `ErrorReason` is `REPLY_NOT_ALLOWED = 16` (W3-25a then took 17 for `PROTECTED_ACCOUNT`, ADR-0025) | `POLL_CLOSED`, `ALREADY_VOTED` (or reuse; A6). W4 and W5 may take 18+ first: take the next free numbers when the PR opens |
| Engagement | `likes/{postId}_{uid}` (natural key), counters through `posts.EngagementWriter` batches, `userLikes/{uid}` `{recent, recentReposts, bookmarks}` read once per request (60 s cache) through `posts.ViewerFlags` → `posts.HydrateViewer` → `ViewerSet` | `VotePoll`, `pollVotes`, `userLikes.pollVotes`, `ViewerSet.PollChoice` (A2, A3) |
| Media | `image/jpeg` and `image/webp` only (`media/service.go:131`); `sniffImage` knows those two; the thumbnail is published with the full image's content type (`finalize.go:184`); full ≤ 2 MiB, thumbnail ≤ 256 KiB; SafeSearch by `gs://` URI (`vision.go:60`), 2 units per image. The client re-encodes everything to JPEG (`image_processor.dart`), so a picked GIF loses its animation today | `image/gif` for post media, a thumbnail content type, frame sampling (W6-3, W6-9, W6-10, W6-16) |
| Local storage | drift `AppDatabase` schema v6; `clearAll` wipes the cache tables on sign-out and keeps `AppSettingEntries`; `SessionEpoch` guards writes | a `ComposerDraftEntries` table, schema v9 (v7 and v8 went to W7), outside `clearAll` (F7) (W6-14) |
| Drafts list | `/scheduled` (CMP-D6) lists scheduled items; X shows one "Drafts" dialog with tabs Unsent posts \| Scheduled (`composer.md` §1h, §6) | the Drafts screen gets both tabs (W6-15) |
| Scheduler | prod: `daily-maintenance` (live) and `publish-scheduled` (defined, not applied); dev: none. 2 of 3 free jobs are spoken for, and W4's option A would take the third | **none** (F1 A) |

## Goal & user value
Three things people reach for in X's composer and cannot do here:
- **Ask a question with a poll** and see what people think. Polls are one of the few posting formats that invite a reply from people who do not follow you.
- **Keep an unfinished post** instead of losing it when the composer closes or the app dies.
- **Post a GIF** that actually moves.

All three are the cheapest Stage 0 versions:
- poll counters ride on the post document, with 0 extra feed reads;
- drafts stay on the device;
- GIFs reuse the photo pipeline, with no third-party API.

## Scope / Out of scope
**In scope (Stage 0 rung):**
- **Polls:**
  - create (F4), vote once (F2), results after voting or at close (F3), read-time close (F1);
  - a poll card in `PostCard`, the thread view and the post detail; a compact poll on repost and quote rows (A7);
  - lifecycle for votes (eraser, export, T11 row);
  - quotas and rate limits;
  - **no notification fan-out** (no "poll ended", no "someone voted").
- **Drafts:**
  - a drift table per uid under `SessionEpoch` and a debounced autosave;
  - "Save post?" with Save and Discard;
  - a Drafts screen with tabs Unsent posts | Scheduled (the existing list), opening a draft back into the composer, and an Edit mode with multi-delete;
  - **no server storage.**
- **GIFs from the device:** `image/gif` through CreateUpload and FinalizeUpload, frame-sampled SafeSearch (F11), at most 2 MiB, one per post, a static thumbnail in feeds with tap to play (F10).

**Stage ladder (the ADR W6-1 adds these rows to `stage-ladder`):**
| Concern | Stage 0 (this plan) | Seam to protect | Stage 2/3 target | Trigger (measured, 7 days sustained) |
|---|---|---|---|---|
| Poll counters | `FieldValue.Increment` on `posts/{id}.poll.counts.<i>` and `poll.total` in the vote batch (rule 3) | the `posts.EngagementWriter` stage method (one counter helper); `ABORTED`/contention on the vote batch surfaced as `poll_vote_contention` | sharded counters `posts/{id}/pollShards/{n}` or Pub/Sub-batched increments (an ADR, as the Counters row) | sustained `ABORTED` on one poll post, or more than 1 vote a second on one poll for 5 minutes (the trigger is traffic shape, not DAU: a viral poll breaks rule 3 at tiny DAU) |
| Poll closing | read-time `now ≥ closesAt` | `Poll.closes_at` on the wire; the client never decides "closed" for the server | a closing event (Cloud Tasks or a sweep) feeding "poll ended" notifications through `notifications.Emitter` | users ask for poll-ended notifications (tracked feedback), or polls exceed 5 % of posts |
| Drafts | drift table on the device, per uid | `DraftsRepository` interface (the only reader and writer); the draft model is the composer state, not a proto | synced drafts `users/{uid}/drafts/{id}` with an eraser and export (a new ADR, cost table) | more than 20 % of weekly posters use drafts **and** cross-device sync requests pass 25 in a month |
| GIFs | device upload through the photo pipeline, frame-sampled SafeSearch, static thumbnail in feeds | `media` content-type table and `Moderator` seam; the client `GifSource` interface (device today, provider later) | (1) a provider picker (Klipy, F9) behind `FEATURE_GIF_SEARCH`; (2) convert GIFs to MP4 or animated WebP on the client (short-video ADR) to cut bytes. The Transcoder API stays on the `CLAUDE.md` not-used list | (1) the founder's written terms check; (2) GIF bytes above 25 % of GCS egress, or a median GIF above 1 MiB |

**Out of scope:**
- "poll ended" and "someone voted in your poll" notifications (F1);
- changing or withdrawing a vote;
- image choices in polls;
- polls on replies, quotes or scheduled posts (F4, F5);
- seeing who voted;
- synced drafts, and drafts for replies or quotes (v1 drafts are new root posts);
- photos in drafts (F8);
- a GIF search picker (F9, conditional W6-23 and W6-24);
- GIFs in avatars or banners;
- GIF transcoding;
- autoplay in feeds (F10);
- the emoji picker and location tagging (X's toolbar has them; no plan asks for them).

## Non-functional targets (Stage 0, 0–300 DAU; credit mode changes no target)
- **Latency (warm):**
  - `VotePoll` p95 < 300 ms;
  - CreatePost with a poll p95 < 500 ms (`CLAUDE.md`);
  - timelines unchanged at p95 < 400 ms, since viewer state adds 0 reads;
  - FinalizeUpload with a GIF p95 < 3 s (decode, contact sheet and Vision).

  Cold start < 1.5 s. Nothing depends on credit mode's min instance of 1.
- **Staleness bounds:**
  | Read | Bound |
  |---|---|
  | Poll counts in a fresh PostView | ≤ 60 s (posts instance cache), except the voter's own `VotePoll` response, which is built from the committed counts |
  | Poll counts in the client's drift timeline cache | as of when the row was fetched. Opening the post fetches it live. A cached row whose poll has passed `closes_at` with hidden counts shows "Final results" and calls GetPost once on tap |
  | The viewer's own choice (`userLikes.pollVotes`) | ≤ 60 s on another instance (userLikes cache). A vote from a stale "not voted" view gets ALREADY_VOTED, and the client then refreshes the post |
  | Closed or open | exact by server time at `VotePoll`; the client counts down from `closes_at` |
  | Drafts | local and exact; autosave debounced 2 s |
- **Volume at 300 DAU:** about 6 polls a day, 90 votes a day and 6 GIFs a day (assumptions below).

## Cost (required)
Method: `free-tier-budget` §2 and `docs/reviews/cost-model.md`. The baseline with W2 is **248.7 reads, 33.5 writes, 8.4 deletes and 37.7 requests per DAU per day**. Reads pass the free quota at about 201 DAU, writes at about 597 and deletes at about 2,390.

Prices are `cost-model.md` §7: asia-south1 $0.035 / $0.104 / $0.012 per 100k reads / writes / deletes; Vision $1.50 per 1,000 units past the free 1,000, at 2 units per image; egress to India $0.12/GiB; GCS Class A $0.005/1k and Class B $0.0004/1k; INR 95 per USD; 30.42 days a month.

**The W3 and W4 deltas are not in `cost-model.md` yet**, so this W6 delta is priced at the margin on top of the W2 baseline, as W2-15 did.

**Per RPC.** Worst-case reads include the account-status interceptor. Every call is charged to the ADR-0010 D5 per-uid read budget.
| RPC | Reads worst (cold) | Reads typical | Writes | Deletes | Notes |
|---|---|---|---|---|---|
| CreatePost, root with a poll | +0 (14 unchanged) | +0 (2.2) | +0 (4: the poll is fields on the post doc) | +0 | validation is CPU only; the `requestHash` gets a suffix only when a poll is present (A8) |
| `VotePoll`, a new vote | 6: interceptor 1, post 1, original post +1 for a REPOST id, author profile 1, caller graph 1, +1 on `blockedBy` overflow | 3 (planning; AddBookmark measured 3.06 for the same shape) | 3 (vote doc, post counters, `userLikes.pollVotes`) | +1 TTL at `closesAt` + 30 d | one batch; no transaction on the hot post doc (A5) |
| `VotePoll` replay, ALREADY_VOTED | 7 (+1 vote doc read after AlreadyExists) | 4 | 0 | 0 | |
| `VotePoll` refused: POLL_CLOSED, author, no poll, flag off | ≤ 5 (0 with the flag off) | 2 | 0 | 0 | the check runs after the visibility read, so it gives no oracle beyond GetPost |
| Viewer choice and redaction on timelines, GetPost, GetThread, ListBookmarks, W3 ListLikedPosts, W4 SearchPosts | **+0**: the one cached `userLikes` read these calls already make with `engagement` on (A3) | 0 | 0 | 0 | `polls` never ramps beyond `engagement` (as `bookmarks`) |
| GetPost of a closed poll with hidden counts (client, once per row) | as GetPost, 4 | 1 | 0 | 0 | |
| CreateUpload with a GIF | unchanged, 2 | 1 | 6 / 3.3 | 1 (idempotency TTL) | content type `image/gif` |
| FinalizeUpload with a GIF | unchanged Firestore, 5 | 1.7 | 5 / 2.7 | 0 | + 1 Class B full-object read (≤ 2 MiB, us-central1 → asia-south1, inside the GCS free egress), ≤ 0.5 s CPU decode, **2 Vision units** (sheet + thumbnail) |
| Eraser step `poll_votes` (the voter's account) | 1 per doc, min 1 | 1 | 0 | 1 per doc | ≤ 500 per page |
| Export section `poll_votes` | 1 per doc, min 1 | 1 | 0 | 0 | |
| Drafts | 0 | 0 | 0 | 0 | client only |

**Calls per DAU per day.** These are assumptions, to be replaced by W6-21 measurements.
| Call | Calls/DAU | Typical reads | Reads/DAU | Writes/DAU | Deletes/DAU |
|---|---|---|---|---|---|
| CreatePost with a poll (2 % of the 1.0 posts/DAU) | 0.02 | +0 | 0 | 0 | 0 |
| `VotePoll` | 0.3 | 3 | 0.9 | 0.9 | 0.3 (TTL, later) |
| GetPost of a closed poll | 0.1 | 1 | 0.1 | 0 | 0 |
| GIF upload (CreateUpload + FinalizeUpload; 10 % of the 0.2 images/DAU) | 0.02 × 2 | 2.7 per GIF | 0.05 | 0.12 | 0.02 |
| GIF plays (tap, full object from GCS, about 1 MB on average) | 0.3 | — | — | — | — |
| **Total W6** | **≈ 0.44 requests** | | **≈ 1.05** | **≈ 1.02** | **≈ 0.32** |

Effect on the quotas (additive):
- reads 249.8 per DAU, so the free reads run out at about **200 DAU** (was 201);
- writes 34.5 per DAU, out at about **580 DAU** (was 597);
- Vision 13.39 units per DAU-month (was 12.17), so the free 1,000 units run out at about **75 DAU** (was 82), and `VISION_MONTHLY_CAP` 10,000 is reached at about **747 DAU** (was 822). Past the cap, photos and GIFs alike become READY_UNSCREENED for established accounts or REJECTED (ADR-0005), and every upload is REJECTED in credit mode with `reject`;
- GCS egress 56 MB per DAU-month (was 47), so the free 100 GB runs out at about **1,786 DAU** (was 2,133).

**Wave total (W6 increment only; Stage 0 as configured, Vision cap 10,000):**
| DAU | Reads/day | Firestore INR/month | Vision INR | GCS egress + ops INR | Cloud Run INR | **W6 total INR/month** | Upper bound: autoplay in feeds (F10) |
|---|---|---|---|---|---|---|---|
| 300 | 315 | 0.3 (reads; writes and deletes inside the free quota) | **52** (365 units, all past the free 1,000) | 0.5 | 0 | **≈ 53** (polls ≈ 0.3, GIF ≈ 52) | ≈ 53 (egress inside the free 100 GB) |
| 1,000 | 1,050 | 4.2 (reads 1.1, writes 3.1) | 0 (the cap is already reached by photos; GIFs bring it forward) | 1.5 | 0 | **≈ 6** | ≈ 6 (total GCS egress about 96 GB, at the edge of the free 100 GB) |
| 3,000 | 3,150 | 12.7 (reads 3.2, writes 9.2, deletes 0.3) | 0 (cap) | 315 (GIF egress 27 GB ≈ 311, ops 4.5) | 13 (requests 1.5, vCPU-s 11.2) | **≈ 342** (polls ≈ 22, GIF ≈ 320) | ≈ 1,690 (GIF egress ≈ 146 GB ≈ 1,664) |

- **Polls alone cost INR 0.3 / 4 / 22 a month** at 300 / 1,000 / 3,000 DAU. **GIFs are the cost line:** Vision at low DAU, egress at high DAU.
- **Credit window (ADR-0022, Vision cap 20,000 with `reject` until 2026-12-22):** at 1,000 DAU the GIFs' 1,220 units a month are paid (about INR 174/month, credit-funded). Nothing here depends on a credit-mode item after 2026-12-22.
- **No new GCP service, no new Scheduler job, no fixed cost.**
  - Storage: about 0.63 MB per DAU-month of GIF objects (190 MB a month at 300 DAU, inside the free 5 GB for years).
  - `pollVotes` docs: about 200 bytes each, with a TTL.
  - Drafts: 0 server bytes.

## Flags
| Flag (wire name) | Gates | Kill switch (`off` only; percent 0 and an empty allowlist are rollouts, `flag-rollout`) |
|---|---|---|
| `FEATURE_POLLS` (`polls`) | **Creating** a poll: CreatePost with `poll` → FEATURE_DISABLED `feature=polls`, 0 reads, checked after `content_disclosure` in the ADR-0010 D2 order. **Voting** needs `engagement` **on for the caller** (as Like does; FEATURE_DISABLED `feature=engagement`) **and** `polls` **not globally off** (`Registry.GloballyOff`, the ADR-0021 L-A pattern). Any viewer with `engagement` can therefore vote in an existing poll during a `polls` allowlist rollout, and the viewer's choice is always hydrated for exactly the callers allowed to vote. The client shows vote buttons only when `engagement` is in `enabled_features`; everyone else sees the total and "Voting isn't available" | `off`: no new polls and `VotePoll` refuses. Existing polls render with results revealed to everyone, since voting is impossible (proposal for W6-1) |
| `FEATURE_DRAFTS` (`drafts`) | client only: the Drafts button, the "Save post?" Save path, the Drafts screen's Unsent tab and autosave. Registered in config, `flags.NewRegistry`, Terraform and the ceilings so `GetMe` reports it (as `ui_shell`) | `off`: the drafts UI is hidden and the old leave prompt returns. **Rows already on devices are not erased** (no server path); they reappear if the flag returns |
| `FEATURE_GIF` (`gif`) | CreateUpload with `image/gif` → FEATURE_DISABLED `feature=gif` (0 reads, before any Firestore access). CreatePost attaching a GIF media doc while `gif` is off → the same answer, **but only after `LoadForPost`'s media reads inside the transaction** (≤ 4, as an unready-media refusal costs today), because the content type is known only there. That is unlike the 0-read D2 checks. W6-1 decides whether to keep this second gate or gate GIFs at CreateUpload only (a GIF uploaded just before a kill switch could then still be posted). SchedulePost with a GIF → VALIDATION (F10) | `off`: no new GIF uploads (and, with the second gate, no new GIF posts); existing GIF posts keep rendering. `DEGRADED_MODE=nomedia` already stops all uploads |

- **Ceilings.** `scripts/promotion/flag-ceiling.json` gets `POLLS`, `DRAFTS` and `GIF` in `flags`, with dev entries `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}` and **no prod raise**. **That file is founder-gated (CODEOWNERS): W6-4's PR needs your review.**
- **Terraform.** `feature_polls*`, `feature_drafts*` and `feature_gif*` go in `envs/dev` and `envs/prod`, default `off` (copy `feature_bookmarks`). Nothing is applied.
- **Ramp order.**
  - `polls` never ramps ahead of `engagement` (viewer state comes from `userLikes`).
  - `gif` never ramps ahead of `media`.
  - `drafts` needs `posts` only.
  - **100 % rule (ADR-0021 L-1):** `FEATURE_POLLS` and `FEATURE_GIF` leave `off`, even for the allowlist, only after 100 % of traffic is on a revision that stores and enforces them. Otherwise proto3 drops `CreatePostRequest.poll` on an old revision and the post goes out without its poll. The client sends poll fields only when `enabled_features` lists `polls`, and runs an **echo check** after CreatePost: if `post.poll` is missing, it warns "Your poll was not added" and offers delete-and-repost.

## Abuse & security surface
- **New writes:**
  - `VotePoll` (signed-in, verified email, ACTIVE, App Check monitor-only, so not counted as a control);
  - poll fields on CreatePost;
  - `image/gif` uploads.
- **No new public reads.** Poll data rides on existing PostViews; there is no voter list and no poll search.
- **Vote integrity:**
  - **One vote per account:** the `pollVotes/{postId}_{uid}` `Create` precondition inside the vote batch. Two concurrent votes by one account (same or different choice) commit at most once, and the counts stay exact because the batch is atomic.
  - **Sybil voting:** bounded by the verified-email gate, the per-account caps below and the new-account limits. Residual: a ring of verified accounts can skew a poll. Polls are informal, and the copy never presents them as binding.
  - **Votes on a REPOST id act on the original** (the ADR-0018 rule).
  - Visibility is checked as GetPost: blocked either way, hidden, or author not ACTIVE → NOT_FOUND, the same bytes as a missing post.
  - **No result oracle:** a refusal happens only after the visibility read, and hidden counts are redacted per viewer in the converter (A4). The total is public by design (F3).
  - **The author never sees voters**; no RPC lists them. Logs never pair a uid with a choice: the `poll_vote` line carries `uid_hash`, `outcome` and `fs_*`, not the choice.
- **Rate limits and caps** (config, rule 11; in memory, so effective × 3 instances):
  | Config | Default | Effective |
  |---|---|---|
  | `RATE_LIMIT_POLL_VOTE_PER_MIN` | 30 | 90/min |
  | `POLL_VOTES_PER_DAY` (`ratelimit.DailyCap`, `limit_name` `poll_votes_daily`; 0 Firestore ops) | 300 (new accounts 50 within `QUOTA_NEW_ACCOUNT_WINDOW`) | ≤ 900/day |
  | Poll creation | the posts daily quota (100, new accounts lower) and the CreatePost bucket; no extra cap | — |
  | GIF uploads | the media quota (20/day, 5 for new accounts) and the CreateUpload bucket; one GIF per post | — |
- **Poll text:** choices follow ADR-0010 D9 (NFC, no control or bidi formatting characters, code-point count). Mentions and hashtags in choices are **not** parsed, so choices send no notifications and create no hashtag entries. Reports and takedowns of the post cover its poll, and a hidden post hides its poll. The moderation review view must show the choices (W6-5).
- **GIF content:**
  - The magic bytes `GIF87a`/`GIF89a` must match the declared type.
  - **Decompression-bomb guards** run before the decode: bytes, frame count, logical screen, frames × area, one decode at a time per instance, a time limit (A10).
  - **Frame-sampled SafeSearch** (F11).
  - The thumbnail is screened as today.
  - GIFs are never accepted for avatars or banners.
  - Objects are served from the GCS domain, not our origin, so a polyglot file cannot script our pages.
  - A GIF comment extension may carry text; the frame sampler ignores it, and stripping it is an A10 question.
- **Drafts (privacy on shared devices):**
  - Drafts are unencrypted rows in the app's local database (sqlite / IndexedDB on web), keyed by uid.
  - Another account on the device never reads them.
  - Anyone with the device or the OS account can.
  - They are wiped on account deletion from this device, and "Delete all" is offered. F7 decides sign-out.
  - **The account export cannot include drafts**, because the server never sees them; the Settings privacy copy says so.
  - **Draft text is never logged or sent to Crashlytics.**
- **Lifecycle (`CLAUDE.md` rule 10, ADR-0011):**
  - `pollVotes` gets an eraser step, an export section and a T11 row **in the same PR as `VotePoll`** (the T11 guard fails `make ci` otherwise).
  - Vote docs of other users on a deleted poll post hold no uid of the deleted author. They expire by TTL at `closesAt + POLL_VOTE_TTL_AFTER_CLOSE` (30 days), so no residue lives longer than 37 days.
  - `userLikes.pollVotes` goes with `userLikes` in the existing `engagement` eraser step.
  - Counts are anonymous (F6).

## Dependencies & open questions
**Dependencies:**
- F1–F12 above (defaults allow work to start).
- W3 ADR-0024 adds `posts.hasMedia` on every create path (W3-7); GIF posts set it like photo posts, and W3's Media tab shows them.
- W4 SearchPosts uses `posts.HydrateViewer` and the converter, so polls in search results are covered with no W4 change.
- No capture blocks this plan. **UNKNOWN until captured** (optional; X-like defaults until then):
  - the poll card in a feed (before and after voting, closed);
  - the GIF picker's device tab;
  - the Unsent posts tab with rows;
  - what Save in "Save post?" does.

**Shared files that must serialise with W3, W4 and W5** (merge one PR at a time):
- **Backend config:** `backend/pkg/platform/config/config.go`, `config_test.go`, `flags.NewRegistry`, `backend/internal/apiserver/{apiserver.go, ratelimit_config.go, engagement_wiring.go, media_wiring.go}`.
- **Lifecycle wiring:** `apiserver/lifecycle_wiring.go`, `lifecycle_wiring_test.go` (the pinned eraser order) and `lifecycle_collections_guard_test.go` (T11 rows).
- **Protos:** `proto/dzeroth/posts/v1/posts.proto` (field numbers and **CreatePost**), `common/v1/common.proto` (`ErrorReason` numbers), `engagement/v1/engagement.proto`, `media/v1/media.proto` (W3-5 adds `MEDIA_PURPOSE_BANNER`).
- **CreatePost and viewer state:** `backend/internal/posts/{service_create.go, repo_create.go, convert.go, api.go (ViewerSet, HydrateViewer)}` (W3-7's `hasMedia` touches CreatePost); `backend/internal/media/{service.go, finalize.go}` (W3-5).
- **Gate files (founder review):** `firebase/firestore.indexes.json` + `firebase/field-overrides.ack` (W3-2, W4-9) and `scripts/promotion/flag-ceiling.json` (W3-4, W4-3, W5).
- **Terraform:** `envs/{dev,prod}` variables and env, and `modules/firestore/variables.tf` `ttl_fields`.
- **Client:**
  - `app/lib/features/posts/presentation/composer_screen.dart` and `bloc/composer_cubit.dart`;
  - `app/lib/shared/widgets/post_card.dart` (W3 pinned label, W4 hashtag tap);
  - `app/lib/core/storage/app_database.dart` (schema version: any wave adding a table);
  - `app/lib/core/router/app_router.dart`;
  - the media `attachments_cubit.dart`, `image_picker_service.dart` and `image_processor.dart`.
- **Docs:** `docs/code-map.md`, `docs/ui-catalog.md`.

**Questions for @architect (W6-1; the ADR decides and states each budget):**
- **A1. Poll storage.**
  - **Default:** a `poll` map on `posts/{postId}`: `options[]` (labels), `durationMin`, `closesAt`, `counts.{0..3}`, `total`. It costs 0 extra feed reads, and the counts share the doc's rule-3 budget with `likeCount` and `replyCount` (sharding trigger in the stage-ladder table).
  - Alternative: `polls/{postId}`, at +1 read per poll row on every list. That is N+1 under rule 6 unless batched and cached.
- **A2. Who owns votes.**
  - **Default: engagement.** `EngagementService.VotePoll`, the `pollVotes/{postId}_{uid}` collection `{postId, uid, choice, createdAt, expireAt}`, counters staged through a new `posts.EngagementWriter.StagePollVote`, and the choice in `userLikes`. This is the Like path with one more field.
  - Alternative: posts owns everything, but it would then write `userLikes`, which engagement alone writes today.
- **A3. The viewer's choice.**
  - **Default:** `userLikes.pollVotes`, strings `"<postId>:<index>"`. The vote batch writes it as a **Set-merge `ArrayUnion`**, which needs no read and works when the user has no `userLikes` doc yet; a plain `Update` would fail on a missing doc. It is **trimmed lazily** to the newest `POLL_VIEWER_VOTES_KEPT` (500) on a later read, as `recent` is (`TrimLikes`). `ViewerSet.PollChoice(p)` uses `viewerID`, so REPOST rows resolve to the original.
  - +0 reads. `HydrateViewer` already reads `userLikes` with `engagement` on, and `polls` never ramps beyond it.
  - A trimmed entry only loses the check mark on an old poll; the vote doc remains the one-vote authority.
- **A4. Where redaction happens.** In the posts converter (`ToView` with the `ViewerSet`), so every PostView producer is covered. Name them in a guard test:
  - CreatePost, GetPost, GetThread;
  - home and user timelines;
  - ListBookmarks;
  - W3 ListLikedPosts;
  - W4 SearchPosts;
  - the `VotePoll` response.
- **A5. The vote write.**
  - **Default:** one batch: `Create` the vote doc, `Update` the post with `Increment(counts.<i>)` + `Increment(total)` (Exists precondition), and the `userLikes.pollVotes` Set-merge `ArrayUnion` (A3). No transaction reads the hot post doc.
  - Closed and author checks read the (cached) post with server time before the batch. The race window, a vote committed a few hundred ms after `closesAt`, is accepted and documented.
- **A6. Errors.** New `ERROR_REASON_POLL_CLOSED` and `ERROR_REASON_ALREADY_VOTED` (FAILED_PRECONDITION; ALREADY_VOTED carries `metadata["choice"]` for the caller's own vote), vs reusing VALIDATION metadata. The author's own vote → VALIDATION `field=post_id`.
- **A7. Repost and quote rows.**
  - **Default:** `EmbeddedPost.poll` carries the definition (choices, `closes_at`) **without counts**, since an embed is a frozen snapshot. Repost and quote rows render a compact "Poll · N choices · ends …" that opens the original through GetPost (live counts).
  - Alternative: hydrate the original's poll on repost rows (+1 cached post read per row).
- **A8. `requestHash`.** Append `|poll=<n>:<sha256 of the NFC labels joined by \x1f>|dur=<minutes>` only when a poll is present, so CreatePost retries across the deploy hash the same (the ADR-0021 pattern).
- **A9. Indexes.**
  - A `fieldOverride` exempting `posts.poll` from single-field indexing: counters churn, and nothing queries them. That needs `firestore.indexes.json` + its `field-overrides.ack` hash, **both founder-gated**.
  - `pollVotes` keeps its automatic `uid` index for the eraser query; no composite index.
  - A TTL policy on `pollVotes.expireAt` (Terraform `ttl_fields` `poll_votes_expire_at`).
- **A10. GIF in media.**
  - `image/gif` allowed for `MEDIA_PURPOSE_POST` only, with extension `gif`.
  - The thumbnail stays JPEG or WebP: a new `UploadItem.thumb_content_type = 8`, or the rule "a GIF's thumbnail is `image/jpeg`".
  - The sniffer learns `GIF87a`/`GIF89a`.
  - Sampling guards: bytes ≤ 2 MiB; ≤ 300 frames; logical screen ≤ 1,280 × 1,280; frames × area ≤ 50 MP; a per-instance semaphore of 1; a 2 s deadline; refuse rather than partially screen.
  - Vision by `Image.Content` for the sheet and by URI for the thumbnail. The Vision counter counts 2 units.
  - **Verify Vision's GIF behaviour against the docs.**
  - The ADR PR adds a dated amendment note to ADR-0005 (new content type, sampling).
- **A11.** The three `stage-ladder` rows above, added in the ADR PR, and the `firestore-data-model` rows for `posts.poll`, `pollVotes` and `userLikes.pollVotes`.

## Milestones
1. **M6.1 Contract:** W6-1 (ADR, accepted by your merge), W6-2 and W6-3 (protos, gate-file entries).
2. **M6.2 Flags and config:** W6-4.
3. **M6.3 Polls backend:** W6-5, W6-6, then W6-7 + W6-8 (**one PR**).
4. **M6.4 GIF backend:** W6-9, W6-10.
5. **M6.5 Client:** W6-11 to W6-16. W6-14 (the drafts store) starts now.
6. **M6.6 Verify and roll:** W6-17 to W6-22. Dev allowlist only; prod waits for the held prod apply (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.2) and your MVP launch decision.
7. **M6.7 (conditional on F9):** W6-23, W6-24.

| ID | Ticket | Owner | Size | Depends | Runs alongside W3/W4/W5? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| W6-1 | ADR-0029 "Composer extras remainder: polls, local drafts, device GIFs" | architect | M | — | **yes, start now** (new file) | In review (PR #473) |
| W6-2 | Proto: poll messages in `posts.proto`, `VotePoll` in `engagement.proto`, `ErrorReason`s; `posts.poll` fieldOverride + ack; data-model rows | architect | M | W6-1 drafted | `posts.proto` and `common.proto` numbers: one PR at a time | In review (PR #473) |
| W6-3 | Proto: `media.proto` GIF content type and thumbnail content type | architect | S | W6-1 drafted | after W3-5's `media.proto` change, or rebase | In review (PR #473) |
| W6-4 | `make proto`; `FEATURE_POLLS` / `FEATURE_DRAFTS` / `FEATURE_GIF`, config, rate limits, daily cap, ceilings, Terraform vars, TTL field | backend-developer | M | W6-2, W6-3 | shared config, ceiling and Terraform files: one PR at a time | In review (PR #484) |
| W6-5 | posts: CreatePost with a poll; `Post.poll` and `EmbeddedPost.poll` converters; `requestHash` suffix; moderation view | backend-developer | M | W6-4 | `service_create.go`, `convert.go`: rebase on W3-7 | Done (#497) |
| W6-6 | posts + engagement: viewer choice (`userLikes.pollVotes` → `ViewerSet.PollChoice`) and per-viewer redaction in the converter | backend-developer | M | W6-5 | `posts/api.go` (`ViewerSet`, `HydrateViewer`) | Done |
| W6-7 | engagement: `VotePoll` (visibility, closed/author checks, the vote batch, natural-key replay, caps) | backend-developer | M | W6-6 | yes (engagement module); **same PR as W6-8** | In review |
| W6-8 | engagement: `pollVotes` lifecycle (eraser, export, T11 row, pinned order), TTL, runbook section | backend-developer | S | W6-7 (same PR) | `lifecycle_wiring_test.go`, guard test: one PR at a time | In review |
| W6-9 | media: accept `image/gif` for post media (validation, sniffing, publish, flag gate, one per post) | backend-developer | M | W6-4 | `media/service.go`, `finalize.go`: after W3-5 | In review |
| W6-10 | media: frame-sampled SafeSearch for GIFs, with decode guards | backend-developer | M | W6-9, F11 | yes (media module) | Open |
| W6-11 | Composer toolbar: Poll and GIF buttons, mutual-exclusion rules, flag gates | frontend-developer | S | W6-4 | `composer_screen.dart`: one PR at a time | In review |
| W6-12 | Poll builder in the composer (choices, length, remove, echo check) | frontend-developer | M | W6-11 | `composer_cubit.dart` | Done (#513) |
| W6-13 | Poll card (vote, results, closed, author view, compact embed) + `VotePoll` repository | frontend-developer | M | W6-2 (generated Dart), W6-7 for the dev check | `post_card.dart`: rebase on W3/W4 | Done (#510) |
| W6-14 | Drafts store: drift table (schema v9), `DraftsRepository`, autosave, account-deletion wipe | frontend-developer | M | — | **yes, start now**; `app_database.dart` schema bump: one PR at a time | In review |
| W6-15 | Drafts UI: Drafts button, "Save post?", Drafts screen (Unsent posts \| Scheduled), Edit mode | frontend-developer | M | W6-14, W6-4 | `app_router.dart`, `composer_screen.dart` | In review |
| W6-16 | GIF from the device: pick, check, thumbnail, upload; GIF badge and tap to play | frontend-developer | M | W6-9 | media client files | In review |
| W6-17 | Backend tests: polls (flag matrix, vote matrix, concurrency, redaction, budgets, lifecycle) | tester | M | W6-8 | yes | Open |
| W6-18 | Backend tests: GIF (sniffing, caps, guards, bombs, Vision units, flag) | tester | S | W6-10 | yes | In review (PR: test/ui-w6-18-gif-tests; defect D-1 filed, see docs/reviews/test-report-w6-gif.md) |
| W6-19 | Client tests: composer, poll card, drafts and GIF across the responsive matrix | tester | M | W6-12 to W6-16 | yes | In review (this PR; report `docs/reviews/test-report-w6-client.md`) |
| W6-20 | Security review: vote integrity, result oracle, GIF moderation and bombs, drafts on shared devices | security-auditor | S | W6-7, W6-10, W6-15 | yes | Open |
| W6-21 | Cost report: `cost-model.md` rows, emulator load smoke (hot poll, GIF finalize) | sre-performance | S | W6-7, W6-10 | yes | Open |
| W6-22 | Dev rollout: targeted Terraform plan, fieldOverride and TTL, allowlist, smoke | production-deployer | S | W6-17 to W6-21, ADR merged | serialise dev applies with W3/W4/W5 | Open |
| W6-23 | *(conditional on F9: terms verified in writing)* GIF picker ADR addendum: provider seam, key handling, cache, attribution | architect | S | F9 | yes | Open |
| W6-24 | *(conditional on W6-23)* GIF search picker behind `FEATURE_GIF_SEARCH` | frontend-developer | M | W6-23, W6-16 | yes | Open |

Order:
1. W6-1, with W6-14 in parallel (no backend dependency).
2. W6-2 and W6-3.
3. W6-4.
4. W6-5 → W6-6 → W6-7 + W6-8 (one PR) ‖ W6-9 → W6-10.
5. Client: W6-11 → W6-12, W6-13; W6-14 → W6-15; W6-16.
6. W6-17 to W6-22, with W6-20 and W6-21 before any flag leaves `off` in dev.

**Definition of done per ticket:**
- Backend: Go unit tests plus emulator integration (`make test-int`, `budgettest.Assert` on every RPC); coverage on `internal/` ≥ 70 %.
- Client: widget tests in light and dark at 360 / 600 / 1200 via `test/support/theme_harness.dart`, and text scale 1.0 / 1.3 / 2.0, for every new screen or widget. Pixel goldens are deferred (B-01).
- `make ci` green.
- `docs/code-map.md` / `docs/ui-catalog.md` updated.
- This table's Status updated in the PR.

## Tickets

### W6-1 — ADR "Composer extras remainder: polls, local drafts, device GIFs"  [owner: architect] [size: M] [depends: —]  Status: In review (PR #473)
- **Description.** ADR-0029 (`docs/adr/0029-composer-extras-remainder-polls-drafts-gif.md`; 0024 and 0025 went to W3, 0026 to W8, 0027 to W7, 0028 to W4). It covers:
  - the poll model and the vote path (A1–A9);
  - F1–F6 and F10–F12 as founder items with options, defaults and INR at 300 / 1,000 / 3,000 DAU citing `cost-model.md`;
  - the per-RPC table and the rate limits above;
  - the lifecycle of `pollVotes` and its TTL;
  - GIF in media and its moderation (A10, F11), after **verifying in Google's Vision documentation** how animated GIFs are screened;
  - drafts as a client-only design with its privacy notes (F7, F8);
  - the stage-ladder rows (A11).

  In the same PR:
  - **a dated note on ADR-0021 D4:** polls and schedules are not combined (F5); `SchedulePostRequest` is unchanged;
  - **a dated amendment note on ADR-0005:** `image/gif` and frame sampling;
  - the `stage-ladder` rows;
  - the `firestore-data-model` rows.

  The decision text of ADR-0005 and ADR-0021 is unchanged.
- **Acceptance criteria.**
  - Given the ADR, when the founder reads it, then F1–F6 and F10–F12 each have options, a default and a cost line, and the F2 rule-4 bend is stated as needing explicit approval (ADR-0018 precedent).
  - Given A9, then the ADR names the exact `firestore.indexes.json` entry and the `field-overrides.ack` step as founder-gated.
  - Given the Scheduler, then the ADR restates "no new job; 2 of 3 spoken for".
  - Given F11, then the ADR quotes the verified Vision behaviour, or records it as unverified and picks (b).
- **Test notes.** Docs only; `code-reviewer` checks the seam and trigger lines.
- **Observability.** The ADR lists the log fields: `poll_vote` (`outcome`, `uid_hash`, `fs_reads`, `fs_writes`, `contention`), `gif_screen` (`frames`, `sampled`, `units`, `decode_ms`, `refused_reason`), and the CreatePost `has_poll` field.
- **Budget.** The ADR's table is the source for W6-5 to W6-10.
- **Flag.** None (docs); it names the three flags and their ceilings.
- **Seam.** `posts.EngagementWriter.StagePollVote`, `posts.ViewerSet.PollChoice`, `engagement.Service.VotePoll`, the `media` content-type table and `Moderator`, and the client `DraftsRepository` and `GifSource`.
- **Runs alongside W3/W4/W5:** yes.

### W6-2 — Poll contract  [owner: architect] [size: M] [depends: W6-1 drafted]  Status: In review (PR #473)
- **Description.** Additive changes only, with numbers as of `main` d2ff011 (re-check at PR time):
  - **`posts.proto`:**
    - `message PollChoice { string label = 1; int64 votes = 2; /* 0 when hidden */ }`;
    - `message Poll { repeated PollChoice choices = 1; google.protobuf.Timestamp closes_at = 2; int64 total_votes = 3; bool results_visible = 4; bool closed = 5; }`;
    - `message PollDraft { repeated string choices = 1; int32 duration_minutes = 2; }`;
    - `CreatePostRequest.poll = 10` (PollDraft), `Post.poll = 21`, `EmbeddedPost.poll = 10` (no counts), `PostView.viewer_poll_choice = 7` (int32: 0 = not voted, 1–4 = choice + 1).
  - **`engagement.proto`:** `rpc VotePoll(VotePollRequest{idempotency_key, post_id, choice_index}) returns (VotePollResponse{dzeroth.posts.v1.PostView post})`, with a budget comment.
  - **`common.proto`:** `ERROR_REASON_POLL_CLOSED` and `ERROR_REASON_ALREADY_VOTED` at the next free numbers when the PR opens (18 and 19 today: W3-25a took 17 for `PROTECTED_ACCOUNT`), if A6 keeps them.
  - **`firebase/firestore.indexes.json`:** a `posts.poll` fieldOverride `indexes: []`, plus the `field-overrides.ack` hash (**gate files**).
  - The `firestore-data-model` rows.
  - **As done (2026-10-30, ADR-0029 D13):** `main` had moved, so the numbers taken are `CreatePostRequest.poll = 10`,
    `Post.poll = 21`, `EmbeddedPost.poll = 10`, **`PostView.viewer_poll_choice = 8`** (7 is `withheld`, W3-41a),
    **`ERROR_REASON_POLL_CLOSED = 19`, `ERROR_REASON_ALREADY_VOTED = 20`** (18 is `CANNOT_MESSAGE`, W7), plus
    `MediaRef.content_type = 8` (W6-3, D10). The fieldOverrides (`posts.poll` **and `userLikes.pollVotes`**) with
    their ack hashes and the data-model rows are follow-ups FU-1 and FU-4 of ADR-0029 (gate files and `.claude/` were
    not edited in the ADR PR); generated code is W6-4.
- **Acceptance criteria.**
  - Given `make proto`, then Go and Dart generate, `buf lint` passes and `buf breaking` against `main` is clean.
  - Given each RPC and field comment, then it states the worst and typical reads, the limits (F4) and the redaction rule (F3).
- **Test notes.** `buf breaking`; the promotion fieldOverrides check passes with the ack.
- **Observability.** —
- **Budget.** Copied from W6-1.
- **Flag.** None (contract); the comments name `polls` as the FEATURE_DISABLED metadata.
- **Seam.** `Poll` is a message (choices with images or a "poll ended" state can be added later); `viewer_poll_choice` is per-viewer and never cached across viewers.
- **Runs alongside W3/W4/W5:** the field and `ErrorReason` numbers collide textually with any other wave's proto PR, so one PR at a time.

### W6-3 — Media contract for GIFs  [owner: architect] [size: S] [depends: W6-1 drafted]  Status: In review (PR #473)
- **Description.** In `media.proto`:
  - the `UploadItem.content_type` comment allows `image/gif` (POST only);
  - add `string thumb_content_type = 8` (`image/jpeg` or `image/webp`; empty = same as `content_type`, today's behaviour), or document the fixed JPEG rule per A10;
  - update the CreateUpload and FinalizeUpload budget comments (Class B full read and Vision units for a GIF).
  - **As done (2026-10-30, ADR-0029 D10):** `UploadItem.thumb_content_type = 8` was chosen over the fixed JPEG rule,
    and `common.v1.MediaRef.content_type = 8` was added so clients badge and play a GIF without parsing the URL (posts
    copy it from the media claim).
- **Acceptance criteria.** Given `make proto`, then the code generates and `buf breaking` is clean; an old client that sends no `thumb_content_type` behaves exactly as today.
- **Test notes.** `buf breaking`.
- **Observability.** —
- **Budget.** Copied from W6-1.
- **Flag.** None (contract); the comment names `gif`.
- **Seam.** The content-type table stays inside `media`; posts never sees a MIME type except through `LoadForPost`'s claim.
- **Runs alongside W3/W4/W5:** after W3-5's `MEDIA_PURPOSE_BANNER` change, or rebase.

### W6-4 — Generate, flags, config, ceilings, Terraform  [owner: backend-developer] [size: M] [depends: W6-2, W6-3]  Status: In review (PR #484)
- **Description.**
  - Register `FEATURE_POLLS`, `FEATURE_DRAFTS` and `FEATURE_GIF` in `config.go` and `flags.NewRegistry` (follow `FEATURE_BOOKMARKS`; `drafts` follows `ui_shell`: no RPC guard).
  - Config, added to `config_test.go`'s env list with range checks: `POLL_MAX_CHOICES` 4, `POLL_CHOICE_MAX_CODEPOINTS` 25, `POLL_MIN_DURATION` 5m, `POLL_MAX_DURATION` 168h, `POLL_VOTE_TTL_AFTER_CLOSE` 720h, `RATE_LIMIT_POLL_VOTE_PER_MIN` 30, `POLL_VOTES_PER_DAY` 300, `POLL_VOTES_PER_DAY_NEW_ACCOUNT` 50, `POLL_VIEWER_VOTES_KEPT` 500, `GIF_MAX_FRAMES` 300, `GIF_MAX_EDGE` 1280, `GIF_MAX_FRAME_AREA_SUM` 50,000,000.
  - Map the `VotePoll` bucket and the `poll_votes_daily` cap in `ratelimit_config.go`.
  - `flag-ceiling.json`: `POLLS`, `DRAFTS` and `GIF` at dev allowlist 3 (**founder-gated file**).
  - Terraform: `feature_polls*`, `feature_drafts*`, `feature_gif*` and the config vars in `envs/dev` and `envs/prod`, default `off`, plus the `ttl_fields` entry `poll_votes_expire_at` (`collection = "pollVotes"`, `field = "expireAt"`) in `modules/firestore/variables.tf`. Nothing is applied.
  - Stub handlers: `VotePoll` → FEATURE_DISABLED or Unimplemented.
- **Acceptance criteria.**
  - Given `FEATURE_POLLS` unset, when CreatePost carries a poll, then FAILED_PRECONDITION `FEATURE_DISABLED` `feature=polls` with 0 reads; and `VotePoll` → FEATURE_DISABLED with 0 reads.
  - Given `allowlist` with a uid, then `GetMe.enabled_features` contains `polls` / `drafts` / `gif` for that uid only.
  - `check-flag-registry.sh` passes; `guard_test.go` sees `VotePoll` under a rate bucket and the daily cap.
  - Out-of-range config fails startup.
- **Test notes.** Flag modes off / allowlist / percent / on; config bounds; `terraform fmt -check` and `validate`.
- **Observability.** Startup logs the flag modes (existing).
- **Budget.** 0 reads on the rejection paths.
- **Flag.** Adds the three flags (default `off`; dev ceiling allowlist 3).
- **Seam.** Limits live in config (rule 11), never in code.
- **Implementation notes (W6-4, as built).**
  - ADR-0029 supersedes this ticket's numbers: dev ceilings are allowlist **6** like every other flag since #463 (ADR-0029 D12 and the text above say 3); `PostView.viewer_poll_choice = 8`, `ErrorReason` 19 and 20.
  - FU-1 and FU-2 are in this PR: fieldOverrides `posts.poll` and `userLikes.pollVotes` with the new `field-overrides.ack` hash, the `poll_votes_expire_at` TTL entry (Terraform, not applied), `feature_polls*`, `feature_drafts*` and `feature_gif*` vars, and the three ceilings.
  - Config values live in `config/composer.go` (`config.Composer`), with hard ceilings the ADR does not state (code points <= 100, max duration <= 30 days, vote TTL 24 h to 90 days, kept votes <= 1,000, GIF frames <= 1,000, edge <= 4,096, area sum <= 200 million); the Terraform side carries the flag vars only (as W4-3), the numbers keep their Go defaults.
  - `POLL_VOTES_PER_DAY_NEW_ACCOUNT` (50) is loaded and validated but not enforced: the ratelimit interceptor has no account-age signal, so W6-7 must apply it in the service (or an ADR note must drop it).
  - Skeletons: `VotePoll` answers FEATURE_DISABLED per the D6 step 2 gate and Unimplemented after it; CreatePost with a poll answers FEATURE_DISABLED `feature=polls` when off and Unimplemented when on (W6-5 replaces it), so a poll is never silently dropped.
- **Runs alongside W3/W4/W5:** logic yes. These shared files conflict textually with W3-4, W4-3 and W5's flag ticket, so merge one at a time: `config.go`, `apiserver.go`, `ratelimit_config.go`, `flag-ceiling.json`, the Terraform vars.

### W6-5 — CreatePost with a poll  [owner: backend-developer] [size: M] [depends: W6-4]  Status: Done (#497)
- **Description.**
  - Validate `CreatePostRequest.poll` (F4): 2–`POLL_MAX_CHOICES` choices, each 1–25 code points after D9 normalisation, distinct after NFC + case fold; duration within the min and max.
  - Reject the combinations: with media, reply, quote, or empty text → VALIDATION `field=poll`.
  - Check the flag in the D2 order (after `content_disclosure`).
  - The server computes `closesAt = createdAt + duration` from the Snowflake `createdAt` drawn inside the attempt (ADR-0010 D13), never from the client.
  - Store `poll {options, durationMin, closesAt, counts: {0..n-1: 0}, total: 0}` in the same post write (0 extra writes).
  - Append the A8 `requestHash` suffix.
  - Converters: `Post.poll` (counts redacted in W6-6; until then hidden for everyone except the author) and `EmbeddedPost.poll` without counts (`snapshotOf`).
  - The moderation review view and the takedown path include the choices.
- **Acceptance criteria.**
  - Given 2 choices and 1 day, then the stored `closesAt` equals `createdAt` + 24 h and the response echoes the poll.
  - Given 5 choices, a 26-code-point choice, duplicate "Yes"/"yes", 4 minutes or 8 days, then VALIDATION `field=poll` with 0 writes.
  - Given a poll plus a photo, a reply or a quote, then VALIDATION.
  - Given a retry with the same key and the same poll, then a replay; with a different poll, then IDEMPOTENCY_KEY_REUSED.
  - Given a CreatePost without a poll, then the `requestHash` equals today's.
- **Test notes.** Unit: the validation table, hash goldens. Emulator: create, replay, `budgettest` (+0 reads and +0 writes versus a root post). Flag matrix.
- **Observability.** A `has_poll` field on the existing CreatePost line; Error Reporting unchanged.
- **Budget.** +0 reads, +0 writes per CreatePost.
- **Flag.** `FEATURE_POLLS` (per caller).
- **Seam.** Poll validation in one `posts/poll.go` file, so the client mirror and the server share the rules (shared `testdata` fixture `poll_rules.json`).
- **Runs alongside W3/W4/W5:** `service_create.go` / `repo_create.go` also change in W3-7 (`hasMedia`), so rebase.
- **Implementation notes (W6-5, as built).**
  - `CreateInput.HasPoll` became `CreateInput.Poll *PollInput` (the service validates; W6-4's Unimplemented branch is gone). Limits come from `posts.Deps.Poll` (`PollLimits`, wired from `config.Composer`); the zero value rejects every poll.
  - The poll's own and combination rules run right after the `idempotency_key` format check and before `reply_policy` and media validation, so a poll with images, a reply, a quote or blank text is always `field=poll`; `field=poll` refusals read and write nothing.
  - Stored `poll` is `{options, durationMin, closesAt, counts {"0".."n-1"}, total}`, built per transaction attempt in `createAttempt`. `Embedded.Poll` is a frozen `{options, closesAt}` copied by `snapshotOf` (so quotes and reposts of a poll post carry the definition; the existing tombstone writer replaces the whole `embedded` map and so drops it).
  - Converter: `pollToProto(p, viewer, now)` is hidden by default (votes 0, `results_visible` false, real `total_votes`) and shows counts when closed or `viewer == author`. `ToView` and the new `ToProtoForViewer` (used by the CreatePost response) pass the viewer; plain `ToProto` has none and hides. `closed` uses `time.Now()` (no clock seam yet). The cached `*Post` is never written. **W6-6 adds** the "viewer voted" rule, the `FEATURE_POLLS` globally-off rule, `viewer_poll_choice` (also cleared in `ApplyWithheld`, which today rebuilds `Post` but leaves `PostView.viewer_poll_choice` alone) and a clock.
  - Moderation: `moderation.Evidence.PollChoices` (labels only; `evidence.pollChoices`, omitempty) for a POST report and, for a REPOST report, the original's frozen labels; `opsctl reports show` prints `evidence poll choices`. Export: the author's posts section gains `poll {choices, closesAt, counts, total}` (ADR-0029 D8).
  - W6-7 note: `Cache.AdjustCounts` shallow-copies `Post`, so every cached copy shares one `*Poll`; after a committed vote build a NEW `Poll` with fresh `Counts` for the cache, never mutate in place.
  - W6-7 note: increment a vote with `firestore.FieldPath{"poll","counts",strconv.Itoa(i)}` and `{"poll","total"}`, not a dotted string (the keys are numeric strings).

### W6-6 — Viewer choice and per-viewer redaction  [owner: backend-developer] [size: M] [depends: W6-5]  Status: Done
- **Description.**
  - engagement: `LoadUserLikes` also returns `pollVotes`.
  - posts: `ViewerSet` gains `pollChoice map[string]int` and `PollChoice(p)`, keyed by `viewerID`.
  - `HydrateViewer` is unchanged in shape (one cached `userLikes` read); polls need `engagement` on.
  - Redaction in the posts converter:
    - `results_visible = closed || viewer is author || viewer voted`;
    - per-choice `votes` are 0 when not visible; `total_votes` always shown;
    - `closed = now ≥ closesAt` by server time;
    - with `FEATURE_POLLS` globally off, results are visible to everyone (no voting is possible).
  - `viewer_poll_choice` is set from the `ViewerSet`.
  - A guard test lists every PostView producer (A4) and fails if one bypasses the converter.
- **Acceptance criteria.**
  - Given a viewer who has not voted on an open poll, then the votes are 0 and `total_votes` is real.
  - Given the author, then the votes are real.
  - Given the poll closed, then the votes are real for everyone.
  - Given a REPOST row of a poll the viewer voted in, then `viewer_poll_choice` is set (original id).
  - Given `engagement` off for the viewer, then no `userLikes` read, per-choice counts hidden, and `viewer_poll_choice` 0. Such a viewer also cannot vote (W6-7 step 1), so "voted but shown as not voted" cannot happen.
  - Given home, user timeline, GetPost, GetThread and ListBookmarks, then each applies the same rule (one table test).
- **Test notes.** `budgettest`: +0 reads on every list; a byte-equality check that hidden counts are identical whether the real count is 0 or 57.
- **Observability.** —
- **Budget.** +0 reads.
- **Flag.** `FEATURE_POLLS` (the GloballyOff rule above); `engagement` for hydration.
- **Seam.** `posts.ViewerSet` and the converter are the only places that know the rule; timeline, engagement and search call them.
- **Runs alongside W3/W4/W5:** `posts/api.go` is read by W4 (`HydrateViewer`); W3-10's ListLikedPosts must use the converter (stated in the guard test).
- **Implementation notes (W6-6, as built).**
  - `ViewerSet` gained `pollChoice map[string]int` and `pollsOff`; `WithPollVotes(entries)` parses `"<postId>:<index>"` (malformed or out-of-range entries skipped), `WithPollsGloballyOff()` marks the set, `PollChoice(p)` resolves a REPOST row to the original. `BookmarksOnly()` drops the choices and keeps the polls-off mark. `engagement.UserLikes.PollVotes` and `likesState.pollVotes` ride on the same `LoadUserLikes` read (+0 reads); the like, repost and bookmark cache updates keep them.
  - `HydrateViewer` sets the polls-off mark from `GloballyOffChecker` before its early returns, so a viewer with `engagement` off still sees results while `FEATURE_POLLS` is off for everyone (no flag read costs a Firestore op). A `FlagChecker` without `GloballyOff` never marks it.
  - Converter: `pollToProto(p, vs, viewer, now)`; `ToViewAt(p, vs, viewer, now)` is the clock seam (`ToView` calls it with `time.Now()`); `PostView.viewer_poll_choice` = index + 1, set from the ViewerSet for a REPOST row too; `ApplyWithheld` clears it. A PROTECTED embed already loses `embedded.poll` through `ApplyEmbedState`.
  - Surfaces: one rule table per producer (voted, not voted, author, closed, engagement off, polls globally off) through the real `flags.Registry`: GetPost and GetThread (`posts/poll_view_test.go`), home and user timelines (`timeline/poll_viewer_test.go`), ListBookmarks and ListLikedPosts (`engagement/poll_lists_test.go`). SearchPosts shares `HydrateViewer` + `ToView` and is covered by the guard only. All production `FlagChecker`s are the `*flags.Registry`, so the globally-off mark reaches every producer.
  - Guard: `TestPollConverterGuard_Repo` (posts package) names the producers (GetPost and GetThread, timelines, SearchPosts, ListBookmarks, ListLikedPosts, CreatePost via `ToProtoForViewer`) and fails on a `PostView`/`Poll` literal outside the converter or a plain `ToProto` call. W6-7 adds the `VotePoll` response to it.
  - Not done here (W6-7): the `userLikes.pollVotes` write and its trim to `POLL_VIEWER_VOTES_KEPT`, the cache update after a vote, and the VotePoll response view. The read side does not trim.

### W6-7 — `VotePoll`  [owner: backend-developer] [size: M] [depends: W6-6]  Status: In review (this PR; ships with W6-8)
- **Description.** `engagement.Service.VotePoll`, step by step:
  1. Flags: `engagement` on for the caller (as Like) and `polls` not globally off; else FEATURE_DISABLED (`feature=engagement` or `polls`) with 0 reads.
  2. `idempotency_key` format, verified identity, `choice_index` in 0..3; VALIDATION with 0 reads.
  3. Resolve the target as Like does: a REPOST id → the original; visibility as GetPost → NOT_FOUND.
  4. No poll → VALIDATION `field=post_id`. The caller is the author → VALIDATION. `now ≥ closesAt` → POLL_CLOSED. `choice_index ≥ len(choices)` → VALIDATION.
  5. Rate bucket and `poll_votes_daily` cap → RATE_LIMITED.
  6. One batch: `Create pollVotes/{postId}_{uid}` `{postId, uid, choice, createdAt, expireAt = closesAt + POLL_VOTE_TTL_AFTER_CLOSE}`; `StagePollVote` (Increment `poll.counts.<i>` and `poll.total`, Exists precondition); `userLikes.pollVotes` as a Set-merge `ArrayUnion` (0 reads; trimmed lazily to `POLL_VIEWER_VOTES_KEPT` by the `TrimLikes` pattern, A3).
  7. AlreadyExists → read the vote doc (1): same choice → return the current view (replay, 0 writes); different choice → ALREADY_VOTED with `metadata["choice"]`.
  8. Response: the PostView with fresh counts (the local post cache is updated from the committed increments) and `viewer_poll_choice`.
  9. Contention (ABORTED after `store.CommitWithRetry`) → UNAVAILABLE with `retry_after`, counted in `poll_vote_contention`.
- **Acceptance criteria.**
  - Given an open poll and a first vote, then 3 writes, counts +1 and total +1, and the response shows results.
  - Given the same call again, then 0 writes and the same response.
  - Given a second vote with another choice, then ALREADY_VOTED and 0 writes.
  - Given 50 concurrent votes by 50 users, then `total = 50` exactly.
  - Given 10 concurrent votes by one user with mixed choices, then exactly 1 vote counted.
  - Given the poll closed, then POLL_CLOSED with 0 writes.
  - Given the author, then VALIDATION.
  - Given a user blocked by the author, then NOT_FOUND with bytes identical to a missing post.
  - Given 31 votes in a minute, then RATE_LIMITED.
  - Given `DEGRADED_MODE=readonly`, then DEGRADED_MODE.
- **Test notes.** Flag matrix: `polls` allowlist with a caller outside the list → still allowed; `polls` globally off → refused; `engagement` off for the caller → refused. `budgettest` 6 worst new, 7 replay, 3 typical. A voter whose `userLikes` doc does not exist yet → vote stored and choice hydrated on the next GetPost. the concurrency tests above on the emulator, noted as not proof for prod `OPTIMISTIC` (W6-22 runs a dev smoke as #292 did); clock-injected closing.
- **Observability.** One `poll_vote` line: `outcome` (voted / replay / already_voted / closed / author / not_found), `uid_hash`, `fs_reads`, `fs_writes`, `contention`. **Never the choice.** Error Reporting on internal errors.
- **Budget.** Reads 6 worst / 3 typical; writes 3; deletes +1 TTL later.
- **Flag.** `FEATURE_ENGAGEMENT` (per caller) + `FEATURE_POLLS` (not globally off).
- **Seam.** `engagement.Service.VotePoll` → `posts.EngagementWriter.StagePollVote` (the one counter helper; sharding replaces its body, not its callers).
- **Runs alongside W3/W4/W5:** yes (the engagement module); `engagement_wiring.go` is shared, so rebase.

### W6-8 — `pollVotes` lifecycle and runbook  [owner: backend-developer] [size: S] [depends: W6-7, in the same PR]  Status: In review (same PR as W6-7)
- **Description.**
  - Eraser step `poll_votes` (engagement): `pollVotes where uid == X`, pages ≤ 500, 1 read and 1 delete per doc. Registered `BeforeIdentity` after `engagement`, with the pinned order in `lifecycle_wiring_test.go` updated. Counts are left as they are (F6).
  - Export section `poll_votes`: `postId`, `choice`, `createdAt` per doc.
  - T11 row `{Name: "pollVotes", Disposition: erasedByStep, Step: "poll_votes", Section: "poll_votes", Owner: "engagement", Cite: "ADR-0029"}`; `userLikes.pollVotes` is covered by the existing `userLikes` row.
  - Runbook `docs/runbooks/engagement.md`, new section "Polls":
    - a hot poll and the `poll_vote_contention` signal → the sharding trigger;
    - the kill switch;
    - ALREADY_VOTED support questions;
    - the TTL field must be applied before prod polls (otherwise vote docs simply stay).
- **Acceptance criteria.**
  - Given an account with 120 votes, then the eraser deletes 120 docs and the export lists 120.
  - Given `make ci`, then the T11 guard passes.
  - Given a vote by a deleted account on an open poll, then the poll's counts are unchanged and no doc names that uid.
- **Test notes.** Emulator: erase, export, the residue sweep, the crash-resume checkpoint, the pinned-order test.
- **Observability.** The existing `account_job` step lines.
- **Budget.** 1 read + 1 delete per vote doc; export 1 read per doc.
- **Flag.** None: lifecycle never sits behind a flag (ADR-0011).
- **Seam.** The `identity.StepEraser` / `ExportSection` adapters.
- **Runs alongside W3/W4/W5:** the pinned order and the guard test are shared, so one PR at a time.

- **Implementation notes (W6-7 and W6-8, as built).**
  - Budgets follow ADR-0029 Cost impact, not the older ticket numbers (6 / 7 / 3): new vote 8 worst (interceptor 1, post 1, author 1, graph 1, +2 REPOST id, +1 overflow, `userLikes` 1 for the response flags), replay or ALREADY_VOTED 9, refusal at step 5 at most 7, 3 writes in one batch. Measured in the chain test (request line, interceptor read not counted): new vote 3 reads / 3 writes, replay 1 / 0, closed 3 / 0.
  - `engagement.Polls` seam (`NewServer` detects it on the Module); `PollRepo` is separate from `Repo` (`FirestoreRepo.Vote` is `store.CommitWithRetry`: AlreadyExists = `VoteExists`, a missing post = `VotePostGone`, exhausted retries wrap `store.ErrContended` = UNAVAILABLE + `retry_after`, `contention=true`, WARN `poll_vote_contention`).
  - New `posts.Engagement.PollVoted` / `Cache.AdjustPoll` / `Post.Voted`: copy on write with a new `Poll`. A replay does not bump the cache, so its counts can lag by the cache TTL (60 s) on another instance.
  - `POLL_VOTES_PER_DAY_NEW_ACCOUNT` is enforced in the service by comparing the interceptor's own `poll_votes_daily` counter (`Deps.PollVoteCap`, `DailySpent`) with the new-account limit; same RATE_LIMITED shape. Per instance, like the cap.
  - Order notes for the client (W6-13): a closed poll answers POLL_CLOSED even for a replay (D6 step 5 precedes the batch); a failed `userLikes` read degrades the response flags, never the vote.
  - W6-8: the `poll_votes` step and section are appended after `messaging` (step names are persisted, so nothing is inserted mid-sequence); the pinned lists in `lifecycle_wiring_test.go` and `registeredLifecycle` and the T11 row are updated. Eraser and export page by document id (`uid ==`), no composite index.
  - Tests: unit (`service_polls_test.go`, `purge_polls_test.go`, `server_polls_test.go`, `posts/poll_vote_test.go`), emulator repo (`repo_polls_integration_test.go`), chain (`engagement_polls_chain_integration_test.go`). Not run: `-race` (no cgo), the full `make ci` and `make test-int`, a lifecycle chain test of an account with real votes (repo-level erase/export with 120 and 1,100 seeded votes instead), prod OPTIMISTIC concurrency (W6-22).

### W6-9 — Accept `image/gif` for post media  [owner: backend-developer] [size: M] [depends: W6-4]  Status: In review (PR #496; flag stays off until W6-10 merges)
- **Description.**
  - CreateUpload accepts `image/gif` for `MEDIA_PURPOSE_POST` only (AVATAR and BANNER refuse), behind `FEATURE_GIF` (FEATURE_DISABLED `feature=gif`).
  - Items: exactly 1 GIF per CreateUpload and never mixed with other items; full ≤ `MaxFullBytes` (2 MiB); the thumbnail per `thumb_content_type` (JPEG or WebP ≤ 256 KiB).
  - `sniffImage` learns `GIF87a`/`GIF89a`; `extension` → `gif`; FinalizeUpload checks the full object's magic against `image/gif` and the thumbnail's against its own type.
  - Publish copies the full object with `image/gif` and the thumbnail with its own type.
  - posts:
    - CreatePost refuses a GIF media doc while `gif` is off for the caller (the content type rides on `LoadForPost`'s claim, 0 reads);
    - a GIF must be the only media item → VALIDATION;
    - SchedulePost refuses GIF media → VALIDATION (F10).
  - The purge and export of media cover the `gif` extension.
- **Acceptance criteria.**
  - Given a 1.5 MiB GIF with a JPEG thumbnail, then READY with `url` ending `.gif`.
  - Given a GIF declared but PNG bytes, then REJECTED.
  - Given a 2.1 MiB GIF, then VALIDATION at CreateUpload (the signed range also refuses).
  - Given an avatar GIF, then VALIDATION.
  - Given a GIF plus a photo in one post, then VALIDATION.
  - Given `gif` off, then FEATURE_DISABLED with 0 reads.
  - Given `DEGRADED_MODE=nomedia`, then refused as today.
- **Test notes.** Unit: the sniffer table, the content-type matrix. Emulator (Storage emulator): create, finalize, publish, purge.
- **Observability.** The existing media lines gain `content_type`.
- **Budget.** Firestore unchanged (CreateUpload 2 / 1, FinalizeUpload 5 / 1.7); GCS +1 Class B per GIF in W6-10.
- **Flag.** `FEATURE_GIF` (per caller).
- **Seam.** The content-type table in `media`; posts sees only `MediaClaim`.
- **Runs alongside W3/W4/W5:** `media/service.go` and `finalize.go` change in W3-5 (banner), so do this after it or rebase.

### W6-10 — Frame-sampled SafeSearch for GIFs  [owner: backend-developer] [size: M] [depends: W6-9, F11]  Status: In review (this PR; `FEATURE_GIF` stays off until 100 % of traffic is on a revision with it)
- **Description.** For a GIF in FinalizeUpload (F11 a):
  1. Read the object from the private upload bucket (≤ 2 MiB).
  2. Parse the header and frame descriptors and **refuse before decoding** above `GIF_MAX_FRAMES`, `GIF_MAX_EDGE` or `GIF_MAX_FRAME_AREA_SUM`.
  3. Decode at most 4 evenly spaced frames (composited onto the logical screen), under a per-instance semaphore of 1 and a 2 s deadline.
  4. Tile them into one ≤ 1,024 px JPEG sheet.
  5. Call `Moderator.SafeSearch` with image bytes (`Image.Content`) for the sheet and by URI for the thumbnail.
  6. Increment the Vision counter by 2 units. The worse verdict of the two wins.

  A refusal → REJECTED ("This GIF is too large or too long"), and its objects are deleted. The cap and exhaustion policy apply as for photos (READY_UNSCREENED or REJECTED).

  If F11 = (b) instead: no sampling; GIFs only for accounts older than 7 days; screen the first frame and the thumbnail; queue for report-driven review.
- **Acceptance criteria.**
  - Given a GIF whose 3rd of 4 sampled frames is explicit and whose first is harmless, then REJECTED.
  - Given a header claiming 10,000 frames, or a 65,535 × 65,535 logical screen, then REJECTED before any frame decode, with memory under 20 MB (test assertion).
  - Given two GIFs finalised at once on one instance, then they run one after another and both finish within the request deadline.
  - Given the Vision counter at the cap, then the policy applies exactly as for photos.
  - Given a READY GIF, then 2 units were counted.
- **Test notes.** Fixture GIFs under `testdata/media/` (harmless and flagged frames via the fake `Moderator`); a fuzz test on the frame-descriptor parser; a `-race` run of concurrent finalizes.
- **Observability.** One `gif_screen` line: `frames`, `sampled`, `units`, `decode_ms`, `refused_reason`. Error Reporting on decode panics (recovered, item REJECTED).
- **Budget.** Firestore unchanged; +1 Class B; Vision 2 units per GIF; CPU ≤ 0.5 s.
- **Flag.** `FEATURE_GIF` (upstream).
- **Seam.** The `Moderator` interface takes either a URI or bytes; the sampler is a pure function, so it can move to a separate job unchanged.
- **Runs alongside W3/W4/W5:** yes.

### W6-11 — Composer toolbar: Poll and GIF  [owner: frontend-developer] [size: S] [depends: W6-4]  Status: In review
- **Description.** In the composer's bottom bar, next to `_AddPhotoButton`, X's order (`composer.md` §1): photo, **GIF**, **poll**, schedule. Each button shows only when its flag is on (`gif` + `media`; `polls` + `engagement`). Mutual exclusion, mirroring X §1b and F4/F5/F10:
  - a poll disables photo, GIF and Schedule;
  - a schedule disables the poll;
  - a GIF disables photo and the poll, and photos disable the GIF;
  - a reply or quote composer never shows the poll.

  Disabled buttons keep a tooltip explaining why. If CMP-1's shared `ComposerToolbar` has landed, add the buttons there instead.
- **Acceptance criteria.**
  - Given `polls` on, when a schedule is set, then Poll is disabled with the tooltip "Polls can't be scheduled".
  - Given a GIF attached, then the photo and poll buttons are disabled.
  - Given the flags off, then no new buttons.
- **Test notes.** Widget tests 360 / 600 / 1200, light and dark, 3 text scales; semantics labels ("Add a GIF", "Add poll").
- **Observability.** —
- **Budget.** 0 RPCs.
- **Flag.** `polls`, `gif`.
- **Seam.** One `ComposerAttachmentKind` rule function decides what is enabled; widgets never restate it.
- **Runs alongside W3/W4/W5:** `composer_screen.dart`, one PR at a time.

### W6-12 — Poll builder  [owner: frontend-developer] [size: M] [depends: W6-11]  Status: In review
- **Description.** Tapping Poll opens an inline builder (`composer.md` §2):
  - the text placeholder becomes "Ask a question";
  - Choice 1 and Choice 2 fields with "N / 25" counters (`CharacterCounter`), an "Add a choice" (+) up to 4, and a remove on choices 3 and 4;
  - "Poll length" as Days / Hours / Minutes (dropdowns on wide screens, platform pickers under 600 dp, as CMP-D6 did), default 1 day, minimum 5 minutes;
  - a red "Remove poll".

  `ComposerCubit` holds `PollDraft`; the idempotency key covers the poll; Post is disabled until the rules hold. The rules mirror the server through the shared fixture `testdata/poll_rules.json`. Echo check after CreatePost (L-1): if `post.poll` is missing, show the snackbar "Your poll was not added" with Delete and Keep.
- **Acceptance criteria.**
  - Given 2 filled choices and text, then Post is enabled.
  - Given a 26th code point, then the counter turns red and Post is disabled.
  - Given duplicate choices, then the inline hint "Choices must be different".
  - Given 0 days, 0 hours and 3 minutes, then the length is clamped to 5 minutes with a hint.
  - Given the server echo without a poll, then the warning shows.
- **Test notes.** Cubit unit tests over the shared fixture; widget tests at 3 widths, light and dark, 3 text scales; keyboard traversal.
- **Observability.** —
- **Budget.** 0 extra RPCs (CreatePost as today).
- **Flag.** `polls`.
- **Seam.** `PollDraft` is the single model used by the builder, drafts (W6-14) and CreatePost.
- **Runs alongside W3/W4/W5:** `composer_cubit.dart`, one PR at a time.

### W6-13 — Poll card and voting  [owner: frontend-developer] [size: M] [depends: W6-2; W6-7 for the dev check]  Status: In review
- **Description.** `PollView` in `PostCard`, the thread view and the post detail:
  - **Open and not voted:** outlined choice buttons and "N votes · 2 days left".
  - **Voted, author or closed:** result bars with percentages (rounded so they total 100), the leading choice bold, a check on the viewer's choice, and "N votes · Final results" when closed.
  - **Compact embed** on repost and quote rows: "Poll · N choices · ends …", which opens the original (A7).

  Voting:
  - `PollRepository.vote` over `VotePoll` with one idempotency key per (post, choice) intent;
  - an optimistic bar update, rolled back on error;
  - ALREADY_VOTED → refresh the post and show the server's choice;
  - POLL_CLOSED → refresh and show final results;
  - FEATURE_DISABLED → "Voting isn't available right now".

  A cached row whose poll has passed `closes_at` with hidden counts shows "See final results", which calls GetPost once. The countdown comes from `closes_at`, with no timer RPC. The poll text is part of the post's semantics label.
- **Capture.** **The poll card in a feed was not captured (UNKNOWN).** X-like defaults with our own copy.
- **Acceptance criteria.**
  - Given a tap on choice 2, then exactly 1 `VotePoll` call and bars with the check on 2.
  - Given a failed call, then the buttons return.
  - Given the author's own poll, then bars with no buttons.
  - Given a closed poll from cache, then "See final results" makes 1 GetPost.
  - Given text scale 2.0, then no overflow.
- **Test notes.** Widget tests (each state × 3 widths × light/dark × 3 text scales); repository tests (error mapping).
- **Observability.** Crashlytics breadcrumbs without the choice.
- **Budget.** 0.3 `VotePoll` + 0.1 GetPost per DAU (cost table).
- **Flag.** None for rendering (the server is authoritative). Vote buttons show only with `engagement` in `enabled_features`, and are hidden after the server answers FEATURE_DISABLED.
- **Seam.** `PollRepository` is the only caller of `VotePoll`; the card is presentational.
- **Runs alongside W3/W4/W5:** `post_card.dart` also changes in W3 (pinned label) and W4-16 (hashtag tap), so rebase.

### W6-14 — Drafts store  [owner: frontend-developer] [size: M] [depends: —]  Status: In review
- **Description.**
  - A drift table `ComposerDraftEntries` (`draftId`, `uid`, `draftText` (not `text`: it would shadow drift's `text()`), `pollJson`, `replyPolicy`, `paidPartnership`, `madeWithAi`, `createdAt`, `updatedAt`) in `AppDatabase`, schema **v9** (additive migration; v7 and v8 were taken by W7 messaging).
  - **Not** in `clearAll` (F7 default); every query is filtered by uid; writes are guarded by `SessionEpoch` (`epoch:`).
  - `DraftsRepository`:
    - `watch(uid)`, newest first;
    - `upsert(draft)`: debounced 2 s autosave, at most `kMaxDrafts` = 50 per uid (the oldest is dropped with a notice), text ≤ 2,000 code points;
    - `delete(ids)`, `deleteAll(uid)`.
  - Wipe the uid's drafts when DeleteAccount succeeds on this device.
  - If F7 = clear: add the table to `clearAll` instead.
  - No images (F8).
- **Acceptance criteria.**
  - Given two accounts on one device, then each sees only its own drafts.
  - Given sign-out and sign-in as the same account, then the drafts are still there (F7 default).
  - Given an autosave racing a sign-out, then no row is written after the epoch ends.
  - Given a successful DeleteAccount, then the uid's rows are gone.
  - Given the 51st draft, then the oldest is removed.
  - Given a v6 database, then migration to v7 keeps every existing row.
- **Test notes.** drift in-memory tests, the migration test from a v6 fixture, the epoch race test.
- **Observability.** No draft text in logs or Crashlytics (a test asserts the logger never receives it).
- **Budget.** 0 RPCs, 0 server bytes.
- **Flag.** None in the store; the UI gates on `drafts`.
- **Seam.** `DraftsRepository` is the only reader and writer, so synced drafts (the stage-ladder row) replace its implementation and change no widget.
- **Runs alongside W3/W4/W5:** **start now.** The `app_database.dart` schema bump conflicts with any other wave adding a table, so one PR at a time.

### W6-15 — Drafts UI  [owner: frontend-developer] [size: M] [depends: W6-14, W6-4]  Status: In review
- **Description.**
  - A composer header "Drafts" text button on the right (X §1).
  - Autosave while composing a new root post.
  - **Leaving with content shows "Save post?"** with Save and Discard (X §1a: "You can save this to send later from your drafts."; our copy may differ). Save keeps the row; Discard deletes it; posting deletes it. With photos attached, add the line "Photos aren't saved in drafts." **This replaces today's "Your photos will not be saved." prompt and closes CMP-2's discard-prompt part; update CMP-2's row in `composer-w15-w6.md` in the PR.**
  - **Drafts screen** `/drafts` with an `AppTabBar` **Unsent posts | Scheduled**: the Scheduled tab is the existing CMP-D6 list widget, and `/scheduled` stays as an alias that opens that tab, so toasts and links keep working.
  - Unsent rows: text preview, poll badge, relative time. A tap reopens the composer prefilled, with the same draft id.
  - Edit mode (X §1h): checkboxes, "Select all", and a red "Delete" behind the confirm dialog "Discard unsent posts?".
  - Empty state with our own copy.
  - The Scheduled tab stays gated as today (`posts` + `scheduled_posts` for the composer action; the list needs `posts`).
- **Acceptance criteria.**
  - Given text typed and the composer closed, then "Save post?" appears; Save → the row exists; Discard → it does not.
  - Given the app killed mid-typing, then the text is in Unsent posts on the next open.
  - Given a draft opened and posted, then the row is gone.
  - Given `drafts` off, then no Drafts button and the old prompt.
  - Given `/scheduled`, then the Drafts screen opens on Scheduled.
- **Capture.** **What Save does, and Unsent rows, were not captured (UNKNOWN).** X-like defaults.
- **Test notes.** Widget tests at 3 widths, light and dark, 3 text scales; navigation tests for `/drafts` and `/scheduled`; back behaviour.
- **Observability.** —
- **Budget.** 0 RPCs (the Scheduled tab's calls are unchanged).
- **Flag.** `drafts` (+ the existing scheduled gates).
- **Seam.** The screen depends only on `DraftsRepository` and the existing scheduled repository.
- **Runs alongside W3/W4/W5:** `app_router.dart` and `composer_screen.dart`, one PR at a time.
- **Built (PR #525).** `ComposerCubit` takes an optional `DraftsRepository` + uid + `initialDraft` (root post only; a quote or a reply has none), autosaves from `onChange`, and decides the leave with `leaveAction` (`none` / `savePrompt` / `discardMedia`); `saveDraft`, `discardDraft` and `loadSavedDraft` serve the prompt and the list. Post and Schedule success delete the row (a schedule starts a new draft id). The header gets an optional secondary action on `AppFormHeader` (the "Drafts" button; saves first when there are changes). `/drafts?tab=scheduled` is the Scheduled tab; `/scheduled` redirects to it while `drafts` is on (the old screen stays with it off); `/drafts` needs `posts` + `drafts`. The composer pushes `/drafts` with `extra: true` (pick mode): a chosen draft pops its id and loads into the same composer; opened standalone, a tap pushes `/compose?draft=<id>`. The Scheduled list body is `ScheduledPostsBody`, shared by both screens. A malformed or unknown draft id never becomes the id of a new draft.
- **Notes for later tickets.** Drafts keep text, poll, audience and the two disclosure labels; photos and a GIF are never kept (the prompt says so). The table key is `draftId` alone; the UI never adopts an id from a URL, and every query filters by uid (W6-20: the one shared-key risk is a caller who knows another account's 16-hex id AND bypasses the UI). A poll or audience whose flag is off is not loaded into the composer (the next autosave then drops it from the row).

### W6-16 — GIFs from the device  [owner: frontend-developer] [size: M] [depends: W6-9]  Status: In review (#522)
- **Description.**
  - `GifSource` interface; `DeviceGifSource` over the platform picker (`.gif` only; web file input `accept="image/gif"`).
  - On-device checks before upload (≤ 2 MiB, ≤ 1,280 px edge, ≤ 300 frames; refuse with a clear message rather than re-encode).
  - A first-frame JPEG thumbnail (≤ 256 KiB, BlurHash) via `ImageProcessor`; the full bytes go up **unchanged**, with `content_type=image/gif` and `thumb_content_type=image/jpeg`.
  - `AttachmentsCubit` gets a GIF attachment kind (1 max, exclusive per W6-11) and alt text as for photos.
  - Rendering in `PostMedia`: lists show the static thumbnail with a "GIF" badge, and a tap plays the full file inline. "Reduce motion" (platform setting) never autoplays; the post detail also starts paused (F10).
- **Acceptance criteria.**
  - Given a 1.8 MiB GIF, then it uploads and the post shows a GIF badge.
  - Given a 3 MiB GIF, then "GIFs can be up to 2 MB" and no upload.
  - Given a tap on the badge, then the animation plays and only then is the full URL fetched.
  - Given a GIF REJECTED by the server, then the attachment shows the server's reason.
  - Given `gif` off, then no GIF button and the picker never offers GIFs.
- **Test notes.** Unit (the checks, thumbnail generation from fixtures); widget tests (attachment tile, badge, play state) at 3 widths, light and dark; a network-fake test that the full URL is not requested before the tap.
- **Observability.** —
- **Budget.** 0.02 GIF uploads per DAU; 0.3 plays per DAU (the egress line).
- **Flag.** `gif` + `media`.
- **Seam.** `GifSource` (device today; the provider picker of W6-24 plugs in without touching the composer).
- **Runs alongside W3/W4/W5:** `attachments_cubit.dart`, `image_picker_service.dart` and `image_processor.dart` (W3's banner editor uses the processor), so rebase.
- **Delivered (2026-10-31).**
  - `GifSource` / `DeviceGifSource` (`image_picker.pickImage` with no resize or quality arguments), `GifPreparer` (separate from `ImageProcessor`, which keeps its interface), `AttachmentKind.gif`, `AttachmentsCubit.pickGif`, `ProcessedImage.thumbContentType`, `GifBadge`, the GIF tile in `PostMedia`.
  - **Deviations.**
    - The picker cannot filter to `.gif` (no `file_selector` dependency was added): a non-GIF is refused after picking with "That file isn't a GIF." The web file input is therefore `image/*`, not `image/gif`.
    - W6-11's rule did not block Schedule on a GIF; it now does, and a schedule disables the GIF button, both with "GIFs can't be scheduled" (SchedulePost refuses GIF media).
    - There is no data-saver setting in the app, so nothing reads one; playback is tap-only everywhere (list and detail), which also satisfies reduced motion.
    - FinalizeUpload's MEDIA_NOT_READY carries no discriminator between "slot busy" and "object missing", so a lone GIF repeats the same finalize (same key, no re-PUT) after 2, 4 and 8 s (jittered) before falling back to the re-PUT path.

### W6-17 — Backend tests: polls  [owner: tester] [size: M] [depends: W6-8]  Status: Open
- **Description.** Emulator integration and unit:
  - flag modes for `polls` and `engagement` (create per caller; vote with `engagement` per caller and `polls` not globally off; the globally-off reveal);
  - the F4 validation table;
  - the vote matrix (new, replay, other choice, closed, author, blocked either way, hidden post, REPOST id, author SUSPENDED);
  - concurrency (50 users at once; one user × 10 mixed);
  - redaction across every PostView producer (A4 guard);
  - `budgettest` per the RPC table;
  - rate limit and `poll_votes_daily`;
  - lifecycle (eraser, export, T11, TTL field present in Terraform);
  - `requestHash` goldens;
  - `DEGRADED_MODE=readonly`.
- **Acceptance criteria.** Every acceptance criterion of W6-5 to W6-8 has a named test; `make test-int` green; coverage ≥ 70 %.
- **Test notes.** Load shape for the stage-ladder trigger: one poll at 50 votes/s for 60 s (with W6-21), recording ABORTED and `poll_vote_contention`.
- **Observability.** —
- **Budget.** 0 (emulators).
- **Flag.** Under test: `polls` in every mode, plus `engagement` off.
- **Seam.** —
- **Runs alongside W3/W4/W5:** yes.

### W6-18 — Backend tests: GIF  [owner: tester] [size: S] [depends: W6-10]  Status: In review (this PR; report `docs/reviews/test-report-w6-gif.md`; one Medium defect D-1, the sampler ignores the browser delay clamp)
- **Description.**
  - The sniffer and content-type matrix;
  - size and edge caps;
  - bomb fixtures (frame count, logical screen, frames × area);
  - the sampled-frame verdict through the fake `Moderator`;
  - Vision units (2) and the cap policy;
  - the flag on CreateUpload, CreatePost and SchedulePost;
  - the avatar refusal;
  - purge of `.gif` objects;
  - `nomedia`.
- **Acceptance criteria.** Every acceptance criterion of W6-9 and W6-10 has a named test; memory assertions pass under `-race`.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** `gif` in every mode.
- **Seam.** —
- **Runs alongside W3/W4/W5:** yes.

### W6-19 — Client tests  [owner: tester] [size: M] [depends: W6-12 to W6-16]  Status: In review (this PR; report docs/reviews/test-report-w6-client.md)
- **Description.** The cross-feature matrix:
  - composer exclusions (poll × photo × GIF × schedule × reply / quote);
  - poll builder → post → card states;
  - drafts across sign-out, two accounts and deletion;
  - `/drafts` and `/scheduled` routing;
  - GIF attach → tap to play;
  - flag combinations (`polls` × `drafts` × `gif` × `engagement` × `media` × `ui_shell`);
  - text scale 2.0 overflow.
- **Acceptance criteria.** All new widgets are covered at 360 / 600 / 1200, light and dark; no overflow at 2.0.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** As listed.
- **Seam.** —
- **Runs alongside W3/W4/W5:** yes.

### W6-20 — Security review  [owner: security-auditor] [size: S] [depends: W6-7, W6-10, W6-15]  Status: Open
- **Description.** A threat model for:
  - vote integrity (natural key, concurrency, sybils, rate × 3 instances, the daily cap);
  - the result oracle (redaction, refusal order, bytes of hidden counts);
  - author/voter privacy (no voter list, logs never pair uid and choice);
  - poll text (D9, no mention parsing);
  - the lifecycle (eraser, TTL residue ≤ 37 days, F6);
  - the GIF moderation gap and bypasses (F11), decompression bombs, polyglots, the content-type confusion between full and thumbnail;
  - drafts on shared devices (F7), web storage, logging;
  - the conditional picker key, if W6-23 is unlocked.

  Findings are fixed or ticketed before any dev allowlist.
- **Acceptance criteria.** A report in `docs/reviews/` with no open Critical or High findings.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Reviews the `polls`, `gif` and `drafts` gates and kill switches.
- **Seam.** Checks the counter seam and the `Moderator` seam.
- **Runs alongside W3/W4/W5:** yes.

### W6-21 — Cost report  [owner: sre-performance] [size: S] [depends: W6-7, W6-10]  Status: Open
- **Description.**
  - Add the W6 rows (+1.05 reads, +1.02 writes, +0.32 deletes, +0.44 requests per DAU; Vision +1.22 units per DAU-month; GIF egress) to `docs/reviews/cost-model.md` §1–§6, beside W2's and any W3/W4 rows that have landed.
  - Emulator load smoke `make loadtest SCENARIO=poll_vote`: a hot poll at 50 votes/s, and a typical mix.
  - Measure GIF finalize CPU and memory on 10 fixture GIFs.
  - Re-check the Vision cap crossover (≈ 747 DAU) and the GCS egress crossover (≈ 1,786 DAU).
- **Acceptance criteria.** The model is updated with measured reads per call (± 25 % of this plan, or this plan's table corrected); a k6 script is added under `loadtest/`; the sharding trigger's signal (`poll_vote_contention`) has a Logs Explorer query in §9.
- **Test notes.** —
- **Observability.** No new log-based metric or alert policy.
- **Budget.** 0 (emulators).
- **Flag.** n/a.
- **Seam.** —
- **Runs alongside W3/W4/W5:** yes.

### W6-22 — Dev rollout  [owner: production-deployer] [size: S] [depends: W6-17 to W6-21, ADR merged]  Status: Open
- **Description.**
  - Show the founder a **targeted** dev Terraform plan (`docs/plans/roadmap.md` section 9, item 3.10: a full dev apply is unsafe) for `feature_polls*`, `feature_drafts*`, `feature_gif*`, the config env vars and the `pollVotes.expireAt` TTL field.
  - The `posts.poll` fieldOverride deploys with the dev deploy workflow after merge. For prod it waits for the held release (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.2) and must be deployed before `FEATURE_POLLS` leaves `off` there.
  - Apply only on OK; allowlist 3 test uids.
  - Smoke:
    - create a poll, vote from a second account, see results, wait for close, see final results;
    - concurrent votes on real dev Firestore (`OPTIMISTIC`), as the #292 smoke did;
    - save, reopen and post a draft;
    - post a GIF and play it.
  - Prod: no change (on hold).
- **Acceptance criteria.** The dev smoke passes; the flags are back to their planned state.
- **Test notes.** —
- **Observability.** Check the `poll_vote` and `gif_screen` lines in dev logs.
- **Budget.** A handful of reads and 2–4 Vision units in dev.
- **Flag.** Dev: `feature_polls`, `feature_drafts` and `feature_gif` at allowlist (3 uids); prod stays `off`.
- **Seam.** —
- **Runs alongside W3/W4/W5:** serialise dev applies with theirs.

### W6-23 — *(conditional on F9)* GIF picker ADR addendum  [owner: architect] [size: S] [depends: F9 terms verified in writing]  Status: Open (conditional)
- **Description.** Only after the founder has Klipy's production terms in writing (rate limits, attribution wording and placement, ads or revenue share, re-hosting allowed or not, cost at scale), decide:
  - copy through our pipeline vs a link (F9);
  - client-direct with a restricted key vs a small server proxy with an instance cache and a per-user cap, so that a limited key is not exhausted;
  - the `GifProvider` interface (search, trending, fetch), so the vendor can be swapped;
  - attribution UI;
  - `FEATURE_GIF_SEARCH` and its ceiling;
  - the cost line, including Vision units for copied GIFs.

  Any third-party host in the CSP or any new outbound dependency is stated with its abuse limits.
- **Acceptance criteria.** The addendum is accepted by the founder's merge; if the terms forbid what Stage 0 needs, it records "picker stays off" and W6-24 is closed.
- **Test notes.** —
- **Observability.** —
- **Budget.** In the addendum.
- **Flag.** Names `FEATURE_GIF_SEARCH`.
- **Seam.** `GifProvider` / `GifSource`.
- **Runs alongside W3/W4/W5:** yes.

### W6-24 — *(conditional on W6-23)* GIF search picker  [owner: frontend-developer] [size: M] [depends: W6-23, W6-16]  Status: Open (conditional)
- **Description.** A picker sheet (search field, trending grid, provider attribution) behind `FEATURE_GIF_SEARCH`, implementing `GifSource`. The chosen GIF follows W6-23's mode. Backend work, if W6-23 picks a proxy, is a separate backend ticket written in that addendum.
- **Acceptance criteria.** Per W6-23.
- **Test notes.** Widget tests at 3 widths, light and dark; the provider fake.
- **Observability.** Per W6-23.
- **Budget.** Per W6-23.
- **Flag.** `gif_search` + `gif` + `media`.
- **Seam.** `GifSource`.
- **Runs alongside W3/W4/W5:** yes.

## Rollout plan
- **Dev:** allowlist (3 uids) for `drafts` first (client only, no server risk), then `polls`, then `gif`, each after its security and cost tickets.
- **Prod:** your MVP launch decision. Allowlist → percent 5 → 25 → 100 → `on`, each step a Terraform change plus a tagged revision (ADR-0019). Before each step:
  - check the `cost-model.md` headroom and the error rate;
  - honour the 100 % rule (L-1) for `polls` and `gif`;
  - `polls` never ahead of `engagement`, `gif` never ahead of `media`;
  - the `pollVotes` TTL field and the `posts.poll` fieldOverride are deployed before `polls` leaves `off`.
- **Rollback triggers:**
  - `VotePoll` error rate above 2 % for 15 minutes;
  - sustained `poll_vote_contention` on any post (the sharding trigger: kill the hot poll's voting with the flag only if users are hurt, then write the sharding ADR);
  - Vision units per day above 1.5× the model after `gif` ramps;
  - a GIF moderation bypass reported.
- **Kill switches:**
  - `FEATURE_POLLS=off`: no new polls, voting refused, results revealed.
  - `FEATURE_GIF=off`: no new GIF uploads or posts.
  - `FEATURE_DRAFTS=off`: drafts UI hidden, local rows kept.
  - `DEGRADED_MODE=nomedia`: all uploads stop.

  Each needs a deploy; none needs a data migration. Never roll back below the revision that enforces poll redaction once `polls` has left `off`: an older revision would show hidden counts. Roll forward.

## Risks
| Risk | Mitigation |
|---|---|
| A viral poll breaks rule 3 (votes and likes on one doc) | batch increments with no reads; `poll_vote_contention`; the stage-ladder trigger and sharding ADR; the load shape in W6-17 / W6-21 |
| The GIF moderation gap (first frame only) | F11 (a) frame sampling; (b) as a fallback; the rollback trigger; report-driven review |
| GIF egress dominates the bill at scale | 2 MiB cap; static thumbnail in feeds and tap to play (F10); the MP4 trigger in the stage ladder |
| GIFs bring the Vision cap forward (822 → about 747 DAU) | the cap policy is unchanged; R4 (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.7) watches daily units |
| Drafts exposed on shared devices | per-uid scoping; wipe on deletion; "Delete all"; F7 lets you choose clear-on-sign-out |
| Users expect drafts on every device | stated in the copy; the synced-drafts trigger in the stage ladder |
| Hidden counts leak through a list that bypasses the converter | one converter, plus the A4 guard test over every PostView producer |
| Old app versions show a poll post as text only | acceptable: the question still reads; no server change needed |
| Merge conflicts with W3/W4/W5 in shared files | the serialisation list above; one PR at a time |
| ADR or `ErrorReason` number clash | "the next free number when the PR opens" |
| The founder's GIF decision is read as "picker now" | F9 restates the 2026-10-22 decision; the picker tickets are conditional and gated on written terms |
