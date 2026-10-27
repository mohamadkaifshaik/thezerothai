# UI W3: profile and graph completion
Plan owner: planner · Date: 2026-10-26 · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **Two parts.** Part A is new backend surface in six modules (identity, media, posts, timeline, engagement, graph) under a new ADR-0024, plus client work per screen. Part B is private accounts and follow requests, which need their own ADR-0025 (they amend ADR-0008 D1); Part B can be dropped or moved without touching Part A. · Flags: new `FEATURE_PROFILE_EXTRAS`, `FEATURE_PROFILE_TABS`, `FEATURE_LIKES_LIST`, `FEATURE_FOLLOW_SUGGESTIONS` (Part A), `FEATURE_PRIVATE_ACCOUNTS` (Part B); existing `graph`, `media`, `posts`, `engagement`, `bookmarks`, `profile_snapshot`, `ui_shell`
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
1. **Founder: private accounts and follow requests in the MVP?** They reverse ADR-0008 D1, which you accepted. **Default: yes, as Part B of W3, behind `FEATURE_PRIVATE_ACCOUNTS`. ADR-0025 is written now, in parallel with ADR-0024. Part B is built only after you accept ADR-0025 by merging it.** ADR-0025 must land **before the W4 search ADR**; otherwise W4 must carry the protected-account filter itself, or hashtag and people search would leak protected posts. Alternative: drop Part B from W3 and keep the stubs; nothing in Part A depends on it.
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
9. **Founder: `hasMedia` backfill.** **Run a one-off `opsctl backfill-has-media` once per project.** It reads each post once and writes only posts that have media. In dev that is a few hundred reads; prod has no real users yet, so it runs before `profile_tabs` leaves `off` there.

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
| W3-6 | identity: banner, location, website, `pinned_post_id` on `Profile` / `UpdateProfile`; `PinChecker` consumer interface; export fields | backend-developer | M | Open |
| W3-7 | posts: `hasMedia` on every create path; `PinChecker` implementation; reader queries for media and reposts | backend-developer | M | Done (PR pending): `posts.HasMediaFor(kind, storedMedia)` is the one definition of `hasMedia` (true when the stored `media[]` is non-empty, never for a REPOST) and `toDoc` writes it as an explicit bool on every create path (CreatePost root, reply and quote, the ADR-0021 publish sweep, the REPOST doc), so +0 writes and never flag-gated; `posts.NewPinChecker(reader).CanPin(ctx, uid, postID) (bool, error)` (own, visible POST / QUOTE / REPLY, never a REPOST; every refusal is `(false, nil)`, an infrastructure failure is an error; 1 read cold, 0 warm); `posts.Reader.ByAuthorMedia(author, window, limit)` and `ByAuthorKind(author, kind, window, limit)` on the W3-2 indexes (reads = rows, 1 when empty); emulator tests for the stored field on all four paths and for both queries (order, tie, window, Limit, budget), unit tests for the checker. Not wired into any handler: W3-6 passes the checker to identity, W3-9 calls the queries |
| W3-8 | posts: `opsctl backfill-has-media` (resumable, throttled, dry run) | backend-developer | S | Open |
| W3-9 | timeline: `GetUserTimeline` tab MEDIA / REPOSTS (token bound to the tab) | backend-developer | M | Done (PR pending): `effectiveTab(tab, include_replies)` is the one resolver (UNSPECIFIED defers to `include_replies`, a set tab wins, an unknown number is `VALIDATION field=tab` with 0 reads); `userFeed(caller, target, tab)` binds the EFFECTIVE tab (`posts`, `replies`, `media`, `reposts`; the first two strings are frozen, so every pre-W3 token stays valid and a Posts token on Media is `VALIDATION field=page_token|since_token` with 0 reads). MEDIA and REPOSTS run one `Limit(page)` `ByAuthorMedia` / `ByAuthorKind(KindRepost)` query with no author-recent read or write; `since_token`, `page_token`, gap tokens and `removed_ids` work as for Posts; the REPOST and QUOTE drop rules reuse `filterEmbeds`. `profile_tabs` gate (`flags.Guard`, `FEATURE_DISABLED` `feature=profile_tabs`) runs first with 0 reads, Posts and Replies stay ungated; request log carries `tab`. Budget asserted with `budgettest` through the real chain (`internal/apiserver/profile_tabs_integration_test.go`): 24 reads at page 20 and 54 at page 50 cold, 20 warm, 0 writes; fakes, flag-mode, token-matrix and drop-rule unit tests in `internal/timeline/tabs_test.go`. Rollout precondition: `profile_tabs` stays off in a project until the two W3-2 indexes are READY and the W3-8 backfill has run (`docs/runbooks/posts.md` section 13); the emulator enforces neither |
| W3-10 | engagement: `ListLikedPosts` (owner-only, from `userLikes.recent`, live posts, drop rules) | backend-developer | M | Open |
| W3-11 | graph: `GetProfileRelationship` ("Follows you", single target, +1 cold read) | backend-developer | S | Open |
| W3-12 | graph: `ListSuggestedUsers` (friends of friends + curated fallback, hard cap, cache) | backend-developer | M | Open |
| W3-13 | Profile header polish: sticky tab bar with per-tab scroll (B-06), app-bar name fade (B-05), "Joined Month YYYY" | frontend-developer | M | Done (PR pending): `NestedScrollView` with a pinned `PinnedHeaderSliver` tab bar, one `TimelineCubit` per opened tab (offset kept by a `PageStorageKey`), pull-to-refresh per tab, scroll-linked app-bar name fade (steps under reduced motion), "Joined Month YYYY" from `created_at` (B-05, B-06 closed). |
| W3-14 | Profile header data: banner image, location and website in the meta row, "Follows you" chip, "Follow back" | frontend-developer | M | Done (PR pending): the 3:1 band shows the banner (thumb below 600 dp, full from 600 dp, flat placeholder, no layout jump), the meta row adds location (pin) and website (link, host only, punycode, opens externally) before "Joined", `ProfileCubit` loads the relationship through `GraphRepository.profileRelationshipFor` (one `GetProfileRelationship` call replacing `GetRelationships`; UNIMPLEMENTED and FEATURE_DISABLED degrade to "no `followed_by`" with a 10-minute per-RPC backoff), the "Follows you" chip sits beside the handle and Follow reads "Follow back". The dev check waits for W3-6 and W3-11. |
| W3-15 | Edit profile: banner editor (3:1 crop, on-device resize, upload) and location / website fields | frontend-developer | M | Open |
| W3-16 | Profile tabs: Reposts and Media (Posts · Replies · Reposts · Media) | frontend-developer | M | Open |
| W3-17 | Pinned post: "Pinned" row on the Posts tab, Pin / Unpin in own post's menu | frontend-developer | M | Open |
| W3-18 | History: Likes tab on `/bookmarks` | frontend-developer | M | Open |
| W3-19 | Who to follow: Home card and the desktop right-column "You might like" | frontend-developer | M | Open |
| W3-20 | Part A backend tests: flag matrix, authz, budgets, token binding, drop rules, backfill | tester | M | Open |
| W3-21 | Part A client tests: responsive matrix, flag-off routing, text scale | tester | S | Open |
| W3-22 | Security review, Part A | security-auditor | M | Open |
| W3-23 | Cost report, Part A: `cost-model.md` rows, load smoke of tabs, likes, suggestions | sre-performance | S | Open |
| W3-24 | Dev rollout, Part A: indexes built, backfill, Terraform plan, allowlist, smoke | production-deployer | S | Open |
| W3-25 | Part B: register `FEATURE_PRIVATE_ACCOUNTS`, config, ceiling, Terraform vars, guards | backend-developer | S | Open (blocked on ADR-0025) |
| W3-26 | Part B identity: `is_private` toggle (quota), accept-all on switch to public per ADR-0025 | backend-developer | S | Open (blocked) |
| W3-27 | Part B graph: Follow to a private account creates a request; withdraw; caps; ADR-0009 invariant kept | backend-developer | M | Open (blocked) |
| W3-28 | Part B graph: `ListFollowRequests`, `RespondToFollowRequest`, `follow_request` event | backend-developer | M | Open (blocked) |
| W3-29 | Part B posts + engagement: protected-author visibility (GetPost, GetThread, `Viewable`, embeds, ListBookmarks, ListLikedPosts) | backend-developer | M | Open (blocked) |
| W3-30 | Part B timeline: protected profile state on `GetUserTimeline` | backend-developer | S | Open (blocked) |
| W3-31 | Part B notifications: `follow_request` and `follow_accepted` types | backend-developer | S | Open (blocked) |
| W3-32 | Part B lifecycle: `followRequests` and `graph.requested` in the eraser and export; T11 guard row | backend-developer | M | Open (blocked) |
| W3-33 | Part B client: protected profile view, lock badge, Requested / withdraw, privacy toggle in Settings | frontend-developer | M | Open (blocked) |
| W3-34 | Part B client: Follow requests screen | frontend-developer | M | Open (blocked) |
| W3-35 | Part B tests: visibility matrix on every read path, request lifecycle, races, invariants | tester | M | Open (blocked) |
| W3-36 | Part B security review | security-auditor | S | Open (blocked) |
| W3-37 | Part B cost report | sre-performance | S | Open (blocked) |
| W3-38 | Part B dev rollout | production-deployer | S | Open (blocked) |

## Milestones
| # | Milestone | Tickets | Exit |
|---|---|---|---|
| M1 | Decisions and contract | W3-1, W3-2, W3-3, W3-4 | ADR-0024 merged (accepted), protos and indexes merged, flags registered, generated code committed; ADR-0025 Proposed |
| M2 | Part A build: backend ‖ client | W3-5 to W3-12 ‖ W3-13 to W3-19 | every Part A RPC implemented behind its flag; every screen built and widget-tested |
| M3 | Part A verification | W3-20 to W3-23 | tests green with budget assertions; security 0 Critical/High; cost report holds |
| M4 | Part A dev rollout | W3-24 | indexes READY, backfill run, dev allowlist on, smoke passed |
| M5 | Part B (only after ADR-0025 is merged) | W3-25 to W3-38 | the same exits as M2 to M4 for `private_accounts` |

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
- **Part B** (W3-25 to W3-38) starts only when ADR-0025 is merged.
  - W3-25 first, then W3-26 ‖ W3-27 ‖ W3-29 ‖ W3-30 ‖ W3-31 ‖ W3-32, then W3-28 after W3-27, then the client tickets, then W3-35 to W3-38.
- **`apiserver.go` has one owner per change.** W3-4 does all W3 config and flag plumbing there, including passing the suggestion config into the graph module. W3-6 wires `identity.WithBannerResolver` and `identity.WithPinChecker` to the media and posts implementations, so W3-6 merges after W3-5 and W3-7 (it builds and tests against fakes until then). No other W3 ticket edits `apiserver.go`. W3-9, W3-10, W3-11 and W3-12 add methods to servers that are already registered.
- **`app_router.dart`:** W3-18 (`/bookmarks?tab=likes`) merges after W2-9, which rewrites the redirect logic in the same file.

**Running alongside W4 (search and Explore).** W4 has no detailed plan yet, so the overlap is named by file, not by ticket:

| Shared file | W3 ticket | Rule |
|---|---|---|
| `firebase/firestore.indexes.json`, `firebase/field-overrides.ack` | W3-2 | founder-gated; merge one wave's index PR at a time, the other merges `origin/main` and re-hashes the ack |
| `scripts/promotion/flag-ceiling.json`, `backend/internal/config/config.go`, the flag registry in `apiserver.go`, `ratelimit_config.go`, Terraform `feature_*` vars | W3-4, W3-25 | serialize the merges with W4's flag ticket |
| `app/lib/shared/widgets/app_side_column.dart` | W3-19 | W4 puts "What's happening" in the same column; whoever merges second rebases |
| `app/lib/features/profile/presentation/widgets/profile_header.dart` | W3-13, W3-14 | W4's profile search icon (B-04) waits for W3-14 |

- **Safe to run concurrently with W4:** every other W3 ticket. That covers the identity, media, posts, timeline, engagement and graph tickets W3-5 to W3-12, and the client tickets W3-15 to W3-18. W4 adds a new `search` module and proto, and an Explore screen.
- **Ownership split:** W3 owns "who to follow" (`GraphService.ListSuggestedUsers`). W4's "suggestions" means search typeahead. W4's Explore may reuse W3-19's card.
- **Private accounts:** if Part B is kept, ADR-0025 precedes W4's ADR (question 1).

## Non-functional targets (Stage 0, ≤ 300 DAU; the credit window allows up to ~3k DAU and changes no target)
| Path | p95 warm | Cold incl. start |
|---|---|---|
| `GetUserTimeline` Reposts / Media tab (page 20) | < 400 ms | < 1.5 s |
| `ListLikedPosts` (page 20) | < 400 ms | < 1.5 s |
| `ListSuggestedUsers` | < 400 ms | < 1.5 s |
| `GetProfileRelationship` | < 150 ms | < 1.5 s |
| `UpdateProfile` with pin, banner or meta | < 500 ms | < 1.5 s |

Staleness bounds for every cached read:
- **Banner, location, website and pin:** the `users/{uid}` instance cache (60 s). A new banner gets a new object URL, so the immutable CDN headers never serve the old one.
- **"Follows you":** the `follows` doc cached 60 s per (caller, target). A Follow or Unfollow by the target shows on other instances within 60 s.
- **Suggestions:**
  - server cache per viewer up to `SUGGESTIONS_CACHE_TTL` (1 h);
  - client cache per uid for 24 h;
  - an account the viewer follows from the card is hidden at once, on the client and in this instance's cache.
- **Likes list:** `userLikes` cache 60 s; posts from the 60 s post cache.
- **Tabs:** no new cache. Every open reads Firestore; the Posts tab keeps its author-recent cache.

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

| RPC (Part A) | Reads cold / warm (planning) | Writes | Deletes | Calls/DAU | Reads/DAU |
|---|---|---|---|---|---|
| `GetUserTimeline` Media tab, page 20 | 24 / 20 (20); page 50: 54 | 0 | 0 | 0.3 | 6.0 |
| `GetUserTimeline` Reposts tab, page 20 | 24 / 20 (20); page 50: 54 | 0 | 0 | 0.15 | 3.0 |
| `GetPost` of a profile's pinned post (existing RPC) | 4 / 0 (1) | 0 | 0 | 0.6 | 0.6 |
| `UpdateProfile` with banner, pin or meta | 3 / 1 (+1 media via the resolver, +1 post via `PinChecker`) | 1 | 0 | 0.03 | 0.06 |
| `CreateUpload` + `FinalizeUpload`, BANNER | 2 / 1 + 5 / 1.7 | 3.3 + 2.7 | 1 (TTL) | 0.005 | 0.01 |
| `ListLikedPosts`, page 20 | 24 / 3 (22); page 50: 54 | 0 | 0 | 0.2 | 4.4 |
| `GetProfileRelationship` (replaces the header's `GetRelationships`) | 2 / 0 (1; +0.5 net) | 0 | 0 | 2 | 1.0 |
| `ListSuggestedUsers` (option a) | 42 / 1 (25) | 0 | 0 | 1.0 | 25.0 |
| **Part A total** | | | | **≈ 2.3 new requests** | **≈ 40.1** (+17% over 232.3) |

- **Per DAU per day:** 40.1 reads, 0.06 writes, 0.005 deletes, 0.30 Vision units per DAU-month (0.005 banners per DAU per day x 2 units x 30.42). GCS egress is 1.34 MB per DAU-month: 1 uncached banner a day, 70% at the 20 KB thumb and 30% at the 100 KB full image. Cloud Run egress is 0.42 MB per DAU-month (2.3 x 6 KB) and Cloud Run CPU 7.0 vCPU-s per DAU-month.
- **Monthly bill, Part A:**

| DAU | Firestore | Vision | GCS (egress + Class B) | Cloud Run (egress + CPU + requests) | **Total INR/month** | vs Stage 0 baseline |
|---|---|---|---|---|---|---|
| 300 | 12.2 | 13.0 | 0 + 0.3 | 1.4 + 0 + 0 | **≈ 27** | 434 → 461 (+6%) |
| 1,000 | 40.6 + 0.2 writes | 0 (cap) | 0 + 1.2 | 4.8 + 0 + 0 | **≈ 47** | 1,626 → 1,673 (+3%) |
| 3,000 | 121.7 + 0.5 writes | 0 (cap) | 45.8 + 3.5 | 14.4 + 47.9 + 8.0 | **≈ 242** | 3,396 → 3,638 (+7%) |

- **Largest line:** who-to-follow (25 of 40.1 reads). Its levers, cheapest first:
  - a 48 h client cache;
  - an edge limit of 20;
  - curated-only for accounts following fewer than 3;
  - option (b) (question 2).
- **Storage:** a banner pair is about 120 KB per user who sets one (US bucket, inside the shared 5 GB). The two composite indexes add about 2 index entries per post (cents).
- **Not added:** no new GCP service, Scheduler job, Pub/Sub topic or fixed cost (INR 0 fixed).
- **Client-only tickets** (W3-13 and the render parts of the others): 0 new reads or writes.
- **Part B placeholder:** at most +3 reads, +0.2 writes per DAU, until ADR-0025's table replaces it (requests and responses are rare; the visibility checks are planned to use docs already read). It is not in the totals above.

## Flags and ceilings
| Flag (wire name) | Gates | Dev ceiling (`flag-ceiling.json`) | Prod |
|---|---|---|---|
| `FEATURE_PROFILE_EXTRAS` (`profile_extras`) | `UpdateProfile` banner, location, website and pin fields (FEATURE_DISABLED `feature=profile_extras` when any is set while off); `CreateUpload(BANNER)` needs it **and** `media` | `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}` | no raise (prod apply on hold, `pending.md` 1.2) |
| `FEATURE_PROFILE_TABS` (`profile_tabs`) | `GetUserTimeline` tab MEDIA / REPOSTS; Posts and Replies stay ungated | same | none |
| `FEATURE_LIKES_LIST` (`likes_list`) | `ListLikedPosts` (and needs `posts`) | same | none |
| `FEATURE_FOLLOW_SUGGESTIONS` (`follow_suggestions`) | `ListSuggestedUsers` (and needs `graph`) | same | none |
| `graph` (existing) | `GetProfileRelationship`, like every GraphService RPC | unchanged (on) | unchanged |
| `profile_snapshot` (existing) | still gates the Edit profile and Change handle screens (and the snapshot job); W3-15's new fields appear only on that screen, so they need `profile_snapshot` **and** `profile_extras` | unchanged | unchanged |
| `FEATURE_PRIVATE_ACCOUNTS` (`private_accounts`, Part B) | `is_private=true`, request creation, the requests RPCs | allowlist 3 (W3-25) | none |

- **Why not reuse `profile_snapshot` or `media` alone:** `profile_snapshot` gates the author-snapshot job, and `media` gates every post image. Links, banners and pins need a kill switch of their own (phishing, Vision spend) that does not stop renames or post images.
- **Render rules:** rendering stays ungated where the data already exists. A banner, meta or pin set while the flag was on keeps showing after a ramp-down. The only read cost of rendering is the client's `GetPost` of a pinned post. With `profile_extras` globally `off` (`Registry.GloballyOff`, 0 reads) identity omits `pinned_post_id` from every `Profile` (W3-6), so clients stop that call: the kill switch for that cost.
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
| `SUGGESTIONS_EDGE_LIMIT` | 30 | |
| `SUGGESTIONS_HYDRATE_MAX` | 10 | |
| `SUGGESTIONS_MAX_RESULTS` | 5 | |
| `SUGGESTIONS_CACHE_TTL` | 1h | |
| `SUGGESTED_USER_IDS` | ≤ 20 uids | Terraform var, not a secret |
| `RATE_LIMIT_LIKES_LIST_PER_MIN` | 10 | |
| `RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN` | 60 | |

  The tabs share the existing `GetUserTimeline` bucket. Every new RPC is charged to the per-uid daily read budget (ADR-0010 D5). The effective limit is per instance x 3 instances (`stage-ladder`).

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

Any of these fields while `profile_extras` is off for the caller returns FEATURE_DISABLED with 0 writes; the name and bio path is unchanged. None of them bumps `snapshotVersion` or spends `snapshotEdits`. `Profile` returns the fields everywhere it is built, except that `pinned_post_id` is omitted while `profile_extras` is globally off (the pin kill switch). The export's profile section adds them (golden file updated); deletion needs no new step (`users/{uid}` goes last, as today). Wiring: W3-6 owns the `identity.WithBannerResolver` / `identity.WithPinChecker` lines in `apiserver.go` and merges after W3-5 and W3-7 (fakes until then). Tests: unit with fakes, emulator `budgettest` at 3 reads / 1 write worst. Observability: `profile_fields_changed` (names only, never values) in the request log. Flag: `profile_extras` for the new fields. Seam: `PinChecker`, `BannerResolver`. Cost: 3 / 1 reads, 1 write.

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

**W3-10 `ListLikedPosts`** [depends: W3-4] [backend-developer, M]. Given `likes_list` on and 25 liked posts, a first call returns the 20 most recently liked live posts and a `next_page_token`; the second returns 5 and `""`. The source is `userLikes/{caller}.recent[]` read from the end (cached 60 s), then one cache-first `posts.Reader.GetMany` of the page's ids. The ADR-0023 D2 drop rules apply (missing, hidden, blocked, blocks, muted, QUOTE embedded author); no pruning (the like path owns the array). The cursor is resume-by-position bound to `likes|<uid>`, 24 h TTL. A like removed between pages neither skips nor repeats a row: the resume point is the first id older than the recorded position. A tampered token is VALIDATION with 0 reads. `NO_SIDE_EFFECTS`; the request has no user id. Tests: `budgettest` 24 / 54 cold, unlike-between-pages, an empty array (2 reads), foreign token. Observability: one log line with `rows_dropped` by cause and `fs_reads`. Flag: `likes_list` (and `posts`). Seam: `engagement.LikesList`; Stage 2/3 `likes (uid, createdAt)` index or a SQL table (Out of scope). Cost: 24 cold / 3 warm per page of 20.

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

Tests: widget tests per state at three widths. Flag: the screen is still reached only with `profile_snapshot`; the new fields also need `profile_extras`, and the banner editor also needs `media`. Seam: one media-upload helper shared by the avatar and banner editors (purpose as a parameter), so a later purpose adds no second upload path. Cost: one upload (2 + 5 reads, 6 writes) and one UpdateProfile per change.

**W3-16 Reposts and Media tabs** [depends: W3-4, W3-13] [frontend-developer, M]. With `profile_tabs` on: Posts · Replies · Reposts · Media, equal width, each a `TimelineCubit` keyed by `FeedKey.user(uid, tab)` with its own cache, and the token sent back unchanged. Media rows render the normal post card (a grid is out of scope). The empty states use our own copy. With the flag off: Posts · Replies as today. Flag: `profile_tabs`. Seam: `FeedKey.user(uid, tab)` and `TimelineRepository` carry the tab, so a later per-tab server cache or a media grid changes no widget. Cost: 1 call per tab open plus pages (24 cold reads per page of 20).

**W3-17 Pinned post** [depends: W3-16 (same file), W3-4] [frontend-developer, M]. When `Profile.pinned_post_id` is set (the server omits it while `profile_extras` is globally off), the Posts tab shows a "Pinned" label row (pin icon, muted) above that post, loaded with `GetPost`. It hides silently on NOT_FOUND and is not repeated in the feed below. Your own post's overflow menu offers "Pin to your profile" or "Unpin from profile" (only for POST, QUOTE or REPLY) through `UpdateProfile`, with a confirm when replacing a pin. Flag: the menu rows need `profile_extras`; the Pinned row renders whenever the server returns a pin. Seam: one `PinnedPostCubit` per profile owns the fetch and the hide-on-NOT_FOUND rule, so a server-embedded pin later changes no widget. Cost: 1 `GetPost` per profile open with a pin (4 cold / 0 warm).

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

**W3-23 Cost report, Part A** [depends: W3-9 to W3-12] [sre-performance, S]. Adds the Part A rows (+40.1 reads, +0.06 writes per DAU, +0.30 Vision units per DAU-month, banner egress) to `docs/reviews/cost-model.md` §2-§5. Runs emulator load smokes (`make loadtest`) of the Media tab, ListLikedPosts and ListSuggestedUsers, and re-states the planning values from measured `fs_reads`. It names the triggers:
- suggestions above 10% of daily reads;
- tabs plus likes above 15%;
- or the §6 Firestore trigger, sustained 7 days.

Cost: 0.

**W3-24 Dev rollout, Part A** [depends: W3-20, W3-22, W3-23, ADR-0024 merged] [production-deployer, S]. Preconditions, in order:
1. The W3-2 composite indexes and fieldOverrides are deployed to the target project and show READY (the dev deploy workflow runs `firebase deploy --only firestore:indexes` after the ack check; for prod, the next `v*` release, on hold with `pending.md` 1.2).
2. `opsctl backfill-has-media` has run there.
3. Show the founder a targeted dev Terraform plan for the four flags and the suggestion config, as for `pending.md` 3.10.

Apply only on OK, with allowlists of 3 test uids. Then a dev smoke: set a banner, location, website and pin; open each tab; list likes; see "Follows you"; get suggestions; turn each flag off. Prod: no change. Cost: the smoke is a handful of reads and writes inside dev's free quota.

**Part B (after ADR-0025 is merged; each ticket's acceptance text is finalised from the ADR before it starts)**
Every Part B ticket: Flag `FEATURE_PRIVATE_ACCOUNTS` (the eraser and export are never flag-gated); Seam: the one `posts`-side visibility policy function from W3-3; Budget: the ADR-0025 per-RPC table, asserted with `budgettest`. W3-26 to W3-32 are owned by backend-developer.
- **W3-25 Flag** [backend-developer, S]: `FEATURE_PRIVATE_ACCOUNTS` as W3-4 (config, registry, dev ceiling allowlist 3 in `flag-ceiling.json` (founder-gated), Terraform vars default off). Cost: 0.
- **W3-26 Identity toggle** [S]: `is_private` accepted while the flag is on; a toggle quota from the ADR; switch to public per the ADR (proposed: pending requests accepted through graph's interface). Seam: `identity.PrivacyListener` (consumer-side). Cost: per ADR-0025.
- **W3-27 Follow to a private account** [M]: creates `followRequests/{a}_{b}` and `graph.requested[]` in one transaction (caps, quota `follows`, replay), and Unfollow of a REQUESTED target withdraws. ADR-0009's invariant is extended, never broken. Cost: per ADR-0025.
- **W3-28 Requests RPCs** [M, after W3-27]: `ListFollowRequests` (index `followRequests (followeeId, createdAt DESC)` already exists, hydration cache-first), and `RespondToFollowRequest` accept/decline (the planned 1 read, 4 writes, 1 delete in `graph.proto`), emitting through `graph.FollowEvents`. Cost: per ADR-0025.
- **W3-29 Visibility in posts and engagement** [M]: one `posts` policy function used by GetPost, GetThread rows, `Engagement.Viewable`, embeds, ListBookmarks and ListLikedPosts; protected posts are NOT_FOUND to non-followers, byte-identical. Cost: target +0 reads (ADR).
- **W3-30 Timeline** [S]: `GetUserTimeline` of a protected account for a non-follower returns the protected state (the ADR's shape), 0 posts read. Cost: ≤ the current NOT_FOUND path.
- **W3-31 Notifications** [S]: `follow_request` and `follow_accepted` types with deterministic ids; push copy. Cost: 1 write per recipient.
- **W3-32 Lifecycle** [M]: `followRequests` (both directions) and `graph.requested` erased in the graph step; export section; T11 guard row; `lifecycle_wiring_test.go` lists updated. Cost: 1 read and 1 delete per request doc.
- **W3-33 Client privacy** [frontend-developer, M]: the protected profile view ("These posts are protected"), lock badge, `FollowButton` Requested and withdraw, and a "Protect your posts" toggle in Settings with a confirm.
- **W3-34 Client requests screen** [frontend-developer, M]: `/follow-requests` (`PagedUserList`, Accept / Decline per row, undo snackbar), entry from Notifications and the drawer while requests exist.
- **W3-35 Tests** [tester, M]: the ADR-0025 visibility matrix on every read path (incl. a W4 search placeholder test once search exists), request races (follow vs block, accept vs withdraw), invariants, eraser and export.
- **W3-36 Security review** [security-auditor, S]: protected-content leaks (embeds, notifications, likes and bookmarks lists, counters), request spam, the export.
- **W3-37 Cost report** [sre-performance, S]: the ADR-0025 rows in `cost-model.md` and an emulator load smoke of the request RPCs.
- **W3-38 Dev rollout** [production-deployer, S, after W3-35 to W3-37]: a targeted dev Terraform plan for `feature_private_accounts*` shown to the founder, allowlist 3 on OK, smoke (protect, request, accept, withdraw, unprotect, flag off). Prod: no change.

Definition of done per ticket:
- backend: Go unit + emulator integration (`make test-int`, `budgettest.Assert` on every RPC);
- client: widget tests in light and dark at 360/600/1200 via `test/support/theme_harness.dart` for every new screen or widget; pixel goldens deferred (B-01);
- `make ci` green;
- `docs/ui-catalog.md` / `docs/code-map.md`, this table and the matching `docs/pending.md` row updated in the PR.

## Rollout, kill switch, risks
- **Ramp:** each flag goes dev allowlist (3), then the founder decides for prod at MVP launch (allowlist → percent 5 → 25 → 100 → on, each a Terraform change and a tagged revision, ADR-0019).
  - `profile_tabs` never leaves `off` in a project before its indexes are READY and the backfill has run.
  - `follow_suggestions` ramps with `graph`.
  - `likes_list` ramps with `engagement`.
- **Rollback trigger:** error rate on a new RPC above 2% for 15 min, or reads per DAU above twice the W3-23 model.
- **Kill switch:** the flag `off`. Data stays; no migration. Banners and meta already set keep rendering at no read cost; pins stop rendering while `profile_extras` is globally off (the server omits `pinned_post_id`), which also stops their `GetPost`.
- **Risks:**
  - Who to follow is the largest new read line (25 of 40 reads/DAU); the levers are in the cost section.
  - `in` + `orderBy` on `follows` may need an index change (W3-12 checks first).
  - The likes list stops at 1,000.
  - Tabs read Firestore on every open (no cache).
  - Banner bytes at 3,000 DAU are about INR 46/month of GCS egress.
  - A website link is a phishing surface (W3-22).
  - Part B touches every read path; a missed path leaks protected posts (W3-35 matrix, ADR-0025 before W4).
  - Another user's profile was not captured (W1.5), so the "Follows you" chip and the protected view use X-conformant defaults.

## Out of scope (with the Stage 2/3 version and its trigger, `stage-ladder`)
- **Suggestions:** a precomputed or ranked source (a batch job over a Firestore export, or a ranking ADR). Trigger: suggestion reads above 10% of daily reads, or the §6 trigger, sustained 7 days.
- **Full likes history:** a `likes (uid, createdAt)` index, or a SQL table at Stage 2. Trigger: user demand, or most active users at the 1,000 cap.
- **Profile tabs:** a per-tab instance cache, then Memorystore. Trigger: tab reads above 15% of daily reads.
- **Banner delivery:** CDN at Stage 3. Trigger: GCS egress above the §6 line.
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
