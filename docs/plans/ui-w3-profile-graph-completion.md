# UI W3: profile and graph completion
Plan owner: planner · Date: 2026-10-26 (Part B tickets finalised 2026-10-27 from the accepted ADR-0025) · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **Two parts.** Part A is new backend surface in six modules (identity, media, posts, timeline, engagement, graph) under a new ADR-0024, plus client work per screen. Part B is private accounts and follow requests, which need their own ADR-0025 (they amend ADR-0008 D1); Part B can be dropped or moved without touching Part A. · Flags: new `FEATURE_PROFILE_EXTRAS`, `FEATURE_PROFILE_TABS`, `FEATURE_LIKES_LIST`, `FEATURE_FOLLOW_SUGGESTIONS` (Part A), `FEATURE_PRIVATE_ACCOUNTS` (Part B); existing `graph`, `media`, `posts`, `engagement`, `bookmarks`, `profile_snapshot`, `ui_shell`
Source: `docs/plans/roadmap.md` (W3 row; section 3 rows P0 Profiles and P1 Following system), `docs/x_research/screens/profile.md` (own profile, desktop dark, 2026-10-22; local, git-ignored), `docs/plans/ui-w1-core-surfaces.md` (W1-3, W1-4), `docs/plans/profile-edit-snapshot.md`, `docs/plans/graph.md`, `docs/plans/backlogs.md` (B-03, B-05, B-06), `docs/plans/ui-w2-engagement-composer-basics.md` (format; Likes tab handed to W3), ADR-0003, ADR-0005, ADR-0008, ADR-0010, ADR-0018, ADR-0023, the protos on `main` 46b9e0f.
Branches: `feat/ui-w3-N-<slug>` off `main` (not stacked); one ticket per PR; merge `origin/main` into the branch.

## Goal and user value
A profile that tells people who someone is and what they post, and a graph that helps a new user find people:
- a cover image, location, website and join date;
- a pinned post;
- Reposts and Media tabs next to Posts and Replies;
- your own likes next to your bookmarks;
- "Follows you" on a profile;
- a who-to-follow card;
- tabs that stay put while you scroll.

Part B adds protected accounts with follow requests, the main privacy control X users expect. Every item is the cheapest Stage 0 version, behind a flag, with a hard read cap.

## What exists already (verified on `main` 46b9e0f)
| Feature | Backend | Client | W3 delta |
|---|---|---|---|
| Cover image | **none**: `MediaPurpose` has POST and AVATAR only; `Profile` has no banner field | `ProfileHeader` draws a flat 3:1 band (W1-3) | ADR-0024: `MEDIA_PURPOSE_BANNER`, `Profile` banner URLs, `UpdateProfile.banner_media_id` through the avatar's resolver pattern (B-03) |
| Profile meta | `Profile.created_at` exists; **no location or website field** | header shows name, handle, bio, counts | "Joined" from `created_at` (client only, now); location and website need fields |
| Pinned post | **none**: no field on `users/{uid}` or `Profile` | none | ADR-0024: `Profile.pinned_post_id`, set through `UpdateProfile`; the client renders it with the existing `GetPost` |
| Profile tabs | `GetUserTimeline(include_replies)`: Posts (root) and Replies; indexes `posts (authorId, isReply, createdAt DESC)` and `(authorId, createdAt DESC)` | Posts · Replies `AppTabBar`, one `TimelineCubit` per tab (W1-4) | Reposts and Media tabs: a tab enum on `GetUserTimeline`, a new `posts.hasMedia` field (`posts.media` is index-exempt), two composite indexes |
| Likes list | `userLikes/{uid}.recent[]` (newest last, trimmed to 1,000, no timestamps; ADR-0018); `likes/{postId}_{uid}` has no `(uid, createdAt)` index | none | `ListLikedPosts` in `EngagementService`, owner-only, the second tab of the W2 Bookmarks screen (X keeps likes under History, own profile only: `profile.md` §6) |
| "Follows you" | `GetRelationships` (≤ 50 ids, 1 read) explicitly does **not** report it ("that would cost 1 read per user") | none | single-target RPC reading `follows/{target}_{caller}`: +1 cold read, profile header only |
| Who to follow | none | none | `ListSuggestedUsers` in `GraphService`, hard read cap, no scan |
| Sticky tabs, name fade | n/a | each tab returns to the top on switch; the app-bar name is always visible (B-05, B-06) | client only |
| Follow requests / private accounts | **stubs only.** `ListFollowRequests` and `RespondToFollowRequest` always return `FEATURE_DISABLED` (`backend/internal/graph/server.go:227-236`); `UpdateProfile(is_private=true)` is rejected; nothing writes `followRequests/*` or `graph.requested[]`; `FOLLOW_STATE_REQUESTED` is unreachable. ADR-0008 D1 deferred private accounts, and its Deciders line records the founder accepting that deferral | `FollowButton` has a hidden Requested variant | **Not a UI-only item.** It is private accounts end to end (Part B): post visibility on every read path, the follow-request lifecycle, eraser and export, a notification type. Needs ADR-0025 and the founder's explicit reversal of ADR-0008 D1 |

The roadmap says "follow-request RPCs exist in `graph.proto`". They exist as **contract and stubs only**; this plan corrects that and does not build a requests screen on top of stubs.

## Open questions (proposed default in bold; nothing blocks Part A)
1. **Founder: private accounts and follow requests in the MVP?** **Answered 2026-10-27: yes** (ADR-0025 accepted by your merge of #325, with every recommended default; the Part B tickets below are final). They reverse ADR-0008 D1, which you accepted. **Default: yes, as Part B of W3, behind `FEATURE_PRIVATE_ACCOUNTS`. ADR-0025 is written now, in parallel with ADR-0024. Part B is built only after you accept ADR-0025 by merging it.** ADR-0025 must land **before the W4 search ADR**; otherwise W4 must carry the protected-account filter itself, or hashtag and people search would leak protected posts. Alternative: drop Part B from W3 and keep the stubs; nothing in Part A depends on it.
2. **Founder: who-to-follow source.** All options use a hard read cap and no scan.

   | Option | How it works | Reads | INR/month at 300 / 3,000 DAU |
   |---|---|---|---|
   | **(a) Friends of friends (default)** | One query `follows where followerId in [≤ 30 most recent followees] order by createdAt desc limit 30` on the existing `followerId, createdAt DESC` index (no gate-file change); rank candidates by how many followees follow them; drop self, followed, blocked, blockedBy, muted and requested at 0 reads from the caller's graph; hydrate ≤ 10 through `identity.Directory` (cache first) | ≤ 42 per call, planning 25 | about 8 / 76 |
   | **(c) Curated fallback (default, with a)** | A founder-picked list `SUGGESTED_USER_IDS` (≤ 20 uids, env var), used when the caller follows fewer than 3 accounts or (a) returns fewer than 3 | ≤ 12 | in (a)'s figures |
   | (b) Recent active authors | One shared per-instance query `posts orderBy createdAt desc limit 50`, refreshed at most hourly, then authors filtered per caller at 0 reads | ≤ 3,600 per day fixed worst (3 instances), plus about 3 per call | about 4 / 13; cheaper at scale, less relevant |

   The `in` + `orderBy` query shape must be checked on the emulator in W3-12 before the budget is final.
3. **Founder: who can see likes?** **Owner only, as on X since 2024.** Likes appear as the "Likes" tab of the Bookmarks screen (W2-7's `/bookmarks`), not on profiles; the RPC takes no user id. The list is **your 1,000 most recent likes** (`userLikes.recent[]`), and the empty and end-of-list copy says so. Alternative: full history through a new `likes (uid, createdAt DESC)` composite index, at about 2x the reads per page (43 instead of 24) and a gate-file change. Alternative: public likes on profiles (a new scraping vector; not recommended).
4. **Founder: profile tabs.** **Posts · Replies · Reposts · Media**, equal width, as captured on X (`profile.md` §6; no Likes tab on profiles). Alternative: drop Reposts (saves one composite index and one tab query).
5. **Founder: profile meta fields.**
   - **Location** (≤ 30 code points, bio text rules).
   - **Website** (≤ 100 characters, `https://` or `http://` only, shown as its host).
   - **"Joined Month YYYY"** from `created_at`.
   - **No birthday:** it is PII, and `CLAUDE.md` rule 10 keeps PII in Firebase Auth and `users/{uid}/private`.
6. **Founder: pinning.** **One pinned post per user; your own POST, QUOTE or REPLY; never a REPOST.** Pin and Unpin are in your own post's overflow menu. A pinned post that is later deleted or hidden simply stops showing; no clean-up write is needed.
7. **Founder: screen title once Likes joins Bookmarks.** **"History", with tabs Bookmarks | Likes**, as on X. The route stays `/bookmarks`, `/bookmarks?tab=likes` opens the Likes tab, and the drawer row stays "Bookmarks". Alternative: keep the title "Bookmarks".
8. **Founder: "Follows you" scope.** **Profile header only, plus the Follow button's label "Follow back".** Chips on list rows are out of scope: they cost 1 read per row.
9. **Founder: `hasMedia` backfill.** **Run a one-off `opsctl backfill-has-media` once per project.** It reads each post once and writes `hasMedia` (true or false) on every post that lacks the field; a rerun writes 0. In dev that is a few hundred reads; prod has no real users yet, so it runs before `profile_tabs` leaves `off` there.

Questions for the architect (W3-1, W3-3): the exact RPC and field shapes below are proposals; the ADR decides and states each per-RPC budget.
- The "Follows you" RPC shape. Proposed: `GraphService.GetProfileRelationship(user_id)` returns `Relationship` + `followed_by`. It replaces the profile header's `GetRelationships([uid])`, so no request is added.
- Precedence between `include_replies` and the new tab field.
- The likes-list cursor: resume by position, as `ListBlockedUsers` does (`graph.md` T9).
- Replaced banner objects: delete them, or keep them as the avatar does today (verify which).
- The banner sizes: proposed full 1500 x 500 and thumb 600 x 200, both WebP q75.
- For ADR-0025: read-time visibility from the cached author `users` doc and the caller's graph (no write fan-out), or ADR-0003's visibility job.

| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| W3-1 | ADR-0024: profile and graph completion (banner, meta, pin, tabs, likes list, follows-you, suggestions; budgets, flags, limits, seams) | architect | M | Done (merged #325) |
| W3-2 | Proto + indexes for ADR-0024: identity, media, timeline, engagement, graph protos; two composite indexes, `users` fieldOverrides + `field-overrides.ack`; `firestore-data-model` rows | architect | M | Done (merged #328): D13 protos (Profile 13-17, UpdateProfileRequest 6-9, `MEDIA_PURPOSE_BANNER` 3, `UserTimelineTab` + `GetUserTimelineRequest.tab` 6, `ListLikedPosts`, `GetProfileRelationship`, `ListSuggestedUsers`) with budget comments, `buf lint` / `buf breaking` clean, no generated code (W3-4); D14 indexes + five `users` overrides, ack re-hashed (35 overrides; founder-gated files); skill rows; ADR-0024 and ADR-0025 Accepted |
| W3-3 | ADR-0025: private accounts and follow requests (amends ADR-0008 D1), with its proto comment changes | architect | M | Done (merged #325) |
| W3-4 | `make proto`; register the four Part A flags, config, rate limits, ceilings, Terraform vars; flag guards | backend-developer | S | Done (PR pending): generated Go and Dart code; `FEATURE_PROFILE_EXTRAS`, `FEATURE_PROFILE_TABS`, `FEATURE_LIKES_LIST` and `FEATURE_FOLLOW_SUGGESTIONS` registered (config, `flags.NewRegistry`, fixture, dev allowlist ceilings in `flag-ceiling.json`, Terraform vars default off in dev and prod, nothing applied); the D8/D10 config (`SUGGESTIONS_*`, `SUGGESTED_USER_IDS`, three per-minute buckets, `suggestions_daily` cap) validated at startup and wired in `apiserver`; `ListLikedPosts`, `GetProfileRelationship` and `ListSuggestedUsers` are flag-gated and Unimplemented until W3-10, W3-11 and W3-12; the `profile_extras` and `profile_tabs` gates arrive with W3-5, W3-6 and W3-9 (until then the new `UpdateProfile` fields and the tab are ignored) |
| W3-5 | media: `MEDIA_PURPOSE_BANNER` (sizes, avatar Racy rule, resolver, purge coverage) | backend-developer | S | Done (PR pending): `PurposeBanner`; `CreateUpload(BANNER)` takes exactly 1 item, declared width <= 1500, height <= 500, 3:1 within 2%, and signs the 1 MiB / 128 KiB caps (POST and AVATAR keep 2 MiB / 256 KiB); needs `media` and `profile_extras` on for the caller (FEATURE_DISABLED `feature=profile_extras`, 0 reads, via `flags.Guard`); `FinalizeUpload` screens full and thumb for a banner (2 Vision units regardless of `VISION_SCREEN_THUMB`) with the avatar Racy rule; `Library.ResolveBanner(ctx, uid, mediaID) (media.Ref, error)` is on `media.Reader` next to `ResolveAvatar` (1 read, `ErrNotReady` for every other case); `purpose` on the CreateUpload / FinalizeUpload request lines next to `vision_units`; purge and export tests cover BANNER docs and objects (unit and emulator); no wiring (W3-6 owns `identity.BannerResolver` and the `apiserver.go` lines) |
| W3-6 | identity: banner, location, website, `pinned_post_id` on `Profile` / `UpdateProfile`; `PinChecker` consumer interface; export fields | backend-developer | M | Done (PR pending): `UpdateProfile` takes `banner_media_id` (resolved before the transaction through `identity.BannerResolver`, adapted in `apiserver` from `media.Reader.ResolveBanner` with the FEATURE_MEDIA check; `""` removes it), `location` (NFC, trim, <= 30 code points, one line, no control or bidi), `website` (http/https, scheme lower-cased, <= 100, host required, no userinfo) and `pinned_post_id` (`identity.PinChecker` = `posts.NewPinChecker(postsSvc)` through a late binding; one VALIDATION `field=pinned_post_id` for every refusal; `""` unpins). Setting any of them needs `profile_extras` for the caller (FEATURE_DISABLED `feature=profile_extras`, checked before validation, 0 reads, 0 writes); an exact `""` clear never does (ADR-0024 Amendment 1 A2, W3-22 M-1); none bumps `snapshotVersion`, spends `snapshotEdits` or enqueues a snapshot job. `Profile` carries all five fields from every RPC that returns one; `pinned_post_id` and `website` are blanked while `profile_extras` is globally off (the stored values are untouched; the website per Amendment 1 A1). Request log: `profile_fields_changed` (names, only for a value that really changed) and `pin_check=ok or rejected`. The export profile section adds `bannerUrl`, `location`, `website` and `pinnedPostId` (golden updated). The ADR handoff's `Pins.ClearIfPinned` is done as `identity.PinJobs`, the third step of the composite `post_delete` job (it checks the post is gone first, so 2 reads per deleted post where ADR-0024 D3 said 1; it clears only the exact pin and forgets the instance's cached profile). `UpdateProfile` still writes the whole `users` document. Budget: 3 reads / 1 write worst in the service (emulator `budgettest`), 0 / 0 with the flag off, `ClearIfPinned` 1 / 1. Runbook: new `docs/runbooks/identity.md` |
| W3-7 | posts: `hasMedia` on every create path; `PinChecker` implementation; reader queries for media and reposts | backend-developer | M | Done (PR pending): `posts.HasMediaFor(kind, storedMedia)` is the one definition of `hasMedia` (true when the stored `media[]` is non-empty, never for a REPOST) and `toDoc` writes it as an explicit bool on every create path (CreatePost root, reply and quote, the ADR-0021 publish sweep, the REPOST doc), so +0 writes and never flag-gated; `posts.NewPinChecker(reader).CanPin(ctx, uid, postID) (bool, error)` (own, visible POST / QUOTE / REPLY, never a REPOST; every refusal is `(false, nil)`, an infrastructure failure is an error; 1 read cold, 0 warm); `posts.Reader.ByAuthorMedia(author, window, limit)` and `ByAuthorKind(author, kind, window, limit)` on the W3-2 indexes (reads = rows, 1 when empty); emulator tests for the stored field on all four paths and for both queries (order, tie, window, Limit, budget), unit tests for the checker. Not wired into any handler: W3-6 passes the checker to identity, W3-9 calls the queries |
| W3-8 | posts: `opsctl backfill-has-media` (resumable, throttled, dry run) | backend-developer | S | Done (PR pending): `opsctl backfill-has-media --project P [--dry-run] [--after POST_ID]` drives `posts.FirestoreRepo.BackfillHasMedia` (pages of ≤ 500 by `__name__`, checkpoint = the last post decided); it writes `posts.HasMediaFor(kind, len(media))` field-level (`Update`, never `Set`) on every post whose `hasMedia` key is missing (true or false, so an absent key stays the "backfill has not visited" marker of the runbook) and never touches an existing value; a rerun writes 0; ≤ 5,000 writes per run, then it prints the checkpoint and the `--after` hint (exit 0); prod asks for the typed project id, the dry run too; the shared `driveLoop` retries a failed page; one `backfill_has_media` log line per page (scanned, missing, updated, checkpoint, post ids only); unit tests (decision, cap, resume, CLI) and emulator tests with `budgettest` (reads = posts, writes = legacy posts, rerun 0, cap and resume, 1,001 posts at the production page size, CLI end to end). Running it is a separate step (W3-24, after 100% of the project's traffic is on a W3-7+ revision): dry run first, then the real run |
| W3-9 | timeline: `GetUserTimeline` tab MEDIA / REPOSTS (token bound to the tab) | backend-developer | M | Done (PR pending): `effectiveTab(tab, include_replies)` is the one resolver (UNSPECIFIED defers to `include_replies`, a set tab wins, an unknown number is `VALIDATION field=tab` with 0 reads); `userFeed(caller, target, tab)` binds the EFFECTIVE tab (`posts`, `replies`, `media`, `reposts`; the first two strings are frozen, so every pre-W3 token stays valid and a Posts token on Media is `VALIDATION field=page_token|since_token` with 0 reads). MEDIA and REPOSTS run one `Limit(page)` `ByAuthorMedia` / `ByAuthorKind(KindRepost)` query with no author-recent read or write; `since_token`, `page_token`, gap tokens and `removed_ids` work as for Posts; the REPOST and QUOTE drop rules reuse `filterEmbeds`. `profile_tabs` gate (`flags.Guard`, `FEATURE_DISABLED` `feature=profile_tabs`) runs first with 0 reads, Posts and Replies stay ungated; request log carries `tab`. Budget asserted with `budgettest` through the real chain (`internal/apiserver/profile_tabs_integration_test.go`): 24 reads at page 20 and 54 at page 50 cold, 20 warm, 0 writes; fakes, flag-mode, token-matrix and drop-rule unit tests in `internal/timeline/tabs_test.go`. Rollout precondition: `profile_tabs` stays off in a project until the two W3-2 indexes are READY and the W3-8 backfill has run (`docs/runbooks/posts.md` section 13); the emulator enforces neither |
| W3-11 | graph: `GetProfileRelationship` ("Follows you", single target, +1 cold read) | backend-developer | S | Done (PR pending): `service.GetProfileRelationship` (`graph/relationship.go`) replaces the W3-4 Unimplemented answer; gated by `FEATURE_GRAPH` only. Order: flag, `user_id` format (VALIDATION, 0 reads), own id (NONE, false, 0 reads), `IsBlockedBy` (target blocked the caller: NOT_FOUND via `identity.ProfileNotFoundError`, the exact GetProfile answer, no Directory call and no edge read; +1 on `blockedByOverflow`), `Directory.GetProfiles` (missing, SUSPENDED or DELETING: the same NOT_FOUND), caller blocks target (`blocking`, `followed_by` false, no edge read), then `follows/{target}_{caller}` from the new pair cache in `graph.Cache` (5,000 pairs, TTL = `CACHE_TTL` <= 60 s, true and false cached) or one `Repo.FollowEdgeExists` point read. Eviction on this instance: `Follow` and `Unfollow` (any success) evict the edge they write, `Block` evicts both directions; the caller's own Follow/Unfollow never touches the opposite edge; other instances converge at the TTL. Log fields `graph_op=profile_relationship`, `followed_by_cache_hit`, `fs_reads`. Measured on the emulators: 2 reads cold (caller graph + edge, target profile warm), 0 warm, 3 with nothing cached, 1 right after the header's GetProfile, 1 for a blocked-by target (edge never read), 3 for an overflowed caller; no new flag, no proto change, `GetRelationships` unchanged. The apiserver W3 flag test now expects NOT_FOUND (unknown target) instead of Unimplemented for this RPC. |
| W3-10 | engagement: `ListLikedPosts` (owner-only, from `userLikes.recent`, live posts, drop rules) | backend-developer | M | Done (PR pending): `engagement.LikesList` / `Module.ListLikedPosts` behind `likes_list` (and `posts`, not `engagement`); the ids are `userLikes.recent` read newest first through the 60 s instance cache (no query), then ONE cache-first `Reader.GetMany` of the page; the ADR-0024 D6 cursor (`likes\|<uid>`, 24 h, payload `v1:<nextId>:<lastId>:<nextIndex>`, resume order next-if-older-than-last, else just older than last, else the offset from the newest end) so an unlike or re-like between pages skips and repeats nothing, issued only when older entries remain (25 likes give 20 + a token, then 5 + `""`); a tampered, foreign, cross-list or expired token is VALIDATION `page_token` with 0 reads; the drop rules and the request-line counters are the ListBookmarks code moved to `list_common.go` and shared (`dropRows`, `blockCause`, `privateToViewer`, `noteRows`, `openListToken`), no pruning, no `rows_pruned`; `NewServer` takes the `LikesList` from `svc` (the Module), so `apiserver.go` is untouched; measured cold 23 reads at page 20, 53 at page 50, 2 for an empty array, 5 for the warm second page, 0 writes (the ticket said 24 / 54, ADR-0024 D6 corrected it to 23 / 53; both are asserted). W3-23 emulator runs: later cold pages 20 / 50; a warm page costs the number of its posts that are not in the 60 s post cache, 0 when all are (not "3"); scrolling a 1,000-like list at page 50 is 1,003 reads |
| W3-12 | graph: `ListSuggestedUsers` (friends of friends + curated fallback, hard cap, cache) | backend-developer | M | Done (PR pending): `ListSuggestedUsers` returns at most 5 rows (no cursor, `since` unset) behind `follow_suggestions` and `graph`. The `in` + order-by query runs on the existing `follows (followerId ASC, createdAt DESC)` index (verified from `firebase/firestore.indexes.json`: the last field is DESC, so `__name__ DESC` is served; the emulator test seeds interleaved followers and asserts a global newest-first order; no index change). The viewer's newest 30 followees come from the new ordered `Snapshot.RecentFollowing` (the tail of `following`, filled by `toSnapshot`). `graph.Suggester` is the seam (default friends of friends with the curated fallback; `Deps.Suggester` swaps it); candidates are ranked by count, ties by a hash of (viewer, candidate, IST day); the exclusion matrix (self, following, requested, blocked, blockedBy, muted) runs inside the suggester and again in the service; the "fewer than 3" test comes after the matrix; ONE `Directory.GetProfiles` over <= `HYDRATE_MAX`; `BlockedByOverflow` suggests nothing (`source=none`). Per-viewer instance cache holds the hydrated rows (expiry kept in the entry, never stretched by a removal); own Follow, Block and Mute evict at once; a warm hit re-checks a cached snapshot at 0 reads. Reads: cold 41 in the service + 1 interceptor = 42 (measured: graph 1 + edges 30 + profiles 10; the chain test logs `fs_reads=42`), curated 6 in the test world (cap 12), warm 0 + interceptor. Log fields `source`, `candidates`, `suggestions_cache_hit`. Tests: unit (exclusion matrix per category, ranking and daily shuffle, sources, caps, cache eviction and expiry, errors with redaction, a custom `Suggester`, concurrency) and emulator integration in `graph` and through `apiserver.Build`. Runbook `graph.md` section 6, code-map row; nothing wired in `apiserver.go` |
| W3-13 | Profile header polish: sticky tab bar with per-tab scroll (B-06), app-bar name fade (B-05), "Joined Month YYYY" | frontend-developer | M | Done (PR pending): `NestedScrollView` with a pinned `PinnedHeaderSliver` tab bar, one `TimelineCubit` per opened tab (offset kept by a `PageStorageKey`), pull-to-refresh per tab, scroll-linked app-bar name fade (steps under reduced motion), "Joined Month YYYY" from `created_at` (B-05, B-06 closed). |
| W3-14 | Profile header data: banner image, location and website in the meta row, "Follows you" chip, "Follow back" | frontend-developer | M | Done (PR pending): the 3:1 band shows the banner (thumb below 600 dp, full from 600 dp, flat placeholder, no layout jump), the meta row adds location (pin) and website (link, host only, punycode, opens externally) before "Joined", `ProfileCubit` loads the relationship through `GraphRepository.profileRelationshipFor` (one `GetProfileRelationship` call replacing `GetRelationships`; UNIMPLEMENTED and FEATURE_DISABLED degrade to "no `followed_by`" with a 10-minute per-RPC backoff), the "Follows you" chip sits beside the handle and Follow reads "Follow back". The dev check waits for W3-6 and W3-11. |
| W3-16 | Profile tabs: Reposts and Media (Posts · Replies · Reposts · Media) | frontend-developer | M | Done (PR pending): with `profile_tabs` in `GetMe.enabled_features` the profile shows Posts · Replies · Reposts · Media in equal widths, otherwise Posts · Replies as before; each tab is a `TimelineCubit` over `FeedKey.user(uid, tab: UserFeedTab...)` with its own rows, `since_token`, `page_token` and gap tokens (sent back unchanged), Media rows are the normal post card (no grid), the empty states have our own copy. Posts and Replies still go out as UNSPECIFIED + `include_replies` (byte-identical to pre-W3, so an older server answers them as before); only Reposts and Media set `tab`. A FEATURE_DISABLED `profile_tabs` answer (the repository then sends 0 further RPCs for those tabs) drops both tabs and shows Posts; a rejected token cold-opens that tab only. `TimelineFeedView(fillViewport: true)` follows `next_page_token` through short or empty pages. The dev check waits for W3-9 (#336) and the flag on a dev allowlist. |
| W3-15 | Edit profile: banner editor (3:1 crop, on-device resize, upload) and location / website fields | frontend-developer | M | Done (PR pending): with `profile_extras` on, Edit profile shows a `BannerEditor` above the avatar (it also needs `media`; without media a saved banner is shown read-only with Remove, see the W3-15 detail below) and Location and Website fields. Banner: pick, centered exact-3:1 crop, 1500 x 500 / 600 x 200 JPEG under the banner's 1 MiB / 128 KiB caps on the device (no pan UI; the preview is the exact result), `CreateUpload(BANNER)` with one item, upload, `FinalizeUpload`, then `UpdateProfile.banner_media_id`; Remove sends `""`. Location (<= 30 code points after NFC and trim, one line, no control or bidi) and website (http/https with a host via `parseProfileWebsite`, <= 100, host preview) have counters and inline errors. One helper, `ImageUploadSlot` (purpose as a parameter), now carries the avatar and the banner, and `EditProfileCubit` keeps each media id and the idempotency key across retries. Request shaping: changed fields only, `""` clears, and nothing but a clear reaches a request while `profile_extras` is off for the caller (setting is hidden; Amendment 1 A2 keeps Remove for an existing banner, location and website: done in W3-22 M-1(c), PR pending: with the flag off for the caller each saved one is shown read-only with Remove (the banner band with its Remove button, which needs neither `media` nor the flag; the location and website in the same outlined `TextField` as the editable ones, `readOnly`, with a 48dp close button), Remove sends an exact `""` and the request carries no other extra, and a FEATURE_DISABLED answer to a clear from a revision without #354 hides Remove); FEATURE_DISABLED `profile_extras` (from UpdateProfile or CreateUpload) hides the extras and keeps the name and bio edit; MEDIA_NOT_READY drops every picture that was sent (the answer names none); VALIDATION `field=location|website` shows inline. `buildUpdateProfileRequest` is the one place an UpdateProfile request is shaped (W3-17 reuses it with `pinnedPostId`). Client only; the dev check needs a dev allowlist uid with `profile_extras` and `media`. |
| W3-17 | Pinned post: "Pinned" row on the Posts tab, Pin / Unpin in own post's menu | frontend-developer | M | Done (PR pending): when `Profile.pinned_post_id` is set the Posts tab shows a muted "Pinned" row (pin icon) above that post, loaded with one `GetPost` by a `PinnedPostCubit` (hidden silently on NOT_FOUND; any other failure shows a notice with Retry and keeps the post in the feed), and the post is filtered out of the Posts cubit's rows (`TimelineCubit.setExcludedPostId`), so it is not repeated below and does not flash there while the row loads. The row renders whatever the viewer's flags are. With `profile_extras` on, the own profile's post menus (every tab, and the Pinned row) offer "Pin to your profile" / "Unpin from profile" on a POST, QUOTE or REPLY (never a REPOST) through `UpdateProfile` with `pinned_post_id` (`""` unpins, a present field), one idempotency key per intent and reused on retry, a confirm when replacing a pin, "This post can't be pinned." for the one VALIDATION answer, and a FEATURE_DISABLED `profile_extras` answer hides the rows until the next `GetMe`. Amendment 1 A2 (W3-22 M-1) narrows that: only "Pin to your profile" needs `profile_extras`, "Unpin from profile" is offered whenever a pin is shown (an empty value is always accepted): done in W3-22 M-1(c), PR pending (`PostPinControl.canPin` gates only Pin; the control is built on every own profile). A success reaches `OnboardingProfileUpdated` and `ProfileCubit.profileUpdated`. Deleting the pinned post from its row clears the pin and the count locally. Only the own profile offers the rows (Home and the post detail do not; one `PostPinControl` seam would add them). Cost: 1 `GetPost` per profile open with a pin (and one after pinning). The dev check waits for W3-6 (merged) and `profile_extras` on a dev allowlist. |
| W3-18 | History: Likes tab on `/bookmarks` | frontend-developer | M | Done (PR pending): `/bookmarks` is titled "History"; with `likes_list` on, `AppTabBar` with the tabs Bookmarks and Likes (with it off there is no tab bar and `?tab=likes` is ignored); `/bookmarks?tab=likes` lands on Likes (the router passes the query; `deepLinkTarget` is unchanged, so a signed-out cold open of the link lands Home); each tab's cubit exists, and asks the server, only when the tab is first selected (Likes: 1 `ListLikedPosts` per open, 23 cold reads per page of 20), both then keep rows and scroll; `LikesRepository` is the one caller (session memory only, follows `next_page_token` through short and empty pages, dedupes by post id, gated by `likes_list`, UNIMPLEMENTED treated like disabled for 10 minutes without a report, its own per-minute hold apart from the shared read-budget hold, dropped on sign-out); `LikesListCubit` removes a row when the `EngagementCubit` overlay says it was unliked (rolled back on failure, the failure worded by the tab) and reloads page 1 on `VALIDATION page_token`; the list body is shared with Bookmarks as `HistoryPostList`; the empty and end copy state the 1,000-most-recent limit. The dev check waits for W3-10 (#339). |
| W3-19 | Who to follow: Home card and the desktop right-column "You might like" | frontend-developer | M | Done (PR pending): `SuggestionsRepository` (24 h per uid in memory and in `AppSettingEntries` under the wiped `account:` prefix, one shared call, FEATURE_DISABLED / UNIMPLEMENTED / RESOURCE_EXHAUSTED handled, session-only dismissals, `SessionEpoch` clear), one `SuggestionsCubit` above both surfaces, `WhoToFollowCard` (3 rows, Show more to 5, x, a followed row leaves once the server confirms) in Home `headerSlivers` under the opt-in card and in `AppSideColumn.sections` (needs `ui_shell`); `UserListRow` gained `onFollowed`, `onDismiss`, `showDivider`; client only, the dev check waits for W3-12 |
| W3-21 | Part A client tests: responsive matrix, flag-off routing, text scale | tester | S | Done (PR pending): `docs/reviews/test-report-w3-client.md`. Matrix cells (360 / 600 / 1200 dp x light / dark x 1.0 / 1.3 / 2.0, asserting no exception, key elements inside the screen, 48 dp targets, the tab bar pinning under the app bar) for the profile screen (header data, "Follows you" and "Follow back" on both `GetProfileRelationship` paths, the four tabs and their empty copy, Pinned row, its error notice and the pin menu rows and replace confirm), Edit profile (banner editor, Location, Website, counters, inline errors, media off, extras off), `BannerEditor`, History and its Likes tab (empty, end note, error, refresh banner, flag off), the Who to follow card in Home and the 350 dp right column. Routing: `/bookmarks` and `/bookmarks?tab=likes` under all eight `posts` / `bookmarks` / `likes_list` combinations, the History drawer row, the four tab sets of `replies` x `profile_tabs`. Banner: the header is the same size before, while and after the image resolves, with no banner, and when a banner is added, replaced or removed; failed images (403 / 404) fall back to the placeholder surface. One defect D-1 (skipped repro): at 360 dp x text scale 2.0 the header actions overlap the display name; fixed in the W3-22 client PR (#361, pending: the strip under the banner grows with the actions), which also turns the repro on (`d1Fixed`). |
| W3-20 | Part A backend tests: flag matrix, authz, budgets, token binding, drop rules, backfill | tester | M | Done (PR pending): 39 integration tests (315 cases) in `backend/internal/apiserver/w320_*_integration_test.go` and `backend/internal/media/banner_matrix_integration_test.go`: the four flags in ten rollout states against every gated RPC (refusals at exactly 0 reads and writes), `profile_extras` fields refused while off, the shared `testdata/profile_text` fixture over the wire (61 accept / 126 reject), the pin rules, the 200-pair tab token matrix (52 open, 148 refused), the D6 drop matrix on Reposts, Media and Likes, unlike between pages, "Follows you" and NOT_FOUND byte identity with GetProfile, the suggestions exclusion matrix and the exact 42-read cap, the banner moderation and claim paths, the backfill rerun at 0 writes, the W3-22 M-1 kill switch and clears after #354 (website hidden under a global off, the exact "" clears from any caller, whitespace-only gated, mixed clear and set refused whole), and a budget table for every Part A RPC at the ADR-0024 ceilings (no cell over). Combined `internal/` coverage 92.5%. Report `docs/reviews/test-report-w3.md`: defect D-1 (Low, likes cursor repeats earlier pages after "Last unliked, Next unliked and re-liked", `engagement/service_likes_list.go:100`), D-2 (test infrastructure: a shared Storage emulator temp directory let one suite crash another; fixed on main by #358); M-1 is verified (the two pre-fix constants are flipped) |
| W3-22 | Security review, Part A | security-auditor | M | Done (PR pending): `docs/reviews/security-review-w3.md`, verdict CLEAR WITH FIXES (no Critical or High; code reviewed on `main` 3a4e175, plus W3-17 f4dcec5, W3-18 fee1c0d, W3-19 fb1ce73). Major: M-1 `profile_extras` off leaves websites rendering, clears are FEATURE_DISABLED outside the cohort and no operator lever is narrower than `suspend-user` (ADR-0024 D9 note by the architect, then backend-developer and frontend-developer; backend A1-A3 built on `fix/w3-22-m1-backend`: the website is omitted while globally off, an exact `""` is always accepted, `opsctl clear-profile-fields` and ACCOUNT report evidence exist; the client Remove / Unpin follow-up is done in the client M-1(c) item below (PR pending); A4 backend is built on `feat/w3-22-a4-media-retire` (PR pending): a replaced or removed avatar or banner is retired by the `profile_media_retired` job on the existing jobs topic (`customTime` on both objects plus a bucket lifecycle rule `days_since_custom_time = 1`, then `retiredAt` and a 72 h TTL on the media document), switch `PROFILE_MEDIA_RETIRE=off|banner|all` default off, config not a flag; `opsctl clear-profile-fields` calls the same step; the lifecycle rule must be applied in dev before the switch leaves `off`, and `all` waits for the app's avatar placeholder release, see `docs/pending.md` 3.12); M-2 the public media bucket is listable (`allUsers` `roles/storage.objectViewer`; production-deployer, the prod apply needs the founder's OK); M-3 concurrent `FinalizeUpload` calls screen one image several times and can burn `VISION_MONTHLY_CAP` (backend-developer). Low: L-1 suggestions can serve a blocker for up to 1 h (server) and 24 h (client); L-2 profile text rules and server/client drift (location U+2028/2029, websites stored but never rendered, display name and bio without control or bidi rules); L-3 website hosts on the viewer's LAN (IP literals, `localhost`, `*.local`); L-4 `UpdateProfile` has no daily cap and always writes; L-5 friends-of-friends steering by one followee. Info I-1 to I-6; I-3 is a W3-24 precondition (100% of dev traffic on a revision with #335 before `profile_extras` goes on). None blocks W3-24; M-1, L-1, L-2, L-3 and L-5 land before their flags leave the dev allowlist, M-3 before `media` or `profile_extras` widen past an allowlist in prod, L-4 in the next backend fix PR. Fixes: server L-1, L-2, L-3 and L-5 in #350, M-3 and L-4 in #351; client L-1, L-2 and L-3 done (PR pending): a suggestion row the server answers NOT_FOUND for is dropped silently, from the cached list too; the Dart profile text and website rules (display name and bio added) pass every row of the shared `testdata/profile_text/` fixture; client M-1(c) done (PR pending, `fix/w3-22-client-remove-unpin`): Edit profile's Remove for a saved banner, location and website while `profile_extras` is off for the caller, "Unpin from profile" ungated, the `AppAvatar` and `ProfileCoverBand` load-error placeholders (any load error, the media bucket's 404 for a retired object included, at the same size; the client precondition of `PROFILE_MEDIA_RETIRE=all`, ADR-0024 A4 point 5, which needs an app release with it), and the W3-21 defect D-1 (the profile header's action button no longer covers the name at 360 dp and text scale 2.0: the strip under the banner grows with the actions) |
| W3-23 | Cost report, Part A: `cost-model.md` rows, load smoke of tabs, likes, suggestions | sre-performance | S | Done (PR pending): `docs/reviews/cost-model.md` gets the Part A rows (section 1 assumptions, section 2 W3 block and notes, section 3 shares and crossovers, section 4 quotas and the W3-22 risk rows, section 5 bill, section 6 triggers, section 9 watch queries, new section 12 measurements); new k6 scenario `loadtest/profile_w3_part_a.js` (Media and Reposts tabs with a viral-profile load, `GetProfileRelationship`, `ListLikedPosts` with a 1,000-like scroll, `ListSuggestedUsers` with a 600-followee viewer) and `loadtest/analyze_w3_part_a.js`, run green on alternate-port emulators (built from `main` fcd0145) together with the repository `budgettest` lines; the three tests that #350 (L-1) and #351 (M-3, L-4) changed were re-run at 16524df (banner Finalize 2 reads / 3 writes, a warm suggestions hit with the snapshot expired 1 read plus the interceptor, an identical profile save 0 writes), the k6 scenarios were not. Measured: tabs 24 cold / 21 typical / 20 warm (page 50: 54 cold), likes 23 cold / 53 at page 50 / 0 warm when the posts are cached, relationship 4 fully cold / 1 after GetProfile / 0, suggestions 42 cold (also at 600 followees) / 12 curated / 0 to 1 warm (2 after the 60 s caches since W3-22 L-1), pin job 2 reads, backfill 1 write per legacy post. Part A restated to **+51.5 reads/DAU** (plan 40.1; the extra 10.7 is the who-to-follow call mix, 35.7 not 25, because the 24 h client cache leaves almost no warm server hits), +0.06 writes, +0.005 deletes, +0.30 Vision units per DAU-month, **INR 30 / 58 / 275 a month at 300 / 1,000 / 3,000 DAU** (Stage 0 with W2: about 471 / 1,711 / 3,773; idle +0). Who to follow is 11.9% of reads against its own 10% trigger: choose a lever (48 h client cache 6.3%, edge limit 20 9.4%) before the ramp. BUDGET: HOLDS (pay per use, no RPC over its documented budget) |
| W3-24 | Dev rollout, Part A: indexes built, backfill, Terraform plan, allowlist, smoke | production-deployer | S | Done (dev applied 2026-10-27; smoke: the server-side legs that need no credential ran and passed, namely `/health` 200, the new revision `Ready` and serving with no ERROR log line, `validate-revision.sh` all checks passed, the three new RPC paths answering 401 unauthenticated, and the 5xx filter on the four RPCs empty after the 15-minute watch (no call of those RPCs was made in it, so the error-rate trigger can only be judged once the testers use them); the authenticated legs of runbook 4.1 and 4.2 and the app steps are owed to the testers, because no tester or smoke credential is on the deploying machine; the flag-off check of runbook section 5 was not run, it is the rollback check and its command is documented). On the founder's GO for all three decisions: the real `opsctl backfill-has-media` ran in dev (dry run 74 scanned and 73 missing; real run 73 writes; rerun 0 writes), the nine lines went into the gitignored dev `terraform.tfvars` (the four flags to `allowlist` with the same 3 test uids as bookmarks, percents 0, `SUGGESTED_USER_IDS` = the same 3 uids), and the targeted plan (`-target` the `api` service and the `billing_alerts` topic: 0 to add, 1 to change, 0 to destroy; 24 env entries added, none removed or changed; the pending.md 3.10 drift excluded) was applied. The new revision `api-00306-482` (same image digest as the revision serving before, `api-00564-vik`, main `b0bc56d7`) serves 100% since about 17:16 UTC; a plan after the apply says No changes; fallback revision `api-00564-vik`. Evidence and the numbers: `docs/runbooks/w3-part-a-rollout.md`, Status and section 8 (PR pending). The open W3-23 item stands: who to follow is modelled at 11.9% of daily reads against its 10% trigger (levers: a 48 h client cache or `SUGGESTIONS_EDGE_LIMIT` 20); choose before `follow_suggestions` ramps past the dev allowlist. Still to do: the authenticated smoke legs by the testers, then the flag-off check |
| W3-25a | Part B contract: the ADR-0025 D14 protos, the D15 `privacy.uids` fieldOverride and ack, the D16 pointer notes, `firestore-data-model` rows | architect | S | Done (PR #372): protos `buf lint` / `buf breaking` clean, no generated code (W3-25b); 36 overrides, ack re-hashed (founder-gated files); skill rows; ADR-0003 / ADR-0008 notes; AQ1 to AQ6 answered in ADR-0025 |
| W3-25b | Part B plumbing: `make proto`, `FEATURE_PRIVATE_ACCOUNTS`, config and limits, `quota.PrivacyToggles`, ceiling, Terraform vars, seam declarations | backend-developer | S | Done (PR #379) (depends: W3-25a) |
| W3-25c | Part B contract: `AuthorSnapshot.is_private` (field 6) for the lock badge on user-list rows, ADR-0025 implementation note | architect | S | Done (PR #391): proto only, `buf lint` / `buf breaking` clean, no generated code (W3-28c runs `make proto`); founder decision 2026-10-28, Option A |
| W3-26a | Part B identity: the protected set, the `ProtectedAuthors` loader, the `is_private` toggle (quota, cap), `PrivacyListener`, identity-step clean-up and T11 `privacy` row | backend-developer | M | Done (PR #383; depends: W3-25b) |
| W3-26b | Part B identity: GetProfile pin omission (`BlockChecker.IsFollowing`), GetMe `pending_follow_request_count` | backend-developer | S | In review (PR #395) (depends: W3-26a, W3-28a) |
| W3-27 | Part B graph: Follow to a protected account creates a request; withdraw; Block clean-up; `REQUESTED` everywhere | backend-developer | M | Done (PR #385; depends: W3-25b; merges only after W3-32, T11 guard) |
| W3-28a | Part B graph: `ListFollowRequests`, `RespondToFollowRequest`, PROTECTED_ACCOUNT on follower lists, the request count | backend-developer | M | Done (PR #388) (depends: W3-27, W3-26a) |
| W3-28b | Part B graph: the `privacy_public` job (auto-accept on switch to public) and its `PrivacyListener` adapter | backend-developer | S | Done (PR #396) (depends: W3-28a, W3-26a) |
| W3-28c | Part B graph: `make proto` and `is_private` on every graph user-list row from the hydrated profile | backend-developer | S | Done (PR #393): `make proto` run, generated Go and Dart committed; `toProtoAuthorSnapshot` fills `is_private` from the hydrated profile, +0 reads; full-chain emulator test over the six lists |
| W3-29a | Part B posts: `posts.Audience` (the one predicate), GetPost and `Viewable`, repost and quote refusal, computed visibility, the PROTECTED embed | backend-developer | M | Done (PR #382) (depends: W3-25b; merges after W3-26a) |
| W3-29b | Part B posts + engagement: GetThread, ListBookmarks and ListLikedPosts through `Audience` | backend-developer | M | In review (PR #386) (depends: W3-29a) |
| W3-30 | Part B timeline: `author_protected` on GetUserTimeline, feed embeds through `Audience` | backend-developer | S | Done (PR #384) |
| W3-31 | Part B notifications: `follow_request` and `follow_accepted`, protected-actor suppression | backend-developer | S | Done (PR #380; depends: W3-25b; W3-26a and W3-29a merged) |
| W3-32 | Part B lifecycle: `follow_requests` eraser step and export section, T11 row flip | backend-developer | M | Done (PR #381; depends: W3-25b; merges before W3-27) |
| W3-33a | Part B client: protected profile view, lock badge, Requested and withdraw, protected follower lists | frontend-developer | M | Done (PR #389) (depends: W3-26a, W3-27, W3-30 serving dev) |
| W3-33b | Part B client: "Protect your posts" setting, protected embed, refusal and error copy | frontend-developer | M | Done (PR #387; avatar follow-up PR #390) |
| W3-33c | Part B client: the lock badge on `UserListRow` from `UserListItem.user.is_private` | frontend-developer | S | Done (PR #394; depends: W3-28c serving dev, W3-33a) |
| W3-33d | Part B client: outlined Requested and Following fit `UserListRow` at 360 dp x2.0 | frontend-developer | S | In review (PR #399; depends: W3-33c) |
| W3-34 | Part B client: Follow requests screen, drawer badge, the two notification rows | frontend-developer | M | Open (depends: W3-28a, W3-26b, W3-31 serving dev) |
| W3-35a | Part B tests: the D4 visibility matrix on every read path, byte identity, media-URL leaks, the audience guard, budget table | tester | M | Open (depends: W3-26b, W3-28a, W3-29b, W3-30, W3-31) |
| W3-35b | Part B tests: request lifecycle and races, I-R and I-X, the `privacy_public` job, flag matrix, eraser and export | tester | M | Open (depends: W3-27, W3-28a, W3-28b, W3-32) |
| W3-35c | Part B client tests: responsive matrix, flag-off routing | tester | S | Open (depends: W3-33a, W3-33b, W3-34) |
| W3-36 | Part B security review | security-auditor | M | Done (PR #403): CLEAR WITH FIXES; M-1 gates W3-38, M-2 before the allowlist widens (depends: W3-26a to W3-32 merged; client tickets at branch heads) |
| W3-37 | Part B cost report and load smoke | sre-performance | S | Open (depends: W3-26a to W3-32 merged) |
| W3-38 | Part B dev rollout | production-deployer | S | Open (depends: W3-35a to W3-35c, W3-36 M-1(c) (its precondition 2), W3-37, founder OK) |
| W3-39 | W3-36 M-2: unguessable public media object names for new uploads (ADR-0025 note W3-36 M-2) | backend-developer | M | Open (depends: W3-36 review; gates `private_accounts` leaving the dev allowlist in any project) |
| W3-40a | W3-36 L-1, L-3, L-5: undo RPCs answer the missing-post shape, the loader's stale copy, the startup wiring assertion | backend-developer | M | Open (depends: W3-36 review) |
| W3-40b | W3-36 L-4 and W3-35b O-1: `ProtectedAuthor` skips own and followed authors and reports once per request; a stuck `privacy_public` delivery acks | backend-developer | S | Open (depends: W3-40a, W3-35b merged (PR #405)) |
| W3-41a | W3-36 L-2 backend: the owner's own REPOST, like and bookmark rows of a protected author kept as stripped placeholders (ADR-0025 note W3-36 L-2) | architect (proto) then backend-developer | M | Open (depends: W3-40b) |
| W3-41b | W3-36 L-2 client: the placeholder rows with Undo, Unlike and Remove | frontend-developer | S | Open (depends: W3-41a and W3-40a serving dev) |
| W3-42 | W3-36 M-1(b): the `PRIVATE_ACCOUNTS` rollback floor in `flag-ceiling.json`, enforced by `resolve-rollback.sh` | production-deployer | S | Open (depends: none; founder review of the gate file; gates any prod ramp) |

## Milestones
| # | Milestone | Tickets | Exit |
|---|---|---|---|
| M1 | Decisions and contract | W3-1, W3-2, W3-3, W3-4 | ADR-0024 merged (accepted), protos and indexes merged, flags registered, generated code committed; ADR-0025 Proposed |
| M2 | Part A build: backend ‖ client | W3-5 to W3-12 ‖ W3-13 to W3-19 | every Part A RPC implemented behind its flag; every screen built and widget-tested |
| M3 | Part A verification | W3-20 to W3-23 | tests green with budget assertions; security 0 Critical/High; cost report holds |
| M4 | Part A dev rollout | W3-24 | indexes READY, backfill run, dev allowlist on, smoke passed |
| M5 | Part B (ADR-0025 accepted 2026-10-27, #325) | W3-25a to W3-38 | contract, flag and seams merged (W3-25a, W3-25b); every Part B RPC and read path on `posts.Audience` behind its rules, budgets asserted (W3-26a to W3-32); client screens built and widget-tested (W3-33a to W3-34); tests green, security 0 Critical/High, cost holds (W3-35a to W3-37); fieldOverride READY, enforcement on 100% of dev traffic and on `last-good`, dev allowlist on, smoke passed (W3-38) |

## Order and parallelism
- **Start now (no dependency):** W3-1, W3-3, W3-13.
- **Then:** W3-2 after W3-1 is merged (merging the ADR is the founder's acceptance), then W3-4.
- **After W3-4, in parallel** (each touches only its own module's files):
  - backend W3-5, W3-6, W3-7, W3-10, W3-11, W3-12;
  - then W3-8 and W3-9 after W3-7.
- **Client after W3-4:**
  - W3-15, W3-18 and W3-19 start at W3-4;
  - W3-14 and W3-16 wait for W3-13 as well, because they share `profile_header.dart` and `profile_screen.dart`;
  - W3-17 follows W3-16, which owns the same file.
  - Each client ticket's dev check waits for its backend ticket: W3-14 for W3-6 and W3-11, W3-15 for W3-5 and W3-6, W3-16 for W3-9, W3-17 for W3-6 and W3-7, W3-18 for W3-10, W3-19 for W3-12.
- **Then** W3-20 to W3-24, with W3-22 and W3-23 done before any flag leaves `off` in dev.
- **Part B** (W3-25a to W3-38): ADR-0025 is accepted (#325), so Part B can start. The batches, the merge-order constraints (W3-32 before W3-27 for the T11 guard; W3-26a before the consumers of the protected set) and the shared files are in "Part B: order, parallelism and gate files" under Tickets.
- **`apiserver.go` has one owner per change.** W3-4 does all W3 config and flag plumbing there, including passing the suggestion config into the graph module. W3-6 wires `identity.WithBannerResolver` and `identity.WithPinChecker` to the media and posts implementations, so W3-6 merges after W3-5 and W3-7 (it builds and tests against fakes until then). No other W3 ticket edits `apiserver.go`. W3-9, W3-10, W3-11 and W3-12 add methods to servers that are already registered.
- **`app_router.dart`:** W3-18 (`/bookmarks?tab=likes`) merges after W2-9, which rewrites the redirect logic in the same file.

**Running alongside W4 (search and Explore).** W4 has no detailed plan yet, so the overlap is named by file, not by ticket:

| Shared file | W3 ticket | Rule |
|---|---|---|
| `firebase/firestore.indexes.json`, `firebase/field-overrides.ack` | W3-2, W3-25a | founder-gated; merge one wave's index PR at a time, the other merges `origin/main` and re-hashes the ack |
| `scripts/promotion/flag-ceiling.json`, `backend/internal/config/config.go`, the flag registry in `apiserver.go`, `ratelimit_config.go`, Terraform `feature_*` vars | W3-4, W3-25b | serialize the merges with W4's flag ticket |
| `proto/dzeroth/{common,identity,graph,timeline,posts,notifications}/v1/*.proto` | W3-25a | ADR-0025 D14 fixes `ErrorReason` 17, `GetMeResponse` 6, `NotificationType` 7 and 8, `EmbedViewerState` 3, `GetUserTimelineResponse` 6; W4-2 and later waves take the next free numbers |
| `app/lib/shared/widgets/app_side_column.dart` | W3-19 | W4 puts "What's happening" in the same column; whoever merges second rebases |
| `app/lib/features/profile/presentation/widgets/profile_header.dart` | W3-13, W3-14 | W4's profile search icon (B-04) waits for W3-14 |

- **Safe to run concurrently with W4:** every other W3 ticket. That covers the identity, media, posts, timeline, engagement and graph tickets W3-5 to W3-12, and the client tickets W3-15 to W3-18. W4 adds a new `search` module and proto, and an Explore screen.
- **Ownership split:** W3 owns "who to follow" (`GraphService.ListSuggestedUsers`). W4's "suggestions" means search typeahead. W4's Explore may reuse W3-19's card.
- **Private accounts:** ADR-0025 is accepted and precedes W4's ADR (question 1). W4's search paths must call `posts.Audience.Decide` on every result (ADR-0025 D4, D16); the W3-35a audience guard fails `make ci` on a package that builds post rows without it.

## Non-functional targets (Stage 0, ≤ 300 DAU; the credit window allows up to ~3k DAU and changes no target)
| Path | p95 warm | Cold incl. start |
|---|---|---|
| `GetUserTimeline` Reposts / Media tab (page 20) | < 400 ms | < 1.5 s |
| `ListLikedPosts` (page 20) | < 400 ms | < 1.5 s |
| `ListSuggestedUsers` | < 400 ms | < 1.5 s |
| `GetProfileRelationship` | < 150 ms | < 1.5 s |
| `UpdateProfile` with pin, banner or meta | < 500 ms | < 1.5 s |
| Part B: `ListFollowRequests` (page 20) | < 400 ms | < 1.5 s |
| Part B: `Follow` (request path), `RespondToFollowRequest`, `UpdateProfile` privacy toggle | < 500 ms | < 1.5 s |
| Part B: any read path that needs the protected set | unchanged (the refresh is one point read per instance per minute, shared by singleflight) | < 1.5 s |

Staleness bounds for every cached read:
- **Banner, location, website and pin:** the `users/{uid}` instance cache (60 s). A new banner gets a new object URL, so the immutable CDN headers never serve the old one.
- **"Follows you":** the `follows` doc cached 60 s per (caller, target). A Follow or Unfollow by the target shows on other instances within 60 s.
- **Suggestions:**
  - server cache per viewer up to `SUGGESTIONS_CACHE_TTL` (1 h);
  - client cache per uid for 24 h;
  - an account the viewer follows from the card is hidden at once, on the client and in this instance's cache.
- **Likes list:** `userLikes` cache 60 s; posts from the 60 s post cache.
- **Tabs:** no new cache. Every open reads Firestore; the Posts tab keeps its author-recent cache.
- **Part B, protected set** (ADR-0025 D3):
  - A toggle applies at once on the instance that committed it, and within 60 s (`CACHE_TTL`) on the others.
  - A failed refresh serves the last good set for at most 10 minutes (`PROTECTED_SET_MAX_STALE`), then fails closed with UNAVAILABLE.
- **Part B, `pending_follow_request_count`:** cached 30 s per protected caller.
- **Part B, "Requested":** from the caller's graph snapshot, with the same 60 s bound as blocks and follows (ADR-0008 D8).

## Cost (method: `free-tier-budget` §2 and the ADR-0022 marginal method of `cost-model.md` §5 and §7; no second model)
Prices: Firestore asia-south1 $0.035 / $0.104 per 100k reads / writes; Vision $1.50 per 1,000 units; egress to India $0.12/GiB; Cloud Run $0.000024 per vCPU-s and $0.40 per million requests; INR 95 per USD.

What the Stage 0 baseline has already used up at each scale (so every W3 unit of that kind is billed):

| Quota | Baseline runs out at | W3 at 300 DAU | W3 at 1,000 DAU | W3 at 3,000 DAU |
|---|---|---|---|---|
| Firestore reads | about 215 DAU | billed | billed | billed |
| Firestore writes | about 630 DAU | free | billed | billed |
| Vision | free 1,000 units at 82 DAU; the 10,000 cap at about 822 DAU | billed | INR 0 (at the cap) | INR 0 (at the cap) |
| GCS egress | about 2,133 DAU | free | free | billed |
| Cloud Run CPU | about 1,603 DAU | free | free | billed |
| Cloud Run requests | about 1,786 DAU | free | free | billed |

At the Vision cap, banners add INR 0 but displace about 304 / 913 units of post-image screening at 1,000 / 3,000 DAU; those images then follow `VISION_EXHAUSTED_POLICY`.

Restated by W3-23 on 2026-10-27 from measured `fs_reads` (`docs/reviews/cost-model.md` section 2 W3 block and section 12; the planning values are what the model multiplies, "cold" includes the account-status interceptor's read):

| RPC (Part A) | Reads cold / warm (planning) | Writes | Deletes | Calls/DAU | Reads/DAU |
|---|---|---|---|---|---|
| `GetUserTimeline` Media tab, page 20 | 24 / 20 (21: the first tab call after the header's calls pays one `userLikes` read); page 50: 54 | 0 | 0 | 0.3 | 6.3 |
| `GetUserTimeline` Reposts tab, page 20 | 24 / 20 (21); page 50: 54 | 0 | 0 | 0.15 | 3.15 |
| `GetPost` of a profile's pinned post (existing RPC) | 4 / 0 (1) | 0 | 0 | 0.6 | 0.6 |
| `UpdateProfile` with banner, pin or meta | 3 / 1 (+1 media via the resolver, +1 post via `PinChecker`) | 1 | 0 | 0.03 | 0.06 |
| `CreateUpload` + `FinalizeUpload`, BANNER | 2 + 2 in the service (measured) + 2 interceptor = 6 | 3 + 3 (Finalize `2n + 1` since the W3-22 M-3 claim write) | 1 (TTL) | 0.005 | 0.03 |
| `ListLikedPosts`, page 20 | 23 cold, 20 for later pages; warm = the page's posts not in the 60 s cache, 0 when all are (23); page 50: 53 | 0 | 0 | 0.2 | 4.6 |
| `GetProfileRelationship` (replaces the header's `GetRelationships`) | 4 fully cold (3 in the service) / 0; 1 after the header's GetProfile (1; +0.5 net) | 0 | 0 | 2 | 1.0 |
| `ListSuggestedUsers` (option a) | 42 friends of friends, 12 curated / 0 within 60 s, 1 within the hour (35.7: 95% cold, of those 85% friends of friends and 15% curated, 5% warm; was a flat 25) | 0 | 0 | 1.0 | 35.7 |
| Pin clean-up in the `post_delete` job | 2 (post gone, fresh; `users` in the transaction; was 1) / 1 when refused | at most 1 (only when the deleted post was the pin) | 0 | 0.05 | 0.10 |
| **Part A total** | | | | **≈ 2.3 new requests** | **≈ 51.5** (was 40.1; +22% over 232.3, +21% over 248.7 with W2) |

- **Why 51.5 and not 40.1 (W3-23):** +0.45 tabs (21 not 20 per open), +0.02 banner (6 reads not 2), +0.2 likes (23 not 22), +0.05 pin job (2 reads not 1), and **+10.7 who to follow: the 25 assumed about half the calls warm, but the client keeps the result 24 h, so a DAU makes about one call a day and the server's 1 h entry is expired by then; nearly every call is cold (42 or 12 reads)**. Measured per call nothing changed: 42 cold, 0 or 1 warm. Who to follow is now 35.7 of 300.2 reads/DAU (the whole product with W2): 11.9%, above its own 10% trigger (see Rollout and Out of scope).
- **Per DAU per day:** 51.5 reads, 0.06 writes, 0.005 deletes, 0.30 Vision units per DAU-month (0.005 banners per DAU per day x 2 units x 30.42). GCS egress is 1.34 MB per DAU-month: 1 uncached banner a day, 70% at the 20 KB thumb and 30% at the 100 KB full image. Cloud Run egress is 0.42 MB per DAU-month (2.3 x 6 KB) and Cloud Run CPU 7.0 vCPU-s per DAU-month.
- **Monthly bill, Part A (restated by W3-23; the first version of this table was 27 / 47 / 242):**

| DAU | Firestore | Vision | GCS (egress + Class B) | Cloud Run (egress + CPU + requests) | **Total INR/month** | vs Stage 0 baseline |
|---|---|---|---|---|---|---|
| 300 | 15.6 | 13.0 | 0 + 0.3 | 1.4 + 0 + 0 | **≈ 30** | 434 → 464 (+7%) |
| 1,000 | 52.1 + 0.2 writes | 0 (cap) | 0 + 1.2 | 4.7 + 0 + 0 | **≈ 58** | 1,626 → 1,684 (+4%) |
| 3,000 | 156.3 + 0.5 writes | 0 (cap) | 44.8 + 3.5 | 14.0 + 47.6 + 7.9 | **≈ 275** | 3,396 → 3,671 (+8%) |

Stacked on W2 (`cost-model.md` section 5) the Stage 0 bill with every flag on is about INR 471 / 1,711 / 3,773 at 300 / 1,000 / 3,000 DAU, idle +0. In credit mode (Vision cap 20,000 below 1,300 DAU, 40,000 above) banners are billed at 1,000 and 3,000 DAU: Part A is about INR 101 and 405 there.

- **Largest line:** who-to-follow (35.7 of 51.5 reads). Its levers, cheapest first, with the share of all reads each leaves (11.9% now):
  - a 48 h client cache (17.8 reads/DAU, 6.3%);
  - `SUGGESTIONS_EDGE_LIMIT` 20 (27.6, 9.4%);
  - curated-only for accounts following fewer than 10;
  - option (b) (question 2).
- **Storage:** a banner pair is about 120 KB per user who sets one (US bucket, inside the shared 5 GB). The two composite indexes add about 2 index entries per post (cents).
- **Not added:** no new GCP service, Scheduler job, Pub/Sub topic or fixed cost (INR 0 fixed).
- **Client-only tickets** (W3-13 and the render parts of the others): 0 new reads or writes.
- **Part B** (replaces the old placeholder of +3 reads, +0.2 writes): +1.25 request-path reads, plus the detached protected-set refresh of +3.2 / 2.4 / 1.4 reads, +0.16 writes and +0.05 deletes per DAU at 300 / 1,000 / 3,000 DAU, about INR 1.4 / 4.2 / 10 a month (ADR-0025 Cost impact). It is not in the Part A totals above; the per-ticket lines and the whole-product restatement are in "Part B: cost" under Tickets.

## Flags and ceilings
| Flag (wire name) | Gates | Dev ceiling (`flag-ceiling.json`) | Prod |
|---|---|---|---|
| `FEATURE_PROFILE_EXTRAS` (`profile_extras`) | `UpdateProfile` banner, location, website and pin fields (FEATURE_DISABLED `feature=profile_extras` when any is set to a non-empty value while off for the caller; an exact `""` clear always passes, Amendment 1 A2); `CreateUpload(BANNER)` needs it **and** `media` | `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}` | no raise (prod apply on hold, `pending.md` 1.2) |
| `FEATURE_PROFILE_TABS` (`profile_tabs`) | `GetUserTimeline` tab MEDIA / REPOSTS; Posts and Replies stay ungated | same | none |
| `FEATURE_LIKES_LIST` (`likes_list`) | `ListLikedPosts` (and needs `posts`) | same | none |
| `FEATURE_FOLLOW_SUGGESTIONS` (`follow_suggestions`) | `ListSuggestedUsers` (and needs `graph`) | same | none |
| `graph` (existing) | `GetProfileRelationship`, like every GraphService RPC | unchanged (on) | unchanged |
| `profile_snapshot` (existing) | still gates the Edit profile and Change handle screens (and the snapshot job); W3-15's new fields appear only on that screen, so they need `profile_snapshot` **and** `profile_extras` | unchanged | unchanged |
| `FEATURE_PRIVATE_ACCOUNTS` (`private_accounts`, Part B) | `UpdateProfile(is_private=true)` for the caller; `ListFollowRequests` and `RespondToFollowRequest` only while the flag is globally off and the caller is not protected (ADR-0025 D12). **Never gated:** the `posts.Audience` predicate on every path, Follow creating a request, withdraw, `is_private=false`, the `privacy_public` job, notification suppression, the eraser and export | `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}` (W3-25b) | none |

- **Why not reuse `profile_snapshot` or `media` alone:** `profile_snapshot` gates the author-snapshot job, and `media` gates every post image. Links, banners and pins need a kill switch of their own (phishing, Vision spend) that does not stop renames or post images.
- **Render rules:** rendering stays ungated where the data already exists. A banner, location, website or pin set while the flag was on keeps showing after a ramp-down to an allowlist or a percent. The only read cost of rendering is the client's `GetPost` of a pinned post. With `profile_extras` globally `off` (`Registry.GloballyOff`, 0 reads) identity omits `pinned_post_id` and `website` from every `Profile`, the owner's own included (W3-6 for the pin; ADR-0024 Amendment 1 A1 adds the website), so the phishing link disappears and clients stop the pin's `GetPost` call: that is the kill switch. Location and banner keep showing. Clearing a field (`""`) is allowed whatever the flag (Amendment 1 A2).
- **Ramp per flag:** off → dev allowlist (3) → founder decision for prod at MVP launch (allowlist → percent 5 → 25 → 100 → on; each step a Terraform change plus a tagged revision, ADR-0019).

## Abuse and security surface
- **New public reads:**
  - the Reposts and Media tabs (same bounds as the Posts tab: `Limit` ≤ 50, the existing user-timeline rate limit, the per-uid daily read budget);
  - `GetProfileRelationship`: reveals only what `ListFollowers` already shows; NOT_FOUND byte-identical to `GetProfile` when the target blocked the caller;
  - `ListSuggestedUsers`: no target parameter, no cursor, ≤ 5 results, so it cannot enumerate. It reveals followee edges that are already public, and never suggests anyone in `blockedBy`.
  - the pinned post id on `Profile`: rendering goes through `GetPost`'s rules.
- **New owner-only read:** `ListLikedPosts` takes no user id; the path comes from the token uid; the cursor is bound to `likes|<uid>`.
- **New writes:**
  - Banner: SafeSearch with the avatar's stricter Racy rule; the 20/day uploads quota; new accounts follow `VISION_EXHAUSTED_POLICY` at the cap.
  - Website:
    - scheme allowlist `https`/`http`;
    - no userinfo, no control or bidi characters, ≤ 100 characters;
    - the client shows the host, with punycode for non-ASCII hosts (homograph), and opens it externally.
  - Location: the bio text rules.
  - Pin: own, visible, non-REPOST post only; any other id is one VALIDATION answer, so the call is no existence oracle.
- **Rate limits and quotas** (config, rule 11):

| Key | Value | Notes |
|---|---|---|
| `RATE_LIMIT_SUGGESTIONS_PER_MIN` | 10 | |
| `SUGGESTIONS_CALLS_PER_DAY` | 50 | in-memory, per uid per instance |
| `SUGGESTIONS_SAMPLE_FOLLOWEES` | 30 | |
| `SUGGESTIONS_EDGE_LIMIT` | 20 | ADR-0024 Amendment 2 (#373); was 30 |
| `SUGGESTIONS_HYDRATE_MAX` | 10 | |
| `SUGGESTIONS_MAX_RESULTS` | 5 | |
| `SUGGESTIONS_CACHE_TTL` | 1h | |
| `SUGGESTED_USER_IDS` | ≤ 20 uids | Terraform var, not a secret |
| `RATE_LIMIT_LIKES_LIST_PER_MIN` | 10 | |
| `RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN` | 60 | |

  The tabs share the existing `GetUserTimeline` bucket. Every new RPC is charged to the per-uid daily read budget (ADR-0010 D5). The effective limit is per instance x 3 instances (`stage-ladder`).
- **Part B surface** (ADR-0025 D13; checked in W3-36).
  - **New owner-only reads:** `ListFollowRequests`, whose cursor is bound to `caller|follow-requests`, and `GetMe.pending_follow_request_count`.
  - **New writes:**
    - Follow creating a request: the follows quota 200/day (50 for new accounts), the Follow bucket 30/min (90 effective), and a 500-entry `requested` cap;
    - `RespondToFollowRequest`: `RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN` 60 (180 effective);
    - the privacy toggle: `QUOTA_PRIVACY_TOGGLES_PER_DAY` 4.
  - **Oracles:**
    - the protected state is public by design (`is_private`);
    - `PROTECTED_ACCOUNT` reveals nothing GetProfile does not;
    - P's posts are NOT_FOUND, byte-identical to a deleted post;
    - block is still checked first.
  - **Notification spam:** one push per requester per target per 90 d (deterministic ids).

## Tickets
**W3-1 ADR-0024** [depends: none] [architect, M]. Given the scope above, `docs/adr/0024-profile-and-graph-completion.md` (Proposed) decides each item with options and costs at idle, 300 DAU and 3k DAU:
- the banner media kind (sizes, moderation rule, resolver, what happens to replaced objects);
- the `users` fields (location, website, `pinnedPostId`, banner URLs; all index-exempt);
- the pin validation through a consumer-side `identity.PinChecker` (the `BlockChecker` pattern, so identity never imports posts);
- the `GetUserTimeline` tab enum, its precedence over `include_replies` (rule 9: the old field stays), and tokens bound to the tab;
- `posts.hasMedia` (set on CreatePost, quotes with images, replies with images and the scheduled publish sweep; false on REPOST) and its backfill;
- `ListLikedPosts` (owner-only, from `userLikes.recent`, resume-by-position cursor, ADR-0010 D6 drop rules);
- `GetProfileRelationship`;
- `ListSuggestedUsers` (question 2, with the emulator check of the `in` + `orderBy` shape);
- the four flags, the rate-limit keys, a per-RPC budget table and the stage ladder (below).

A banner change does not enqueue the author-snapshot job (the banner is not in `AuthorSnapshot`). The founder accepts by merging and answers questions 2 to 9. Seam: `identity.PinChecker`, `graph.Suggester`, `engagement.LikesList`, the timeline tab behind the `timeline` interface. Cost: the ADR's table is the source for W3-5 to W3-12.

**W3-2 Proto + indexes** [depends: W3-1 merged] [architect, M]. All changes are additive; `buf lint` and `buf breaking` are clean. Field numbers are the architect's.
- `identity.proto`: `Profile` gets the banner URL and thumb URL, location, website and `pinned_post_id`; `UpdateProfileRequest` gets `optional` banner media id, location, website and pinned post id (`""` clears).
- `media.proto`: `MEDIA_PURPOSE_BANNER`.
- `timeline.proto`: a `UserTimelineTab` enum (UNSPECIFIED = use `include_replies`, POSTS, REPLIES, MEDIA, REPOSTS) on `GetUserTimelineRequest`.
- `engagement.proto`: `ListLikedPosts`.
- `graph.proto`: `GetProfileRelationship`, `ListSuggestedUsers`.

Each RPC comment carries its reads and writes from W3-1. `firebase/firestore.indexes.json` gains:
- the composite indexes `posts (authorId ASC, hasMedia ASC, createdAt DESC)` and `posts (authorId ASC, kind ASC, createdAt DESC)`;
- fieldOverrides `indexes: []` for `users.bannerUrl`, `users.bannerThumbUrl`, `users.location`, `users.website` and `users.pinnedPostId`;
- the matching `firebase/field-overrides.ack` hash.

**Both files are founder-gated (CODEOWNERS).** It also updates the `firestore-data-model` skill rows (users, posts, op-cost table). `make proto` is run in W3-4, not here. Seam: opaque, tab-bound tokens. Cost: 0.

**W3-3 ADR-0025 private accounts** [depends: none; acceptance is founder question 1] [architect, M]. `docs/adr/0025-private-accounts-and-follow-requests.md` (Proposed) amends ADR-0008 D1 and records the founder's reversal in Deciders. It decides:
- `is_private` toggling (quota, what happens to pending requests on switch to public);
- the request lifecycle (`followRequests/{a}_{b}`, `graph.requested[]` cap 500, withdraw, accept/decline, replay);
- the ADR-0009 invariant extended to requests;
- read-time visibility (proposed: the cached author `users.isPrivate` plus the caller's `following`, 0 extra reads, no write fan-out) against ADR-0003's visibility job;
- the visibility matrix for GetPost, GetThread, user timelines, Home, `Viewable` (like, repost, quote, bookmark), embeds of protected posts, ListBookmarks, ListLikedPosts, notifications and **W4 search**;
- the notification types, the eraser and export, the flag, the rate limits and the per-RPC budget.

After acceptance it updates the `graph.proto` / `identity.proto` comments (stubs to live budgets). Seam: visibility decided in one `posts`-side policy function every read path calls. Cost: its table replaces the Part B placeholder.

**W3-4 Generate + flags** [depends: W3-2] [backend-developer, S]. `make proto` (generated Go and Dart committed). The four Part A flags are registered in `config.go` and `flags.NewRegistry`, with `config_test.go` entries, the rate-limit keys mapped in `ratelimit_config.go` and the suggestion config from the table above. Given a flag unset, each gated RPC returns FAILED_PRECONDITION `FEATURE_DISABLED` (`flags.DisabledError`, metadata `feature=<name>`) with 0 reads; `GetMe.enabled_features` lists the names for allowlisted uids only. `scripts/promotion/flag-ceiling.json` gets the four names with dev allowlist ceilings and no prod raise (**founder-gated**). `feature_*`, `_allowlist` and `_percent` Terraform vars go in `envs/dev` and `envs/prod`, default `off`, and nothing is applied; `check-flag-registry.sh` passes. Handlers are flag-guarded and Unimplemented until their module ticket. It also owns all W3 config plumbing in `apiserver.go` (see "Order and parallelism"). Observability: the startup `feature_flags` line lists the four names. Flag: the four new flags. Seam: flags stay env vars checked in the service layer (`flags.Guard`), so a module later split into its own service keeps its own guard. Cost: 0.

**W3-5 Banner media kind** [depends: W3-4] [backend-developer, S]. Given `CreateUpload(purpose=BANNER)` with exactly 1 item, the signed URLs bind the banner size caps from W3-1. `FinalizeUpload` applies the avatar's stricter Racy rule. `ResolveBanner` (in `attach.go`, next to the avatar resolver) accepts only a READY or READY_UNSCREENED BANNER owned by the caller; anything else is `MEDIA_NOT_READY`. The account purge deletes BANNER objects and docs, which `media` purge tests assert. Observability: `purpose=BANNER` and `vision_units` on the existing CreateUpload / FinalizeUpload log lines. Flag: `media` and `profile_extras` on for the caller. Seam: `identity.BannerResolver` (consumer-side), mirroring `AvatarResolver`. Cost: the existing CreateUpload (2 / 1 reads, 6 / 3.3 writes) and FinalizeUpload (5 / 1.7 reads, 2.7 writes) rows; 2 Vision units per banner.

**W3-6 Identity profile fields** [depends: W3-4] [backend-developer, M]. `UpdateProfile` accepts:
- the banner media id (resolved before the transaction, like the avatar; `""` removes it);
- location (≤ 30 code points, NFC, no control or bidi characters);
- website (scheme allowlist, ≤ 100, no userinfo; else VALIDATION `field=website`);
- `pinned_post_id` (`identity.PinChecker`: own, visible, not a REPOST; else VALIDATION `field=pinned_post_id`, one message for every cause; `""` unpins).

Setting any of these fields (a non-empty value) while `profile_extras` is off for the caller returns FEATURE_DISABLED with 0 writes; an exact `""` clear is always accepted (Amendment 1 A2); the name and bio path is unchanged. None of them bumps `snapshotVersion` or spends `snapshotEdits`. `Profile` returns the fields everywhere it is built, except that `pinned_post_id` and `website` are omitted while `profile_extras` is globally off (the kill switch; the website per Amendment 1 A1). The export's profile section adds them (golden file updated); deletion needs no new step (`users/{uid}` goes last, as today). Wiring: W3-6 owns the `identity.WithBannerResolver` / `identity.WithPinChecker` lines in `apiserver.go` and merges after W3-5 and W3-7 (fakes until then). Tests: unit with fakes, emulator `budgettest` at 3 reads / 1 write worst. Observability: `profile_fields_changed` (names only, never values) in the request log. Flag: `profile_extras` for the new fields. Seam: `PinChecker`, `BannerResolver`. Cost: 3 / 1 reads, 1 write.

**W3-7 Posts `hasMedia` + pin check + tab queries** [depends: W3-4] [backend-developer, M]. Every create path writes `hasMedia`:
- CreatePost root, reply and quote;
- the scheduled publish sweep;
- RepostPost's REPOST doc (always false).

It is true when the stored `media[]` is non-empty, in the same write (0 extra writes). `posts.PinChecker` reads the post cache-first (1 cold / 0 warm) and applies `Visible()`, owner and kind. `posts.Reader` gains:
- `ByAuthorMedia(author, cursor, limit)`: `authorId == A && hasMedia == true order by createdAt desc, __name__ desc`;
- `ByAuthorKind(author, REPOST, ...)`.

Both use `Limit` and the W3-2 indexes. Tests: emulator queries against the indexes, `hasMedia` on all four create paths. Observability: `pin_check` outcome (ok / rejected, never the cause) in the UpdateProfile log line. Flag: the `hasMedia` write is never flag-gated (the field must be right before `profile_tabs` turns on); the queries run only through W3-9. Seam: `posts.Reader`. Cost: +0 writes per post; reads only through W3-9.

**W3-8 Backfill** [depends: W3-7] [backend-developer, S]. `opsctl backfill-has-media --project P [--dry-run]` pages `posts` by `__name__` in pages of ≤ 500 with a checkpoint, and sets `hasMedia` field-level only where it is missing. A rerun writes 0. It requires `--project`, a prod confirmation prompt, and prints counts. Throttled to stay under 5,000 writes per run (rerun the next day if more). Observability: `backfill_has_media` progress lines (scanned, updated, checkpoint). Flag: never flag-gated (an ops tool). Seam: it writes through the `posts` repo helper that W3-7 uses, so there is one definition of `hasMedia`. Cost: 1 read per post, 1 write per post that lacks the field (dev: a few hundred; prod before launch: about 0).

**W3-9 Timeline tabs** [depends: W3-7] [backend-developer, M]. Given `tab = MEDIA` or `REPOSTS` with `profile_tabs` on for the caller, `GetUserTimeline` returns that author's media posts, or their reposts, newest first. The rules match the Posts tab:
- NOT_FOUND byte-identical to GetProfile for missing, SUSPENDED, DELETING or blocking authors;
- REPOST rows whose embedded author the caller blocks or mutes, or who blocks the caller, are dropped (ADR-0010 D6);
- `since_token`, `page_token` and `removed_ids` work as for the Posts tab, with tokens bound to the tab (a Posts token on the Media tab is VALIDATION with 0 reads).

`tab = UNSPECIFIED` keeps today's `include_replies` behaviour exactly; a set tab wins over `include_replies`. No author-recent cache for these tabs. Tests: `budgettest` 24 (page 20) and 54 (page 50) cold; flag-off and token-binding tests. Observability: `tab` in the request log. Flag: `profile_tabs` for MEDIA and REPOSTS; Posts and Replies ungated. Seam: `timeline` interface; Stage 2/3 per-tab caching (Out of scope). Cost: 24 / 20 reads per page of 20, 0 writes.

**W3-10 `ListLikedPosts`** [depends: W3-4] [backend-developer, M]. Given `likes_list` on and 25 liked posts, a first call returns the 20 most recently liked live posts and a `next_page_token`; the second returns 5 and `""`. The source is `userLikes/{caller}.recent[]` read from the end (cached 60 s), then one cache-first `posts.Reader.GetMany` of the page's ids. The ADR-0023 D2 drop rules apply (missing, hidden, blocked, blocks, muted, QUOTE embedded author); no pruning (the like path owns the array). The cursor is resume-by-position bound to `likes|<uid>`, 24 h TTL. A like removed between pages neither skips nor repeats a row: the resume point is the first id older than the recorded position. A tampered token is VALIDATION with 0 reads. `NO_SIDE_EFFECTS`; the request has no user id. Tests: `budgettest` 23 / 53 cold (24 / 54 stays asserted as the ceiling), unlike-between-pages, an empty array (2 reads), foreign token. Observability: one log line with `rows_dropped` by cause and `fs_reads`. Flag: `likes_list` (and `posts`). Seam: `engagement.LikesList`; Stage 2/3 `likes (uid, createdAt)` index or a SQL table (Out of scope). Cost: 24 cold / 3 warm per page of 20.

**W3-11 "Follows you"** [depends: W3-4] [backend-developer, S]. `GetProfileRelationship(user_id)` returns the caller's `Relationship` (from the cached caller graph, as `GetRelationships`) plus `followed_by`: whether `follows/{target}_{caller}` exists (1 cold read, cached 60 s per pair). The caller's own Follow or Unfollow never changes that doc. The pair is evicted on this instance when the target follows or unfollows the caller, or when either side blocks the other (a Block deletes both edges). Other instances converge within 60 s. Rules:
- if the target blocked the caller: NOT_FOUND byte-identical to GetProfile;
- for the caller's own id: NONE and false;
- `GetRelationships` is unchanged.

Tests: the block matrix, eviction after the target's Follow and after a Block, `budgettest` 2 cold / 0 warm. Observability: `graph_op=profile_relationship`, `followed_by_cache_hit`, `fs_reads`. Flag: `graph`. Seam: graph `Reader`; never computed for more than one target. Cost: 2 / 0 reads.

**W3-12 Who to follow** [depends: W3-4] [backend-developer, M]. With `follow_suggestions` on, `ListSuggestedUsers` returns ≤ 5 `UserListItem`s (with relationship) and no cursor. Option (a), friends of friends:
1. Read the caller graph (cached).
2. Run one query over the newest `SUGGESTIONS_SAMPLE_FOLLOWEES` followees: `follows where followerId in [...] order by createdAt desc limit SUGGESTIONS_EDGE_LIMIT`. **Verify on the emulator first** that `in` + `orderBy` runs on the existing index; if not, stop and return to the architect.
3. Rank candidates by count, ties by a stable hash.
4. Exclude self, following, requested, blocked, blockedBy and muted at 0 reads.
5. Hydrate ≤ `SUGGESTIONS_HYDRATE_MAX` through `identity.Directory`, dropping non-ACTIVE users.

Fallback (c): `SUGGESTED_USER_IDS` when the caller follows fewer than 3 accounts or (a) yields fewer than 3. The result is cached per viewer for `SUGGESTIONS_CACHE_TTL`; this instance's Follow removes the followed uid from it. Rate limit and daily cap as in the abuse section. Tests: the exclusion matrix (incl. blockedBy), the read cap (`budgettest` ≤ 42 cold, 1 warm), empty graph → curated, curated users that are blocked or deleted dropped. Observability: `source=fof|curated`, `candidates`, `fs_reads`. Flag: `follow_suggestions` (and `graph`). Seam: `graph.Suggester`, so option (b) or a precomputed source changes no caller. Cost: 42 cold worst / 1 warm, planning 25.

**W3-13 Header polish** [depends: none] [frontend-developer, M]. Client only, no flag beyond the existing screen gates:
- The profile becomes a `NestedScrollView`. The tab bar pins under the app bar, and each tab keeps its own scroll offset when switching (B-06).
- The app-bar name and post count fade in only after the header name scrolls under it (B-05; X `profile.md` §2).
- "Joined Month YYYY" (calendar icon, muted) shows from `Profile.created_at` in a meta row that W3-14 extends.

Tests: widget tests at 360/600/1200, light and dark, text scale 1.0/1.3/2.0, tab switch keeps offsets. Flag: none new (the screen's existing gates; rollback = revert). Seam: the tab list is data (a list of tab descriptors fed to one scroll scaffold), so W3-16 adds tabs without touching the scroll code. Cost: 0.

**W3-14 Header data** [depends: W3-4, W3-13] [frontend-developer, M].
- The 3:1 band shows the banner: thumb below 600 dp, full image at 600 dp and above, flat placeholder while loading, no layout jump.
- The meta row adds location (pin icon) and website (link icon, host only, punycode for non-ASCII, opens externally) before "Joined".
- On another user's profile the header calls `GetProfileRelationship` instead of `GetRelationships`. With `followed_by`, a "Follows you" chip sits next to the handle, and the Follow button reads "Follow back".

Capture: another user's profile was **not captured** (W1.5). Default: X-conformant chip (muted surface, small label); the founder's capture may adjust it. Flag: render ungated; the chip needs `graph`. Seam: `ProfileCubit` loads the relationship through `GraphRepository`, and the header reads only cubit state, so a later list-row "Follows you" reuses the repository. Cost: 0 new RPCs (one call replaced); banner bytes in the cost section.

**W3-15 Edit profile: banner, location, website** [depends: W3-4] [frontend-developer, M].
- A banner editor above the avatar in Edit profile: pick, crop 3:1, resize on device (full and thumb), `CreateUpload(BANNER)`, upload, `FinalizeUpload`, then `UpdateProfile.banner_media_id`. It reuses `EditProfileCubit`'s avatar flow (media id and key remembered across retries) and adds Remove.
- Location and website fields with counters and client checks mirroring the server.
- Friendly text for `MEDIA_NOT_READY`, rejection, quota and `FEATURE_DISABLED profile_extras`.

Tests: widget tests per state at three widths. Flag: the screen is still reached only with `profile_snapshot`; setting the new fields also needs `profile_extras`, and the banner editor also needs `media`. Amendment 1 A2: while the flag is off for the caller (outside the cohort, or globally off), Edit profile shows each existing banner, location and website read-only with Remove (sends `""`; setting stays hidden); banner Remove needs neither `media` nor `profile_extras`; while the flag is globally off only the banner and the location can appear (the server omits the website then). Seam: one media-upload helper shared by the avatar and banner editors (purpose as a parameter), so a later purpose adds no second upload path. Cost: one upload (2 + 5 reads, 6 writes) and one UpdateProfile per change.

**W3-16 Reposts and Media tabs** [depends: W3-4, W3-13] [frontend-developer, M]. With `profile_tabs` on: Posts · Replies · Reposts · Media, equal width, each a `TimelineCubit` keyed by `FeedKey.user(uid, tab)` with its own cache, and the token sent back unchanged. Media rows render the normal post card (a grid is out of scope). The empty states use our own copy. With the flag off: Posts · Replies as today. Flag: `profile_tabs`. Seam: `FeedKey.user(uid, tab)` and `TimelineRepository` carry the tab, so a later per-tab server cache or a media grid changes no widget. Cost: 1 call per tab open plus pages (24 cold reads per page of 20).

**W3-17 Pinned post** [depends: W3-16 (same file), W3-4] [frontend-developer, M]. When `Profile.pinned_post_id` is set (the server omits it while `profile_extras` is globally off), the Posts tab shows a "Pinned" label row (pin icon, muted) above that post, loaded with `GetPost`. It hides silently on NOT_FOUND and is not repeated in the feed below. Your own post's overflow menu offers "Pin to your profile" or "Unpin from profile" (only for POST, QUOTE or REPLY) through `UpdateProfile`, with a confirm when replacing a pin. Flag: "Pin to your profile" needs `profile_extras`; "Unpin from profile" is offered whenever a pin is shown (Amendment 1 A2: an empty value is always accepted, so an owner outside the cohort can still unpin); the Pinned row renders whenever the server returns a pin. Seam: one `PinnedPostCubit` per profile owns the fetch and the hide-on-NOT_FOUND rule, so a server-embedded pin later changes no widget. Cost: 1 `GetPost` per profile open with a pin (4 cold / 0 warm).

**W3-18 History: Likes tab** [depends: W3-4, W2-9] [frontend-developer, M]. The W2-7 screen becomes "History" (question 7) with `AppTabBar` Bookmarks | Likes when `likes_list` is on; `/bookmarks?tab=likes` deep-links. The Likes tab is a live `PostCard` list over `ListLikedPosts`: each open replaces page 1, and paging follows `next_page_token` through short pages. Unliking removes the row. The empty and end copy states the 1,000-most-recent limit. Reuses the `BookmarksListCubit` pattern (session memory, cleared under `SessionEpoch`). Merges after W2-9 (`app_router.dart`). Flag: `likes_list` for the tab; the screen keeps W2-7's gates. Seam: a `LikesRepository` keeps the list in session memory only, so a later full-history source or offline cache changes no caller. Cost: 1 call per open, 24 cold reads per page of 20.

**W3-19 Who to follow** [depends: W3-4] [frontend-developer, M].
- With `follow_suggestions` on, an `AppSurface` card "Who to follow" (up to 3 `UserListRow`s with `FollowButton`, plus "Show more" opening the full 5) appears once in Home's `headerSlivers` under the push card.
- The desktop right column (`AppSideColumn`, ≥ 1200 dp) shows "You might like".
- The result is fetched at most once per 24 h per uid (drift `AppSettingEntries`) and shared by both surfaces.
- A followed row disappears; a local "dismiss" hides a row for the session (no server storage).

Flag: `follow_suggestions` (and `graph`; the right column also `ui_shell`). Seam: one `SuggestionsRepository` (24 h cache, dismissals) feeds both surfaces, so W4's Explore can reuse it and a server source change touches no widget. Cost: about 1 `ListSuggestedUsers` per DAU (25 reads planning).

**W3-20 Backend tests** [depends: W3-5 to W3-12] [tester, M]. Integration on emulators:
- flag modes off/allowlist/percent/on per new flag;
- `profile_extras` fields rejected while off;
- website and location validation tables;
- pin rules (other user's, REPOST, hidden, deleted, `""`);
- banner moderation path;
- tab token binding and the Posts-vs-Media token mismatch;
- the ADR-0010 D6 drop matrix on Reposts and Likes;
- unlike between pages;
- follows-you block matrix and NOT_FOUND byte-identity;
- the suggestions exclusion matrix and read cap;
- backfill rerun = 0 writes;
- `budgettest` on every RPC at the W3-1 ceilings.

Coverage on `internal/` stays ≥ 70%. Cost: 0 (emulators).

**W3-21 Client tests** [depends: W3-13 to W3-19] [tester, S]. The responsive matrix (360/600/1200, light/dark, text scale 1.0/1.3/2.0) for every new widget and screen, flag-off routing for `/bookmarks?tab=likes` and the tabs, and banner loading without layout jump. Cost: 0.

**W3-22 Security review, Part A** [depends: W3-6, W3-9 to W3-12, W3-14, W3-15] [security-auditor, M]. A threat model of the surface in the abuse section:
- website rendering (scheme, homograph, external open);
- banner moderation and the Vision cap path;
- suggestions enumeration and its rate-limit arithmetic (per instance x 3);
- tab scraping bounds;
- likes owner-only and cursor binding;
- follows-you as an oracle;
- pin validation as an existence oracle;
- the export fields.

Findings are fixed or ticketed before any dev allowlist. Cost: 0.

**W3-23 Cost report, Part A** [depends: W3-9 to W3-12] [sre-performance, S]. Done 2026-10-27; the figures it restated are in the Cost section and the status row above. Adds the Part A rows (+40.1 reads, +0.06 writes per DAU, +0.30 Vision units per DAU-month, banner egress) to `docs/reviews/cost-model.md` §2-§5. Runs emulator load smokes (`make loadtest`) of the Media tab, ListLikedPosts and ListSuggestedUsers, and re-states the planning values from measured `fs_reads`. It names the triggers:
- suggestions above 10% of daily reads;
- tabs plus likes above 15%;
- or the §6 Firestore trigger, sustained 7 days.

Cost: 0.

**W3-24 Dev rollout, Part A** [depends: W3-20, W3-22, W3-23, ADR-0024 merged] [production-deployer, S]. Preconditions, in order:
1. The W3-2 composite indexes and fieldOverrides are deployed to the target project and show READY (the dev deploy workflow runs `firebase deploy --only firestore:indexes` after the ack check; for prod, the next `v*` release, on hold with `pending.md` 1.2).
2. `opsctl backfill-has-media` has run there.
3. Show the founder a targeted dev Terraform plan for the four flags and the suggestion config, as for `pending.md` 3.10.

Apply only on OK, with allowlists of 3 test uids (runbook and evidence: `docs/runbooks/w3-part-a-rollout.md`). Then a dev smoke: set a banner, location, website and pin; open each tab; list likes; see "Follows you"; get suggestions; turn each flag off. Prod: no change. Cost: the smoke is a handful of reads and writes inside dev's free quota.

Definition of done per ticket (Part A and Part B):
- backend: Go unit + emulator integration (`make test-int`, `budgettest.Assert` on every RPC);
- client: widget tests in light and dark at 360/600/1200 via `test/support/theme_harness.dart` for every new screen or widget; pixel goldens deferred (B-01);
- `make ci` green;
- `docs/ui-catalog.md` / `docs/code-map.md`, this table and the matching `docs/pending.md` row updated in the PR.

### Part B: private accounts and follow requests (final, from ADR-0025)
Finalised 2026-10-27 from ADR-0025, which the founder accepted on 2026-10-27 by merging #325 with every recommended default. That merge reverses ADR-0008 D1. The decisions are the ADR's D1 to D16, and nothing here re-decides them.

The ADR's handoff put more than a day of work into W3-25, W3-26, W3-28, W3-29, W3-33 and W3-35. Each of those is split with a letter suffix, as W5-25b was, so the W3-N numbering is unchanged.

ADR-0025 cannot be edited, and the W5, W7 and W8 plans also use the old ids. Read them through this mapping:

| Old id (ADR-0025 and other plans) | New tickets |
|---|---|
| W3-25 | W3-25a (protos, gate files), W3-25b (flag, config, quota kind) and W3-25c (`AuthorSnapshot.is_private`, added 2026-10-28) |
| W3-26 | W3-26a and W3-26b (the `privacy_public` handler moved to W3-28b, AQ1) |
| W3-28 | W3-28a, W3-28b and W3-28c (list-row `is_private`, added 2026-10-28) |
| W3-29 | W3-29a and W3-29b |
| W3-33 | W3-33a, W3-33b and W3-33c (list-row lock badge, added 2026-10-28) |
| W3-35 | W3-35a, W3-35b and W3-35c |

Every Part B ticket:
- Status Open;
- one ticket per PR;
- branch `feat/ui-w3-N-<slug>` off `main`.

#### Part B: common to every ticket
- **Flag.** `FEATURE_PRIVATE_ACCOUNTS` (`private_accounts`, registered in W3-25b). It gates only what ADR-0025 D12 lists:
  - `UpdateProfile(is_private=true)` for the caller (FEATURE_DISABLED `feature=private_accounts`, 0 reads, 0 writes);
  - `ListFollowRequests` and `RespondToFollowRequest`, only while the flag is globally off and the caller is not protected;
  - the `enabled_features` entry.
- **Never gated** (D12, ADR-0008 D6):
  - the `posts.Audience` predicate on every path;
  - Follow creating a request;
  - withdraw;
  - `is_private=false`;
  - the `privacy_public` job;
  - notification suppression;
  - the eraser and export.

  Ramping the flag down never un-hides anything.
- **Seams.**
  - `posts.Audience` (`CanSee`, `Decide`) is the one posts-side visibility function that W3-3 promised. Every read path calls it.
  - `identity.ProtectedAuthors` is the only way to learn who is protected.
  - `identity.PrivacyListener` carries "this account went public" out of identity.
  - `graph.FollowEvents` carries `FollowRequested` and `FollowRequestAccepted` to notifications.
  - No caller decides visibility from `users.isPrivate` or from the `privacy/protectedAuthors` doc.
  - Nothing filters on the stored `posts.visibility`, which is always `PUBLIC` (D2).
- **Budget.**
  - The ADR-0025 Cost impact table and D7 table are the ceilings.
  - Each ticket asserts its RPCs with `budgettest.Assert` through the real `apiserver.Build` chain, "cold" including the account-status interceptor's read, as W3-20 did (`TestW320_BudgetTable`).
  - Every existing read path keeps its W2 and W3-20 ceiling. The predicate adds 0 reads per request. The set refresh runs on a detached counter logged as `protected_set_reads`, so it never appears in a caller's `fs_reads` (D3).

#### Part B: what Part A taught, applied here
1. **pending.md row 3.12 conflicts.** Every PR edits `docs/pending.md` row 3.12 and this plan's table, and three PRs touched row 3.12 on 2026-10-27 alone. So:
   - one ticket per PR;
   - merge `origin/main` into the branch just before starting the CI watcher;
   - keep both sides' text in row 3.12;
   - never rewrite history.
2. **Emulators only through `make`.** Run them through `make test-int` and `make loadtest`, which wrap the emulators in `scripts/with-private-tmp.sh` (#358; runbook `docs/runbooks/emulator-collisions.md`).
   - Never use a bare `firebase emulators:exec` sharing the machine's temp directory (W3-20 defect D-2).
   - On this Windows machine, use `make test-int FIREBASE=firebase` (D-T17-2).
   - Ports 8080 and 8085 may be held by an orphan `java.exe`.
3. **Reuse the shared paged-list helpers.** Write no second cursor, hydration or drop function (`reuse-first`; `docs/code-map.md` first).
   - The owner-only post lists keep `engagement/list_common.go` (`openListToken`, `dropRows`, `noteRows`).
   - `ListFollowRequests` reuses graph's list cursor and hydration (`graph/follows_list.go`, `graph/lists.go`).
4. **Undo is never gated** (the platform rule from W3-22 M-1, `pkg/platform/flags/flags.go`:157-161): a caller outside a rollout cohort may still undo what they created. In Part B that means:
   - withdraw (Unfollow of a REQUESTED target);
   - `is_private=false`;
   - Accept and Decline by a protected caller;
   - UnlikePost, UndoRepost and RemoveBookmark of a protected author's post. These resolve through `resolveForCounts`, not `Viewable` (`engagement/service.go`:239), and must stay outside `Audience`;
   - the client control for each of these.
5. **Byte-identical NOT_FOUND.**
   - Reuse W3-20's comparator: `TestW320_TabNotFoundBytesMatchGetProfile`, `w320_profile_tabs_integration_test.go`:255. It compares HTTP status, content type and body.
   - The oracle is the same RPC on a deleted post: GetPost of P's post against GetPost of a deleted post, and likewise Like, AddBookmark, Report, a reply to and a quote of each.
6. **Never filter on the stored `visibility`.** Six sites on `main` test it today. Each is a silent no-op after ADR-0025, and each is named in its ticket:
   - `engagement/list_common.go`:89-94 `privateToViewer` (W3-29b);
   - `posts/service_delete.go`:201 (W3-29a);
   - `posts/convert.go`:148, the wire value (W3-29a);
   - `posts/service_thread.go`:174 and :249 (W3-29b);
   - `timeline/service.go`:521 `isPublic` (W3-30);
   - `apiserver/notifications_wiring.go`:84 (W3-31).

   W3-35a adds a source-scan guard so no new site appears.
7. **The T11 guard decides merge order.** `apiserver/lifecycle_collections_guard_test.go` fails `make ci` when code names a collection whose row is `pendingEraser` (`followRequests`, line 83; self-test at line 333) or a collection with no row (`privacy`). Therefore:
   - W3-32 (eraser, export, row flip) merges before W3-27 writes the first request;
   - W3-26a adds the `privacy` row together with the identity-step `ArrayRemove` (rule 10: no write without its delete path).

   This is why W2-3 and W2-5 shipped as one PR (#307).
8. **Shared text fixtures.** Part B adds no user-entered text field, so it needs no new `testdata/` fixture. Any later text rule goes in `testdata/`, read by both the Go and Dart tests (W3-22 L-2).
9. **No media URL of a protected author reaches an unapproved viewer.** M-2 closed bucket listing in dev and prod on 2026-10-27, but post images stay public-read objects named `m/<snowflake id>[_t].<ext>` (`media/retire.go`). Path by path:
   - QUOTE embeds are stripped of text and media, keeping `post_id` and the author snapshot (W3-29a).
   - REPOSTs of P are dropped (W3-29a, W3-29b, W3-30).
   - Notification rows and push payloads carry only the actor snapshot and a post id (`notifications/fanout.go`:64-66, `notifications/fcm.go`:123). The snapshot (handle, name, avatar thumb) is public header data. Post-bearing types from P are suppressed (W3-31).
   - ListBookmarks and ListLikedPosts drop P's rows (W3-29b).
   - W4 search must call `Audience.Decide`; W3-35a's guard enforces it.
   - Another user's export carries post ids and that user's own text only (`posts/purge.go`:190-210; bookmarks and likes are ids only). W3-35a asserts it.
   - **The A4 retire job.** The ADR-0024 A4 retire job (#360; replaced images deleted 24-48 h later) touches only replaced or removed avatars and banners, which stay public header data for protected accounts (D4, GetProfile row). Part B adds no branch to it, and protecting an account retires, renames or deletes nothing. A post-image URL someone already saw while the account was public keeps working (founder question B1).
10. **Rollback.** The I-3 rollout lesson applies with more force: a revision older than the enforcement tickets shows protected posts to everyone, because stored posts are `PUBLIC`. So:
    - nobody may protect in a project until 100% of traffic **and** the `last-good` tag run a revision with W3-26a to W3-32 (W3-38);
    - a rollback never targets an older revision while any account is protected.
11. **Client.**
    - The W3-21 matrix: 360 / 600 / 1200 dp x light / dark x text scale 1.0 / 1.3 / 2.0, 48 dp targets, `expectMinTarget`.
    - The W3-21 D-1 lesson: header actions grow with text scale. Check the lock badge and the Requested button at 360 dp and 2.0.
    - The degrade pattern of W3-14 and W3-18: FEATURE_DISABLED and UNIMPLEMENTED hide the surface, with a 10-minute backoff and no error report.

#### Part B: open design points for the architect (the tickets use the default until answered; none blocks W3-25a)
**Answered 2026-10-28 (W3-25a):** every default below stands. The reasons, and three details the tickets need (AQ4: a plain `Delete` and the `requested` clean-up; AQ5: fail closed with a Pub/Sub retry; AQ6: the pin only, only for unapproved viewers), are in ADR-0025, "Implementation notes (W3-25a, 2026-10-28)". The tickets they touch (W3-26b, W3-27, W3-31, W3-35a) carry a one-line pointer.
- **AQ1. Who runs the `privacy_public` job.**
  - Default: graph. Identity only reports "went public" through `identity.PrivacyListener` after its commit, the ADR-0024 A4 precedent: identity calls `MediaRetirer` and media owns the job (`identity/media_retire.go`, `apiserver.go`:394).
  - The job's transaction writes `follows`, `graph` and `followRequests`, which graph owns (ADR-0002). It reuses W3-28a's accept code.
  - The ADR handoff listed the job under W3-26; this moves only the handler, not the behaviour.
- **AQ2. Where the predicate's expression lives.** identity cannot import posts, because posts imports identity, yet GetProfile must decide the pin (D4).
  - Default: the expression `viewer == author || !set.Has(author) || following` is written once, as a pure method on identity's `ProtectedSet`.
  - `posts.Audience.CanSee` calls it. Every read path still calls only `posts.Audience`; GetProfile is the one identity caller.
- **AQ3. `pending_follow_request_count`.** identity cannot query graph's collection.
  - Default: a consumer-side `identity.FollowRequestCounter`, implemented by graph (the `BlockChecker` pattern), cached 30 s in identity.
- **AQ4. Follow of a public target with a leftover request.** This happens when the job has not run yet, or its enqueue failed.
  - Default: Follow's transaction already reads the caller's graph and the target fresh. It creates the edge and deletes the request in the same transaction: +1 delete, 0 reads, I-X kept.
  - Without this, Follow answers REQUESTED for a public account until the job runs.
- **AQ5. Notification suppression seam.**
  - Default: notifications declares a consumer-side audience checker that `apiserver` adapts from `posts.Audience`.
  - Importing posts into notifications would also work: posts imports only graph and identity, so there is no cycle.
- **AQ6. GetProfile while the set is unavailable.**
  - Default: omit `pinned_post_id` (fail closed) and still return the header, which is public data either way, with WARN.
  - Every other path answers UNAVAILABLE, per D3.

#### Part B: ticket table
Budgets are the ceilings that `budgettest` asserts. "+0" means the path's existing ceiling is unchanged.

| ID | Ticket | Owner | Size | Depends on | Budget (ADR-0025) |
|---|---|---|---|---|---|
| W3-25a | Contract: D14 protos, D15 fieldOverride + ack, D16 notes, skill rows | architect | S | ADR-0025 Accepted (#325) | 0 |
| W3-25b | Plumbing: `make proto`, flag, config and limits, `quota.PrivacyToggles`, ceiling, Terraform vars, seam declarations | backend-developer | S | W3-25a | flag refusal 0 reads / 0 writes |
| W3-25c | Contract: `AuthorSnapshot.is_private = 6`, ADR-0025 implementation note | architect | S | founder decision 2026-10-28 (Option A) | 0 |
| W3-26a | Identity: set, loader, toggle, `PrivacyListener`, identity-step clean-up | backend-developer | M | W3-25b | toggle 4 cold / 3 warm reads, 3 writes; equal value 0 writes; refresh ≤ 1 read per instance per 60 s, detached |
| W3-26b | Identity: GetProfile pin omission, GetMe request count | backend-developer | S | W3-26a, W3-28a | GetProfile +0; GetMe +1 read per 1,000 matches for protected callers (cached 30 s), 0 otherwise |
| W3-27 | Graph: Follow request path, withdraw, Block clean-up, REQUESTED | backend-developer | M | W3-25b; merges after W3-32 | Follow 4 cold / 3 warm (planning 4), 5 writes (edge) or 3 (request), replay 0; withdraw 0 reads in the batches + 1 interceptor, 1 write, 1 delete; Block +0 reads, +0 writes, ≤ +2 deletes |
| W3-28a | Graph: ListFollowRequests, RespondToFollowRequest, protected follower lists, request count | backend-developer | M | W3-27, W3-26a | List 42 / 102 cold at page 20 / 50, 21 / 51 warm; Respond 3 cold / 2 warm after a List (up to 5 cold standalone; founder-accepted 2026-10-28, ADR-0025 "Implementation note (W3-28a)"), accept 4 writes + 1 delete, decline 1 + 1, replay 2 / 1 and 0 writes; ListFollowers / ListFollowing of P unapproved 3 cold, 0 page reads; request count 1 read, capped at 1,000 |
| W3-28b | Graph: `privacy_public` job | backend-developer | S | W3-28a, W3-26a | per pending request 2 reads, 3 writes (+1 per page), 1 delete; 500 pending: 1,000 / 1,505 / 500 |
| W3-28c | Graph: `make proto`, `is_private` on graph user-list rows | backend-developer | S | W3-25c, W3-28a | +0 on every list (ListFollowers, ListFollowing, ListFollowRequests, ListSuggestedUsers, ListBlockedUsers, ListMutedUsers keep their ceilings) |
| W3-29a | Posts: `Audience`, GetPost, `Viewable`, D5 refusals, computed visibility, PROTECTED embed | backend-developer | M | W3-25b; merges after W3-26a | +0 reads on every path (GetPost 4 cold / 0 warm unchanged), except +1 cold / 0 warm when a caller opens their own REPOST or QUOTE of another user's post (founder-accepted 2026-10-28, ADR-0025 "Implementation note (W3-29a)"); refusals 0 writes |
| W3-29b | Posts + engagement: GetThread, ListBookmarks, ListLikedPosts | backend-developer | M | W3-29a | +0 (ListBookmarks 43 / 103 / 2, ListLikedPosts 23 / 53 / 2, GetThread unchanged) |
| W3-30 | Timeline: `author_protected`, feed embeds | backend-developer | S | W3-29a, W3-26a | P unapproved 3 cold, 0 page reads; tabs 24 / 54 cold and Home unchanged, except +1 cold / 0 warm on the caller's own tabs when a page holds their REPOST or QUOTE of another user's post (own tabs 25 cold at page 20; founder-accepted 2026-10-28, ADR-0025 "Implementation note (W3-29a)") |
| W3-31 | Notifications: two types, suppression | backend-developer | S | W3-25b; W3-26a, W3-29a merged | fan-out about 2 reads per recipient, 1 write, 1 TTL delete (90 d); suppression 0 |
| W3-32 | Lifecycle: `follow_requests` step and section | backend-developer | M | W3-25b; merges before W3-27 | eraser: outgoing 1 read + 1 delete per doc, incoming 1 read + 1 delete + 1 write per doc, minimum 2 reads; export 1 read per doc, minimum 2 |
| W3-33a | Client: protected profile, lock badge, Requested and withdraw | frontend-developer | M | W3-26a, W3-27, W3-30 serving dev | 0 new RPCs; a protected profile open is 3 reads |
| W3-33b | Client: protect setting, protected embed, copy | frontend-developer | M | W3-26a, W3-29a serving dev | 1 UpdateProfile per toggle (4 / 3 reads, 3 writes) |
| W3-33c | Client: lock badge on `UserListRow` | frontend-developer | S | W3-28c serving dev, W3-33a | 0 new RPCs, 0 reads |
| W3-33d | Client: outlined Requested/Following fit `UserListRow` at 360 dp x2.0 | frontend-developer | S | W3-33c | 0 new RPCs, 0 reads |
| W3-34 | Client: Follow requests screen, badge, notification rows | frontend-developer | M | W3-28a, W3-26b, W3-31 serving dev | 1 ListFollowRequests per open (42 cold), 1 Respond per tap |
| W3-35a | Tests: D4 matrix, byte identity, leaks, guard, budget table | tester | M | W3-26b, W3-28a, W3-29b, W3-30, W3-31 | 0 (emulators) |
| W3-35b | Tests: lifecycle, races, invariants, job, flags, eraser and export | tester | M | W3-27, W3-28a, W3-28b, W3-32 | 0 (emulators) |
| W3-35c | Tests: client matrix, flag-off routing | tester | S | W3-33a, W3-33b, W3-34 | 0 |
| W3-36 | Security review, Part B | security-auditor | M | W3-26a to W3-32 merged; client at branch heads | 0 |
| W3-37 | Cost report, Part B | sre-performance | S | W3-26a to W3-32 merged | 0 (emulators) |
| W3-38 | Dev rollout, Part B | production-deployer | S | W3-35a to W3-35c, W3-36 M-1(c), W3-37, founder OK | a handful of reads and writes in dev |
| W3-39 | M-2: unguessable public media names | backend-developer | M | W3-36 review | +0 reads, +0 writes, +0 deletes, +0 Class A and B on every path; media doc about +110 bytes, +66 bytes per stored image copy and per image on the wire |
| W3-40a | L-1, L-3, L-5 | backend-developer | M | W3-36 review | Unlike and Undo repost of a post the caller may not see: +0 warm, +1 cold (the caller's graph snapshot), writes unchanged; loader and assertion 0 |
| W3-40b | L-4, O-1 | backend-developer | S | W3-40a, W3-35b (#405) | +0 on every path (fewer `Current` calls); a stuck `privacy_public` delivery: the same reads, 0 writes, acked instead of nacked (no redeliveries) |
| W3-41a | L-2 backend: owner placeholders | architect (proto), backend-developer | M | W3-40b | +0 reads, +0 writes (rows already read are kept and stripped instead of skipped) |
| W3-41b | L-2 client: placeholder rows | frontend-developer | S | W3-41a, W3-40a serving dev | 0 new RPCs; 1 Unlike, Undo repost or RemoveBookmark per tap |
| W3-42 | M-1(b): rollback floor | production-deployer | S | none (founder review of `flag-ceiling.json`) | 0 (CI and the rollback path only) |

#### W3-25a Part B contract [architect] [S] [depends: ADR-0025 Accepted, #325] Status: Done (PR #372)
- **Description.** The ADR-0025 D14 proto changes, the D15 gate-file change and the D16 records, as W3-2 did for Part A. No generated code (W3-25b runs `make proto`).
- **Protos** (all additive):
  - `common.v1.ErrorReason`: `ERROR_REASON_PROTECTED_ACCOUNT = 17`, with the D14 comment.
  - `identity.v1.GetMeResponse`: `int64 pending_follow_request_count = 6`.
  - `graph.v1.RespondToFollowRequestResponse`: `Relationship relationship = 1`.
  - `timeline.v1.GetUserTimelineResponse`: `bool author_protected = 6`.
  - `posts.v1.EmbedViewerState`: `EMBED_VIEWER_STATE_PROTECTED = 3`.
  - `notifications.v1.NotificationType`: `NOTIFICATION_TYPE_FOLLOW_REQUEST = 7`, `NOTIFICATION_TYPE_FOLLOW_ACCEPTED = 8`.
  - The D14 comment-only changes in `identity.proto`, `graph.proto` (the stubs' comments become the live budgets: Follow 4 cold / 3 warm, ListFollowRequests 42 / 102, RespondToFollowRequest 3 / 2), `posts.proto`, `engagement.proto` and `timeline.proto`.
- **Gate files** (founder review, CODEOWNERS):
  - `firebase/firestore.indexes.json` gets one fieldOverride, `{"collectionGroup": "privacy", "fieldPath": "uids", "indexes": []}`, and `firebase/field-overrides.ack` is re-hashed.
  - No composite index: `followRequests (followeeId ASC, createdAt DESC)` exists, `followerId ==` uses the automatic index, and `graph.requested` is already exempt.
  - `.claude/skills/firestore-data-model/SKILL.md` gets the `privacy` row, the `followRequests` row and the op-cost rows (path `/.claude/`).
- **Records.** Dated pointer notes in ADR-0003 (the visibility-job paragraph is superseded by ADR-0025 D3) and ADR-0008 (D1 reversed by ADR-0025). Their Decision sections are not edited.
- **Acceptance.**
  - Given the PR, when CI runs `buf lint` and `buf breaking` against `main`, then both are clean and no field or enum number is reused or renumbered.
  - Given the PR, then `scripts/promotion/check-field-overrides.sh` passes with the re-hashed ack.
  - Given ADR-0003 and ADR-0008, then their text is unchanged except the appended dated notes.
- **Tests.** CI only: buf, the ack check and `make ci`.
- **Number clash.** ADR-0025's numbers are taken here. The W7 plan names `GetMeResponse.unread_conversation_count = 6` and `NOTIFICATION_TYPE_MESSAGE = 7`, and W6 expects `ErrorReason` 17+. Those PRs (W5-2, W6-2, W7-2) take the next free numbers when they open.
- **Merge rule.** One wave's index PR at a time: W4-9, W6-2 and W7-3 also touch the index file, and the second merges `origin/main` and re-hashes the ack.
- **Seam.** Protos stay additive. `author_protected` fails closed on old clients, which see an empty list.
- **Cost.** 0.

#### W3-25b Part B plumbing [backend-developer] [S] [depends: W3-25a] Status: Done (PR #379)
- **Description.**
  - `make proto`, with the generated Go and Dart committed.
  - Before `make proto`, fix the `ListSuggestedUsers` comment in `graph.proto`: "hard cap 42 reads cold (… follows edges <= 30 …)" becomes cap 32 with edges <= 20, per ADR-0024 Amendment 2 (comment only; `buf breaking` stays clean). Found in the code review of #373 (2026-10-28).
  - Register `FEATURE_PRIVATE_ACCOUNTS` like W3-4: `config.Config`, `flags.NewRegistry`, `config_test.go`, the flag fixture.
  - `scripts/promotion/flag-ceiling.json` (founder-gated): add `PRIVATE_ACCOUNTS` to `flags`, with dev `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}` and no prod entry.
  - Terraform vars `feature_private_accounts`, `_allowlist` and `_percent` in `envs/dev` and `envs/prod`, default `off`, wired into `cloud-run-api`. Nothing is applied.
- **Config** (rule 11), validated at startup and carried as Terraform env vars with these defaults:
  - `QUOTA_PRIVACY_TOGGLES_PER_DAY` = 4;
  - `PROTECTED_AUTHORS_MAX` = 20,000;
  - `PROTECTED_SET_MAX_STALE` = 10m;
  - `RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN` = 60, mapped in `ratelimit_config.go`.
  - `ListFollowRequests` uses the existing graph list bucket (20/min) and `graph_list_daily` (100/day per instance).
- **`quota.PrivacyToggles`.** The `Record` field and the `valueFor` and `increment` cases ship together (ADR-0021 I-3).
- **Seam declarations** (declarations only, no behaviour), so W3-26a and its consumers can be built in parallel against fakes:
  - `identity.ProtectedAuthors` (`Current(ctx) (ProtectedSet, error)`);
  - `identity.ProtectedSet` (`Has`, plus the AQ2 expression);
  - `identity.PrivacyListener` (`BecamePublic(ctx, uid, at) error`);
  - `identity.FollowRequestCounter`;
  - `graph.FollowEvents` gains `FollowRequested(ctx, requester, target, at)` and `FollowRequestAccepted(ctx, target, requester, at)`. The `apiserver` `followNotifier` gets no-op methods so the build stays green, and W3-31 fills them.
- **Stubs.** `ListFollowRequests` and `RespondToFollowRequest` get the D12 gate and stay Unimplemented until W3-28a. `UpdateProfile(is_private=true)` stays refused until W3-26a.
- **Files.** W3-25b is the only Part B ticket that edits `config.go`, `ratelimit_config.go`, the flag lines in `apiserver.go`, the Terraform `feature_*` and limit vars, and `flag-ceiling.json`.
- **Acceptance.**
  - Given `FEATURE_PRIVATE_ACCOUNTS` unset, when a caller sends `UpdateProfile(is_private=true)`, then FAILED_PRECONDITION `FEATURE_DISABLED` `feature=private_accounts` with 0 reads and 0 writes (`budgettest`).
  - Given an allowlisted uid, then `GetMe.enabled_features` contains `private_accounts`; for any other uid it does not.
  - Given an invalid value for any new config key, then startup fails.
  - Given the PR, then `check-flag-registry.sh` and the ceiling check pass.
- **Tests.** Config unit tests, the flag guard test entry, and the quota kind's I-3 test.
- **Observability.** The startup `feature_flags` line lists `private_accounts`; the config line lists the four limits.
- **Flag.** Registered here.
- **Seam.** Flags stay env vars checked in the service layer (`flags.Guard`).
- **Cost.** 0.

#### W3-25c Part B contract: `AuthorSnapshot.is_private` [architect] [S] [depends: founder decision 2026-10-28, Option A] Status: Done (PR #391)
- **Description.** W3-33a could not build the lock badge on user-list rows: `graph.v1.UserListItem.user` is the shared `common.v1.AuthorSnapshot`, which had no privacy field. Founder decision 2026-10-28 (Option A): add one. Protos only, no generated code, as W3-25a did; W3-28c runs `make proto`.
- **Proto** (additive): `common.v1.AuthorSnapshot`: `bool is_private = 6`. The comment says it is set only on live rows (`graph.v1.UserListItem.user`, every graph user list), always false in the frozen copies (`Post.author`, `EmbeddedPost.author`, `Notification.actor`), and that false never means public: the authoritative signals stay `Profile.is_private` and the post's `visibility` / `EmbedViewerState`.
- **Records.** ADR-0025 "Implementation note (W3-25c, 2026-10-28)" and its header pointer line.
- **Acceptance.** Given the PR, when CI runs `buf lint` and `buf breaking` against `main`, then both are clean and no field number is reused or renumbered.
- **Firestore.** No change: the stored `posts.author{}` and notification `actor{}` maps are untouched, no index, no rules.
- **Seam.** One shared message, filled at one graph helper; the access decision stays on `posts.Audience`.
- **Cost.** 0.

#### W3-26a Identity: the protected set, the loader and the toggle [backend-developer] [M] [depends: W3-25b] Status: Done (PR #383)
- **The set** (D2): `privacy/protectedAuthors` `{uids[], updatedAt}`.
  - Identity owns it, through a `privacyCollection` constant. It is written only in the same transaction as `users.isPrivate`.
  - The first protect creates it (`Set` with merge, inside the transaction). It is never deleted.
- **T11 guard row,** added in this PR: `privacy`, `erasedByStep: identity`, with an ExportNote saying the set lists other users, so the entry is removed and the doc is never exported.
- **The identity deletion step.** It removes the uid from the set with `ArrayRemove` before `users/{uid}` is deleted (D11): ≤ 1 write, idempotent, and NotFound of the set doc counts as success.
- **The toggle** (D8): `UpdateProfile` with an `is_private` that differs from the stored value runs one transaction.
  - Reads: `users` fresh, the set doc fresh (for the cap), `quotas`.
  - Writes: `isPrivate`, `ArrayUnion` or `ArrayRemove` on the set, `quotas.privacyToggles`.
  - Cost: 4 cold / 3 warm reads, 3 writes.
  - An `is_private` equal to the stored value is 0 writes and is not charged to the quota.
  - The 5th toggle in an IST day: QUOTA_EXCEEDED `quota=privacy_toggles`, 0 writes.
  - Protect with `PROTECTED_AUTHORS_MAX` uids already in the set: FAILED_PRECONDITION LIMIT_REACHED `limit=private_accounts`, 0 writes.
  - A toggle bumps no `snapshotVersion` and enqueues no snapshot job.
- **Gates** (D12):
  - `is_private=true` needs the flag on for the caller, checked before any read.
  - `is_private=false` is accepted from any caller whatever the flag (the undo rule).
  - A request that sets `is_private=true` together with other fields is refused whole while the flag is off for the caller (the W3-22 M-1 mixed rule).
- **After the commit.**
  - On unprotect, call `PrivacyListener.BecamePublic` with a detached, short-deadline context, as `retireImages` does (`identity/media_retire.go`:82-95). A failure is ERROR `privacy_public_enqueue_failed` (Error Reporting, uid scrubbed). A nil listener publishes nothing, which is the case until W3-28b.
  - The committing instance updates its cached set in place, so the toggle applies at once there and within 60 s elsewhere.
  - The written profile is cached in place (`s.cache.SetProfile`), as for every UpdateProfile. No `Directory.Forget(uid)`: it would only evict that fresh entry and cost the next request a cold read (founder decision 2026-10-28; `Forget` is for other modules whose commits change `users/{uid}` without the profile in hand).
- **The loader** (implements `identity.ProtectedAuthors`, D3):
  - Lazy: it reads only when a caller asks and the cached copy is older than `CACHE_TTL` (60 s).
  - Singleflight: concurrent requests share one refresh.
  - Detached `budget.Counter`, logged as `protected_set_reads`, never charged to the caller.
  - A missing doc is an empty set.
  - A failed refresh keeps the last good set for at most `PROTECTED_SET_MAX_STALE`, with WARN `protected_set_stale`.
  - Past that, or if the instance never loaded a set, it returns an error. Callers answer UNAVAILABLE (retryable), with ERROR `protected_set_unavailable`. An unknown set never reads as "everyone public".
- **Wiring.** `apiserver.go` constructs the loader (W3-26a owns that line). Consumers add their own `With…` line in their tickets.
- **Acceptance** (Given / When / Then):
  - Given an allowlisted public caller, when they set `is_private=true`, then `users.isPrivate` is true, their uid is in the set, the quota is 1, and the call costs exactly 4 cold reads and 3 writes.
  - Given the same caller, when they send `is_private=true` again, then 0 writes and the quota is unchanged.
  - Given a protected caller outside the cohort, or with the flag globally off, when they send `is_private=false`, then it is accepted.
  - Given 4 toggles today, when a 5th arrives, then QUOTA_EXCEEDED with 0 writes.
  - Given the cap lowered to 2 in test config with 2 uids in the set, when a third account protects, then LIMIT_REACHED with 0 writes.
  - Given 50 concurrent loader calls with an expired cache, then exactly 1 Firestore read.
  - Given the refresh failing for 9 minutes, then the last good set is served with WARN.
  - Given the refresh failing for 11 minutes, or an instance that never loaded, then UNAVAILABLE with ERROR, never an empty set.
  - Given a deleted protected account, then its uid is gone from the set before `users/{uid}` is deleted.
  - Given the PR, then the T11 guard is green.
- **Tests.** Unit tests with fakes: the toggle matrix (on, off, equal, quota, cap, flag modes, mixed request) and the loader (lazy, singleflight, TTL, missing doc, stale, never loaded, in-place update). Emulator tests through `make test-int`: `budgettest` on the toggle, and the identity step.
- **Observability.**
  - `privacy_toggle=on|off|noop|quota|cap` on the request line;
  - `privacy_toggle_attempts` (transaction attempts; the D3 hot-doc signal);
  - `protected_set_reads`, `protected_set_stale`, `protected_set_unavailable`.
- **Docs.**
  - New `docs/runbooks/private-accounts.md`. It covers the stale set and UNAVAILABLE, the 20,000 cap, and how to verify the set equals `count(users where isPrivate == true)` at 1 read per 1,000.
  - `docs/runbooks/identity.md`: the toggle row.
  - `docs/code-map.md`: the loader row.
- **Flag.** `private_accounts` for `is_private=true` only.
- **Seam.** `identity.ProtectedAuthors`: the Stage 2 sharded set (16 docs) or Memorystore changes no caller. Also `identity.PrivacyListener`.
- **Cost.**
  - Toggles: 0.002 calls per DAU, 0.01 reads per DAU.
  - Set refresh: ≤ 1,440 reads per instance per day, about 960 / 2,400 / 4,320 a day at 300 / 1,000 / 3,000 DAU. That is +3.2 / 2.4 / 1.4 reads per DAU.
  - 0 when idle: the refresh happens only when a request needs the set.

#### W3-26b Identity: GetProfile and GetMe for protected accounts [backend-developer] [S] [depends: W3-26a, W3-28a] Status: In review (PR #395)
- **GetProfile(P) for an unapproved viewer** (D4):
  - It returns the header: name, handle, bio, avatar, banner, location, website, counts and `is_private = true`. It omits `pinned_post_id`.
  - "Approved" is the AQ2 expression over the set and `BlockChecker.IsFollowing(ctx, viewer, target)`. That method extends the interface, and graph implements it from the viewer's cached snapshot (0 reads warm).
  - The blocked-by NOT_FOUND still comes first, unchanged.
  - The ADR-0024 Amendment 1 A1 website rule still applies on top.
  - While the set is unavailable, the pin is omitted (AQ6), only for a viewer who is neither the account nor a follower, with WARN `pin_omitted=set_unavailable`; the rest of the profile is returned (ADR-0025 implementation notes).
- **GetMe** (D7): for a caller whose `isPrivate` is true, `pending_follow_request_count` comes from `FollowRequestCounter` (graph's `count()`, W3-28a), cached 30 s per uid. For everyone else it is 0 reads and 0. A count failure leaves the badge at 0 with WARN, and GetMe does not fail.
- **Acceptance.**
  - Given P protected and A not following, when A calls GetProfile(P), then every header field is returned and `pinned_post_id` is empty, at the same reads as before Part B.
  - Given A follows P, or A is P, then the pin is returned.
  - Given P protected with 3 pending requests, when P calls GetMe twice within 30 s, then `pending_follow_request_count` = 3 and the second call adds 0 reads.
  - Given a public caller, then GetMe reads are unchanged.
- **Tests.** Unit and emulator tests (`budgettest`: GetProfile +0, GetMe +1 cold for a protected caller).
- **Observability.** `pin_omitted=protected` on GetProfile (no uid); `follow_requests_count_cache_hit`.
- **Docs.** `docs/runbooks/identity.md` rows.
- **Flag.** None: never gated.
- **Seam.** `identity.BlockChecker.IsFollowing` and `identity.FollowRequestCounter`. The Stage 2 version is a counter on the target, when one protected account gets more than 1 request/s.
- **Cost.** About 0.2 calls per DAU (4 GetMe x 5% protected), 0.10 reads per DAU.

#### W3-27 Graph: Follow to a protected account, withdraw, Block [backend-developer] [M] [depends: W3-25b; merges only after W3-32] Status: Done (PR #385)
- **Follow** (D6). It reads the target's `users` doc inside the transaction through `identity.TxProfiles.ProfileInTx` instead of the 60 s cache: 4 cold / 3 warm reads (planning value 4, ADR-0008 A2). Checks run in this order:
  1. The existing NOT_FOUND, TARGET_BLOCKED and VALIDATION rules.
  2. Already following: a replay, before any request logic (I-X).
  3. Target protected and not followed:
     - `Create followRequests/{caller}_{target}` with `{followerId, followeeId, createdAt}`;
     - `ArrayUnion` the target into the caller's `requested`;
     - `quotas.follows`.

     3 writes; returns `REQUESTED`.
  4. Replay (the request exists, or the target is in `requested`): `REQUESTED`, 0 writes, no quota.
  5. `requested` at 500: LIMIT_REACHED `limit=follow_requests`.

  The follows quota (200/day, 50 for new accounts) is unchanged and counts requests. A public target with a leftover request takes the AQ4 path: the edge, plus a plain `Delete` of the request and its removal from `requested` in the same transaction (+1 delete, 0 reads; ADR-0025 implementation notes). After the commit, `FollowEvents.FollowRequested`, and no `Followed`. Never gated.
- **Withdraw = Unfollow** (D7). Today's blind edge batch runs first. On its failed precondition, a second blind batch: `Delete(followRequests/{caller}_{target}, Exists)` plus `ArrayRemove` from `requested`. A second failure means NONE.
  - Cost: 0 reads in the batches (+1 logged interceptor), 1 write, 1 delete.
  - ADR-0009's 0-read design is unchanged. Never gated.
- **REQUESTED everywhere** (D2). `relationshipFor` (`graph/api.go`:65) reports `FOLLOW_STATE_REQUESTED` when the target is in the caller's `requested`, at 0 reads. That covers GetRelationships, every `UserListItem`, the Follow and Unfollow responses, GetProfileRelationship and suggestions.
- **Block** (D7). The existing transaction also deletes `followRequests` in both directions when present in either `requested`, and removes the entries in the writes it already makes: +0 reads, +0 writes, ≤ +2 deletes.
- **Invariants.** Every writer here keeps I1, I-R and I-X (D9); the checker is W3-35b.
- **Acceptance.**
  - Given P protected, when A follows P, then the request doc exists, P ∈ A.`requested`, A's quota is +1, the response is REQUESTED, and the call costs 4 cold reads and 3 writes.
  - Given the same Follow again, then REQUESTED with 0 writes.
  - Given A has 500 pending requests, when A follows another protected account, then LIMIT_REACHED with 0 writes.
  - Given A requested P, when A unfollows P, then the request doc and the entry are gone (1 write, 1 delete) and A's relationship is NONE.
  - Given nothing to withdraw, then NONE with 0 writes.
  - Given a protect committed while A's Follow is in flight, then A's Follow commits as a request, never as an edge (the in-transaction read).
  - Given requests in both directions, when either side blocks, then both request docs and both entries are gone with no extra read.
- **Tests.** Unit and emulator tests with `budgettest`, including the follow-vs-protect race on the emulator.
- **Observability.**
  - `follow_outcome=edge|requested|replay`;
  - `txn_attempts`, and ABORTED per target hash (the D6 contention signal);
  - `withdraw=request|none`.
- **Docs.**
  - `docs/runbooks/graph.md` "Follow requests": caps, quota, the contention signal and its fallback (back to the 60 s cached target read).
  - `docs/runbooks/abuse-spike.md` "request spam": the D13 arithmetic — 200/day, the Follow bucket 30/min x 3 = 90/min, the 500 cap, one push per requester per target per 90 d, and a block deletes the request.
- **Flag.** None: never gated.
- **Seam.** `graph.Service` and `graph.FollowEvents`. The Stage 2 version is an edge table with a state column.
- **Cost.**
  - Follow: 0.5 calls per DAU, +0 reads at planning.
  - 0.05 follows per DAU go to protected targets, at 3 writes instead of 5: -0.1 writes per DAU.
  - Withdraw: 0.005 calls per DAU.

#### W3-28a Graph: request lists and responses, protected follower lists [backend-developer] [M] [depends: W3-27, W3-26a] Status: Done (PR #388)
- **`ListFollowRequests`** (D7). Incoming requests, newest first.
  - Query: `followRequests where followeeId == caller ORDER BY createdAt DESC, __name__ DESC Limit(page)`, on the existing composite index.
  - Hydrate through `Directory` (non-ACTIVE rows dropped), and drop users in the caller's `blocked` or `blockedBy`.
  - `relationship` comes from the caller's snapshot.
  - Page 20 by default, max 50.
  - The cursor is sealed to `caller|follow-requests` with a 24 h TTL, using the graph list helpers (no second cursor). A foreign, expired or tampered token is VALIDATION `page_token` at 0 reads.
- **`RespondToFollowRequest`** (the D7 table):
  - Accept: the request is read fresh (absent means replay), then the requester's graph fresh; the requester's status comes from `Directory`, cache-first. It writes:
    - `Create follows/{requester}_{target}`;
    - the requester's graph: `following += target`, `requested -= target`;
    - `followingCount +1` and `followersCount +1` through `identity.Counters`;
    - the request delete.

    3 cold / 2 warm reads, 4 writes, 1 delete.
  - Decline: 1 write, 1 delete.
  - Replay: the caller's current relationship to the requester, 2 / 1 reads, 0 writes.
  - Requester not ACTIVE: the request is deleted and `requested` cleaned, no edge.
  - Requester following 5,000 accounts: LIMIT_REACHED `limit=requester_following`, 0 writes.
  - `relationship` in the response is the caller's relationship to the requester, from the snapshot at 0 reads.
  - The idempotency key is validated, not stored.
  - After an accept, `FollowEvents.FollowRequestAccepted`. Nothing is emitted on decline, and the target gets no plain FOLLOW notification.
  - The accept code is written once, as a page-sized transaction helper that W3-28b reuses.
  - Rate limit: `RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN` (60 per instance, 180 effective).
- **Gate for both RPCs** (D12): the flag is not globally off, or the caller is protected now. That costs 0 extra reads: the interceptor already read the profile.
- **`ListFollowers(P)` and `ListFollowing(P)`** for an unapproved viewer: FAILED_PRECONDITION + `ERROR_REASON_PROTECTED_ACCOUNT`, decided before any page read (3 cold reads). Approved viewers are unchanged. While the set is unavailable: UNAVAILABLE.
- **`FollowRequestCounter`** for W3-26b: `count()` on `followRequests where followeeId == uid`, 1 read per 1,000 matches.
- **Acceptance.**
  - Given 25 pending requests, then page 1 returns 20 rows and a token, and page 2 returns 5 rows and `""`, at 42 cold / 21 warm reads for page 20 and 102 / 51 for page 50.
  - Given a requester whom the caller blocked, then that row is dropped.
  - Given a pending request, when it is accepted, then the edge, both counters and the requester's graph change in one transaction at 3 cold reads, 4 writes and 1 delete, and the response carries the caller's relationship to the requester.
  - Given the same accept again, then a replay with 0 writes.
  - Given a decline, then 1 write and 1 delete, and no notification.
  - Given the flag globally off and a protected caller, then both RPCs still work.
  - Given A not approved, when A lists P's followers, then PROTECTED_ACCOUNT at 3 cold reads.
  - Every new ceiling (42, 102, 3) is under `readBudgetMaxCallReads` (269), per D13.
- **Tests.** Emulator tests with `budgettest`; the cursor matrix; the accept-vs-withdraw and accept-vs-block races (one wins, and I-R and I-X hold); the PROTECTED_ACCOUNT matrix.
- **Observability.**
  - `respond=accept|decline|replay|requester_inactive|requester_cap`;
  - `rows_dropped` on the list line;
  - `fs_reads`.
- **Docs.** `docs/runbooks/graph.md` "Follow requests" (list, respond, limits); a `docs/code-map.md` row for the accept helper.
- **Flag.** The D12 gate above.
- **Seam.** The opaque `follow-requests` cursor and `graph.FollowEvents`.
- **Cost.**
  - List: 0.02 calls per DAU, 0.84 reads per DAU.
  - Respond: 0.04 calls per DAU, 0.12 reads, 0.16 writes and 0.04 deletes per DAU.

#### W3-28b Graph: the `privacy_public` job [backend-developer] [S] [depends: W3-28a, W3-26a] Status: Done (PR #396)
- **Description** (D8, AQ1).
  - An `apiserver` adapter implements `identity.PrivacyListener` by publishing `{kind: privacy_public, uid}` to the existing `jobs` topic.
  - Graph's handler is registered with `lifecycle.RegisterJobHandler`, as `profile_media_retired` is (`apiserver.go`:394).
- **The handler.**
  1. Read `users/{uid}` fresh. If the account is protected again, ack and stop.
  2. Page `followRequests where followeeId == uid ORDER BY createdAt DESC Limit(100)`. The paging self-resumes because accepted requests drop out.
  3. Accept each page in one transaction through W3-28a's helper. It re-reads every request and requester graph fresh, then writes the per-request accept effects and, once per page, `followersCount += n`. That is at most 401 operations.
  4. Requesters at the following cap or no longer ACTIVE are handled as in D7, inside the same transaction.
  5. Emit `FollowRequestAccepted` per accepted request after the page commits.

  There is no start gate. At-least-once delivery is safe. Never gated.
- **Acceptance.**
  - Given P with 250 pending requests, when P unprotects, then all 250 become edges, P's `followersCount` rises by exactly 250, and no request remains.
  - Given a crash after page 1 and a redelivery, then no counter is doubled or lost.
  - Given P re-protects before the job runs, then the job accepts nothing.
  - Cost per request: 2 reads, 3 writes and 1 delete, plus 1 write per page.
- **Tests.** Emulator tests through `make test-int` with 0, 1, 100, 101 and 250 pending; redelivery; re-protect; requester at the cap; requester deleting.
- **Observability.** One `privacy_public` line per page: `accepted`, `skipped_inactive`, `skipped_cap`, `page`, `outcome`. ERROR on failure (Pub/Sub retries).
- **Docs.** `docs/runbooks/private-accounts.md`, section "privacy_public job": stuck or partial means rerun by republishing; the job is idempotent.
- **Flag.** None: never gated.
- **Seam.** `identity.PrivacyListener`, the `jobs` topic, and one accept implementation.
- **Cost.** Rare, about 0 per DAU. Worst case is 500 pending: 1,000 reads, 1,505 writes, 500 deletes (7.5% of the free daily writes), bounded by the 4-a-day toggle quota.

#### W3-28c Graph: `is_private` on user-list rows [backend-developer] [S] [depends: W3-25c, W3-28a] Status: Done (PR #393)
- **Description** (ADR-0025 "Implementation note (W3-25c)").
  - `make proto`, with the generated Go and Dart committed (the W3-25c field).
  - Set `IsPrivate: p.IsPrivate` in `toProtoAuthorSnapshot` (`graph/server.go`), the one helper behind every `UserListItem`. That fills ListFollowers, ListFollowing, ListFollowRequests (as built by W3-28a), ListSuggestedUsers, ListBlockedUsers and ListMutedUsers from the profile the list already hydrated through `identity.Directory`.
  - Do not read the protected set (`identity.ProtectedAuthors`) here: the profile is the source of truth and already in hand, and the set's fail-closed rule has no meaning for a badge.
  - Do not touch the frozen copies: `posts/convert.go` (`Post.author`, `EmbeddedPost.author`) and `notifications/server.go` (`Notification.actor`) keep leaving the field unset. No Firestore field is added to `posts.author{}` or a notification's `actor{}`.
- **Acceptance.**
  - Given P protected and A public, both followed by the caller, when the caller lists their following, then P's row has `user.is_private = true` and A's row false.
  - Given the same pair, then the same holds on each of the six graph lists that can contain them (followers, following, follow requests to a protected caller, suggestions, blocked, muted).
  - Full chain: given P sets `is_private=true` through `UpdateProfile`, when a list containing P is read over the wire after the `Directory` cache expires (or on a fresh instance), then the row shows true; and after P turns it off, false.
  - Given any post or notification whose author or actor is protected, then `author.is_private` / `actor.is_private` is false on the wire (frozen copies are never filled).
  - Budget: every list's reads, writes and deletes are unchanged (`budgettest`, +0 against the current ceilings: ListFollowRequests 42 / 102 cold, ListSuggestedUsers cap 32 cold, the others as in the op-cost table).
- **Tests.** A unit test of `toProtoAuthorSnapshot`; emulator tests through `make test-int` for the six lists and the full chain; the budget assertions above.
- **Observability.** None new: the existing list lines already carry `fs_reads`.
- **Docs.** A `docs/code-map.md` row for `toProtoAuthorSnapshot` if it is not listed.
- **Flag.** None. The field is filled whatever the flag, as `Profile.is_private` is.
- **Seam.** One conversion helper; access decisions stay on `posts.Audience`.
- **Cost.** +0 reads, +0 writes; at most 2 bytes per row on the wire when true.

#### W3-29a Posts: `posts.Audience`, GetPost, `Viewable`, refusals, embeds [backend-developer] [M] [depends: W3-25b; merges after W3-26a] Status: Done (PR #382)
- **`posts.Audience`** (D3):
  - `CanSee(viewer, author, snap, set) bool` is pure, using the AQ2 expression.
  - `Decide(ctx, viewer, snap, p, surface)` returns Show, Drop, NotFound, or Show with the embed state BLOCKED, MUTED or PROTECTED. It covers `Visible()`, ADR-0010 D6 block and mute by surface, and `CanSee` on `p.AuthorID` and on `p.EmbeddedAuthor()`.
  - The set is fetched through `identity.ProtectedAuthors` only for an author who is neither the viewer nor followed. A set error is UNAVAILABLE.
- **Sites converted in this ticket.**
  - `posts/service_delete.go`:201 (`viewable`): GetPost and every `Engagement.Viewable` caller (Like, AddBookmark, Report, reply parent, quote target) answer P's post with NOT_FOUND "post not found", byte-identical to a deleted post.
  - `posts/convert.go`:148: the wire `Post.visibility` is computed, `VISIBILITY_FOLLOWERS` while the author is in the set. Stored docs and writers stay `PUBLIC`.
  - The `EmbedViewerState` hinter (`posts/server.go`:164, :243; `service_thread.go`:439-464) gains PROTECTED.
- **The strip.** When the embed state is PROTECTED, the one view converter empties the embed's text, media (URLs, thumbs, alt text, sizes), hashtags and mentions. It keeps `post_id` and the author snapshot. Every surface inherits this. A REPOST whose original is by P resolves to NOT_FOUND on GetPost and is dropped in feeds and lists.
- **D5 write rules.**
  - RepostPost of P's post, and CreatePost with `quote_of_post_id` set to P's post:
    - unapproved caller: NOT_FOUND;
    - approved caller other than P: FAILED_PRECONDITION `PROTECTED_ACCOUNT`, 0 writes;
    - P may repost and quote their own posts.
  - Like, bookmark, reply and report by approved callers work as today. A public reply to P's post shows "Replying to @P" and its own text, never P's.
  - Mentions of P are unaffected. Existing copies are never rewritten.
  - UnlikePost, UndoRepost and RemoveBookmark stay outside `Audience` (lesson 4).
- **Wiring.** `posts.WithProtectedAuthors` in `apiserver.go`, after W3-26a merges. The ticket builds against a fake set until then.
- **Acceptance.**
  - Given P protected and A not approved, when A calls GetPost(P's post), then the HTTP status, content type and body are byte-identical to GetPost of a deleted post (the W3-20 comparator). The same holds for Like, AddBookmark, Report, a reply and a quote.
  - Given A follows P, then everything is as today.
  - Given an approved non-author, when they repost or quote P's post, then PROTECTED_ACCOUNT with 0 writes.
  - Given P, when P reposts their own post, then it succeeds.
  - Given X quoted P while P was public, when A reads X's quote, then the embed state is PROTECTED and the JSON has no embedded text and no `m/<id>` URL of P's media, but has `post_id` and P's handle.
  - Given A liked P's post while approved, when A unlikes after P protects, then it succeeds.
  - Given the set is unavailable, when A reads a post by a non-followed author, then UNAVAILABLE.
  - Every path is at +0 reads: GetPost 4 cold / 0 warm, as in W3-20.
- **Tests.** A unit table over every D4 GetPost and `Viewable` cell (self, follower, non-follower, P blocks A first, A blocks P, mute, taken down, suspended author, set unavailable); emulator byte-identity, strip, refusal, undo and `budgettest`.
- **Observability.** `audience=protected` on the refusal line, never with the author uid.
- **Docs.**
  - `docs/runbooks/posts.md` "Protected posts": stored visibility stays PUBLIC, and the decision is made at read time.
  - `docs/code-map.md` `posts.Audience` row: the only visibility predicate, which W4, W5 and W7 call.
- **Flag.** None: never gated.
- **Seam.** `posts.Audience`. In Stage 2 the same predicate is pushed into the query layer with the timeline ADR.
- **Cost.** +0 reads per DAU; the refusals write nothing.

#### W3-29b Posts + engagement: GetThread and the owner-only lists [backend-developer] [M] [depends: W3-29a] Status: In review (PR #386)
- **GetThread** (D4).
  - Focal post by P: NOT_FOUND, byte-identical to a deleted focal post.
  - Parent or root by P: unset, with `parent_unavailable` or `root_unavailable` (a tombstone).
  - Reply rows by P are dropped. The page may be short, and clients follow `next_page_token`.
  - Converts `posts/service_thread.go`:174 and :249.
- **ListBookmarks and ListLikedPosts** (the D4 list row, W2 L-2):
  - `privateToViewer` (`engagement/list_common.go`:89-94) is deleted. `dropRows` calls `Audience.Decide` with the list surface.
  - Rows by P are dropped and kept, never pruned, under a new `rows_dropped_protected` field in `noteRows`. The existing `rows_dropped_*` fields stay.
  - A QUOTE row embedding P shows the stripped PROTECTED embed. A REPOST of P is dropped.
- **Acceptance.**
  - Given A not approved, then GetThread(P's post) is byte-identical to GetThread of a deleted post.
  - Given X's reply to P's post as focal, then the parent is unset with `parent_unavailable` and X's text is shown.
  - Given A bookmarked and liked P's posts while following, when A unfollows, then both lists drop those rows and nothing is pruned.
  - Given A follows again, or P unprotects, then the rows return.
  - Reads stay at +0: ListBookmarks 43 / 103 / 2, ListLikedPosts 23 / 53 / 2, GetThread at its current ceilings.
- **Tests.** Emulator thread and list matrices with `budgettest`.
- **Observability.** `audience_dropped` by cause (protected, blocked, muted, hidden) on the GetThread line; `rows_dropped_protected` on the list lines.
- **Docs.** `docs/runbooks/bookmarks.md` and `docs/runbooks/engagement.md`: rows hidden for protected authors.
- **Flag.** None: never gated.
- **Seam.** `list_common.go` (one drop function) and `posts.Audience`.
- **Cost.** +0.

#### W3-30 Timeline: protected profile state and feed embeds [backend-developer] [S] [depends: W3-29a, W3-26a] Status: Done (PR #384)
- **`GetUserTimeline(P)`, any tab** (Posts, Replies, Media, Reposts), for an unapproved viewer:
  - `author_protected = true`, no posts and no tokens.
  - Decided before the author-recent cache is consulted, at 3 cold reads (interceptor, target `users`, caller graph) and 0 page reads.
  - A token issued before P protected gets the same answer.
  - Approved viewers are unchanged.
- **Feeds.**
  - Home and other users' Reposts and Replies tabs: a REPOST whose original is by P is dropped, and a QUOTE of P shows the stripped PROTECTED embed.
  - `filterEmbeds` and `embedAllowed` (`timeline/service.go`:294-335) call `Decide`.
  - `isPublic` (:521) is replaced.
  - `removed_ids` is unchanged.
- **Wiring.** `timeline.WithProtectedAuthors`, after W3-26a.
- **Acceptance.**
  - Given A not approved, then all four tabs answer `author_protected` at 3 cold reads.
  - Given A follows P, then the tabs are as today: 24 / 54 cold at page 20 / 50.
  - Given X's REPOST and QUOTE of P in A's Home, then the REPOST is absent and the QUOTE's embed is stripped.
  - Home ceilings are unchanged.
- **Tests.** Unit and emulator tests with `budgettest`.
- **Observability.** `author_protected=true` and `audience_dropped` counts on the request line.
- **Docs.** `docs/runbooks/posts.md` (timelines) row.
- **Flag.** None: never gated.
- **Seam.** The `timeline` interface and the opaque tokens.
- **Cost.** No more than today's NOT_FOUND path.
- **Built (W3-30).** `timeline/audience.go` (`WithProtectedAuthors`, `audienceFilter`), `timeline/service.go` (`checkVisible` returns `protected`; `isPublic` replaced by `moderationVisible`; `filterEmbeds` and Home call `Decide`; `toViews` applies `ApplyEmbedState` and `ApplyWireVisibility`), and two small additions to `posts/audience.go` (`NewSnapshotAudience`, `VisibleAuthor`). Wiring: one `timeline.WithProtectedAuthors(protectedAuthors)` argument on the existing `timeline.NewServer` call. Own-profile corner: a page holding a copy of another user's post reads the caller's graph once (+1 cold, cached 60 s), only when a loader is wired. Measured (emulator, cold, interceptor included): unapproved tabs 3 reads; approved Media or Reposts at most 24; Home 6 reads before and after protecting.

#### W3-31 Notifications: request types and protected-actor suppression [backend-developer] [S] [depends: W3-25b; W3-26a and W3-29a merged] Status: Done (PR #380)
- **The two types** (D10):
  - `follow_request`, id `follow_request_{requesterUid}`, sent to the target.
  - `follow_accepted`, id `follow_accepted_{targetUid}`, sent to the requester.
  - Both are written by the existing fan-out handler with `actorIds = [actor]`, so the ADR-0017 D10 eraser finds them.
  - `Create` is used: AlreadyExists means no new row and no second push within the 90 d TTL.
  - A withdraw or decline does not delete the `follow_request` row.
  - Push text is generic: "New follow request" and "Follow request accepted". The FCM data carries type, notification id and actor id only.
  - Both types are gated by `notifications` like every type, never by `private_accounts`.
  - `followNotifier` fills the two `FollowEvents` methods that W3-25b left as no-ops.
- **Suppression** (D10, D4). Post-bearing types (mention, reply, quote, repost) are dropped at fan-out when the recipient cannot see the actor (`CanSee` false), through the AQ5 seam. That costs 0 reads: the actor's status comes from the set, and the recipient's snapshot is already read. Like and follow rows are unaffected. While the set is unavailable, a post-bearing fan-out returns a retryable error (Pub/Sub redelivers) and never writes the row (AQ5, ADR-0025 implementation notes).
- **Site.** `apiserver/notifications_wiring.go`:84 (`post.Visibility != PUBLIC`) is replaced. A protected author's post still notifies recipients who can see it.
- **Acceptance.**
  - Given A requests P, then P gets one `follow_request` row and one push.
  - Given A withdraws and requests again within 90 d, then no second row and no second push.
  - Given P accepts, then A gets `follow_accepted` and P gets no FOLLOW row.
  - Given P mentions A who is not approved, then no row.
  - Given A follows P, then a row.
  - Given P deletes the account, then the eraser removes P's rows from other users' lists.
- **Tests.** Unit and emulator tests.
- **Observability.** `suppressed_protected` count on the fan-out line.
- **Docs.** `docs/runbooks/notifications.md` rows for both types and the suppression.
- **Flag.** `notifications`.
- **Seam.** `graph.FollowEvents`, `notifications.Emitter` on Pub/Sub, and the AQ5 checker.
- **Cost.** 0.05 + 0.04 calls per DAU, about 2 reads per recipient: 0.18 reads and 0.09 writes per DAU, plus TTL deletes after 90 d.

#### W3-32 Lifecycle: `follow_requests` eraser and export [backend-developer] [M] [depends: W3-25b; merges before W3-27] Status: Done (PR #381)
- **The eraser** (D11): a new appended step, `follow_requests` (`graph.RequestEraser`), registered after `bookmarks` and before `identity`. Step names are persisted in `deletionJob.step` (the ADR-0023 D6 precedent), so graph's internal step numbers do not change.
  - Outgoing: `followRequests where followerId == uid Limit(500)`, 1 read + 1 delete each.
  - Incoming: `followRequests where followeeId == uid ORDER BY createdAt DESC Limit(500)`, 1 read + 1 delete + 1 `Update` with `ArrayRemove(uid)` on the requester's `graph`. NotFound is skipped and logged as `purge_missing_counterpart`, never `Set`.
  - The step self-resumes, minimum 2 reads.
- **The export:** a new appended section, `follow_requests`: `{"sent":[{userId, handle, requestedAt}], "received":[…]}`, newest first, 1 read per doc, minimum 2. Handles resolve as the graph section does (`graph/export.go`:106). The graph section's bytes and golden file are unchanged, and the set doc is never exported.
- **T11.** The `followRequests` row changes from `pendingEraser` to `erasedByStep: follow_requests`, Section `follow_requests` (`lifecycle_collections_guard_test.go`:83).
- **`lifecycle_wiring_test.go`.** Steps: `…, scheduled, bookmarks, follow_requests, identity, auth_delete, users_doc`. The export list ends `…, bookmarks, follow_requests`.
- **Why first.** Until W3-27 merges nothing writes `followRequests`, so the step costs 2 reads per deletion. Merging it first is what lets W3-27 pass the guard.
- **Acceptance.**
  - Given a user with 501 outgoing and 3 incoming requests, when the account is deleted, then every request doc and every `requested` entry naming them is gone, and a missing counterpart is logged and skipped.
  - Given an export, then `follow_requests` lists sent and received rows, newest first, with handles.
  - The existing goldens are unchanged, and the T11 guard is green.
- **Tests.** Emulator tests (0, 1 and 501 rows each way; missing counterpart), the export golden and the wiring lists.
- **Observability.** `graph_purge_follow_requests` (counts only) and `purge_missing_counterpart`.
- **Docs.** `docs/runbooks/account-deletion.md`: the new step.
- **Flag.** None: never gated.
- **Seam.** identity's `StepEraser` / `ExportSection`.
- **Cost.** Per deletion and per export only.
- **Built (W3-32).** `graph/purge_requests.go` (`RequestEraser`, `RequestCheckpoint{Phase}`), `graph/export_requests.go` (`ExportRequests`), `apiserver/lifecycle_wiring.go` (`registerFollowRequestsLifecycle`). The incoming page is 250, not 500: each doc is a delete plus a requester update, and a batch holds at most 500 operations. The outgoing pass uses the automatic `followerId` index, and the export orders the sent side by document id and sorts in memory, so no new composite index is needed.

#### W3-33a Client: protected profile, lock badge, Requested and withdraw [frontend-developer] [M] [depends: W3-26a, W3-27, W3-30 serving dev] Status: Done (PR #389)
- **Profile.**
  - `author_protected` replaces the cached feed for every tab's `FeedKey.user(uid, tab)` with the protected view: a lock, "These posts are protected", and "Only approved followers can see @handle's posts. To request access, tap Follow." (X-like default).
  - The tab bar is hidden, and the Pinned row is absent because the server omits the pin.
  - The owner never sees this view.
- **Lock badge.**
  - In the header, from `Profile.is_private`.
  - In `UserListRow`: moved to W3-33c (the field `UserListItem.user.is_private` did not exist until W3-25c).
  - In the post card author line, when `Post.visibility` is FOLLOWERS.
- **`FollowButton`.**
  - The REQUESTED variant reads "Requested". Tapping it asks "Cancel your follow request?" and then calls Unfollow. Never gated (the undo rule).
  - Follow of a protected target shows Requested and reconciles with the response.
  - LIMIT_REACHED `follow_requests` has its own copy.
- **Followers and Following lists of P.** `PROTECTED_ACCOUNT` shows a protected state instead of an error.
- **Acceptance.**
  - Given a server answer with `author_protected`, then a previously cached Posts feed for that user is not shown.
  - Given REQUESTED, when the user withdraws, then one Unfollow is sent and the button returns to Follow, with the flag off as well.
  - At 360 dp and text scale 2.0, the lock badge and Requested do not overlap the name (W3-21 D-1).
- **Tests.** Widget tests in the W3-21 matrix; repository tests for the cache replacement.
- **Docs.** `docs/ui-catalog.md` rows.
- **Flag.** Rendering is ungated.
- **Seam.** `ProfileCubit` and `TimelineRepository` read `author_protected`, so no widget reads the proto.
- **Cost.** 0 new RPCs; a protected profile open costs 3 reads.

#### W3-33b Client: protect setting, protected embed, refusals [frontend-developer] [M] [depends: W3-26a, W3-29a serving dev] Status: Done (PR #387; avatar follow-up PR #390)
- **Setting.** Settings > Privacy and safety > Audience > "Protect your posts".
  - Turning it on needs `private_accounts` in `enabled_features`. The confirm explains:
    - only approved followers see your posts, past and future;
    - current followers stay;
    - it takes effect within about a minute;
    - images already shared may still open from their link (founder question B1);
    - turning it off later approves pending requests.
  - Turning it off is shown whenever `is_private` is true, whatever the flag (the undo rule), with a confirm about auto-approval.
  - Copy for QUOTA_EXCEEDED `privacy_toggles` ("You can change this 4 times a day") and for LIMIT_REACHED `private_accounts`.
  - FEATURE_DISABLED hides the turn-on control until the next GetMe; turn-off stays.
- **Protected embed.** "This post is from an account that protects its posts." Avatar shown (founder 2026-10-28); no post text or media. The author is shown.
- **Refusals.** Repost and Quote are disabled on another user's FOLLOWERS post. `PROTECTED_ACCOUNT` shows "You can't repost or quote posts from a protected account." The server stays authoritative.
- **Acceptance.**
  - Given the flag off for a protected user, then the switch shows "on" and can be turned off.
  - Given the flag off for a public user, then no switch.
  - Given a PROTECTED embed, then no post text and no post media are shown; the author avatar is shown (founder 2026-10-28).
- **Tests.** The widget matrix.
- **Docs.** `docs/ui-catalog.md` rows.
- **Flag.** `private_accounts`, for turn-on only.
- **Seam.** One settings row and one embed widget variant, so W5 and W7 reuse them.
- **Cost.** 1 UpdateProfile per toggle (4 / 3 reads, 3 writes).

#### W3-33c Client: the lock badge on user-list rows [frontend-developer] [S] [depends: W3-28c serving dev, W3-33a] Status: Done (PR #394)
- **Description** (ADR-0025 "Implementation note (W3-25c)").
  - `UserListRow` shows the lock badge after the display name when `UserListItem.user.is_private` is true, with the same badge widget and semantics label as the profile header (W3-33a).
  - Every surface that renders `UserListRow` gets it: Followers, Following, Follow requests (W3-34), Who to follow (the Home card and the right column), Blocked and Muted accounts.
  - The field is a hint: false renders no badge and never a "public" state. Nothing gates on it; access still comes from the server's answers.
  - The post card keeps its own rule (W3-33a): its lock comes from `Post.visibility` FOLLOWERS, never from `Post.author.is_private`, which is always false.
- **Acceptance.**
  - Given a row with `is_private = true`, then the badge shows; given false, then no badge and no other privacy text.
  - Given a post with `visibility` FOLLOWERS and `author.is_private = false`, then the post card still shows the lock.
  - Given a Who to follow row cached on the device (48 h, ADR-0024 Amendment 2), then the badge reflects the cached row and updates on the next refresh; no extra call is made for it.
  - At 360 dp and text scale 2.0, the badge does not overlap or push out the Follow button (W3-21 D-1).
- **Tests.** Widget tests across the W3-21 matrix (360 / 600 / 1200 dp x light / dark x 1.0 / 1.3 / 2.0) for `UserListRow` with and without the badge, a long display name, and the Follow / Requested / Following button states.
- **Docs.** `docs/ui-catalog.md`: the `UserListRow` line mentions the badge.
- **Flag.** None: rendering is ungated, like the header badge.
- **Seam.** `UserListRow` reads the generated field; no second user-list model.
- **Cost.** 0 new RPCs, 0 reads.

#### W3-34 Client: Follow requests screen [frontend-developer] [M] [depends: W3-28a, W3-26b, W3-31 serving dev] Status: Open
- **The screen.** `/follow-requests`: a `PagedUserList` over `ListFollowRequests`.
  - Page 20. It follows `next_page_token` through short pages, sends the token back unchanged, and reloads page 1 on VALIDATION `page_token`.
  - Accept and Decline per row. After Accept, "Follow back" uses the response's `relationship`. The row leaves on success and returns on failure.
  - No undo: the server has none, and there is no "remove follower" (founder question B3).
- **Reachability.** Reachable when `private_accounts` is in `enabled_features` or the caller is protected (the undo rule). FEATURE_DISABLED hides it with a 10-minute backoff.
- **Drawer.** A "Follow requests" entry with a badge from `pending_follow_request_count`, shown while the count is above 0 or the caller is protected.
- **Notifications.**
  - FOLLOW_REQUEST rows read "@x requested to follow you" and open `/follow-requests`.
  - FOLLOW_ACCEPTED rows read "@y accepted your follow request" and open the profile.
- **Acceptance.**
  - Given 25 requests, then 20 rows then 5, with no duplicates.
  - Given Accept, then the row leaves and Follow back appears.
  - Given the flag globally off and a protected caller, then the screen still works.
- **Tests.** The widget matrix, router flag-off routing and repository tests.
- **Docs.** `docs/ui-catalog.md`.
- **Flag.** `private_accounts`, or the caller being protected.
- **Seam.** A `FollowRequestsRepository` (session memory only, cleared under `SessionEpoch`).
- **Cost.** 1 ListFollowRequests per open (42 cold reads) and 1 Respond per tap.

#### W3-35a Tests: visibility matrix, byte identity, leaks, budgets [tester] [M] [depends: W3-26b, W3-28a, W3-29b, W3-30, W3-31] Status: Open
- **The matrix.** Every D4 row on the emulators through `apiserver.Build`.
  - Viewer classes: self, approved follower, non-follower, P blocks A, A blocks P, A mutes P, P suspended, post taken down, `blockedBy` overflow.
  - Paths:
    - GetPost and every `Viewable` caller;
    - GetThread focal, parent, root and replies;
    - Home REPOST and QUOTE;
    - GetUserTimeline, all four tabs;
    - X's Reposts and Replies tabs embedding P;
    - ListBookmarks, ListLikedPosts, ListFollowers, ListFollowing;
    - GetProfile (pin), GetProfileRelationship (REQUESTED), ListSuggestedUsers (P may be suggested; Follow creates a request);
    - the notification fan-out.
- **Byte identity.** The W3-20 comparator (lesson 5).
- **Leaks.**
  - No unapproved response body contains any `m/<id>` media URL of P's posts (full or thumb). P's avatar and banner may appear.
  - Push payloads carry no post text.
  - Another user's export after liking, bookmarking, reposting and quoting P's post carries post ids and that user's own quote text only.
  - With `PROFILE_MEDIA_RETIRE=banner`, P's banner replacement retires exactly as for a public account, and protecting retires nothing.
- **Flag off keeps protection.** With `private_accounts` off everywhere, P stays protected on every path and can unprotect, list and respond.
- **Stale set.** A fake loader failure serves the last good set for 10 minutes, then UNAVAILABLE. Paths with only own or followed authors are unaffected.
- **The audience guard,** `apiserver/audience_guard_test.go`. A source scan fails when any of these is true:
  - a non-test file under `internal/`, outside `posts/audience.go` and the writers, compares `Visibility` with `VisibilityPublic` (`==` or `!=`; the wire converter's `switch` in `posts/convert.go` is not a comparison and is excluded by name);
  - a package that builds `PostView` rows never calls `posts.Audience`;
  - a non-test file other than `posts/audience.go` and identity's GetProfile calls the AQ2 expression on `identity.ProtectedSet` (ADR-0025 implementation notes).

  It catches W4 search, W5 lists and W7 the day they land. It replaces the ADR's "W4 placeholder test that fails until search calls Decide", which cannot compile before the package exists.
- **Budget table.** Every Part B RPC and every modified read path, at the ADR-0025 ceilings and +0 against the W3-20 table.
- **Report.** `docs/reviews/test-report-w3b.md`.
- **Cost.** 0.

#### W3-35b Tests: lifecycle, races, invariants, job, eraser [tester] [M] [depends: W3-27, W3-28a, W3-28b, W3-32] Status: Open
- **D7 cells and races.** Every D7 cell, plus these races:
  - follow vs protect;
  - accept vs withdraw;
  - accept vs block;
  - Respond on two instances;
  - the job vs a re-protect;
  - job redelivery mid-run.
- **Invariants.** The T16a checker (`graph/invariants_integration_test.go`) gains I-R and I-X, each with negative self-tests, as `TestGraphInvariantChecker_DetectsEveryViolation` has.
- **Flag matrix.** The D12 matrix in the ten rollout states of `TestW320_FlagModeMatrix`:
  - gated calls refused at 0 reads and 0 writes;
  - every never-gated call works in every state;
  - `enabled_features` exact.
- **Limits.** Toggle quota, the cap, and the equal-value no-op.
- **Eraser and export.** Deletion of a requester and of a target with requests both ways; the export golden; the wiring lists; the identity step removes the set entry; T11 green.
- **Runs and coverage.** Every run through `make test-int FIREBASE=firebase`. `internal/` coverage stays ≥ 70%.
- **Report.** A section of `docs/reviews/test-report-w3b.md`.
- **Cost.** 0.

#### W3-33d Client: Requested and Following fit user-list rows [frontend-developer] [S] [depends: W3-33c] Status: In review (PR #399)
- **Description.** W3-33c found that the outlined Requested and Following `FollowButton` states were about 12 dp wider than the `UserListRow` at 360 dp x text scale 2.0 (with or without the badge), which hid the lock (name column under 48 dp). Same class as the W3-21 D-1 lesson: actions grow with text scale. Founder decision 2026-10-28 (option A): the label is never scaled down, because shrinking it undoes the user's chosen text size (text must scale to 200% without loss).
  - `FollowButton` is unchanged: its label always renders at the user's text scale.
  - `UserListRow` lays out avatar, name column and the control with a small custom layout (`_AdaptiveRow`). The control keeps its natural width and the name column shrinks first (ellipsis), keeping the lock while it is at least 48 dp.
  - Only when the name column would drop under 48 dp (decided from measured widths, not a text-scale threshold) the control moves onto its own line under the name and handle, aligned to the text column (a control wider than that column ends at the row's right edge), still a 48 dp target, as on X's narrow list rows.
  - A caller's own `trailing` (Unblock/Unmute) follows the same rule; the dismiss "x" travels with the control.
- **Tests.** `user_list_row_badge_test.dart` no longer discards the overflow exception in any cell: every state x protected/public x the full matrix asserts no overflow, a 48 dp target, the label at theme size x text scale (no `FittedBox`), and the badge when protected; plus the wrapped layout at 360 dp x2.0 and a custom `trailing`.
- **Docs.** `docs/ui-catalog.md`: `FollowButton` and `UserListRow` rows.
- **Flag.** None. **Cost.** 0 new RPCs, 0 reads.

#### W3-35c Tests: client [tester] [S] [depends: W3-33a, W3-33b, W3-33c, W3-34] Status: Open
- **The responsive matrix** (360 / 600 / 1200 dp x light / dark x 1.0 / 1.3 / 2.0, 48 dp targets, inside the screen) for:
  - the protected profile view, the lock badge (header and `UserListRow`, W3-33c) and Requested;
  - the protect switch and its two confirms;
  - the protected embed;
  - `/follow-requests` rows and the drawer badge;
  - the two notification rows.
- **Flag-off routing.** `/follow-requests` for `private_accounts` off and on x protected and public. Turn-off and withdraw stay visible with the flag off.
- **Report.** `docs/reviews/test-report-w3b-client.md`.
- **Cost.** 0.

#### W3-36 Security review, Part B [security-auditor] [M] [depends: W3-26a to W3-32 merged; client at branch heads] Status: Done (PR #403): CLEAR WITH FIXES, `docs/reviews/security-review-w3b.md`
- **Every D4 leak path:**
  - embed strip completeness: text, media, alt text, hashtags, mentions;
  - notification rows and push payloads;
  - the bookmarks, likes, followers and following lists;
  - the pinned post;
  - counts;
  - the audience guard for search;
  - other users' exports;
  - client caches holding rows fetched while P was public;
  - post-image URLs: public-read Snowflake object names, listing closed by M-2, the A4 retire job;
  - the 60 s window.
- **Request spam arithmetic, x3 instances:** follows 200/day, the Follow bucket 30/min (90 effective), the 500 cap, Respond 60/min (180), one push per 90 d.
- **Other surfaces:**
  - the fail-closed loader;
  - the protect-vs-follow race;
  - the `privacy_public` job: a forged message behind the OIDC push, and idempotency;
  - the rollback-revision risk (lesson 10).
- **Oracles.**
  - PROTECTED_ACCOUNT reveals only `is_private`.
  - NOT_FOUND is byte-identical.
  - Block is checked first.
- **L-2.** Confirm W2 L-2 is closed by `Audience.Decide`, not by a stored-`visibility` test (D2).
- **Output.** `docs/reviews/security-review-w3b.md`. Findings are fixed or ticketed before W3-38.
- **Cost.** 0.

#### W3-37 Cost report, Part B [sre-performance] [S] [depends: W3-26a to W3-32 merged] Status: Open
- **`docs/reviews/cost-model.md`.** The ADR-0025 rows go into §1 to §6 and §9, plus a new §13 of measurements:
  - +1.25 request-path reads, the set-refresh line (detached), +0.16 writes and +0.05 deletes per DAU, restated on the 300.2 base ("Part B: cost" below);
  - the who-to-follow share after Part B;
  - the Part B §6 rows.
- **Load smoke.** A new k6 scenario, `loadtest/private_accounts_w3b.js`, run with `make loadtest SCENARIO=private_accounts_w3b` on alternate-port emulators. It covers:
  - ListFollowRequests at pages 20 and 50 with 500 pending;
  - a Respond burst;
  - a viral protected account receiving requests (Follow `txn_attempts` on the target's `users` doc);
  - the job with 500 pending;
  - read paths with 0 and with many protected authors (`protected_set_reads` ≤ 1 per instance per minute).
- **Dashboard notes, §9 queries:** `protected_set_reads`, `protected_set_stale`, `protected_set_unavailable`, `privacy_toggle_attempts`, Follow `txn_attempts` per target hash, and the `privacy_public` lines. No new alert policy or log-based metric.
- **Verdict.** BUDGET: HOLDS, or not.
- **Cost.** 0.

#### W3-38 Dev rollout, Part B [production-deployer] [S] [depends: W3-35a to W3-35c, W3-36 M-1(c) (precondition 2), W3-37, founder OK] Status: Open
- **Preconditions, in order:**
  1. The `privacy.uids` fieldOverride is deployed in dev and shows READY. The deploy-dev workflow runs `firebase deploy --only firestore:indexes` after the ack check.
  2. 100% of dev traffic **and** the `last-good` tag are on a revision with W3-26a to W3-32 (lesson 10). The deployer checks both before the allowlist apply and records both revision names in the rollout record. This is W3-36 M-1(c).
  3. The W3-36 findings that gate the dev allowlist are fixed. Only M-1(c), precondition 2 above, gates the allowlist of 3 (the runbook rule of M-1(a) is PR #404). The other findings gate later steps, not this ticket:
     - M-2 (W3-39) must be serving 100% of a project's traffic **and** be on its `last-good` before `private_accounts` leaves the dev allowlist (more uids, a percent, or on) in any project;
     - M-1(b) (W3-42, the rollback floor) and M-1(d) gate any prod ramp of `private_accounts`;
     - the Lows (W3-40a, W3-40b, W3-41a, W3-41b) gate nothing; they land in the next fix PRs (founder 2026-10-28).
  4. A targeted dev Terraform plan (`-target` the `api` service only, so the `pending.md` 3.10 drift is excluded) for `feature_private_accounts*` and the four new limits is shown to the founder. It is applied only on OK, with the allowlist of 3 test uids (founder question B4).
- **Smoke** (runbook `docs/runbooks/w3-part-b-rollout.md`):
  1. A protects.
  2. B, a non-follower, gets `author_protected`; A's post is NOT_FOUND; a QUOTE of it is stripped.
  3. B follows and gets REQUESTED. A sees the badge and the row, and accepts. B now sees A's posts.
  4. C requests, then withdraws.
  5. A unprotects with one request pending, and the job accepts it. A protects again.
  6. With the flag off, A is still protected, can respond and can unprotect.
  7. A non-allowlisted user's `is_private=true` is FEATURE_DISABLED.
- **Prod.** No change (on hold, `pending.md` 1.2).
- **Cost.** A handful of reads and writes in dev's free quota.

#### Part B: W3-36 fix tickets (from `docs/reviews/security-review-w3b.md`, founder decisions 2026-10-28)
The founder's decisions on the review: M-2 accepted (unguessable public names for new uploads); M-1 gets the runbook rule now (PR #404) and the `resolve-rollback.sh` floor before any prod ramp; the Lows are fixed in the next fix PRs. O-1 of the W3-35b test report (PR #405) rides with the Lows. Every ticket below follows "Part B: common to every ticket" (budget assertions through `apiserver.Build`, logs with hashes or counts only, `make ci` and `make test-int` green).

#### W3-39 Media: unguessable public object names for new uploads (W3-36 M-2) [backend-developer] [M] [depends: W3-36 review] Status: Open
- **Design.** ADR-0025 "Implementation note (W3-36 M-2, 2026-10-28)", with a pointer note on ADR-0005. New uploads publish as `m/<mediaId>-<suffix>.<ext>` and `m/<mediaId>-<suffix>_t.<ext>`. The suffix is 128 bits from `crypto/rand` as 32 lowercase hex characters, chosen at `CreateUpload` and stored as `nameSuffix` on the PENDING media doc in the existing create write. Old docs and objects keep the old shape (founder B1).
- **Seam.** `MediaRef.url` and `thumb_url` stay opaque full URLs built only by `media` (`publicBaseURL + "/" + PublicPath`); no proto change, and no caller or client builds a name.
- **Gate.** It must be serving 100% of a project's traffic and be on its `last-good` before `private_accounts` leaves the dev allowlist (more uids, a percent, or on) in that project. It does not gate W3-38.
- **Work.**
  - `media/service.go`: `CreateUpload` generates the suffix per item; `publicObject` and `publicThumbObject` take it ("" = the old shape). `media/repo_firestore.go`: `Doc.NameSuffix` (`firestore:"nameSuffix,omitempty"`).
  - `media/finalize.go`: publish, resolve and the converge path use the doc's suffix.
  - `media/retire.go`: `imageObjectPattern` becomes `^m/([0-9]{19})(?:-([0-9a-f]{32}))?(_t)?\.(jpg|webp)$`; `ImageObject.Suffix`; `parseRetiredImage` also requires the thumbnail's suffix to equal the full image's.
  - `media/purge.go`: `publicNames` returns the recorded paths plus the names derived for the doc's own shape. The eraser, the `post_delete` job (`jobs.go`) and the retire step all go through it, so each image still touches 2 public names. Update the `PurgeUser` comment.
  - `cmd/opsctl/clear_profile.go` uses only `ObjectNameFromURL` and needs no change; a test proves it with a suffixed URL.
- **Acceptance criteria.**
  1. A new upload of each purpose (POST, AVATAR, BANNER) is published under the suffixed names, `MediaRef.url` and `thumb_url` carry them, and two uploads never share a suffix (a 1,000-upload test).
  2. A `CreateUpload` replay returns the same suffix; two concurrent finalizes of one doc (the W3-22 M-3 claim test) publish one pair of names, and the loser's converge path drops nothing it should keep.
  3. A doc without `nameSuffix` (written by the old code path in the test) finalizes, erases, retires and deletes under the old names; its posts keep the old URLs.
  4. `ParseObjectName` table test: old full and thumb, new full and thumb, upper-case hex, 31 or 33 hex characters, `_` or `-` inside the suffix, a suffix on a different id, and both extensions. `parseRetiredImage` refuses a full and thumb pair whose suffixes differ.
  5. The retire job retires a replaced avatar and banner of both shapes (emulator integration, `customTime` on both objects, 2 Class A each).
  6. The account eraser and the `post_delete` job delete both shapes, including a suffixed doc whose finalize copied the objects and lost the record race (the orphaned-copy case of `publicNames`).
  7. Budget: `CreateUpload`, `FinalizeUpload`, the retire step, the eraser and `post_delete` keep their ceilings exactly (+0 reads, +0 writes, +0 deletes); `budgettest` through `apiserver.Build`.
  8. No log line carries a suffix or a full object name of a new upload (hash or id only).
- **Docs.** `docs/runbooks/media.md`: the two name shapes and the rollback residual (a revision older than W3-39 publishes new docs under the old names and does not retire suffixed avatars). Handoff to the founder: the `media/{mediaId}` row of the `firestore-data-model` skill gains `nameSuffix` (a `/.claude/` change, founder-gated, in a separate PR).
- **Flag.** None: names change for every new upload; there is no user-visible behaviour to ramp.
- **Cost.** +0 operations; bytes as in the budget row (ADR-0025 note).

#### W3-40a Backend: W3-36 L-1, L-3 and L-5 [backend-developer] [M] [depends: W3-36 review] Status: Open
- **L-1, the undo oracle** (`engagement/service.go`, `resolveForCounts` and the Unlike and Undo repost paths).
  - The write stays ungated (rule 4): an undo always lands.
  - The answer is the missing-post shape (`post_id` only, zero counts, the same bytes as a deleted post) when `Audience.VisibleAuthor` is false for the caller, when the post is hidden (taken down, author suspended), or when the author blocks the caller.
  - A REPOST id is no longer resolved to its original for a caller who may not see the original's author.
  - AC: a matrix test (unapproved, approved, blocked-by, taken down, missing, REPOST id) over UnlikePost and UndoRepost asserts byte identity with the deleted-post answer, and that the like or repost is still removed. Budget: +0 warm, +1 cold (the caller's graph snapshot), writes unchanged.
- **L-3, the stale copy** (`identity/protected_set.go`, `refresh` and `Current`).
  - On a `gen` mismatch after a successful read, install the fetched copy with the local deltas re-applied (preferred), or re-check age after the flight and fail closed past `PROTECTED_SET_MAX_STALE`.
  - AC: a unit test with a fake clock and repo: idle for more than 10 minutes, then a same-instance `Apply` during the refresh read. `Current` never returns a copy older than `PROTECTED_SET_MAX_STALE`, and the local unprotect is still reflected.
- **L-5, fail-open wiring** (`apiserver/apiserver.go`, `Build`).
  - `Build` fails startup when any of the seven protected-set seams is nil outside `ENV=local` tests: the loader, graph `Protected`, `identity.WithProtectedAuthors`, the notifications `Audience`, `posts.WithProtectedAuthors`, the engagement `rowAudience(posts.AudienceOf(postsSvc))`, and `timeline.WithProtectedAuthors` (`apiserver.go`:137, :150, :198, :247, :308, :333, :353 at 15975e53).
  - AC: a test that wraps `postsSvc` so that `AudienceOf` returns nil makes `Build` fail with a named seam. The W3-35a guard asserts all seven are wired. `make test-int` still starts every suite.
- **Flag.** None (server-side correctness). **Cost.** As the budget row.

#### W3-40b Backend: W3-36 L-4 and W3-35b O-1 [backend-developer] [S] [depends: W3-40a (both edit `identity/protected_set.go`); W3-35b merged (PR #405)] Status: Open
- **L-4, the wire-visibility hint** (`posts/audience.go` `ProtectedAuthor`, `timeline/service.go`, `posts/server.go`, `engagement/list_common.go`, `identity/protected_set.go`).
  - `ProtectedAuthor` answers without the loader for the caller's own and followed authors, from the snapshot the path already holds (D3's "only when needed").
  - A set outage is reported once per request (`protected_set_unavailable` at ERROR), then WARN, so Error Reporting does not count one error per row (up to 50 per page) and does not prompt an M-1-hazard rollback.
  - AC: a Home page of followed authors makes 0 `Current` calls; an outage page of 50 rows logs exactly one ERROR; the wire `visibility` of every row is unchanged against the W3-30 and W3-29b tests.
- **O-1, the stuck `privacy_public` delivery** (`graph/privacy_public.go`; W3-35b test report, Low).
  - A request whose requester is at the 5,000 following cap never leaves the job's query, so with more than 5,000 such requests every redelivery ends `ErrPrivacyPublicMore` (a nack) and Pub/Sub retries to the DLQ until the owner declines them.
  - Fix: when a whole delivery (every page up to `privacyPublicMaxPages`) accepted nothing, ack with one log line, `privacy_public` outcome `stuck` (counts only: pages, scanned, `skipped_cap`, `skipped_inactive`), instead of returning `ErrPrivacyPublicMore`. A delivery that accepted at least one request still nacks, so the next delivery continues.
  - AC: a test using the W3-35b page-size setter (`graph/export_w335b_test.go`) fills more than `privacyPublicMaxPages` pages with requesters at the cap and asserts outcome `stuck`, an ack, 0 writes and no `ErrPrivacyPublicMore`; a mixed fixture (some acceptable) still nacks after accepting. Update `docs/runbooks/private-accounts.md` section 6 (the `stuck` outcome: the owner declines, or the requesters unfollow someone).
- **Flag.** None. **Cost.** As the budget row; a stuck delivery stops costing redeliveries.

#### W3-41a Backend: the owner's placeholder rows (W3-36 L-2) [architect (proto) then backend-developer] [M] [depends: W3-40b (same files)] Status: Open
- **Design.** ADR-0025 "Implementation note (W3-36 L-2, 2026-10-28)": it changes the D4 list row for the owner only.
- **Contract first (architect).** `bool withheld = 7` on `posts.v1.PostView` (verify the next free number), and the `EMBED_VIEWER_STATE_PROTECTED` comment change. Additive, `buf lint` and `buf breaking` clean, `make proto` (one proto PR at a time).
- **Work (backend-developer).**
  - `GetUserTimeline` with target == caller: on every tab that returns the caller's REPOST rows, the caller's REPOST of a protected author they may not see is kept with the embed stripped (`ApplyEmbedState`), `embed_viewer_state = PROTECTED` and `reposted_by_viewer = true`.
  - `ListLikedPosts` and `ListBookmarks`: such a row is kept with `withheld = true` and the post stripped to `post_id`, `kind` and the author snapshot; the viewer flags stay true. Still not pruned.
  - Through `posts.Audience` with an owner-only surface value; no module decides visibility on its own.
- **Acceptance criteria.**
  1. A matrix (A unfollows P; P protects; P unprotects; P blocks A; P muted by A) over the owner's profile tabs, Likes and Bookmarks: the placeholder appears exactly in the unapproved, not-blocked, not-muted cells, and the full row returns when A is approved again.
  2. Byte check: a placeholder carries no text, media, alt text, labels, hashtags, mentions, counts, reply fields, timestamp or embed body.
  3. Another viewer of A's profile and every other surface (Home, GetPost, GetThread) keep the D4 outcome (REPOST dropped, NOT_FOUND), byte-identical to before.
  4. Unlike, Undo repost and RemoveBookmark from the placeholder ids remove the row on the next page.
  5. Budget: every list and tab keeps its ceiling (+0 reads, +0 writes).
- **Flag.** None (undo paths are never gated). **Cost.** +0.

#### W3-41b Client: the owner's placeholder rows (W3-36 L-2) [frontend-developer] [S] [depends: W3-41a and W3-40a serving dev] Status: Open
- Render the protected placeholder (the W3-33b embed placeholder, reused) on the caller's own profile tabs for a REPOST row with `embed_viewer_state = PROTECTED`, and on the Likes and Bookmarks lists for a row with `withheld = true`, with one action each: Undo repost, Unlike, Remove.
- After W3-40a, an undo of such a post answers the missing-post shape: treat it as success and remove the row.
- AC: widget tests for the three rows, light and dark, 360 dp x2.0, a 48 dp target for the action; the action removes the row optimistically and restores it on a real error; `docs/ui-catalog.md` updated if the placeholder widget gains a variant.
- **Flag.** None. **Cost.** 0 new RPCs; 1 undo RPC per tap.

#### W3-42 Promotion: the `PRIVATE_ACCOUNTS` rollback floor (W3-36 M-1(b)) [production-deployer] [S] [depends: none; founder review of the gate file] Status: Open
- **Gate.** Before any prod ramp of `private_accounts` (with M-1(d): the flag stays `off` in prod until the first Part B release is at 100% and its `last-good` is post-Part-B). Not a W3-38 precondition.
- **Where the floor lives.** In `scripts/promotion/flag-ceiling.json` (a founder-gated file), next to `PRIVATE_ACCOUNTS`, once for every environment: for example `"rollback_floors": {"PRIVATE_ACCOUNTS": {"commit": "061395a0a2ef3202482ffcd34273c032069865bf", "pr": 395, "reason": "W3-36 M-1"}}`. The floor is the image built from `main` at 061395a0 (#395, the last enforcement ticket) or later.
- **Enforcement.** `resolve-rollback.sh` refuses a `last-good` image older than the floor whenever `PRIVATE_ACCOUNTS`' effective mode in that environment is not `off`.
  - The revision JSON pins only `@sha256:`, so the commit comes from `images.json` (`gcloud artifacts docker images list`): the digest's tags include the `github.sha` image tag (`IMAGE_TAG` in `deploy-dev.yml`).
  - Preferred check: `git merge-base --is-ancestor <floor> <image commit>` (the job needs enough fetch depth). The alternative is a `createTime` comparison against the floor image. The deployer picks one and documents it.
  - Fail closed: a digest with no commit tag, or a commit not found, is refused while the flag is not `off`.
- **Raise the floor for M-2.** After W3-39 merges and its image is on `last-good`, a one-line follow-up raises the floor to W3-39's merge commit before `private_accounts` leaves the dev allowlist. Do not raise it earlier, or every rollback is refused while the flag is on.
- **Files.** `scripts/promotion/flag-ceiling.json`, `resolve-rollback.sh`, `scripts/promotion/test/*`, `scripts/promotion/README.md`, and `check-flag-registry.sh` if it validates the JSON's keys; `docs/runbooks/rollback.md` and `docs/runbooks/private-accounts.md` point to the guard.
- **Acceptance criteria.** Script tests (fixtures): flag `off` with a pre-floor image passes; flag `allowlist` with a pre-floor image fails with a named message; a post-floor image passes; a digest without a commit tag fails while the flag is not `off`; the existing `resolve-rollback.sh` cases still pass; `make ci` runs the promotion tests.
- **Flag.** None. **Cost.** 0.

#### Part B: order, parallelism and gate files
At most 5 agents run at once, each in its own worktree under `.claude/worktrees/`. A ticket starts when its dependencies have merged, and merges in the order the constraints below say.

| Batch | Runs concurrently | Starts when | Merge-order notes |
|---|---|---|---|
| B0 | W3-25a | now | founder review of the index file, the ack and `/.claude/` |
| B1 | W3-25b | W3-25a merged | founder review of `flag-ceiling.json` |
| B2 | W3-26a, W3-32, W3-29a, W3-31 (4) | W3-25b merged | W3-26a and W3-32 merge first, one at a time (both edit the T11 guard file); W3-29a merges after W3-26a; W3-31 merges after W3-29a |
| B3 | W3-27, W3-29b, W3-30 (+ W3-31 if still open) | W3-27: W3-32 merged; W3-29b and W3-30: W3-29a merged | W3-30 after W3-26a |
| B4 | W3-28a, W3-33a, W3-33b | W3-28a: W3-27 merged; W3-33a: W3-27 and W3-30 serving dev; W3-33b: W3-26a and W3-29a serving dev | |
| B5 | W3-28b, W3-26b, W3-28c, W3-33c | W3-28b, W3-26b: W3-28a merged; W3-28c: W3-25c and W3-28a merged; W3-33c: W3-28c serving dev and W3-33a merged | W3-28b and W3-26b both edit `apiserver.go` wiring: one at a time; W3-28c edits `graph/server.go` (no `apiserver.go` line): after W3-28a, one at a time with W3-28b |
| B6 | W3-34, W3-35a, W3-35b, W3-36, W3-37 (5); W3-33d rides along (after W3-33c, one at a time with W3-34 on `user_list_row.dart`); W3-39 and W3-40a (W3-36 fixes) as slots free up | W3-34: W3-26b and W3-31 serving dev; tests, review and cost: their backend tickets merged; W3-39 and W3-40a: the W3-36 review (PR #403) | W3-39 owns the media files alone; W3-40a merges before W3-40b (`identity/protected_set.go`) |
| B7 | W3-35c; W3-40b, W3-42 | W3-35c: W3-33a, W3-33b, W3-34 merged; W3-40b: W3-40a and W3-35b (PR #405) merged; W3-42: any time (founder review of `flag-ceiling.json`) | W3-40b merges before W3-41a (`posts/audience.go`, `timeline/service.go`, `engagement/list_common.go`) |
| B8 | W3-38; W3-41a | W3-38: W3-35a to W3-35c, W3-37, M-1(c) (its precondition 2), founder OK; it does **not** wait for W3-39 to W3-42; W3-41a: W3-40b merged | W3-41a's proto PR is one `make proto` PR at a time with any other wave |
| B9 | W3-41b; the W3-42 floor raise | W3-41b: W3-41a and W3-40a serving dev; floor raise: W3-39 on 100% of dev traffic and on `last-good` | widening `private_accounts` past the dev allowlist waits for W3-39 (and the raised floor); any prod ramp waits for W3-42 and M-1(d) |

"Serving dev" means merged to `main` and served by the deploy-dev revision. The client tickets start once their RPCs serve in dev, and are built and widget-tested against the generated code and fakes. Their end-to-end dev check waits for W3-38, because nobody can protect in dev until W3-38 puts the 3 test uids on the allowlist.

**Shared files (merge one PR at a time; merge `origin/main` just before the watcher):**

| File | Part B tickets | Rule |
|---|---|---|
| `proto/dzeroth/*/v1/*.proto` | W3-25a, W3-25c (`common.proto` `AuthorSnapshot.is_private = 6`) | ADR-0025's numbers; W5-2, W6-2 and W7-2 take the next free numbers |
| `firebase/firestore.indexes.json`, `firebase/field-overrides.ack` | W3-25a | founder-gated; one wave's index PR at a time (W4-9, W6-2, W7-3) |
| `config.go`, `ratelimit_config.go`, the flag lines of `apiserver.go`, Terraform `feature_*` and limit vars, `flag-ceiling.json` | W3-25b only | serialize with W4-3, W5-3, W6-4, W7-4 and W8-1 |
| `identity/api.go`, `graph/api.go` | W3-25b declares; W3-26b extends `BlockChecker` | later tickets implement, never redeclare |
| `backend/pkg/platform/quota/quota.go` | W3-25b (`PrivacyToggles`) | one at a time with W5-3, W5-22 and W7-4 |
| `identity/service.go` | W3-26a, then W3-26b | sequential |
| `graph/rpcs.go`, `graph/service.go`, `graph/server.go`, `graph/repo_*.go`, `graph/lists.go` | W3-27, then W3-28a, then W3-28b and W3-28c (`server.go` `toProtoAuthorSnapshot` only) | sequential |
| generated code (`backend/gen`, `app/lib/gen`) | W3-28c (`make proto` for W3-25c) | one `make proto` PR at a time with any other wave's proto PR |
| new `graph/purge_requests.go` and export file | W3-32 | new files, parallel with B2 |
| `posts/audience.go` (new), `service_delete.go`, `service_thread.go`, `server.go`, `convert.go` | W3-29a, then W3-29b | sequential |
| `engagement/list_common.go` | W3-29b | |
| `timeline/service.go` | W3-30 | |
| `apiserver/notifications_wiring.go` | W3-25b (no-ops), then W3-31 | sequential |
| `apiserver/apiserver.go` (wiring) | W3-25b (flag, config), W3-26a (constructs the loader: its only owner), W3-29a, W3-30, W3-31 (one `With…` line each), W3-26b (counter, `IsFollowing`), W3-28b (listener adapter, job registration) | one line per ticket, one PR at a time |
| `apiserver/lifecycle_collections_guard_test.go` | W3-26a (`privacy`), W3-32 (`followRequests`) | one at a time |
| `apiserver/lifecycle_wiring.go`, `lifecycle_wiring_test.go` | W3-32 | |
| `profile_header.dart`, `profile_screen.dart`, `follow_button.dart` | W3-33a | |
| `user_list_row.dart` (graph widgets) | W3-33c (after W3-33a; W3-34 renders it) | W3-33c and W3-34 one at a time |
| settings screens, the post-card embed widget | W3-33b | |
| `app_router.dart`, the drawer, the notifications list | W3-34 | serialize with W4, W7 and W8 router tickets |
| `media/service.go`, `finalize.go`, `retire.go`, `purge.go`, `jobs.go`, `repo_firestore.go` | W3-39 | alone in Part B; serialize with any later wave's media ticket |
| `engagement/service.go` (undo paths) | W3-40a (L-1) | |
| `identity/protected_set.go` | W3-40a (L-3), then W3-40b (L-4 once-per-request reporting) | sequential |
| `posts/audience.go`, `posts/server.go`, `timeline/service.go`, `engagement/list_common.go` | W3-40b (L-4), then W3-41a (owner surface) | sequential |
| `engagement` Likes and Bookmarks list files (`service_likes_list.go`, the bookmarks list) | W3-41a | after W3-40b |
| `apiserver/apiserver.go` (`Build`) | W3-40a (L-5 assertion) | one PR at a time with any other wiring change |
| `graph/privacy_public.go` | W3-40b (O-1) | after W3-35b (#405) |
| `proto/dzeroth/posts/v1/posts.proto` and generated code | W3-41a (`PostView.withheld`, comment change) | one `make proto` PR at a time |
| app profile tabs, Likes and Bookmarks lists, the protected placeholder widget | W3-41b | |
| `scripts/promotion/flag-ceiling.json`, `resolve-rollback.sh`, `scripts/promotion/test/*` | W3-42, then its floor raise | founder-gated; serialize with any other ceiling PR |
| `docs/pending.md` row 3.12 and this plan's table | every Part B PR | keep both sides' text |

**Gate files needing the founder's review (CODEOWNERS):**
- `firebase/firestore.indexes.json` and `firebase/field-overrides.ack` (W3-25a): one fieldOverride, `privacy.uids`, and no new composite index.
- `scripts/promotion/flag-ceiling.json` (W3-25b): `PRIVATE_ACCOUNTS`, dev allowlist 3, `max_percent` 0, no prod entry.
- `/.claude/` (W3-25a): the `firestore-data-model` skill rows of D16; later, the `media/{mediaId}` `nameSuffix` row (W3-39 follow-up).
- `scripts/promotion/flag-ceiling.json` (W3-42): the `PRIVATE_ACCOUNTS` rollback floor, and its raise to W3-39's merge commit.

No workflow change is planned. The W3-38 smoke is a runbook. Wiring a smoke script into `deploy-dev.yml` would add a gated `.github/workflows/` change. The dev Terraform apply (W3-38) is the founder's OK, not a file.

#### Part B: cost (the ADR-0025 table, restated on the cost-model base)
Method: `free-tier-budget` §2 and the cost-model marginal method (§5, §7 prices); no second model. Planning values are the ADR's.

| Ticket | Line | Calls / DAU | Reads per call (planning) | Reads / DAU | Writes / DAU | Deletes / DAU |
|---|---|---|---|---|---|---|
| W3-29a, W3-29b, W3-30, W3-31 | `Audience` on every read path | all | +0 | 0 | 0 | 0 |
| W3-26a | protected-set refresh (detached) | n/a | ≤ 1 per instance per minute | 3.2 / 2.4 / 1.4 at 300 / 1,000 / 3,000 DAU | 0 | 0 |
| W3-27 | Follow (in-transaction target read) | 0.5 | 4 (unchanged) | +0 | -0.1 | 0 |
| W3-27 | withdraw | 0.005 | 0 (+1 interceptor) | ~0 | 0.005 | 0.005 |
| W3-28a | ListFollowRequests, page 20 | 0.02 | 42 | 0.84 | 0 | 0 |
| W3-28a | RespondToFollowRequest | 0.04 | 3 | 0.12 | 0.16 | 0.04 |
| W3-26a | UpdateProfile toggle | 0.002 | 4 | 0.01 | 0.006 | 0 |
| W3-26b | GetMe count (5% protected) | 0.2 | 1 per 1,000 matches, cached 30 s | 0.10 | 0 | 0 |
| W3-28a, W3-30 | GetUserTimeline, ListFollowers, ListFollowing of P, unapproved | replaces page reads | 3 | ≤ 0 | 0 | 0 |
| W3-31 | `follow_request` / `follow_accepted` fan-out | 0.05 / 0.04 | about 2 per recipient | 0.18 | 0.09 | TTL after 90 d |
| W3-28b | `privacy_public` job | rare | 2 per request | ~0 | ~0 | ~0 |
| W3-33d | Layout fix only (no call) | none | +0 | 0 | 0 | 0 |
| W3-25c, W3-28c, W3-33c | `AuthorSnapshot.is_private` on graph user-list rows (from the hydrated profile) | all list calls | +0 | 0 | 0 | 0 |
| W3-32 | eraser, export | per deletion or export | 1 per doc | n/a | n/a | n/a |
| **Part B** | | **about +0.1 requests** | | **+1.25 request path + 3.2 / 2.4 / 1.4 refresh** | **+0.16** | **+0.05** |

Assumptions (ADR-0025): 5% of DAU protected; 0.05 follows per DAU to a protected target; 0.04 responses per DAU.

**Whole product with W2, Part A and Part B on for every DAU.** The cost-model base is 300.2 reads, 33.6 writes, 8.4 deletes and 40.0 requests per DAU, from W3-23.
- **Reads:** 304.7 / 303.9 / 302.9 per DAU at 300 / 1,000 / 3,000 DAU. That is 91.4k a day at 300 DAU, against 90.1k.
  - Free reads now end at about 163 DAU (was 167). The 80% line (the 40k/day alert) is crossed at about 130 DAU (was 133).
  - The ADR's "about 293 per DAU, free reads end at about 170" was computed on 288.9, before W3-23 restated Part A.
- **Writes:** 33.76 per DAU, so the free quota ends at about 592 DAU (was 596).
- **Deletes:** 8.45 per DAU, so the free quota ends at about 2,367 DAU (was 2,380).
- **Requests:** 40.1 per DAU.
- **Shares of the daily reads at 300 DAU:**
  - Part B: 4.45 of 304.7 = 1.5%.
  - Who to follow: 35.7 of 304.7 = **11.7%**, still above its own 10% trigger.
  - Tabs plus likes: 4.6%.

**Monthly bill, Part B alone** (the ADR's figures, re-derived with the `cost-model.md` §7 prices):

| DAU | Firestore reads | Writes | Deletes | Cloud Run requests | **Total INR/month** | Stage 0 with W2 + A + B |
|---|---|---|---|---|---|---|
| 300 | 1.35 | 0 (writes free until about 592 DAU) | 0 | 0 | **≈ 1.4** | ≈ 472 (was 471) |
| 1,000 | 3.7 | 0.5 | 0 | 0 | **≈ 4.2** | ≈ 1,715 (was 1,711) |
| 3,000 | 8.2 | 1.4 | 0.05 | 0.35 | **≈ 10** | ≈ 3,783 (was 3,773) |

- **Fixed cost:** INR 0.
  - No new GCP service, Pub/Sub topic (the existing `jobs` topic) or Scheduler job.
  - No composite index; one fieldOverride.
  - Idle adds 0, because the refresh runs only when a request needs the set.
  - Part B has no Vision, egress or min-instance line, so credit mode changes nothing.
- **Triggers that apply** (`free-tier-budget` §6 and the ADR-0025 stage ladder; any one sustained 7 days needs an ADR):
  - protected accounts above 10,000 (half the 20,000 cap), the set doc above 300 KB, or sustained `ABORTED` / `privacy_toggle_attempts > 3` on toggles: shard the set into 16 docs;
  - Follow `txn_attempts > 3` or `ABORTED` for one target, sustained: go back to the cached target read (a documented 60 s window), then sharded follower counters;
  - one protected account receiving more than 1 request/s, sustained: a requests counter on the target;
  - the §6 Firestore trigger (more than 1.5M reads a day, or a bill above $30 a month): at about 4,960 DAU (was 4,996) and about 2,100 DAU (unchanged to the nearest 10). This also moves the follow-requests edge table to SQL with the timeline's Stage 2 ADR.
- **Before any ramp past dev.** The who-to-follow trigger amendment (ADR-0024 Amendment 2, accepted on 2026-10-28 by the merge of #367) must be built and applied in a project, as its Handoff says, before any W3 flag, `private_accounts` included, ramps past the dev allowlist there. Without it, who to follow would be 11.7% of reads after Part B; the amendment models it at about 6% (17.2 reads per DAU).

#### Part B: rollout, kill switch, risks
- **Ramp.**
  1. Dev allowlist of 3 (W3-38; gated by W3-36 M-1(c) only).
  2. Widening past the allowlist in any project waits for W3-39 (W3-36 M-2) on 100% of that project's traffic and on `last-good`, and for the W3-42 floor raised to W3-39.
  3. Then the founder's MVP decision for prod: allowlist, then percent 5, 25, 100, then on. Each step is a Terraform change plus a tagged revision (ADR-0019), and `private_accounts` ramps with `graph`.
- **Prerequisites before prod leaves `off`:**
  - the `privacy.uids` fieldOverride is in the prod release;
  - the enforcement revision is at 100% and on `last-good` (lesson 10);
  - W3-36 findings are closed: W3-39 and W3-42 (the rollback floor) are merged, M-1(d) holds (the first Part B release is at 100% and its `last-good` is post-Part-B), and the Lows (W3-40a to W3-41b) are merged or explicitly deferred by the founder;
  - ADR-0024 Amendment 2 is accepted;
  - the prod apply hold (`pending.md` 1.2) is lifted.
- **Rollback trigger.** Any one of these:
  - error rate above 2% for 15 minutes on a Part B RPC;
  - `protected_set_unavailable` above 0.1% of requests for 15 minutes;
  - reads per DAU on the Part B lines above twice the model, about 9 at 300 DAU.
- **Kill switch.**
  - `FEATURE_PRIVATE_ACCOUNTS=off` stops new protects only. Protected accounts stay protected and can still respond and unprotect (D12).
  - Enforcement is never flag-gated, so a defect in it is fixed forward. If a revision rollback is unavoidable, it may only target a revision with W3-26a to W3-32.
  - Data stays, and there is no migration.
- **Risks.**
  - **A missed read path leaks protected posts.** Controls: W3-35a's matrix and audience guard; W4's ADR calls `Decide`.
  - **A rollback below the enforcement revision un-protects everyone** (lesson 10).
  - **The loader fails closed.** A loader defect turns reads of non-followed authors into UNAVAILABLE. Controls: the 10-minute stale window and the rollback trigger above.
  - **Popular-account contention.** The in-transaction target read makes concurrent Follows of a popular account conflict (D6). The fallback is the cached read.
  - **Stale copies on other devices.** Rows fetched while P was public stay on other users' devices until those feeds reload. Only P's own profile is replaced via `author_protected`. This is the ADR's 60 s premise ("they were public a minute earlier") applied to client caches.
  - **Delivered notifications stay.** Opening one gives NOT_FOUND.
  - **Withdrawn requests leave a stale notification row** (D10).
  - **Post images stay reachable by a URL already seen** (founder question B1).

#### Part B: out of scope (Stage 2/3 version and its trigger, `stage-ladder`)
- **The protected set.**
  - Stage 2/3: sharded into 16 docs first, then a Memorystore set, or `users.is_private` joined in the Stage 2 SQL timeline.
  - Trigger: protected accounts above 10,000, the set doc above 300 KB, or `ABORTED` on toggles.
- **Visibility enforcement.**
  - Stage 2/3: pushed into the query layer (a SQL `WHERE`, or applied at fan-out).
  - Trigger: moves with the timeline's Stage 2 ADR, never alone.
- **Follow requests.**
  - Stage 2/3: an edge table with a state column.
  - Trigger: the §6 Firestore trigger.
- **The requests counter.**
  - Stage 2/3: a counter on the target doc.
  - Trigger: a protected account above 1 request/s, sustained.
- **Private media for protected accounts.**
  - Stage 2/3: signed GET URLs or a private bucket (an ADR; it would change rule 7's public-read serving and the CDN headers).
  - Trigger: the founder's answer to B1, or a user report.
- **Not built in W3:**
  - "remove follower";
  - undo of Accept or Decline;
  - deleting a `follow_request` row on withdraw;
  - protected-account rules for W4 search, W5 lists and W7 messaging (each wave's ADR calls `Audience.Decide`; D4 rows).

#### Part B: questions for the founder
Each question has a default. Nothing blocks W3-25a.

**Answered 2026-10-28 (founder): every default stands.** B1: link-reachable images of a protected account are accepted, and the W3-33b confirm dialog says so. B2: ADR-0025 confirmed (followers kept, Likes owner-only, counts public). B3: no undo on Accept or Decline. B4: the same 3 test uids on the W3-38 dev allowlist.
1. **B1. Post images of a protected account.** Protecting hides every image URL from people who are not approved followers (lesson 9). It cannot revoke a link someone already copied while the account was public: the objects stay public-read at unlisted, random-looking addresses. Listing has been closed since M-2.
   - Default: accept this, and say it in the confirm dialog (W3-33b).
   - Alternative: ask the architect for a private-media ADR before the prod ramp. Images would then need signed links, which is more cost and work.
2. **B2. Followers, likes and counts during the switch.** ADR-0025 already decides this; listed for confirmation only, so no action is needed unless you disagree.
   - Existing followers are kept and see everything as before (D8).
   - Their reposts of your posts disappear from their own followers' feeds within 60 s, and their quotes show "protected" (D4).
   - The Likes list stays owner-only for everyone (ADR-0024 question 3), so nobody can list a protected account's likes. No "liked by" list exists.
   - Like, follower and post counts stay public, as on X (D4, ADR question 5).
3. **B3. Accept and Decline have no undo.** The old sketch of W3-34 said "undo snackbar", but the server has no undo and there is no "remove follower".
   - Default: no undo, as on X.
   - Alternative: a "remove follower" feature, which needs its own small ADR.
4. **B4. Dev testers.** Default: the same 3 test uids as Part A for the W3-38 allowlist. The smoke needs two of them following each other and one not following.

## Rollout, kill switch, risks
- **Ramp:** each flag goes dev allowlist (3), then the founder decides for prod at MVP launch (allowlist → percent 5 → 25 → 100 → on, each a Terraform change and a tagged revision, ADR-0019).
  - `profile_tabs` never leaves `off` in a project before its indexes are READY and the backfill has run.
  - `follow_suggestions` ramps with `graph`.
  - `likes_list` ramps with `engagement`.
- **Rollback trigger:** error rate on a new RPC above 2% for 15 min, or reads per DAU above twice the W3-23 model (the Part A RPCs above about 103 reads/DAU).
- **Kill switch:** the flag `off`. Data stays; no migration. Banners and meta already set keep rendering at no read cost; pins and websites stop rendering while `profile_extras` is globally off (the server omits `pinned_post_id` and `website`, Amendment 1 A1), which also stops the pin's `GetPost`. Owners can still clear any of the four (an exact `""`), and an operator clears one account's fields with `opsctl clear-profile-fields`.
- **Risks:**
  - Who to follow is the largest new read line (35.7 of 51.5 reads/DAU, 11.9% of all reads, above its own 10% trigger at the modelled usage; W3-23); the levers are in the cost section and should be chosen before the flag ramps past the dev allowlist; ADR-0024 Amendment 2 (proposed) chooses both and gates the ramp on them.
  - `in` + `orderBy` on `follows` may need an index change (W3-12 checks first).
  - The likes list stops at 1,000.
  - Tabs read Firestore on every open (no cache).
  - Banner bytes at 3,000 DAU are about INR 46/month of GCS egress.
  - A website link is a phishing surface (W3-22).
  - Part B touches every read path; a missed path leaks protected posts (the W3-35a matrix and audience guard; ADR-0025 is accepted before W4). The other Part B risks are in "Part B: rollout, kill switch, risks" under Tickets.
  - Another user's profile was not captured (W1.5), so the "Follows you" chip and the protected view use X-conformant defaults.

## Out of scope (with the Stage 2/3 version and its trigger, `stage-ladder`)
- **Suggestions:** a precomputed or ranked source (a batch job over a Firestore export, or a ranking ADR). Trigger: suggestion reads above 10% of daily reads, or the §6 trigger, sustained 7 days. W3-23 models it at 11.9% already. **ADR-0024 Amendment 2 (proposed) takes both levers and keeps the 10% line:** a 48 h client cache with guards for empty and used-up cards, and `SUGGESTIONS_EDGE_LIMIT` 20 (cap 42 to 32), bring it to 17.2 reads/DAU, 6.1% (the line fires at about 29.4); `follow_suggestions` stays on the dev allowlist until both are built and the edge limit is applied in the project (Amendment 2 Handoff, steps 3 to 5). Watch `source=fof` with `candidates` of 3 or fewer (L-5), `fs_reads` per RPC and Vision units per day (`cost-model.md` section 9).
- **Full likes history:** a `likes (uid, createdAt)` index, or a SQL table at Stage 2. Trigger: user demand, or most active users at the 1,000 cap.
- **Profile tabs:** a per-tab instance cache, then Memorystore. Trigger: tab reads above 15% of daily reads (tabs plus likes are 4.7% in the W3-23 model; the line needs about 3.6x the usage).
- **Banner delivery:** CDN at Stage 3. Trigger: GCS egress above the §6 line.
- **Part B (private accounts):** the sharded set, query-layer visibility, an SQL request table, a requests counter and private media, each with its trigger, are in "Part B: out of scope" under Tickets.
- **Not built in W3:**
  - "Follows you" on list rows and a mutual-followers count ("Followed by X and Y");
  - Highlights and Articles tabs (premium);
  - a media grid layout;
  - birthday;
  - a profile search icon (B-04, W4);
  - an avatar or banner full-screen viewer;
  - server-stored suggestion dismissals;
  - "Follow back" on notification rows;
  - verified badges.
