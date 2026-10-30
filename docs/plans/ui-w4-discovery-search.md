# UI W4: discovery (search, suggestions, Explore, trends, hashtag tap-through)
Plan owner: planner · Date: 2026-10-26 · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **New backend surface: a `search` module with three read-only RPCs in a new `dzeroth.search.v1.SearchService`, one new collection (`trends`), two new reader methods on existing module seams (identity, posts); no new GCP service, no fixed cost** · Flags: new `FEATURE_SEARCH` and `FEATURE_TRENDS` (founder question F3); existing `posts`, `engagement`, `ui_shell`, and W3's suggestion flag for the who-to-follow card
Source: `docs/plans/roadmap.md` (W4 row, sections 3, 5, 7), `docs/plans/ui-w2-engagement-composer-basics.md` (hashtag decision, question 1), `docs/x_research/screens/explore.md`, `screens/mobile/screens.md` §2, `08_navigation_flows.md`, `14_mvp_structured_plan.md` (W4 row, cost row 67, decisions 1 and 4; all local and git-ignored), ADR-0003, ADR-0004, ADR-0008, ADR-0010 (D5 read budget, D6 filtering, D8 hashtag grammar, D14 tokens), ADR-0011 (daily-maintenance), ADR-0021 D1 (cron routes, Scheduler count), ADR-0022 (credit window). Supersedes `docs/plans/phase1.md` decision (1) (search deferred) and the hashtag half of decision (3) (founder 2026-10-22, roadmap section 1).
Branches: `feat/ui-w4-N-<slug>` off `main` (not stacked); one ticket per PR; merge `origin/main` into the branch.

## Questions for the founder (proposed default in bold; nothing blocks the ADR or proto tickets)
- **F1. Where does the trends sweep run?** Cloud Scheduler gives 3 free jobs per billing account. The account defines 2 today, both prod: `daily-maintenance` is live, and `publish-scheduled` is defined but not applied (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.18; the prod apply is on hold, dated step 1.2). `envs/prod/main.tf` keeps the third slot free as headroom. The read cost is the same in every option, about 1 read per new post, because the sweep reads only posts newer than its watermark. Options:
  - **(A) Spend the third free job.** It runs hourly as `trends-refresh`. Cost: INR 0, and it is clean module ownership. Afterwards the account is at 3 of 3, so any later job costs about USD 0.10/month and needs an ADR.
  - **(B) Piggyback on `daily-maintenance`.** The handler runs the trends step after the deletion backstop, inside the same 30 s request, and it never changes the status code (a 500 would make Scheduler retry the backstop). Freshness is daily ("Trending today"), with 0 new jobs.
  - **(C) Piggyback on `publish-scheduled`.** It runs on the first tick of each hour. That gives hourly freshness with 0 new jobs, but it couples trends to a job that is not applied in prod and to the scheduled-posts route.

  **Default: (B) for the MVP.** At a few hundred posts a day, hourly buckets are noise and a daily list is honest. Move to (A) when posts per day pass the per-run cap (2,000, about 2,000 DAU at the cost model's 1.0 posts per DAU) or when the founder wants hourly trends. Option (A) is a Terraform change plus a prod plan-then-OK and needs no code change: the route `/internal/cron/trends-refresh` exists in every option. Dev has no jobs in any option, so it is tested by a direct OIDC call (W4-24).
- **F2. People search by display name in v1?** `users.displayName` is exempt from indexing (`firebase/firestore.indexes.json`) and case-sensitive, so it cannot be searched as it is. The cheapest form is a new derived field `nameKeys` (lower-cased word prefixes, 2 to 10 characters, at most 4 words, so at most 36 entries). It has an automatic array-contains index, so **no index-file change**. Its costs:
  - index storage of about 2 KB per user (300 to 3,000 users: under 6 MB, inside the free 1 GiB);
  - 0 extra writes per profile edit (the field is written in the same write);
  - a one-off backfill of 1 write per existing user;
  - one more query per people search (up to +limit reads).

  **Default: handle prefix only in v1.** W4-11 and W4-12 are written and ready. They are marked conditional and start only on a "yes".
- **F3. One flag or two?** **Two:** `FEATURE_SEARCH` (search RPCs, the search UI, the hashtag tap-through, the Explore entry) and `FEATURE_TRENDS` (GetTrends, the refresh step and the trends sections). Trends show user-generated tags to everyone, so they need a kill switch of their own. With one flag, the sweep would stop only when search is globally off.
- **F4. A plain-word query (not `@name`, not `#tag`).** **It searches people by handle prefix and posts tagged `#word` (an exact tag).** The posts tabs say "Search posts by #hashtag" when the word is not a valid tag body. Full-text search of post text is deferred (Out of scope, with its trigger).
- **F5. Hashtag tap-through in W4** (W2 plan question 1): **yes.** A tap on `#tag` opens `/search?q=%23tag` on the Top tab, as X does. W2 keeps "Hashtags are coming soon." (`post_card.dart:348`) until W4-16.
- **F6. Trend rules.** **A tag trends only when at least 3 distinct authors used it in the window (`TRENDS_MIN_AUTHORS`), ranked by distinct authors, then posts. Explore shows the top 10, and the Trending list shows up to 30. An ops denylist (`TRENDS_DENYLIST`, env var) hides a tag at the next deploy, and `FEATURE_TRENDS=off` hides everything at once.**
- **F7. Explore content at Stage 0.** **The search pill, one "Trending" tab, the trends list and the who-to-follow card (W3's data).** Not built:
  - the News, Sports and Entertainment tabs (🔒 no external news or trends feed, founder 2026-10-22; editorial categories need curation);
  - the promoted hero (an ad);
  - "Posts for you" (For You needs its own ADR);
  - the Explore settings gear.
- **F8. Search is for signed-in users only.** **Yes.** A signed-out or public search page is a new unauthenticated read and scraping vector and needs its own ADR.

## What exists already (verified on `main` 46b9e0f)
| Piece | State | W4 delta |
|---|---|---|
| Search module / proto | **none**: no `backend/internal/search`, no `proto/dzeroth/search` (roadmap section 2) | new module + `dzeroth.search.v1` |
| Handle data | `users/{uid}.handleLower` (automatic single-field index, not exempt) and `handles/{handleLower}` (uniqueness, ADR-0003); identity exposes `ResolveHandle(s)` only | one prefix-range reader on identity's interface |
| Display name | `users.displayName` is index-exempt (`fieldOverrides`), case-sensitive | only if F2 = yes: `nameKeys` |
| Hashtags on posts | `posts.hashtags[]`, lower-cased NFC, ≤ 10, D8 grammar (`posts/text.Hashtags`, `testdata` grammar fixtures); REPOST docs store `hashtags: []` (`service_engagement.go:111`), so reposts never double-count | none |
| Hashtag index | `posts (hashtags CONTAINS, createdAt DESC)` is already declared | **no index-file change for Latest/Top** |
| Media on posts | `posts.media` is index-exempt; there is no `hasMedia` field | Media tab = bounded post-filter (architect A3) |
| Feed tooling | `posts.Reader` ("later search" is named in its doc comment), `posts.Cache`, `timeline.Merge`/`Compare`, `cursor.Cursor`, `cache.LRU`, `ratelimit.DailyCap`, `posts.HydrateViewer`, `graph.Reader.Snapshot` (`docs/code-map.md`) | reuse, no second merge/cache/cursor |
| Client | `PostRichText` / `parsePostText` (hashtag spans; the tap shows "Hashtags are coming soon."), `AppTabBar`, `UserListRow` / `PagedUserList` / `FollowButton`, `AppEmptyView`, `AppSideColumn`, `PostCard`, `AppSettingEntries` (`docs/ui-catalog.md`); no search screen, no Explore route; `MainShell` has Home, Notifications, Profile | search feature folder, `/search`, `/explore`, nav entry |
| Scheduler | prod: `daily-maintenance` (live), `publish-scheduled` (defined, not applied); dev: `jobs = {}` | F1 |
| Who to follow | **not built**; W3 owns the suggestion query (roadmap W3 row: "suggestion query with read cap"); **no W3 plan exists yet** | W4 renders it only (W4-19) |

**Update 2026-10-30 (W4-1, `main` 1dff3b3).** W3 and W7 merged after this table was written; ADR-0028 "Context" lists what changed. In short:
- private accounts shipped (ADR-0025): A9 is not deferred, so SearchPosts goes through `posts.Audience` and the trends sweep skips protected authors;
- `posts.hasMedia` exists (ADR-0024 D4): A3 keeps the post-filter on `len(media) > 0` and names the index switch;
- who to follow exists (`ListSuggestedUsers`, flag `follow_suggestions`, 48 h client cache): W4-19 waits only for W4-17;
- the cost baseline moved: W4 at 3,000 DAU is about INR 275, not 169, because it now pays Cloud Run vCPU-s and requests (ADR-0028 Cost impact).

**Ownership decision (who-to-follow):** **W3 owns the suggestion query, its RPC, flag, read cap and budget.** W4 only renders that list in an Explore section and in the desktop side column, behind W3's flag, and adds 0 RPCs of its own for it. W3's budget should count one call per Explore open (1.0 a DAU a day, below) plus side-column mounts under a 5-minute client cache. If W3's RPC has not shipped, the slot renders nothing.

## Goal & user value
People can find accounts and topics: type a handle and get matching people as they type; tap a `#hashtag` anywhere, or search one, and see Top / Latest / Media posts for it; open Explore and see what the community is posting about today and whom to follow. Discovery is the main growth loop after Home: a following-only Home (founder 2026-10-22) has no other way to reach accounts you do not already know.

## Scope / Out of scope
**In scope (Stage 0 rung):**
- **People search:** handle prefix only, `@?[a-z0-9_]{2,15}`, at most 20 results with no pagination. Display names only if F2 = yes.
- **Hashtag search:** results tabs **Top** (bounded re-rank), **Latest** (paged, existing index), **People** (the handle prefix of the same query) and **Media** (bounded post-filter).
- **Hashtag tap-through** from every post body.
- **Search suggestions:**
  - recent searches, on the device only;
  - people typeahead with a small limit;
  - hashtag suggestions taken from the cached trends doc (0 reads).
- **Explore:** search pill, a "Trending" tab, the trends list, and the who-to-follow card (W3's data).
- **Desktop side column:** a search pill and a "What's happening" trends card.
- **Trends:** our own hashtag counters, built by one scheduled sweep (F1).

**Feasible at Stage 0 vs deferred:**
| Results surface | Stage 0 (this plan) | Why / seam | Stage 2/3 target and trigger |
|---|---|---|---|
| Latest (`#tag`) | yes: `hashtags array-contains` + `createdAt DESC`, existing index, opaque cursor | `search.Service.Posts(tab=LATEST)`; `posts.Reader.ByHashtag` | unchanged until full-text arrives |
| Top (`#tag`) | **bounded:** the newest 30 tagged posts (one shared instance entry) ranked by an engagement score; one page, no paging | the `SearchTab` enum and an opaque cursor, so a real ranking can replace the in-request sort without a client change | a ranked index (Postgres FTS or Typesense) when the trigger below fires |
| People | yes: handle prefix (F2 for names) | `search.Service.People` → `identity` prefix reader | the same engine as posts |
| Media (`#tag`) | **bounded post-filter:** posts with media among the tag entry, then scans of 30 older tagged posts per call | `SearchTab.MEDIA`; switch to an index `hashtags CONTAINS, hasMedia, createdAt DESC` if W3's ADR adds `hasMedia` (architect A3) | index or engine |
| Words in post text | **no** (no search engine at Stage 0, `CLAUDE.md`): F4 hint | `SearchPostsResponse.unsupported_query` | **Postgres FTS (Cloud SQL) or Typesense** (`free-tier-budget` §6 "Need full-text search"). Proposed trigger (architect A7): unsupported post queries > 30 % of post searches with > 1,000 post searches/day, or search reads > 15 % of daily Firestore reads, sustained 7 days |
| Trends | daily (F1 B) or hourly (F1 A) sweep over new posts, distinct authors | `search.Trends` interface, `trends/current` doc | Pub/Sub-batched counters or a stream job when posts/day exceed the per-run cap with hourly runs |

**Out of scope:**
- full-text post search (above);
- search filters (from:, date, near), "Advanced search" and saved searches;
- server-side search history (recent searches stay on the device);
- signed-out search (F8);
- News, Sports and Entertainment tabs, the promoted hero, "Posts for you" and Explore settings (F7);
- trends by location or personalised trends;
- a per-trend "More" menu ("Not interested");
- sharing search URLs as deep links (not in W2-9's allowlist);
- private-account exclusion: every post is PUBLIC today (ADR-0008 D1); architect A9 names the seam;
- square organisation avatars.

The stage-ladder skill has no search row today. ADR-0028 (W4-1) proposes the rows (Stage 0 choice, seam, Stage 2/3 target, trigger) in its "Stage ladder" and "Proposed skill rows" sections; the skill edit itself is a follow-up `.claude/` PR (the W4-1 PR does not edit `.claude/`).

## Non-functional targets (Stage 0, 0–300 DAU; credit mode to ~3k DAU changes no target)
- **Latency (warm):**
  - SearchPeople p95 < 300 ms (typeahead);
  - SearchPosts p95 < 400 ms (the timeline target);
  - GetTrends p95 < 200 ms.

  Cold start < 1.5 s (`CLAUDE.md`). No target depends on credit mode's min instance of 1 (ADR-0022: nothing may depend on it after 2026-12-22).
- **Staleness bounds (every cached read):**
  | Cached read | Bound |
  |---|---|
  | People prefix entry (per instance, shared, not viewer-scoped) | 60 s: a new handle or a rename shows within 60 s. Block and relationship filtering is applied per viewer after the cache, from the 60 s graph cache. |
  | Tag entry (newest 30 posts per tag, per instance, shared) | 60 s: a new tagged post reaches Top, Latest page 1 and Media page 1 within 60 s. Takedowns and hidden posts are filtered at serve time (`!Visible()`, post cache ≤ 60 s). |
  | Trends doc (per instance) | 10 min after a refresh. With F1 B, a tag can be up to 24 h + 10 min old (hourly + 10 min with A). The response carries `computed_at`, so the UI can say "Trending today". |
  | Client | Recent searches are local and exact. Trends are cached 5 min client-side (side column and Explore share one cubit). Search results are not persisted (session memory only). |

## Cost (required)
Method: `free-tier-budget` §2 and `docs/reviews/cost-model.md` (baseline 232.3 reads, 32.4 writes, 7.71 deletes per DAU; prices §7: asia-south1 $0.035 per 100k reads, $0.104 per 100k writes; egress to India $0.12/GiB; Cloud Run $0.40 per million requests past 2M; INR 95 per USD). W2's +18.2 reads per DAU (ADR-0023) is not yet in `cost-model.md` (W2-15). The product passes the free 50k reads/day at about 215 DAU, so **every W4 read is billed at 300 DAU and above**. Writes stay free to about 630 DAU.

**Per-RPC (worst-case reads include the account-status interceptor; every call is charged to the ADR-0010 D5 per-uid read budget, max 53 per call, under `ReadBudgetMaxCallReads` = 269):**
| RPC | Reads worst (cold) | Reads warm | Writes | Notes |
|---|---|---|---|---|
| SearchPeople, limit 5 / 20 | 7 / 22 (interceptor 1 + caller graph 1 + query ≤ limit, min 1) | 0–2 (prefix entry hit) | 0 | invalid grammar → VALIDATION, 0 reads; non-handle text → empty, 0 Firestore reads |
| SearchPeople with F2 = yes | +limit (second query on `nameKeys`) → 12 / 42 | 0–2 | 0 | |
| SearchPosts TOP, LATEST page 1, MEDIA page 1 | 33 (interceptor + graph + `userLikes` + tag entry 30); LATEST page 1 at page_size 50: 53 | 0–3 | 0 | one entry serves all three (page_size ≤ 30) |
| SearchPosts LATEST older page (20 / 50) | 23 / 53 | same | 0 | sealed cursor, bound to caller, tag and tab |
| SearchPosts MEDIA older scan | 33 (scan cap 30 per call; short pages allowed) | same | 0 | cursor continues the scan |
| GetTrends (incl. `prefix` suggestions) | 2 (interceptor + `trends/current`) | 0–1 | 0 | ≤ 1 doc read per instance per 10 min ⇒ ≤ 432 reads/day at 3 instances, whatever the DAU |
| Trend refresh run (system, not a user budget) | 1 state + new posts since the watermark (≤ 2,000 per run, 500 per page, projection query) | — | 1 (`trends/current`); 0 under `DEGRADED_MODE=readonly` or `FEATURE_TRENDS` off (0 reads too) | 1 run/day (F1 B) or 24 (A): same reads, +23 writes/day with A |

**Calls per DAU per day (assumptions, to be replaced by W4-23 measurements):**
| Call | Calls/DAU | Typical reads | Reads/DAU |
|---|---|---|---|
| SearchPeople typeahead (limit 5; debounce 300 ms, min 2 chars; ~0.5 search sessions × 3) | 1.5 | 4 (prefix entries rarely shared at low DAU) | 6.0 |
| SearchPeople People tab (limit 20) | 0.3 | 12 | 3.6 |
| SearchPosts page 1 (0.5 hashtag taps + 0.5 searches; tag entry hit rate 40 %) | 1.0 | 19 | 19.0 |
| SearchPosts older pages / Media scans | 0.3 | 23 | 6.9 |
| GetTrends (Explore 1.0 + side column; 5-min client cache) | 2.0 | ~0.05 (shared instance cache) | 0.1 |
| Trend refresh (1.0 posts per DAU per day, cost model §1) | system | 1 per post | 1.0 |
| **Total W4** | **5.1 requests** | | **≈ 36.6 reads, ≈ 0 writes, 0 deletes** |

The who-to-follow card's reads are W3's line (one call per Explore open). The prefix and tag caches are per instance (3 cold caches at most), so the hit rates above are conservative at low DAU.

**Wave total (Stage 0 as configured; W4 increment only):**
| DAU | Reads/day | Firestore reads INR/month | Cloud Run egress (≈ 41 KB/DAU/day JSON) | Cloud Run requests | **W4 total INR/month** | Upper bound with result images as extra GCS egress |
|---|---|---|---|---|---|---|
| 300 | 10,980 (+15.8 % on the 69.7k baseline) | 11 | 4 | 0 (inside 2M free) | **≈ 15** | 15 (GCS egress inside the free 100 GB) |
| 1,000 | 36,600 | 37 | 13 | 0 | **≈ 50** | 50 |
| 3,000 | 109,800 | 111 | 40 | 18 (465k/month, all past the free 2M) | **≈ 169** | ≈ 325 (+10 image GETs/DAU/day × 15 KB, if fully additive to browsing; it mostly replaces Home browsing) |

- **Writes:** 1 per day (F1 B) or 24 per day (A), so INR 0. **Deletes:** 0.
- **Vision units:** 0. **Storage:** `trends/current` < 100 KB. With F2 = yes, about 2 KB of index per user and a one-off backfill of 1 write per user (300 to 3,000 writes, under one day's free 20k).
- **No new GCP service and no fixed cost.** With F1 = A, the third Scheduler job is free; a later fourth job would be about USD 0.10/month and need an ADR.
- **Credit window:** nothing here depends on ADR-0022 items.

## Flags
- `FEATURE_SEARCH` (wire name `search`) gates SearchPeople and SearchPosts. The client gates the search field, `/search`, the hashtag tap-through and the Explore destination on it.
- `FEATURE_TRENDS` (wire name `trends`) gates GetTrends, the trends sections and the refresh step. The step honours only `Registry.GloballyOff` (`flag-rollout`: only `off` is a kill switch for a job).
- **Ceilings.** `scripts/promotion/flag-ceiling.json` gets `SEARCH` and `TRENDS` in `flags` and dev entries `{"mode": "allowlist", "max_allowlist": 6, "max_percent": 0}` (6 since #463, ADR-0028 D8), with **no prod raise**. **That file is founder-gated (CODEOWNERS)**: W4-3's PR needs the founder's review.
- **Terraform.** `feature_search*` and `feature_trends*` variables go in `envs/dev` and `envs/prod`, default `off` (copy `feature_bookmarks`). Nothing is applied.
- **Ramp.** Dev allowlist (3 uids) → the founder's MVP launch decision for prod: allowlist → percent 5 → 25 → 100 → `on`, each step a Terraform change plus a tagged revision (ADR-0019). `FEATURE_TRENDS` never ramps ahead of `FEATURE_SEARCH`: the trend rows link to search.

## Abuse & security surface
- **New public reads (signed-in only).** All three RPCs need App Check plus an ID token, like every RPC. They are `NO_SIDE_EFFECTS`, so they are allowed under `DEGRADED_MODE=readonly`.
- **Enumeration (`stage-ladder` scraping vectors: handle prefix, hashtag `array-contains`):**
  - People results are capped at 20 with **no page token**, so walking the handle space costs at least one call per 20 handles.
  - The prefix minimum is 2 characters (1-character prefixes are refused), and the grammar is `@?[a-z0-9_]{2,15}`.
  - Hashtag pages are at most 50 posts with a sealed cursor bound to the caller, the tag and the tab, 24 h TTL (`cursor.Cursor`, ADR-0010 D14 pattern). A foreign or tampered token → VALIDATION `page_token`, 0 reads.
- **Rate limits and caps (config, rule 11; in memory per instance, so the effective limit is × 3 instances):**
  | Config | Default | Effective at 3 instances |
  |---|---|---|
  | `RATE_LIMIT_SEARCH_PEOPLE_PER_MIN` | 30 | 90/min |
  | `RATE_LIMIT_SEARCH_POSTS_PER_MIN` | 20 | 60/min |
  | `SEARCH_CALLS_PER_DAY` (one `ratelimit.DailyCap` shared by both RPCs, `limit_name` `search_daily`) | 300 | ≤ 900/day |
  | GetTrends | the 60/min default bucket | — |
  | Read budget (ADR-0010 D5) | 2,000 reads/uid/day | binds first: at most 2,368 reads per uid per day across everything |

  Worst people rows per account per day: 900 × 20 = 18,000 handles, already public on profiles. Worst post rows: bounded by the read budget.
- **Query grammar (validated before any read, 0 reads on rejection; ADR-0028 D1 is authoritative and settles the sigil, length and one-character cases below, with the shared fixture `testdata/search_query_grammar.json`):**
  - Normalise: NFC, trim, lower-case.
  - At most 50 code points. Control characters and bidi formatting controls are rejected, as in ADR-0010 D9.
  - People: `@?[a-z0-9_]{2,15}`.
  - Posts: `#?` + one D8 hashtag body, using the same extractor (`posts/text.Hashtags`) and the shared `testdata` grammar fixtures, so the client and server agree.
  - Anything else is an empty result with `unsupported_query = true`, 0 Firestore reads, not an error.
  - The range upper bound is the successor of the prefix (last character + 1; the charset is ASCII). Do not copy the literal `q + ""` in `firestore-data-model` line 97, where the `` was lost; flag the line in W4-1.
- **Block oracle.**
  - Users who block the caller are dropped from People results, matching GetProfile's NOT_FOUND. Suspended and deleting users are dropped too.
  - Users the caller blocks or mutes stay, with the relationship set so `FollowButton` shows "Unblock".
  - Posts follow ADR-0010 D6 (Home column): drop blocked, blocking and muted authors, including a QUOTE's embedded author, and `!Visible()`.
  - A short page is allowed and reveals nothing new: `next_page_token` follows the query, not the filtered count.
  - **`blockedByOverflow` (ADR-0008 D2):** no per-row graph read. The lists precedent fails closed: `timeline.embedAllowed` and `service_bookmarks_list.go:92`. So when the caller's `blockedBy` overflowed:
    - People keeps only accounts the caller follows, plus the caller (a block removes the follow edges);
    - Posts keeps only the caller's posts and posts by followed authors.

    The worst-case reads in the table therefore hold with overflow too.
- **Trend manipulation.**
  - Counts are distinct authors per window, so one account at its 100-posts/day quota counts once.
  - A tag needs `TRENDS_MIN_AUTHORS` (3) to appear.
  - Taken-down posts are skipped at sweep time.
  - Moderation levers: `TRENDS_DENYLIST` and `FEATURE_TRENDS=off`.
  - Residual: sockpuppet rings of 3 or more accounts (Risks).
- **Privacy.**
  - Raw query text is never logged: log `query_kind` (handle / hashtag / unsupported), `query_len`, `results`, `fs_reads` and `cache_hit`.
  - Recent searches stay on the device, per uid, and are cleared on sign-out (`SessionEpoch`).
  - The trends doc holds tags and counts only, no uid. Authors are de-duplicated in memory, so no eraser step is needed. A `lifecycle_collections_guard_test.go` row ("no user data") is still required.

## Dependencies & open questions
**Dependencies:**
- W2 question 1 (F5) is answered yes by default. If no, W4-16 moves back to W2.
- W3 plan (not yet written): who-to-follow RPC and widget (W4-19). If W3's ADR adds `posts.hasMedia` for the profile Media tab, A3 can switch the Media tab to an index.
- The founder's answers to F1 to F8 above.
- The W4 capture session (roadmap section 5, W4 row: search box focused with suggestions, results tabs, empty results). **Optional; it does not block.** The UI tickets use X-like defaults and say so. **UNKNOWN until captured:** the suggestion dropdown content, the results tabs' look, empty and error states, and the Trending tab content (`explore.md` §8, §10).

**Questions for @architect (ADR W4-1; answered in ADR-0028):**
- **A1. People query.** `users` range on `handleLower`, with status and blockedBy filtered in memory (no composite index; short results allowed), vs a `handles` doc-id range plus a `GetAll` of `users` (2× reads). **Default: the `users` range.** A `status == ACTIVE` filter in the query would need a composite index (gate file) and is not worth it at Stage 0.
- **A2.** Tag entry size (30), the Top score (default likes + 2 × reposts + 2 × quotes + replies, posts from the last 7 days, ties newest first), and the cache sizes (`CACHE_SEARCH_PREFIX_ENTRIES` 2,000; `CACHE_SEARCH_TAG_ENTRIES` 500).
- **A3. Media tab.** Bounded post-filter (default) vs W3's `hasMedia` plus a composite index (gate file).
- **A4. `trends/current` shape.**
  - The items array must not be single-field indexed: a `fieldOverride` `trends.items` `indexes: []` with its `field-overrides.ack` hash (**both founder-gated**, repo convention), or an opaque bytes field with no gate-file change.
  - **Default: the fieldOverride.**
  - Also: the watermark position `(createdAt, id)` and the per-run cap.
- **A5. Composition with `daily-maintenance` (F1 B).**
  - An apiserver-level handler runs the backstop first, unchanged, then the trends step.
  - Only the backstop's result sets the status code.
  - The trends step gets `min(10 s, time left before 28 s)` and is skipped with `trends_skipped reason=deadline` when less than 3 s is left, because Cloud Run's request timeout is 30 s (`modules/cloud-run-api`). The watermark resumes the next run.
  - `/internal/cron/trends-refresh` is also mounted alone, for dev and for F1 A.
- **A6.** Token binding and TTL (`cursor.Cursor`, kinds LATEST and MEDIA).
- **A7. The `stage-ladder` search row.** Seam: the `search.Service` Go interface, the `SearchTab` enum and opaque cursors. Target: Postgres FTS or Typesense. Trigger: as in Scope. The ADR PR adds the row to the skill.
- **A8. If F2 = yes, the `nameKeys` design.** Word prefixes 2 to 10, at most 4 words, Unicode lower-case plus NFC; written in `CreateProfile` / `UpdateProfile`'s existing write; never exported (derived, like `status`); a backfill command in `opsctl`. Alternative: `displayNameLower` as a whole-name prefix (cheaper, matches only the first word).
- **A9. Private accounts (deferred).** When `isPrivate` ships, SearchPosts must drop private authors' posts unless the caller is an approved follower. Name the check point behind `search.Service.Posts`.

## Milestones
1. **M4.1 Contract:** W4-1 (ADR, accepted by the founder's merge) and W4-2 (proto).
2. **M4.2 Search backend:** W4-3 to W4-8. Flags off; dev check by allowlist.
3. **M4.3 Trends backend:** W4-9, W4-9b (per F1), W4-10.
4. **M4.4 Client:** W4-13 to W4-19.
5. **M4.5 Verify and roll:** W4-20 to W4-24. Dev allowlist only; prod waits for the held prod apply (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.2) and the founder's MVP launch decision.

(W4-11 and W4-12 are conditional on F2.)

| ID | Ticket | Owner | Size | Depends | Parallel with W3? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| W4-1 | ADR-0028 "Search, trends and Explore at Stage 0" (0024 to 0027 went to W3, W8 and W7) | architect | M | — | **yes, start now** (new file) | In review (PR #465) |
| W4-2 | `proto/dzeroth/search/v1/search.proto` (SearchService: SearchPeople, SearchPosts, GetTrends) with per-RPC cost comments | architect | S | W4-1 drafted | **yes, start now** (new file) | In review (PR #465) |
| W4-3 | `make proto`; `FEATURE_SEARCH` / `FEATURE_TRENDS`, config, rate limits, daily cap, ceiling, Terraform vars; `internal/search` skeleton with flag-guarded handlers | backend-developer | M | W4-2 | logic yes; shared files (`config.go`, `apiserver.go`, `ratelimit_config.go`, `flag-ceiling.json`, Terraform vars): merge one at a time | Open |
| W4-4 | `identity` handle-prefix reader (`Directory.SearchHandles`) | backend-developer | S | W4-3 | yes; one method in `identity/api.go` (W3 edits identity too) | In review (PR #469) |
| W4-5 | SearchPeople service + prefix cache + filters | backend-developer | M | W4-4 | yes (search module only) | Open |
| W4-6 | `posts.Reader.ByHashtag` and `posts.Reader.CreatedAfter` | backend-developer | S | W4-3 | yes; `posts/api.go` is shared with W3's media filter / pin | In review (PR #467) |
| W4-7 | SearchPosts LATEST: tag entry cache, sealed cursor, D6 filter, viewer flags | backend-developer | M | W4-6 | yes | Open |
| W4-8 | SearchPosts TOP and MEDIA | backend-developer | S | W4-7 | yes | Open |
| W4-9 | Trends refresh: `trends/current`, watermark sweep, `/internal/cron/trends-refresh` route, guard row, runbook | backend-developer | M | W4-6 | yes | Open |
| W4-9b | *(F1 = B)* compose the trends step into `daily-maintenance` (apiserver wrapper, status code from the backstop only). *(F1 = A instead: the `trends-refresh` Scheduler job in `envs/prod`, owner production-deployer, plan-then-OK)* | backend-developer (B) / production-deployer (A) | S | W4-9, F1 | yes; the wrapper lives in `apiserver`, identity code untouched | Open |
| W4-10 | GetTrends RPC + instance cache + `prefix` suggestions | backend-developer | S | W4-9 | yes | Open |
| W4-11 | *(conditional, F2 = yes)* `nameKeys` written by identity + `opsctl` backfill | backend-developer | M | W4-1 (A8), W4-4 | **conflicts with W3 profile-write changes**: sequence after W3's identity PRs | Open (conditional) |
| W4-12 | *(conditional, F2 = yes)* SearchPeople merges name matches | backend-developer | S | W4-5, W4-11 | yes | Open (conditional) |
| W4-13 | Client data layer: query parser (shared grammar), `SearchRepository`, recent-search store | frontend-developer | S | parser/store: — ; repository: W4-3 | **parser and store: yes, start now** | In review (PR #464): parser + store; repository waits for W4-3 |
| W4-14 | Search field + suggestions overlay | frontend-developer | M | W4-13 | yes | Open |
| W4-15 | Results screen `/search` with Top / Latest / People / Media | frontend-developer | M | W4-13 | yes | Open |
| W4-16 | Hashtag tap-through from post bodies | frontend-developer | S | W4-15 | yes; `post_card.dart` may also change in W3 (pinned label) | Open |
| W4-17 | Explore screen `/explore` + nav destination | frontend-developer | M | W4-14, W4-10 for the dev check | shell nav files (`MainShell`, `AppBottomBar`, rail, drawer) may conflict with W3 UI | Open |
| W4-18 | Desktop side column: search pill + "What's happening" card | frontend-developer | S | W4-17 | yes (`AppSideColumn`) | Open |
| W4-19 | Who-to-follow card on Explore and in the side column (renders W3's data) | frontend-developer | S | W4-17, W3 suggestion RPC + widget | **depends on W3** | Open |
| W4-20 | Backend tests: flag matrix, grammar, budgets, block oracle, cursors, trends sweep | tester | M | W4-5, W4-8, W4-10 | yes | Open |
| W4-21 | Client tests: responsive matrix and flows across the new screens | tester | S | W4-14 to W4-18 | yes | Open |
| W4-22 | Security review: enumeration, oracle, trends abuse, logging, local history | security-auditor | S | W4-5, W4-8, W4-10, W4-14 | yes | Open |
| W4-23 | Cost report: `cost-model.md` rows, emulator load smoke, trigger | sre-performance | S | W4-8, W4-10 | yes | Open |
| W4-24 | Dev rollout: Terraform plan, allowlist, smoke incl. direct trends-refresh call | production-deployer | S | W4-20, W4-22, W4-23, ADR merged | serialise dev applies with W3's | Open |

Order:
1. W4-1 and W4-2.
2. W4-3.
3. W4-4 → W4-5 ‖ W4-6 → W4-7 → W4-8 ‖ W4-9 → W4-9b and W4-10.
4. Client: W4-13 (parser and store at once), then W4-14 ‖ W4-15, W4-16, W4-17, W4-18, W4-19 (when W3 is ready).
5. W4-20 to W4-24, with W4-22 and W4-23 before any flag leaves `off` in dev.

**Definition of done per ticket:**
- Backend: Go unit tests plus emulator integration (`make test-int`, `budgettest.Assert` on every RPC).
- Client: widget tests in light and dark at 360 / 600 / 1200 via `test/support/theme_harness.dart` for every new screen or widget, and text scale 1.0 / 1.3 / 2.0. Pixel goldens deferred (B-01).
- `make ci` green.
- `docs/code-map.md` / `docs/ui-catalog.md` updated; this table's Status updated in the PR.

## Tickets

### W4-1 — ADR "Search, trends and Explore at Stage 0"  [owner: architect] [size: M] [depends: —]  Status: In review (PR #465)
- **Description.** ADR-0028 (`docs/adr/0028-search-trends-and-explore-at-stage-0.md`; 0024 to 0027 were taken by W3, W8 and W7 before the PR opened). The ADR covers:
  - the query grammar and normalisation;
  - People search (A1; F2 and A8 as a founder question);
  - the four tabs at Stage 0 (A2, A3);
  - the shared prefix and tag caches with their staleness bounds;
  - the `trends` collection, its shape and index exemption (A4), the refresh cadence and host (F1, A5) and the per-run cap;
  - the abuse limits and the per-RPC cost table above;
  - flags (F3), privacy, the lifecycle (no user data);
  - the Stage 2/3 target and trigger (A7), and private accounts (A9).

  Then, in the same PR:
  - if F1 = B, a **dated amendment note on ADR-0011**: the `daily-maintenance` route also runs the trends step. The backstop and its "never behind a flag or `DEGRADED_MODE`" contract are unchanged, and the trends step has its own switches. The decision text is unchanged.
  - if F1 = A, a dated note on ADR-0021 D1 for the Scheduler count (3 of 3 used);
  - correct the garbled prefix-search line in `firestore-data-model` (or ticket it);
  - add the `stage-ladder` "Search and trends" row in the ADR PR;
  - add `firestore-data-model` rows for `trends` and the new queries.
- **Acceptance criteria.**
  - Given the ADR, when the founder reads it, then each of F1 to F8 has options, a default and a cost line in INR at 300 / 1,000 / 3,000 DAU that cite `cost-model.md`.
  - Given A4 = fieldOverride, then the ADR names the exact `firestore.indexes.json` entry and the `field-overrides.ack` step as founder-gated.
  - Given the Scheduler count, then the ADR restates "2 of 3 jobs used" and which option spends the third.
- **Test notes.** None (docs). `code-reviewer` checks that the seam and trigger lines are present.
- **Observability.** The ADR lists the log fields (`query_kind`, `query_len`, `results`, `fs_reads`, `cache_hit`, `trends_posts_scanned`, `trends_tags`, `trends_skipped`).
- **Budget.** The ADR's table is the source for W4-4 to W4-10.
- **Flag.** None (docs); it names `FEATURE_SEARCH` and `FEATURE_TRENDS` and their ceilings.
- **Seam.** It defines `search.Service` (People, Posts, Trends), `search.TrendsRefresher`, `identity.Directory.SearchHandles` and `posts.Reader.ByHashtag` / `CreatedAfter`.
- **Parallel with W3:** yes.

### W4-2 — `dzeroth.search.v1` proto  [owner: architect] [size: S] [depends: W4-1 drafted]  Status: In review (PR #465)
- **Description.** A new `proto/dzeroth/search/v1/search.proto`, `option go_package` as the others. The service (all `NO_SIDE_EFFECTS`), each RPC with a cost comment:
  - `SearchPeople(query, limit 0→10, max 20)` → `repeated dzeroth.graph.v1.UserListItem` (reuses the graph row so `UserListRow` / `FollowButton` render it with 0 extra reads).
  - `SearchPosts(query, tab SearchTab {UNSPECIFIED = TOP, TOP, LATEST, MEDIA}, page_size 0→20 max 50, page_token)` → `repeated dzeroth.posts.v1.PostView posts`, `next_page_token`, `normalized_tag`, `unsupported_query`.
  - `GetTrends(limit 0→10 max 30, prefix)` → `repeated Trend {tag, post_count, rank}`, `computed_at`.

  Error contract: VALIDATION `field=query|page_token|limit`; FEATURE_DISABLED `feature=search|trends`; RATE_LIMITED. `buf lint` and `buf breaking` clean (a new package, so nothing breaks).
- **Acceptance criteria.**
  - Given `make proto`, then Go and Dart code generates.
  - Given the comments, then each RPC states worst and warm reads, the grammar, the caps and "no pagination for People".
- **Test notes.** `buf breaking` against `main`.
- **Observability.** —
- **Budget.** Copied from W4-1.
- **Flag.** None (contract); the comments name `search` and `trends` as the FEATURE_DISABLED metadata.
- **Seam.** `SearchTab` is an enum (a new tab is additive); every cursor is opaque.
- **Parallel with W3:** yes.

### W4-3 — Generate, flags, config, module skeleton  [owner: backend-developer] [size: M] [depends: W4-2]  Status: Open
- **Description.**
  - Register `FEATURE_SEARCH` and `FEATURE_TRENDS` in `config.go` and `flags.NewRegistry` (follow `FEATURE_BOOKMARKS`).
  - Add the config values to `config_test.go`'s env list: `RATE_LIMIT_SEARCH_PEOPLE_PER_MIN` 30, `RATE_LIMIT_SEARCH_POSTS_PER_MIN` 20, `SEARCH_CALLS_PER_DAY` 300, `CACHE_SEARCH_PREFIX_ENTRIES` 2,000, `CACHE_SEARCH_TAG_ENTRIES` 500, `TRENDS_MIN_AUTHORS` 3, `TRENDS_MAX_POSTS_PER_RUN` 2,000, `TRENDS_DENYLIST` "", `TRENDS_MIN_INTERVAL` 12 h (ADR-0028 D6: a run within it of the last list is skipped as `fresh`).
  - Map the limits in `ratelimit_config.go` (two limiters, one shared `DailyCap` `search_daily`).
  - `flag-ceiling.json`: `SEARCH` and `TRENDS` dev allowlist 6 (since #463; **founder-gated file**).
  - Terraform `feature_search*` / `feature_trends*` in `envs/dev` and `envs/prod`, default `off`, not applied.
  - `internal/search` with `api.go` (interfaces), a Connect server whose three handlers return FEATURE_DISABLED or Unimplemented, and wiring in `apiserver.Build`.
- **Acceptance criteria.**
  - Given `FEATURE_SEARCH` unset, when any search RPC is called, then FAILED_PRECONDITION `FEATURE_DISABLED` `feature=search` with 0 reads; likewise GetTrends with `trends`.
  - Given `allowlist` with a uid, then `GetMe.enabled_features` contains `search` / `trends` for that uid only.
  - `check-flag-registry.sh` passes; `guard_test.go` sees both RPCs in the read budget and the daily cap.
- **Test notes.** Flag modes off / allowlist / percent / on; the guard test; the config bounds (reject negative or zero).
- **Observability.** Startup logs the flag modes (existing).
- **Budget.** 0 reads (rejection paths).
- **Flag.** Adds `FEATURE_SEARCH` and `FEATURE_TRENDS` (default `off`; dev ceiling allowlist 3).
- **Seam.** `search.Service` Go interface; handlers call only it.
- **Parallel with W3:** logic yes. These shared files conflict textually with W3's flag ticket, so merge one PR at a time:
  - `config.go`, `apiserver.go`, `ratelimit_config.go`;
  - `flag-ceiling.json`;
  - the Terraform vars.

### W4-4 — Identity handle-prefix reader  [owner: backend-developer] [size: S] [depends: W4-3]  Status: In review (PR #469)
- **Description.** `identity.Directory.SearchHandles(ctx, prefix string, limit int) ([]Profile, error)`, a new repo file:
  - `users where handleLower >= p and handleLower < succ(p) orderBy handleLower Limit(limit)`, with limit clamped to 1..20;
  - reads = len(result), minimum 1;
  - returns raw profiles, including status; filtering is the caller's job, as with `posts.Reader`.
- **Acceptance criteria.**
  - Given handles `ab_c`, `abc`, `abd` and prefix `ab`, then the results are in `handleLower` order and an exact match comes first.
  - Given prefix `z`, then `succ` is computed per character (`_` → `` ` ``, `z` → `{`).
  - Given limit 50, then it is clamped to 20.
  - Given no match, then 1 read is charged.
- **Test notes.** Emulator integration, `budgettest` exact counts.
- **Observability.** —
- **Budget.** ≤ 20 reads per call.
- **Flag.** None on the method; it is reached only through SearchPeople behind `FEATURE_SEARCH`.
- **Seam.** Identity owns `users`: search never queries `users` directly.
- **Parallel with W3:** yes. It adds one method to `identity/api.go`, which W3 also edits; rebase on merge.

### W4-5 — SearchPeople  [owner: backend-developer] [size: M] [depends: W4-4]  Status: Open
- **Description.** `search.People`, step by step:
  1. Validate (grammar above; 0 reads on rejection).
  2. Read the prefix entry (`cache.LRU`, 60 s, keyed by `(prefix, limit)`, shared across viewers), or call `SearchHandles`.
  3. Drop users who are not ACTIVE and users in the caller's `blockedBy`, using `graph.Reader.Snapshot` (cached 60 s). If `blockedByOverflow`, fail closed with no per-row graph read: keep only followed accounts and the caller (Abuse section).
  4. Set `Relationship` from the caller graph (follow state, blocking, muting).
  5. Return at most `limit`, with no token.

  A non-handle query returns an empty list, 0 reads. The `search_daily` cap and rate limits apply.
- **Acceptance criteria.**
  - Given `@Ali`, then results for `ali` arrive with relationships.
  - Given a user who blocks the caller, then that user is absent, and the response bytes match a non-existent user's case.
  - Given a suspended user, then absent.
  - Given a 1-character query, then VALIDATION with 0 reads.
  - Given 31 calls in a minute, then RATE_LIMITED.
  - Given the 301st call in a day, then RATE_LIMITED with `limit_name=search_daily`.
  - Given a warm entry, then 0 Firestore reads for the results.
- **Test notes.**
  - Flag matrix.
  - `budgettest` 7 / 22 cold, 0–2 warm.
  - Block both directions; a muted user stays.
  - A cache entry shared by two viewers filters differently per viewer.
- **Observability.** One slog line: `query_kind`, `query_len`, `results`, `dropped` (status / blocked), `cache_hit`, `fs_reads`. Error Reporting on internal errors. Never the raw query.
- **Budget.** Cold 7 (limit 5) / 22 (limit 20); warm 0–2; writes 0.
- **Flag.** `FEATURE_SEARCH` (per caller).
- **Seam.** `search.Service.People`; the cache sits behind a small interface with a stated bound (60 s).
- **Parallel with W3:** yes.

### W4-6 — Posts reader methods  [owner: backend-developer] [size: S] [depends: W4-3]  Status: In review (PR #467)
- **Description.** Two methods on `posts.Reader`:
  - `ByHashtag(ctx, tag, window Window, limit)`: `hashtags array-contains tag`, `createdAt DESC, __name__ DESC`, Limit 1..50, existing composite index.
  - `CreatedAfter(ctx, after Position, limit)`: `createdAt ASC, __name__ ASC` from the watermark, Limit ≤ 500, projection of `hashtags`, `authorId`, `moderation`, `createdAt` and `kind` (still 1 read per doc). It runs on the automatic single-field index; confirm on the emulator and in dev that no composite index is needed, otherwise stop and ask (a gate file).

  Both return unfiltered posts, per the Reader contract.
- **Acceptance criteria.**
  - Given 25 posts tagged `#go`, then pages of 20 + 5 come newest first with the window honoured.
  - Given a REPOST (empty hashtags), then it never matches.
  - Given `CreatedAfter` at a watermark, then only strictly newer posts come back, in order, and ties are broken by id.
- **Test notes.** Emulator integration with exact reads (minimum 1 on empty); the index existence check in `firestore.indexes.json` (no change).
- **Observability.** —
- **Budget.** ≤ limit reads, minimum 1.
- **Flag.** None on the methods; they are reached only behind `FEATURE_SEARCH` (ByHashtag) and `FEATURE_TRENDS` (CreatedAfter).
- **Seam.** `posts.Reader` (named "later search" in its comment); no second post query outside posts.
- **Parallel with W3:** yes. It adds to `posts/api.go` and a new repo file; W3's media filter or pin may edit the same interface, so rebase.

### W4-7 — SearchPosts LATEST  [owner: backend-developer] [size: M] [depends: W4-6]  Status: Open
- **Description.**
  - Validate the tag (D8 extractor).
  - The **tag entry**: the newest 30 posts per tag, `cache.LRU` with 60 s TTL and `CACHE_SEARCH_TAG_ENTRIES`, shared across viewers, filled by one `ByHashtag(limit 30)`.
  - Page 1 = the first `page_size` items of the entry (a page size above 30 reads the rest).
  - Older pages use a sealed `cursor.Cursor` bound to `search|<uid>|<tag>|LATEST`, 24 h TTL, and call `ByHashtag` with `Before`.
  - Filter per ADR-0010 D6 (Home column: blocked, blockedBy, muted, QUOTE embedded author, `!Visible()`). On `blockedByOverflow`, fail closed with no extra read: keep only the caller's posts and followed authors' posts; foreign embeds are dropped, as in `timeline.embedAllowed`.
  - Hydrate viewer flags through `posts.HydrateViewer` (1 cached `userLikes` read with `engagement` or `bookmarks` on).
  - `next_page_token` is set whenever the query page was full, even when filtering shortened the page.
  - A query that is not a tag → `unsupported_query = true`, 0 reads.
- **Acceptance criteria.**
  - Given 45 tagged posts, then page 1 has 20, page 2 has 20 and page 3 has 5 with `""`.
  - Given a foreign or tampered token, then VALIDATION `page_token` with 0 reads.
  - Given a post by a blocked author, then it is dropped and the token still advances.
  - Given a taken-down post in a warm entry, then it is dropped at serve time.
  - Given `#Go` and `go`, then the same `normalized_tag` `go`.
  - Given 21 calls a minute, then RATE_LIMITED.
- **Test notes.** Flag matrix; `budgettest` 33 cold (page 1), 23 / 53 (older 20 / 50), 0–3 warm; the D6 drop matrix; cursor tampering; concurrency (two viewers share an entry).
- **Observability.** One slog line: `tab`, `results`, `dropped` by cause, `cache_hit`, `fs_reads`. Never the raw query (log the tag length).
- **Budget.** As the per-RPC table; writes 0.
- **Flag.** `FEATURE_SEARCH`; viewer flags follow `engagement` and `bookmarks` as on timelines.
- **Seam.** `search.Service.Posts(tab)`; reuse `timeline.Compare` order and the existing cursor codec; no second merge.
- **Parallel with W3:** yes.

### W4-8 — SearchPosts TOP and MEDIA  [owner: backend-developer] [size: S] [depends: W4-7]  Status: Open
- **Description.**
  - **TOP:** rank the filtered tag entry by the A2 score, posts from the last 7 days, ties newest first. One page of at most 20, `next_page_token` always `""`. The client shows a "See latest" footer.
  - **MEDIA:** page 1 = the entry's posts with `media` (their own images; a QUOTE's embedded media does not count unless A3 says otherwise). Then a sealed MEDIA cursor scans 30 older tagged posts per call and returns the media ones (short or empty pages are allowed, and the token continues while the scan has more).
- **Acceptance criteria.**
  - Given posts with 0 / 5 / 2 likes, then TOP orders 5, 2, 0.
  - Given an 8-day-old post with 100 likes, then it is excluded from TOP.
  - Given 3 media posts among 30, then MEDIA page 1 returns 3.
  - Given a scan page with 0 media, then `[]` plus a token.
  - Given a scan that reaches the end, then `""`.
- **Test notes.** `budgettest` TOP 33 cold / 0–3 warm and MEDIA scan 33; a TOP score determinism test.
- **Observability.** The same line as W4-7, with `tab`.
- **Budget.** ≤ 33 reads per call; writes 0.
- **Flag.** `FEATURE_SEARCH`.
- **Seam.** The ranking sits behind `search.Service.Posts(TOP)`, so a later engine replaces it without a client change.
- **Parallel with W3:** yes.

### W4-9 — Trends refresh  [owner: backend-developer] [size: M] [depends: W4-6]  Status: Open
- **Description.** `search.TrendsRefresher.Refresh(ctx)` (search owns the `trends` collection):
  1. Read `trends/current`: watermark, the last window's items, `computedAt`.
  2. Page `posts.Reader.CreatedAfter(watermark, 500)` up to `TRENDS_MAX_POSTS_PER_RUN`.
  3. Skip `!Visible()` posts and REPOST kinds.
  4. Count per tag: distinct authors (in-memory set; nothing persisted) and posts.
  5. Drop `TRENDS_DENYLIST` tags and tags under `TRENDS_MIN_AUTHORS`.
  6. Keep the top 100 (doc < 100 KB).
  7. Write `{items, watermark, computedAt, windowStart}` in 1 write.

  Bounds and switches:
  - The cap reached → the watermark stops at the last read post, and the next run resumes (log `trends_backlog`).
  - `Registry.GloballyOff("trends")` or `DEGRADED_MODE=readonly` → 0 reads, 0 writes, 204.
  - Route `/internal/cron/trends-refresh` (OIDC like every `/internal/*`), POST only, 25 s deadline, its own `budget` counter, `recoverPanic`; it answers 204, or 500 only when the first page fails.
  - The cron host is W4-9b.

  Housekeeping:
  - `lifecycle_collections_guard_test.go` gets a `trends` row (no user data, no eraser step).
  - If A4 = fieldOverride: `firebase/firestore.indexes.json` gets `trends.items` `indexes: []`, plus the `firebase/field-overrides.ack` hash (**founder-gated files**).
  - Runbook `docs/runbooks/search.md`: kill switches, denylist, a stuck watermark, `trends_skipped`, how to call the route in dev.
- **Acceptance criteria.**
  - Given 5 posts by 1 author with `#spam`, then `#spam` does not trend (1 distinct author < 3).
  - Given 3 authors with `#launch`, then it trends with authors 3.
  - Given a taken-down post, then it is not counted.
  - Given a denylisted tag, then it is absent.
  - Given 2,500 new posts and the cap at 2,000, then 2,000 are counted, the watermark sits at the 2,000th, and the next run continues.
  - Given the flag globally off, then 0 reads.
- **Test notes.**
  - Emulator integration.
  - `budgettest`: 1 + new posts, 1 write.
  - The time budget with a fake clock.
  - Kill switch: percent 0 is not a kill switch (`flag-rollout`).
- **Flag.** `FEATURE_TRENDS`; the refresh stops only on `Registry.GloballyOff("trends")`.
- **Observability.**
  - One `trends_refresh` line: `posts_scanned`, `tags_counted`, `tags_kept`, `backlog`, `skipped` reason, `fs_reads`, `fs_writes`, `duration_ms`.
  - Error Reporting on failure.
  - No uid in logs.
- **Budget.** Reads 1 + new posts (≤ 2,001 per run); writes 1; deletes 0.
- **Seam.** `search.TrendsRefresher`. The cron host is wiring only, so F1 A and B differ in Terraform and `apiserver.go`, not in the module.
- **Parallel with W3:** yes.

### W4-9b — Cron host for the refresh (per F1)  [owner: backend-developer if F1 = B; production-deployer if F1 = A] [size: S] [depends: W4-9, founder F1]  Status: Open
- **Description.**
  - **F1 = B (default):** `apiserver` mounts `/internal/cron/daily-maintenance` as a wrapper. It calls `lifecycle.CronHandler()` unchanged through a status-capturing response writer, then runs `search.TrendsRefresher.Refresh` with the A5 sub-deadline: `min(10 s, time left before 28 s)`, skipped below 3 s. It writes the backstop's captured status. No change to `identity/lifecycle_jobs.go`, which is W3 territory.
  - **F1 = A:** no wrapper. A `trends-refresh` entry (hourly, path `/internal/cron/trends-refresh`) goes into `envs/prod/main.tf` `jobs`, and the Scheduler count comment becomes 3 of 3. Plan-then-OK by the founder at MVP launch, after confirming that no other Scheduler job exists on the billing account (ADR-0021 founder decision 1).
- **Acceptance criteria (B).**
  - Given the backstop fails, then 500 is returned, whatever trends did; Scheduler retries the backstop (trends resumes from its watermark, so a retry double-counts nothing).
  - Given trends fail or are skipped, then the status reflects the backstop only, and the reason is logged.
  - Given a Scheduler retry minutes after a successful run, then the trends step is skipped as `fresh` (ADR-0028 D6) and the list is not replaced.
  - Given the backstop takes 26 s, then trends is skipped with `trends_skipped reason=deadline`.
- **Acceptance criteria (A).** The targeted prod plan shows exactly one added job; nothing is applied without the founder's OK.
- **Test notes.** The status-code matrix (backstop ok / failed × trends ok / failed / skipped) with a fake clock; ADR-0011's backstop tests are unchanged and green.
- **Observability.** The existing `account_job` line, plus the `trends_refresh` line from W4-9.
- **Budget.** As W4-9; option A adds +23 writes a day (hourly).
- **Flag.** `FEATURE_TRENDS` (inside the step); the backstop is never flag-gated (ADR-0011).
- **Seam.** The cron host is wiring only; switching B to A later is this ticket alone.
- **Parallel with W3:** yes.

### W4-10 — GetTrends  [owner: backend-developer] [size: S] [depends: W4-9]  Status: Open
- **Description.**
  - Read `trends/current` through a per-instance cache with a 10 min TTL.
  - Return the top `limit` (0 → 10, max 30), with ranks and `computed_at`.
  - A `prefix` (1 to 50 code points, D8 body characters) filters the cached items for typeahead hashtag suggestions, with 0 extra reads.
  - No doc yet → an empty list.
- **Acceptance criteria.**
  - Given a warm cache, then 0 Firestore reads.
  - Given `prefix=la`, then only tags starting with `la`, in rank order.
  - Given the flag off, then FEATURE_DISABLED `trends` with 0 reads.
- **Test notes.** Flag matrix; `budgettest` 2 cold / 0–1 warm; the TTL with a fake clock.
- **Observability.** One slog line: `results`, `cache_hit`, `fs_reads`, `computed_age_s`.
- **Budget.** 2 cold / 0–1 warm; writes 0.
- **Flag.** `FEATURE_TRENDS` (per caller).
- **Seam.** `search.Service.Trends`.
- **Parallel with W3:** yes.

### W4-11 — *(conditional on F2 = yes)* Display-name keys  [owner: backend-developer] [size: M] [depends: W4-1 A8, W4-4]  Status: Open (conditional)
- **Description.**
  - `users.nameKeys` (A8) is written in the existing `CreateProfile` / `UpdateProfile` write, so 0 extra writes.
  - It is not exported (derived) and is erased with `users/{uid}`.
  - An `opsctl search backfill-name-keys` command pages users by `__name__` (≤ 500) and is throttled, resumable and dry-run first.
  - `Directory.SearchNames(prefix, limit)`: `nameKeys array-contains p` (first 10 characters), Limit ≤ 20; longer queries are re-checked in memory.
  - No index-file change: the new array is auto-indexed.
- **Acceptance criteria.**
  - Given the display name "Ravi Kumar", then the keys include `ra`, `rav`, `ku` and `kumar`.
  - Given a rename, then the keys are replaced in the same write.
  - Given the backfill on 300 users, then 300 writes and a resumable cursor.
- **Test notes.** Emulator integration; a fuzz test on Unicode names (Indic scripts, ZWJ); the export golden is unchanged.
- **Observability.** The backfill logs `users_scanned`, `users_written`.
- **Budget.** Backfill 1 read + 1 write per user, one-off; query ≤ 20 reads.
- **Flag.** The field is written and backfilled regardless of flags (derived data); it is read only behind `FEATURE_SEARCH`.
- **Seam.** `identity.Directory`.
- **Parallel with W3:** **no.** It edits the profile write path that W3's profile meta / pin / cover tickets also edit, so sequence it after them.

### W4-12 — *(conditional on F2 = yes)* SearchPeople with names  [owner: backend-developer] [size: S] [depends: W4-5, W4-11]  Status: Open (conditional)
- **Description.**
  - SearchPeople runs the handle query and, for a query that is a name prefix (Unicode letters, at least 2 characters), the `nameKeys` query.
  - Results are merged handle matches first, de-duplicated by uid, and capped at `limit`.
  - A non-handle query (for example Devanagari) now reaches the names query.
- **Acceptance criteria.**
  - Given "rav", then handle and name matches merge with no duplicates.
  - Given limit 5, then ≤ 5 results.
  - Worst reads are 12 / 42 (limit 5 / 20).
- **Test notes.** `budgettest`; the block and status filters on name matches.
- **Observability.** `results_handle`, `results_name`.
- **Budget.** +limit reads.
- **Flag.** `FEATURE_SEARCH`.
- **Seam.** `search.Service.People`.
- **Parallel with W3:** yes.

### W4-13 — Client data layer  [owner: frontend-developer] [size: S] [depends: — (parser, store); W4-3 (repository)]  Status: In review (PR #464): parser + store; repository waits for W4-3
- **Description.**
  - `SearchQuery.parse` (pure) classifies `@handle` / `#tag` / plain word with the same rules as the server. It tests against the shared `testdata` hashtag grammar fixtures, as `parsePostText` does.
  - `RecentSearchesStore`: at most 10 entries per uid, newest first, de-duplicated, stored in `AppSettingEntries` (the local store used by W2-12), cleared on sign-out (`SessionEpoch`), with "Clear all" and per-item remove. Nothing is sent to the server.
  - `SearchRepository` over the generated connect-dart client: SearchPeople, SearchPosts, GetTrends; friendly mapping of FEATURE_DISABLED, RATE_LIMITED and VALIDATION.
  - `kFeatureSearch` / `kFeatureTrends` read from `GetMe.enabled_features`.
- **Acceptance criteria.**
  - Given `#Launch`, then the kind is tag with body `launch`.
  - Given `@a`, then too short (no call).
  - Given 11 searches, then the oldest is dropped.
  - Given sign-out, then the store is empty for the next user.
- **Test notes.** Unit tests only; the grammar fixtures are shared with Go.
- **Observability.** —
- **Budget.** 0 RPCs (parser and store).
- **Flag.** Client gates `search` and `trends` (`kFeatureSearch`, `kFeatureTrends`); the parser and store are not gated.
- **Seam.** `SearchRepository` is the only place that calls the RPCs; recent searches stay behind a store interface, so a server history later changes no caller.
- **Parallel with W3:** the parser and store, **yes, now**.

### W4-14 — Search field and suggestions  [owner: frontend-developer] [size: M] [depends: W4-13]  Status: Open
- **Description.** A pill search field (`AppSearchField`, a new shared widget: 1 dp outline `#333639` dark, fully rounded, search icon, "Search" placeholder; `explore.md` §2). On focus, an overlay shows:
  - empty input: "Recent" (from the store) with "Clear all";
  - typing: hashtag suggestions from GetTrends `prefix` (needs `trends`) and people rows from SearchPeople with limit 5 (debounce 300 ms, at least 2 characters, the in-flight call cancelled on the next keystroke);
  - a "Search for <query>" row.

  Enter or a row tap records the recent search and opens `/search`. Keyboard: arrows, Enter, Escape. A rate-limited answer shows a quiet inline hint.
- **Capture.** **The suggestion dropdown was not captured (UNKNOWN).** Default: X-like rows with our own copy; the founder's capture may adjust it.
- **Acceptance criteria.**
  - Given "ab" typed quickly as "a", "ab", then exactly 1 SearchPeople call.
  - Given 1 character, then no call.
  - Given `trends` off, then no hashtag suggestions and no GetTrends call.
  - Given `search` off, then the field is absent.
- **Test notes.** Widget tests 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0; a debounce test with a fake clock; focus and semantics (`combobox`-like labels, "Search query").
- **Observability.** —
- **Budget.** ≈ 1.5 SearchPeople calls per session (cost table).
- **Flag.** `search` (field and people rows), plus `trends` (hashtag suggestions).
- **Seam.** The suggestions cubit depends on `SearchRepository` and the store only.
- **Parallel with W3:** yes.

### W4-15 — Results screen  [owner: frontend-developer] [size: M] [depends: W4-13]  Status: Open
- **Description.** `/search?q=<query>&tab=top|latest|people|media`:
  - the search field in the header (`AppBackHeader` variant) and an `AppTabBar` with Top · Latest · People · Media (content-sized);
  - the default tab is Top, or People for an `@` query;
  - post tabs render `PostCard` rows (live counts, engagement row with `engagement` on) with prefetch paging on Latest and Media and a "See latest" footer on Top;
  - People renders `UserListRow` rows (`FollowButton` from `relationship`) with no paging;
  - an unsupported query shows "Search posts by #hashtag" on the post tabs;
  - empty states use `AppEmptyView` ("No results for …", our copy); FEATURE_DISABLED shows a "not available" state; RATE_LIMITED shows retry.
  - Results are session memory only; switching tabs reuses each tab's state.
- **Capture.** **The results tabs and empty results were not captured (UNKNOWN).** X-like defaults.
- **Acceptance criteria.**
  - Given `#go`, then Top shows ≤ 20 with "See latest".
  - Given Latest, then scrolling follows `next_page_token` through short pages.
  - Given People, then rows show Follow / Following / Unblock correctly.
  - Given an unsupported word, then People still works and the post tabs show the hint.
- **Test notes.** Widget tests at 3 widths, light and dark, 3 text scales; flag-off routing; tab persistence.
- **Observability.** —
- **Budget.** Per the cost table (1.0 page-1 call + 0.3 more pages per DAU).
- **Flag.** `search` (route); the action row needs `engagement`, as everywhere.
- **Seam.** One `SearchResultsCubit` per tab over `SearchRepository`.
- **Parallel with W3:** yes.

### W4-16 — Hashtag tap-through  [owner: frontend-developer] [size: S] [depends: W4-15]  Status: Open
- **Description.**
  - In `PostRichText`, a hashtag span tap opens `/search?q=%23<tag>&tab=top` when `search` is on; otherwise the existing "Hashtags are coming soon." stays (W2 kept it).
  - It applies to posts, quotes' own text and the thread view (every `PostRichText`).
  - Record the reversal of `phase1.md` decision (3) in that file's decision note.
- **Acceptance criteria.**
  - Given `search` on, when `#Launch` is tapped, then the results open for `launch` on Top.
  - Given `search` off, then the old snackbar.
  - Semantics: the span is a link "Search #launch".
- **Test notes.** Widget tests on `PostCard`, flag on and off.
- **Observability.** —
- **Budget.** 1 SearchPosts call per tap (counted in W4-15's line).
- **Flag.** `search`.
- **Seam.** Navigation goes through `AppRouter` helpers (`searchPath(query, tab)`), never string-built in widgets.
- **Parallel with W3:** yes (rebase if W3 touches `post_card.dart`).

### W4-17 — Explore screen and navigation  [owner: frontend-developer] [size: M] [depends: W4-14; W4-10 for the dev check]  Status: Open
- **Description.** `/explore` as a shell destination:
  - a two-row sticky header: the search pill, then a one-tab `AppTabBar` "Trending";
  - a trends list (rank and grey meta "Trending", bold `#tag`, grey "N posts"; tap → W4-16 route) with up to 10 rows and a "Show more" that expands to 30;
  - the who-to-follow slot (W4-19);
  - an empty state, "Nothing is trending yet", when the list is empty;
  - with `trends` off, the trends section is absent (search only).

  Navigation:
  - an Explore destination in `MainShell` second, after Home (X order; bar, rail and drawer per `08_navigation_flows.md`, at most 5 bar items), with the filled glyph when selected;
  - it needs `search` and `ui_shell`;
  - the legacy chrome (`ui_shell` off) gets no Explore.

  Not built (F7): the News, Sports and Entertainment tabs, the hero, "Posts for you" and the gear.
- **Capture.** Desktop Explore is MEASURED (`explore.md`) and mobile Explore is OBSERVED (`mobile/screens.md` §2). The Trending tab content is UNKNOWN; default rows follow the A11Y trends in `explore.md` §5.
- **Acceptance criteria.**
  - Given `search` + `ui_shell` on, then Explore is in the bar and rail.
  - Given `trends` on, then 1 GetTrends per 5 minutes across Explore and the side column (shared cubit).
  - Given `search` off, then no destination.
- **Test notes.** Widget tests at 360 / 600 / 1200, light and dark, 3 text scales; the shell destination order; back behaviour (Explore is a root).
- **Observability.** —
- **Budget.** GetTrends ≤ 1 per 5 minutes per client.
- **Flag.** `search` + `ui_shell` (destination); `trends` (trends section); W3's flag (who-to-follow slot).
- **Seam.** `TrendsCubit` (app-level, 5-minute cache) is shared with W4-18.
- **Parallel with W3:** shell nav files (`MainShell`, `AppBottomBar`, rail, `AppDrawer`) may conflict with W3 UI changes; merge in turn.

### W4-18 — Desktop side column  [owner: frontend-developer] [size: S] [depends: W4-17]  Status: Open
- **Description.**
  - At ≥ 1200 dp, `AppSideColumn` gains, at the top, the search pill (it opens the W4-14 overlay) and a "What's happening" card: 1 dp `#2f3336` outline, 16 dp gaps, the top 5 trends and "Show more" → `/explore` (`explore.md` §5).
  - On `/explore` itself the side search pill is hidden, as on X (the pill moves into the centre header).
  - It needs `search`, plus `trends` for the card.
- **Acceptance criteria.**
  - Given 1200 dp on Home, then the pill and card show.
  - Given `/explore`, then no side pill.
  - Given `trends` off, then no card.
- **Test notes.** Widget tests at 1200 / 1536; the responsive matrix.
- **Observability.** —
- **Budget.** Shares the `TrendsCubit` cache (0 extra calls).
- **Flag.** `search` + `ui_shell` (pill); `trends` (card).
- **Seam.** Side-column cards stay presentational (no fetch inside `AppSideColumn`).
- **Parallel with W3:** yes.

### W4-19 — Who-to-follow card (renders W3's data)  [owner: frontend-developer] [size: S] [depends: W4-17, W3 suggestion RPC + widget]  Status: Open
- **Description.**
  - A "Who to follow" card (outlined, 3 rows of `UserListRow` with `FollowButton`, a "Show more" link to W3's full list) in the Explore slot and the desktop side column.
  - Data comes only from W3's repository and flag.
  - With W3's flag off, or before W3 ships, the slot renders nothing.
  - W4 adds no RPC, no query and no cache for suggestions.
- **Acceptance criteria.**
  - Given W3's flag on, then 3 rows render from W3's call.
  - Given it off, then no card and no call.
  - Given a follow from the card, then the row's button updates through `RelationshipCubit`.
- **Test notes.** Widget tests at 3 widths, light and dark.
- **Observability.** —
- **Budget.** W3's line: one call per Explore open plus side-column mounts under W3's client cache.
- **Flag.** W3's suggestion flag (name set by the W3 plan) + `search` + `ui_shell` (the Explore placement).
- **Seam.** W3's suggestion repository is the only data source.
- **Parallel with W3:** **depends on W3.**

### W4-20 — Backend tests  [owner: tester] [size: M] [depends: W4-5, W4-8, W4-10]  Status: Open
- **Description.** Integration tests on emulators:
  - flag modes off / allowlist / percent / on for `search` and `trends`, with the refresh kill switch (`off` only);
  - the grammar table (valid, too short, too long, control and bidi characters, `#` with a digits-only body), each rejection at 0 reads;
  - `budgettest` per the RPC table;
  - the block oracle (People and Posts byte-identity for a blocking user vs a non-existent one);
  - cursor tampering and binding (another uid, another tag, another tab, expired);
  - the D6 drop matrix on hashtag results;
  - rate limits and `search_daily`;
  - trends: distinct authors, min authors, denylist, `!Visible()`, cap and resume, readonly, the composite cron status matrix;
  - the guard-test row.

  Coverage on `internal/` stays at 70 % or more.
- **Acceptance criteria.** Every acceptance criterion in W4-3 to W4-10 has a named test; `make test-int` is green.
- **Test notes.** Load shapes for the trigger scenarios: one hot tag at 50 posts a minute and a 600-entry typeahead burst (with W4-23).
- **Observability.** —
- **Budget.** 0 (emulators).
- **Flag.** Under test: `search` and `trends` in every mode, plus the refresh kill switch.
- **Seam.** —
- **Parallel with W3:** yes.

### W4-21 — Client tests  [owner: tester] [size: S] [depends: W4-14 to W4-18]  Status: Open
- **Description.** The cross-screen responsive matrix:
  - field → overlay → results → hashtag tap → Explore → side column;
  - flag combinations (`search` × `trends` × `ui_shell` × W3's flag);
  - sign-out clears recent searches;
  - text scale 2.0 overflow checks.
- **Acceptance criteria.** All new widgets are covered at 360 / 600 / 1200, light and dark; no overflow at 2.0.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `search` × `trends` × `ui_shell` × W3's flag.
- **Seam.** —
- **Parallel with W3:** yes.

### W4-22 — Security review  [owner: security-auditor] [size: S] [depends: W4-5, W4-8, W4-10, W4-14]  Status: Open
- **Description.** A threat model for the new public reads:
  - handle enumeration (cap 20, no pagination, 2-character minimum, 30/min × 3 instances, `search_daily` 300 × 3, read budget);
  - hashtag scraping (sealed cursors, page ≤ 50);
  - the block oracle in People and Posts;
  - query logging (no raw text);
  - trend manipulation (distinct authors, min 3, denylist, kill switch) and offensive-tag exposure;
  - local recent-search storage on a shared device;
  - the composite cron route (OIDC, no new public route);
  - the `nameKeys` privacy note if F2 = yes.

  Findings are fixed or ticketed before any dev allowlist.
- **Acceptance criteria.** A report in `docs/reviews/` with no open Critical or High findings.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Reviews the `search` and `trends` gates and the refresh kill switch.
- **Seam.** Checks the rate-limit multiplication and the `stage-ladder` scraping vectors.
- **Parallel with W3:** yes.

### W4-23 — Cost report  [owner: sre-performance] [size: S] [depends: W4-8, W4-10]  Status: Open
- **Description.**
  - Add the W4 rows (+36.6 reads per DAU, about 0 writes, 5.1 requests) to `docs/reviews/cost-model.md` §2-§3, alongside W2's if W2-15 has not landed.
  - Run an emulator load smoke: `make loadtest SCENARIO=search` (typeahead burst, hashtag page 1 with a warm and a cold entry, trends refresh at 2,000 posts).
  - Measure the response sizes behind the 41 KB/DAU/day egress assumption.
  - Name the triggers: search reads > 15 % of daily Firestore reads for 7 days; the unsupported-query share; and posts/day above the per-run cap (F1 A).
- **Acceptance criteria.** The model updated with measured reads per call (± 25 % of this plan, or this plan's table corrected); a k6 script added under `loadtest/`.
- **Test notes.** —
- **Observability.** A Logs Explorer query for `query_kind` and `fs_reads` in `cost-model.md` §9 (no new log-based metric or alert policy).
- **Budget.** 0 (emulators, no cloud load test).
- **Flag.** n/a (it measures with both flags on).
- **Seam.** —
- **Parallel with W3:** yes.

### W4-24 — Dev rollout  [owner: production-deployer] [size: S] [depends: W4-20, W4-22, W4-23, ADR merged]  Status: Open
- **Description.**
  - Show the founder a **targeted** dev Terraform plan (`docs/plans/roadmap.md` section 9, item 3.10: a full dev apply is unsafe) for `feature_search*`, `feature_trends*` and the search config env vars.
  - If A4 = fieldOverride: the `trends.items` override deploys with the dev deploy workflow's `firebase deploy --only firestore:indexes` after merge. For prod it waits for the held release (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.2) and must be deployed before `FEATURE_TRENDS` leaves `off` there.
  - Apply only on OK, allowlist 3 test uids, then smoke: people search, hashtag tap → Top / Latest / Media, Explore with trends.
  - Exercising the refresh in dev needs a direct OIDC call to `/internal/cron/trends-refresh` (no dev Scheduler job). That needs the opt-in `cron_test_invoker` grant recreated by a targeted apply with the founder's OK, and removed after (`docs/runbooks/credit-sunset-pause-resume.md`, dated step 1.20, ADR-0021 D1).
  - Prod: no change (on hold). With F1 = A, the prod job is a separate plan-then-OK at MVP launch, after confirming 2 jobs exist on the billing account.
- **Acceptance criteria.** The dev smoke passes; the flags are back to their planned state; the grant is removed.
- **Test notes.** —
- **Observability.** Check the `trends_refresh` line and the search request lines in dev logs.
- **Budget.** A handful of reads in the dev project's free quota.
- **Flag.** Dev: `feature_search` and `feature_trends` set to allowlist (3 uids); prod stays `off`.
- **Seam.** —
- **Parallel with W3:** serialise dev applies with W3's rollout.

## Rollout plan
- **Dev.** Allowlist (3 uids) for `search`, then `trends`.
- **Prod.** The founder's MVP launch decision: allowlist → percent 5 → 25 → 100 → `on`. Each step is a Terraform change plus a tagged revision (ADR-0019). Before each step, check the `cost-model.md` headroom and the error rate. `trends` follows `search`, never ahead.
- **Rollback triggers:**
  - error rate on search RPCs above 2 % for 15 min;
  - search reads per DAU above twice the W4-23 model for a day;
  - an abusive or offensive tag trending (first `TRENDS_DENYLIST`, else `FEATURE_TRENDS=off`).
- **Kill switches:**
  - `FEATURE_SEARCH=off`: the RPCs reject and the client hides the field, the Explore destination and the tap-through (back to the snackbar).
  - `FEATURE_TRENDS=off`: the refresh stops (`GloballyOff`) and the trends sections disappear.
  - Both need a deploy. No data migration: the trends doc stays and is harmless.
- **Client-only pieces** roll back with their flags or by revert.

## Risks
| Risk | Mitigation |
|---|---|
| Users expect full-text search; Stage 0 searches handles and exact hashtags only | the F4 hint; the A7 trigger measures demand (unsupported-query share); the Postgres FTS ADR when it fires |
| Top is a re-rank of the newest 30, so an older popular post never shows | the "See latest" footer; honest copy; engine target in A7 |
| Daily trends (F1 B) are up to 24 h stale and empty at low volume | the "Trending today" label, `computed_at`, the empty state; F1 A when posts/day pass the cap or the founder wants hourly |
| Sockpuppet rings (3 or more accounts) push a tag | distinct-author counting, min 3, denylist, `FEATURE_TRENDS=off`; later weight by account age (needs reads, an ADR) |
| Handle enumeration | cap 20, no paging, 2-character minimum, rate × 3 instances, daily cap, read budget; handles are public on profiles anyway |
| The prefix and tag caches are per instance (3 cold caches) | the 60 s bound is stated; hit rates in the model are conservative |
| Trends composed into `daily-maintenance` delay or break the deletion backstop | backstop first and unchanged, status code from the backstop only, a trends sub-deadline, skip and resume |
| Merge conflicts with W3 in shared files | the parallel column above; one PR at a time |
| Uncaptured visuals (suggestions, results tabs, empty states, Trending tab) | X-like defaults stated per ticket; a founder capture adjusts them in a follow-up PR |
| ADR number clash with W3 | resolved: W4 took ADR-0028, the next free number when the PR opened |
| The Media tab's post-filter returns short or empty pages | allowed by the contract; A3 moves to an index if W3 adds `hasMedia` |
