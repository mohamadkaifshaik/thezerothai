# 0028. Search, trends and Explore at Stage 0 (W4)
Status: Proposed
Date: 2026-10-30
Deciders: architect (proposal); the founder accepts by merging the PR. The founder said "start W4" without answering
F1 to F8, so **each F is decided by its default and the founder may override it at acceptance** (table below).

Plan: `docs/plans/ui-w4-discovery-search.md`, ticket W4-1 (this ADR) and W4-2 (`proto/dzeroth/search/v1/search.proto`,
same PR). The plan asked for "ADR-0024 (or the next free number)"; 0024 to 0027 went to W3 Part A, W3 Part B, W8 and
W7, so this is 0028. W5 and W6 planned with the same "next free number" rule and take the next free numbers.

Related ADRs:
- ADR-0003: data model (`users.handleLower`, the `posts (hashtags CONTAINS, createdAt DESC)` index).
- ADR-0004 and ADR-0010: pull-on-read, D5 (per-uid read budget), D6 (feed filtering), D8 (hashtag grammar), D9 (text
  normalisation), D14 (sealed tokens).
- ADR-0008: D2 (`blockedBy` overflow), D6 (flags are env vars), D9 (block oracle).
- ADR-0011: the `daily-maintenance` backstop. A dated note in this PR (F1 = B).
- ADR-0021: D1 (cron routes, the Scheduler count).
- ADR-0022: the credit window. **Nothing here depends on it.**
- ADR-0024: D4 (`posts.hasMedia`), D8 (`ListSuggestedUsers`, the who-to-follow data W4 renders).
- ADR-0025: private accounts. `posts.Audience` decides every read path, search included.

## Context
Home is chronological Following only (founder, 2026-10-22), so a new user has no way to reach accounts and topics they
do not already follow. W4 adds people search, hashtag results, hashtag tap-through, Explore and trends. `CLAUDE.md`
fixes the Stage 0 means: Firestore prefix queries for handles, `array-contains` for hashtags, **no search engine**, no
fixed cost.

**Measured and modelled state (`docs/reviews/cost-model.md`, 2026-10-29 W7-23 block):** 321.0 reads, 39.56 writes,
8.5 deletes and 52.3 requests per DAU per day with W2, W3 Part A, W3 Part B and W7 on, plus the protected-set refresh.
Free reads run out at about **156 DAU**, writes at about 506, Cloud Run requests at about 1,257 and vCPU-s at about
1,131 DAU. The Stage 0 bill is about **INR 479 / 1,755 / 4,205** a month at 300 / 1,000 / 3,000 DAU.

**What changed since the plan was written (plan "What exists already", `main` 46b9e0f).** Each changes this ADR:
1. **Private accounts shipped (ADR-0025).** The plan's A9 treats them as deferred ("every post is PUBLIC today"). That
   is no longer true: stored `visibility` must never be filtered on, and every read path decides through
   `posts.Audience`. SearchPosts goes through `Audience` with `SurfaceList` from day one (D3), and the trends sweep skips
   protected authors (D6).
2. **`posts.hasMedia` exists (ADR-0024 D4)** with the `opsctl backfill-has-media` one-off. A3 is no longer hypothetical
   (D3, MEDIA).
3. **Who to follow exists:** `GraphService.ListSuggestedUsers`, flag `follow_suggestions`, 48 h client cache
   (ADR-0024 D8, Amendment 2). W4-19 can start once W4-17 lands (D12).
4. **The cost baseline moved** (above). Cloud Run requests and vCPU-s are now billed at 3,000 DAU, and the plan did not
   price vCPU-s, so W4's 3,000 DAU line rises from the plan's INR 169 to about **INR 275** (Cost impact).
5. `posts.Reader` gained `ByAuthorMedia` and `ByAuthorKind`. `ByHashtag` and `CreatedAfter` (D11) follow their
   contract (unfiltered, `Hidden()` set, reads = len(result), minimum 1).

## Founder decisions F1 to F8 (decided by default, founder may override at acceptance)
INR are a month, the W4 increment, at 300 / 1,000 / 3,000 DAU, priced as the `cost-model.md` §5 W7 block (Mumbai prices
of §7, INR 95 per USD, 0.1 s of vCPU per request).

| # | Question | Options | Default (applied) | INR 300 / 1,000 / 3,000 |
|---|---|---|---|---|
| F1 | Where the trends sweep runs | (A) a third free Scheduler job `trends-refresh`, hourly; (B) piggyback on `daily-maintenance`, daily; (C) piggyback on `publish-scheduled`, hourly | **B**. **Scheduler count: 2 of 3 free jobs used on the billing account** (`daily-maintenance` live in prod; `publish-scheduled` defined in `envs/prod/main.tf` but not applied; dev has none). **Option A spends the third**, after which any job is about USD 0.10/month and needs an ADR. C couples trends to a job not applied in prod | B: 0 / 0 / 0 (1 write a day). A or C: +23 writes a day, ≈ 0 / 0.07 / 0.07. Reads are the same in every option (1 per new post) |
| F2 | Display-name search in v1 | (no) handle prefix only; (yes) a derived `users.nameKeys` array (A8) | **No.** W4-11 and W4-12 stay conditional | no: 0. yes: +13.5 reads per DAU worst (1.5 × 5 + 0.3 × 20) ≈ 4.1 / 13.7 / 41.0, + a one-off 1 write per user, + about 2 KB of index per user |
| F3 | One flag or two | one `FEATURE_SEARCH`; two, `FEATURE_SEARCH` + `FEATURE_TRENDS` | **Two** (D8). Trends show user-generated tags to everyone, so they need their own kill switch | 0 / 0 / 0 |
| F4 | A plain word (not `@`, not `#`) | people by handle prefix + posts with the exact tag `#word`; full-text post search | **People by handle prefix + the exact tag**; the posts tabs show "Search posts by #hashtag" when the word is not a tag body. Full text is deferred with its trigger (Stage ladder) | default: inside the W4 total. Full text needs Cloud SQL or a VM: a fixed monthly fee (estimate INR 750+ for the smallest Cloud SQL instance, unverified), excluded at Stage 0 by `CLAUDE.md` |
| F5 | Hashtag tap-through in W4 | yes (W4-16); no (stays in W2's "coming soon") | **Yes**: a tap opens `/search?q=%23tag` on Top | 0.5 of the 1.0 page-1 SearchPosts per DAU: ≈ 3 / 10 / 41 (inside the W4 total) |
| F6 | Trend rules | as the plan | **≥ 3 distinct authors in the window (`TRENDS_MIN_AUTHORS`), ranked by distinct authors, then posts, then tag; Explore shows 10, the Trending list 30; `TRENDS_DENYLIST` env var; `FEATURE_TRENDS=off`** | 0 / 0 / 0 (in memory) |
| F7 | Explore content | search pill, one "Trending" tab, trends, who to follow; vs News / Sports / Entertainment tabs, promoted hero, "Posts for you", settings gear | **The first set only** (no external feed, no ad, no For You) | ≈ 0: GetTrends is 0.1 reads per DAU; who to follow stays inside ADR-0024's 48 h client cache (+0 calls, D12) |
| F8 | Signed-in only | signed-in; a public search page | **Signed-in only.** A signed-out search is a new unauthenticated read and scraping vector and needs its own ADR | 0 / 0 / 0 |

## Options
### A. Search backend
- **A1. Firestore at Stage 0 (chosen).** Handle prefix range on `users.handleLower` (automatic single-field index) and
  `hashtags array-contains` on the existing composite index. Pros: INR 0 idle, no new service, no index change. Cons:
  no words in post text, no display names (F2), Top is a bounded re-rank. Cost: idle 0; W4 total ≈ INR 15 / 50 / 275.
- **A2. Postgres FTS on Cloud SQL, or Typesense on a VM.** Pros: real full text, ranking, names. Cons: a fixed monthly
  fee (on the "not used at Stage 0" list), a second datastore to keep in sync, an indexer job. Cost: idle INR 750+ a
  month (estimate), more at 10× DAU. Rejected for Stage 0; it is the Stage 2 target with a trigger.

### B. People query (plan A1)
- **B1. `users` range on `handleLower` (chosen):** `handleLower >= p AND handleLower < succ(p) ORDER BY handleLower
  LIMIT n`, status and `blockedBy` filtered in memory. n reads.
- **B2. `handles` doc-id range plus a `GetAll` of `users`:** 2n reads. Rejected.
- **B3. B1 with `status == ACTIVE` in the query:** needs a composite index (gate file). Not worth it: suspended and
  deleting users are rare, and a short result is allowed.

### C. Trends
- **C1. One sweep over new posts with distinct-author counts in memory, one doc (chosen).** Reads 1 per new post, 1 write
  per run, no uid persisted.
- **C2. Per-tag counters incremented on post create.** A write per tag per post, a hot doc for any popular tag (rule 3),
  and distinct authors need per-author state. Rejected: more writes, contention, user data in counters.
- **C3. A stream job or Pub/Sub-batched counters.** The Stage 2 target when one run cannot keep up (Stage ladder).

### D. `trends/current` index exemption (plan A4)
- **D-a. fieldOverride `trends.items` `indexes: []` (chosen, the plan default and the repo convention).** Founder-gated
  files (`firebase/firestore.indexes.json`, `firebase/field-overrides.ack`), added by **W4-9, not this PR**.
- **D-b. `items` as an opaque bytes field.** No gate-file change, but the doc is not readable in the console and the
  format is a second codec. Rejected.

## Decision

### D1. Query grammar and normalisation (validated before any read; 0 reads on rejection)
Settled with W4-13 (the client parser, PR #464) on 2026-10-30. Client and server apply the same rules in the same order.
1. **Normalise:** NFC, trim, Unicode lower-case.
2. **Sigil:** at most one leading sigil is recognised, `@` or `#`. It is removed **before** the length check.
3. **Invalid → INVALID_ARGUMENT + VALIDATION, `field=query`:**
   - nothing left after step 2 (an empty query, `@` alone, `#` alone);
   - **more than 50 code points after step 2**, so the sigil does **not** count: `#` + a 50-code-point tag body is
     valid (51 code points in all), and a tag tap-through can always search its own tag;
   - a control character (`\p{Cc}`) or a bidi formatting control (ADR-0010 D9) anywhere.
4. **People** (SearchPeople, and the client's People tab and typeahead):
   - a `#` sigil → unsupported;
   - otherwise (an `@` sigil or none) the rest must match `[a-z0-9_]{1,15}`:
     - **1 character → VALIDATION `query` ("too short")**; `@a` and `a` alike;
     - **2 to 15 characters → a handle prefix** (`@ab` and `ab` are valid). Full handles are 3 to 15
       (`pkg/platform/handle`); 2 is the minimum for a *prefix*.
   - Anything else (a space, another character, more than 15) → an empty result with `unsupported_query = true`, 0
     Firestore reads.
5. **Posts** (SearchPosts, the Top / Latest / Media tabs):
   - an `@` sigil → unsupported;
   - otherwise (a `#` sigil or none) the rest must be exactly one ADR-0010 D8 hashtag body, decided by the same
     extractor (`posts/text.Hashtags("#" + rest)` returns exactly `[rest]`). This includes **a 1-code-point body**: `#a`
     and the plain word `a` both search the tag `a`. D8 allows such tags, and a tap on `#a` in a post must work. So **a
     one-character plain word is valid for Posts and too short for People.** The client skips the SearchPeople call
     and its People tab shows the "too short" hint, while the posts tabs search. Typeahead still makes no call below 2
     characters (W4-14), because typeahead suggests people.
   - `normalized_tag` is the stored form (lower-case, NFC).
   - Anything else (`#123` with no letter, several words, `#go!`) → empty with `unsupported_query = true`, 0 reads.
6. **Range upper bound:** `succ(p)` replaces the last character by the next code point. The class is ASCII
   (`_` → `` ` ``, `z` → `{`, `9` → `:`), so it never overflows. The `firestore-data-model` skill's prefix line
   `q + "..."` has lost its U+F8FF sentinel character; do not copy it (follow-up F-2).
7. **GetTrends `prefix`:** optional; one leading `#` removed; at most 50 code points after that; control or bidi
   characters → VALIDATION `field=prefix`. Characters outside the D8 body class simply match nothing.
8. **Shared fixture:** `testdata/search_query_grammar.json`, read by the Go and Dart tests, as
   `post_text_grammar.json` is for whole post text. Each case is
   `{ "query": "...", "people": {"result": "prefix|too_short|unsupported|invalid", "prefix": "..."}, "posts": {"result": "tag|unsupported|invalid", "tag": "..."} }`.
   - It must cover every example in steps 2 to 5: `@`, `#`, `@a`, `a`, `ab`, `@ab`, `#a`, `@AbC`, `#Go` / `go`, `#123`,
     `#भारत`, `#café`, `go lang`, `#go!`, a 50-code-point body with and without `#`, a 51-code-point body, a body with a
     bidi control, and a 16-character handle-class word.
   - **The W4-13 follow-up PR (frontend-developer) adds the fixture** and the Dart test. W4-5 (People) and W4-7 (Posts)
     load it in their Go tests.
   - Where this ADR and the fixture disagree, the ADR wins and the fixture is fixed.
9. **Limits:** a negative `limit` or `page_size` → VALIDATION (`field=limit` or `page_size`); values above the maximum are
   clamped (the repo convention).

### D2. People search (plan A1; F2 = no)
`search.Service.People`:
1. Validate (D1).
2. The **prefix entry**: `cache.LRU` keyed by `(prefix, limit)`, 60 s TTL, `CACHE_SEARCH_PREFIX_ENTRIES` (2,000), shared
   across viewers, filled by `identity.Directory.SearchHandles(prefix, limit)` (B1; identity owns `users`, search never
   queries it). The entry holds raw profiles, status included.
3. Filter per viewer, from `graph.Reader.Snapshot` (cached 60 s): drop users who are not ACTIVE and users in the caller's
   `blockedBy` (the response is then byte-identical to a missing user's, ADR-0008 D9). Users the caller blocks or mutes
   **stay**, with `relationship.blocking` / `muting` set, so the row shows "Unblock".
4. **`blockedByOverflow` (ADR-0008 D2):** no per-row graph read. Fail closed as `service_bookmarks_list.go` and
   `timeline.embedAllowed` do: keep only the caller and accounts the caller follows. The worst-case reads hold.
5. **Protected accounts are listed** (as on X), with `user.is_private` set (a live row; `common.proto`'s comment is
   extended in this PR). Listing a protected account reveals only its public profile.
6. `relationship` from the caller's graph (follow state incl. REQUESTED, blocking, muting), 0 extra reads. `since` unset.
7. At most `limit` rows (0 → 10, max 20), **no page token**. The caller is included when matched.

### D3. Posts search: four tabs at Stage 0 (plan A2, A3, A6, A9)
**The tag entry:** the newest 30 posts per tag, `cache.LRU` with 60 s TTL and `CACHE_SEARCH_TAG_ENTRIES` (500), shared
across viewers, filled by one `posts.Reader.ByHashtag(tag, window{}, 30)`. It holds unfiltered posts.

**Serve-time filtering (every tab, per viewer, after the cache):**
- `!Visible()` posts dropped (a takedown reaches a warm entry at once: the flag is on the cached post, and the post cache
  is ≤ 60 s).
- ADR-0010 D6, the Home column: authors the caller blocks, who block the caller, or whom the caller mutes are dropped,
  including a QUOTE's embedded author.
- **`posts.Audience` with `SurfaceList` (ADR-0025):** a post by a protected author the caller neither is nor follows is
  dropped; a QUOTE of such a post is kept with `embed_viewer_state = PROTECTED` and the embed stripped. If the protected
  set cannot be trusted (`PROTECTED_SET_MAX_STALE`), the call fails closed with UNAVAILABLE, as every other list does.
- `blockedByOverflow`: keep only the caller's posts and posts by followed authors; foreign embeds are dropped.
- Viewer flags through `posts.HydrateViewer` (one cached `userLikes` read with `engagement` or `bookmarks` on).
- A short page reveals nothing: `next_page_token` follows the query, not the filtered count.

**Tabs:**
- **LATEST:** page 1 = the first `page_size` items of the entry (`page_size` ≤ 30). A `page_size` above 30 skips the
  entry and runs one `ByHashtag(page_size)`. Older pages: a sealed cursor (D5) and `ByHashtag` with `Before`.
- **TOP (`SEARCH_TAB_UNSPECIFIED` means TOP):** the filtered entry, posts from the last 7 days, ranked by
  `likes + 2 × reposts + 2 × quotes + replies` (counts as cached, ≤ 60 s stale), ties newest first. One page of at most
  20; `next_page_token` always `""`; the client shows "See latest". A real ranking replaces this behind the same tab.
- **MEDIA (A3, the default stays the bounded post-filter):** page 1 = the entry's posts that carry **their own** images.
  The filter is `len(media) > 0` on the post, **not** `hasMedia`, so it does not depend on `opsctl backfill-has-media`
  having run in a project. A QUOTE's embedded media does not count. Older: a sealed MEDIA cursor scans 30 older tagged
  posts per call and returns the media ones; short or empty pages are allowed and the token continues while the scan has
  more. **Switch** (Stage ladder): a composite index `posts (hashtags CONTAINS, hasMedia ASC, createdAt DESC)` (a gate
  file) with `hasMedia == true` in the query, after the backfill ran in that project.
- **People tab:** the client calls SearchPeople with the same query (no SearchPosts tab value).

### D4. Caches and staleness bounds
| Cached read | Bound | Instance / client story |
|---|---|---|
| Prefix entry (shared, not viewer-scoped) | 60 s: a new handle or a rename shows within 60 s | per instance (≤ 3 cold copies); viewer filtering after the cache from the 60 s graph snapshot |
| Tag entry (newest 30 per tag, shared) | 60 s: a new tagged post reaches Top, Latest page 1 and Media page 1 within 60 s | per instance; `!Visible()`, D6 and Audience applied at serve time |
| `trends/current` | 10 min after a refresh; with F1 B a tag is up to 24 h + 10 min old (hourly + 10 min with A) | per instance; ≤ 1 read per instance per 10 min ⇒ ≤ 432 reads a day at 3 instances whatever the DAU; `computed_at` lets the UI say "Trending today" |
| Client | recent searches local and exact; trends 5 min (one app-level `TrendsCubit` shared by Explore and the side column); results in session memory only | drift / IndexedDB for recent searches only, per uid, wiped on sign-out (`SessionEpoch`) |

All three server caches sit behind small interfaces in `internal/search`, so Memorystore can replace them by ADR at
Stage 2 with no caller change.

### D5. Tokens (plan A6)
`cursor.Cursor` sealed with the existing codec, binding `search|<uid>|<tag>|<tab>`, **24 h TTL** (`cursor.DecodeTTL`),
kinds LATEST (the `(createdAt, id)` of the last returned query row) and MEDIA (the scan position). TOP issues no token.
An expired, foreign or tampered token, or one used on another tag or tab → VALIDATION `field=page_token`, 0 reads.
No `since_token`: search results are not refreshed incrementally.

### D6. Trends: collection, shape, sweep (plan A4; F6)
**Owner:** `search`. **Doc:** `trends/current` (one doc, < 100 KB):
`{schemaVersion: 1, items: [{tag, posts, authors}] (≤ 100, rank order), windowStart, watermark: {at, id}, computedAt,
postsScanned, backlog (bool)}`. Tags and counts only, **no uid**.

**Index exemption (founder-gated, W4-9's PR, not this one):** in `firebase/firestore.indexes.json` `fieldOverrides`,
next to the `users.displayName` entry:
```json
{ "collectionGroup": "trends", "fieldPath": "items", "indexes": [] }
```
plus its hash line in `firebase/field-overrides.ack` (the promotion validator's acknowledgement step). Both files are
CODEOWNERS gate files and need the founder's review. The override deploys with `firebase deploy --only firestore:indexes`
in the dev deploy workflow; prod gets it before `FEATURE_TRENDS` leaves `off` there.

**`search.TrendsRefresher.Refresh(ctx)`:**
1. Switches first: `Registry.GloballyOff("trends")` or `DEGRADED_MODE=readonly` → 0 reads, 0 writes, `trends_skipped
   reason=flag_off|readonly`. (Only `off` is a job kill switch: percent 0 is not, `flag-rollout`.)
2. Read `trends/current` (1 read). If `computedAt` is younger than `TRENDS_MIN_INTERVAL` (default 12 h; 50 min with F1 A)
   and the last run was not `backlog`, stop: `trends_skipped reason=fresh`, 0 writes. **This makes a Scheduler retry of
   the backstop (D7) harmless**: without it a retry minutes later would replace the day's list with an almost empty
   window.
3. Page `posts.Reader.CreatedAfter(watermark, 500)` up to `TRENDS_MAX_POSTS_PER_RUN` (2,000). First run (no doc):
   from `now − 24 h`. A watermark older than 48 h jumps to `now − 24 h` (`trends_backlog_skipped`), so a stuck sweep
   never shows a week-old list as "today".
4. Skip `!Visible()` posts, REPOST kinds (they store `hashtags: []` anyway), and **posts by protected authors** (the
   instance's `identity.ProtectedAuthors` copy, read on its detached `protected_set_reads` counter; if the set is
   unavailable the run fails and resumes next time). A protect after the run is reflected at the next run.
5. Count per tag: distinct authors (an in-memory set, never persisted) and posts.
6. Drop `TRENDS_DENYLIST` tags (comma-separated tag bodies, normalised like D1) and tags under `TRENDS_MIN_AUTHORS` (3).
   Rank by authors, then posts, then tag. Keep the top 100.
7. Write the doc in **1 write** (`Set`; the doc holds no user data, so a write after an eraser cannot resurrect anything).
   The cap reached → `backlog = true`, the watermark stops at the last read post, the next run resumes (`trends_backlog`).

**Window:** `[windowStart, watermark]` = the posts since the previous run, about 24 h with F1 B. With F1 A the window
becomes the hour; a rolling 24 h list with hourly freshness needs per-hour buckets of author sets and is designed only
when F1 A is chosen (a dated note on this ADR).

**`CreatedAfter` projection:** `Select(hashtags, authorId, moderation, createdAt, kind)` still bills 1 read per doc. A
projected post is partial: it **must never be stored in `posts.Cache`** or the author-recent cache.

**Lifecycle:** `lifecycle_collections_guard_test.go` gets a `trends` row, "no user data", no eraser step, not exported.

### D7. Cron host (F1 = B; plan A5)
- `apiserver` mounts `/internal/cron/daily-maintenance` as a **wrapper**: it calls `lifecycle.CronHandler()` unchanged
  through a status-capturing response writer, then runs the trends step, then writes **the backstop's captured status
  only** (204, or 500 so Scheduler retries the backstop). No change to `identity/lifecycle_jobs.go`.
- The trends step gets `min(10 s, 28 s − elapsed)` and is skipped with `trends_skipped reason=deadline` when less than
  3 s is left. It runs under its own `recoverPanic` and `budget` counter; a trends failure or panic is logged and
  reported to Error Reporting, never turned into a status.
- **Deadline chain:** the backstop runs under its own 25 s deadline. `daily-maintenance` has no
  `attempt_deadline_seconds`, so Scheduler's attempt deadline is the module default 30 s, equal to Cloud Run's 30 s
  request timeout. The 28 s cut-off leaves 2 s of margin. A backstop that takes 25 s leaves 3 s, so trends is skipped
  that day and resumes from its watermark. Follow-up option (not needed now): give the job
  `attempt_deadline_seconds = 60` as `publish-scheduled` has (a prod Terraform change, plan-then-OK).
- `/internal/cron/trends-refresh` is also mounted alone (OIDC, POST only, 25 s deadline; 204, or 500 only when the
  first page fails), for dev (a direct OIDC call; dev has no Scheduler jobs) and for F1 A.
- **F1 A later** is Terraform only: one `trends-refresh` entry in `envs/prod/main.tf` `jobs` (3 of 3) and
  `TRENDS_MIN_INTERVAL` 50 min; no code change. A dated note on ADR-0021 D1 records the count then.

### D8. Flags (F3)
- `FEATURE_SEARCH` (wire `search`): SearchPeople and SearchPosts, per caller. The client gates the search field,
  `/search`, the hashtag tap-through and the Explore destination on it.
- `FEATURE_TRENDS` (wire `trends`): GetTrends per caller; the refresh step honours only `GloballyOff`.
- Off → FAILED_PRECONDITION + FEATURE_DISABLED, `metadata["feature"] = "search"` or `"trends"`, 0 reads.
- **Ceilings** (W4-3, `scripts/promotion/flag-ceiling.json`, founder-gated): `SEARCH` and `TRENDS` dev
  `{"mode": "allowlist", "max_allowlist": 6, "max_percent": 0}` (the plan said 3; #463 made 6 the dev ceiling of every
  allowlist flag), no prod raise. Terraform `feature_search*` / `feature_trends*` default `off`.
- `trends` never ramps ahead of `search` (the trend rows link to search).

### D9. Abuse limits (rule 11; config; in memory per instance, so × 3 instances)
| Config | Default | Effective at 3 instances |
|---|---|---|
| `RATE_LIMIT_SEARCH_PEOPLE_PER_MIN` | 30 | 90/min |
| `RATE_LIMIT_SEARCH_POSTS_PER_MIN` | 20 | 60/min |
| `SEARCH_CALLS_PER_DAY` (one `ratelimit.DailyCap` for both RPCs, `limit_name` `search_daily`) | 300 | ≤ 900/day |
| GetTrends | the 60/min default bucket | 180/min |
| `CACHE_SEARCH_PREFIX_ENTRIES` / `CACHE_SEARCH_TAG_ENTRIES` | 2,000 / 500 | per instance |
| `TRENDS_MIN_AUTHORS` / `TRENDS_MAX_POSTS_PER_RUN` / `TRENDS_MIN_INTERVAL` / `TRENDS_DENYLIST` | 3 / 2,000 / 12 h / "" | one run at a time |
| Read budget (ADR-0010 D5) | 2,000 reads/uid/day | binds first: ≤ 2,368 reads per uid per day per instance |

- **Enumeration (`stage-ladder` scraping vectors):** people ≤ 20 per call with no token, 2-character minimum; worst
  900 × 20 = 18,000 handle rows per account per day, already public on profiles. Hashtag pages ≤ 50 behind a sealed,
  caller-bound 24 h token. Every call is charged to the read budget.
- **Trend manipulation:** distinct authors (one account at its 100 posts/day quota counts once), min 3, protected and
  hidden posts not counted, denylist, kill switch. Residual: sockpuppet rings of 3 or more accounts.
- All three RPCs need App Check plus an ID token and are `NO_SIDE_EFFECTS`, so they keep answering under
  `DEGRADED_MODE=readonly`.

### D10. Privacy and logs
- **Raw query text is never logged.** Request lines: `query_kind` (handle / hashtag / unsupported), `query_len`, `tab`,
  `results`, `dropped` (by cause: status / blocked / muted / protected / hidden), `cache_hit`, `fs_reads`.
- Refresh: one `trends_refresh` line with `trends_posts_scanned`, `trends_tags` (counted), `tags_kept`, `backlog`,
  `fs_reads`, `fs_writes`, `duration_ms`; `trends_skipped` with `reason` (deadline / fresh / readonly / flag_off). No uid.
- GetTrends: `results`, `cache_hit`, `fs_reads`, `computed_age_s`.
- Error Reporting on every internal error path. Recent searches stay on the device (per uid, cleared on sign-out).

### D11. Seams
- `search.Service`: `People(ctx, uid, query, limit)`, `Posts(ctx, uid, query, tab, pageSize, token)`, `Trends(ctx, uid,
  limit, prefix)`. Handlers call only it.
- `search.TrendsRefresher.Refresh(ctx)`; the cron host is wiring only (B ↔ A is W4-9b alone).
- `identity.Directory.SearchHandles(ctx, prefix, limit) ([]Profile, error)`: limit clamped 1..20, reads = len(result),
  minimum 1, raw profiles incl. status.
- `posts.Reader.ByHashtag(ctx, tag, window, limit)`: `hashtags array-contains tag ORDER BY createdAt DESC, __name__ DESC`,
  limit 1..50, the existing composite index (a composite carries `__name__` in its last field's direction, so DESC is
  served).
- `posts.Reader.CreatedAfter(ctx, after Position, limit)`: `createdAt > t` (and `__name__` tie-break) `ORDER BY createdAt
  ASC, __name__ ASC`, limit ≤ 500, projection (D6), the automatic single-field index. W4-6 confirms on the emulator and in
  dev that no composite is needed; if one is, stop and ask (gate file).
- Proto: the `SearchTab` enum (a new tab is additive), opaque tokens, `unsupported_query`.

### D12. Who to follow (W3, rendered by W4-19)
Data comes only from `GraphService.ListSuggestedUsers` (ADR-0024 D8, flag `follow_suggestions`) through W3's repository
and its **48 h client cache**. W4 adds no RPC, no query, no cache and **no calls beyond that cache**, so `cost-model.md`'s
0.63 calls per DAU is unchanged. The plan's "one call per Explore open" is superseded. Flag off → no card, no call.

### D13. Contract (W4-2, `proto/dzeroth/search/v1/search.proto`)
`SearchService` with `SearchPeople`, `SearchPosts`, `GetTrends`, all `NO_SIDE_EFFECTS`, no `idempotency_key` (no
mutation). Errors: VALIDATION `field=query|page_token|page_size|limit|prefix`; FEATURE_DISABLED `feature=search|trends`;
RATE_LIMITED (per-minute buckets, `search_daily`, the read budget); UNAVAILABLE when the protected set is stale.
**No new `ErrorReason` value** (the highest is `CANNOT_MESSAGE = 18`; the next free is 19).

## Cost impact
- **Fixed monthly cost added: INR 0.** No new GCP service, no Scheduler job (F1 B), no Pub/Sub topic, no composite index.
  One fieldOverride (an index exemption, free). Nothing depends on ADR-0022 credit items.
- **Vision units:** 0. **Storage:** `trends/current` < 100 KB. **Deletes:** 0. **Writes:** 1 a day (F1 B).

**Per RPC** (worst-case reads include the account-status interceptor; every call is charged to the ADR-0010 D5 per-uid
budget, max 53 per call, under `ReadBudgetMaxCallReads` = 269):
| RPC | Reads worst (cold) | Reads warm | Writes | Notes |
|---|---|---|---|---|
| SearchPeople, limit 5 / 20 | 7 / 22 (interceptor 1 + caller graph 1 + query ≤ limit, min 1) | 0–2 (prefix entry hit) | 0 | grammar rejection 0 reads; unsupported 0 Firestore reads |
| SearchPeople with F2 = yes | 12 / 42 (+ a `nameKeys` query) | 0–2 | 0 | conditional |
| SearchPosts TOP, LATEST page 1, MEDIA page 1 (page_size ≤ 30) | 33 (interceptor + graph + `userLikes` + tag entry 30) | 0–3 | 0 | one entry serves all three |
| SearchPosts LATEST page 1 at page_size 50 | 53 | — | 0 | skips the entry |
| SearchPosts LATEST older page (20 / 50) | 23 / 53 | — | 0 | sealed cursor |
| SearchPosts MEDIA older scan | 33 (scan cap 30) | — | 0 | short pages allowed |
| GetTrends (incl. `prefix`) | 2 (interceptor + `trends/current`) | 0–1 | 0 | ≤ 432 doc reads a day at 3 instances, any DAU |
| Trend refresh run (system) | 1 + new posts (≤ 2,001), + the detached protected-set copy | — | 1; 0 when skipped | 1 run a day (B); `fresh` / `flag_off` / `readonly` skips: 1 / 0 / 0 reads |

**Per DAU per day** (the plan's assumptions, W4-23 replaces them): SearchPeople typeahead 1.5 calls × 4 = 6.0; People
tab 0.3 × 12 = 3.6; SearchPosts page 1 1.0 × 19 = 19.0; older pages and Media scans 0.3 × 23 = 6.9; GetTrends 2.0 ×
0.05 = 0.1; refresh 1 per post (1.0 post per DAU) = 1.0 → **≈ 36.6 reads, ≈ 0 writes, 0 deletes, 5.1 requests,
≈ 41 KB egress**.

| INR per month (W4 increment) | 300 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|
| Firestore reads (36.6 × 30.42 = 1,113 per DAU-month, all billed) | 11.1 | 37.0 | 111.1 |
| Firestore writes / deletes | 0 | 0 | 0 |
| Cloud Run requests (+155 per DAU-month) | 0 | 0 (1.75M of 2M) | 17.7 |
| Cloud Run vCPU-s at 0.1 s a request (+15.5 per DAU-month) | 0 | 0 (174.6k of 180k) | **106.1** |
| Egress to India (≈ 41 KB per DAU per day, JSON) | 4.0 | 13.2 | 39.7 |
| **W4 total** | **≈ 15** | **≈ 50** | **≈ 275** |
| Upper bound if result images add to browsing (+10 GCS GETs × 15 KB per DAU per day; GCS egress free to about 2,100 DAU) | 15 | 50 | ≈ 466 (+156 egress, +35 Class B) |
| Stage 0 bill with W2, W3 A+B, W7 and W4 | 479 → **≈ 494** | 1,755 → **≈ 1,805** | 4,205 → **≈ 4,480** |

The plan's INR 15 / 50 / 169 matched on reads and egress; **the 3,000 DAU line rises to about 275** because the plan
priced no vCPU-s and, since W7, the product passes the free Cloud Run requests and vCPU-s before 3,000 DAU.

**Free quotas that move** (whole product with W4 on for every DAU):
| Quota | Runs out at (was) | W4 increment at 2× | at 10× |
|---|---|---|---|
| Firestore reads 50k/day (357.6 reads per DAU) | **≈ 140 DAU** (156) | 280 DAU: INR 10.4 | 1,400 DAU: INR 51.8 |
| Cloud Run requests 2M/month (1,746 per DAU-month) | **≈ 1,145 DAU** (1,257) | 2,290 DAU: INR 13.5 | 11,450 DAU: INR 67.5 |
| Cloud Run vCPU-s 180k/month (174.6 per DAU-month) | **≈ 1,031 DAU** (1,131) | 2,062 DAU: INR 73.0 | 10,310 DAU: INR 365 |
| Firestore writes, deletes, storage, Vision, Pub/Sub | unchanged | — | — |

- **Abuse bound:** one account at the daily cap is ≤ 900 search calls a day across 3 instances, bounded first by the
  read budget (≤ 2,368 reads per instance, 7,104 at 3 instances, ≈ INR 0.24 a day).
- **Trigger that justifies it:** none needed (no fixed cost). Scale-up triggers are in the Stage ladder.

## Stage ladder
| Concern | Stage 0 (this ADR) | Seam to protect now | Stage 2/3 target (ADR) | Trigger (measured, sustained 7 days) |
|---|---|---|---|---|
| People and post search | handle prefix range on `users.handleLower`; exact `#tag` via `array-contains`; Top = bounded re-rank of the newest 30; no words in text, no names (F2) | `search.Service` (People, Posts(tab), Trends); `SearchTab` enum; sealed opaque tokens; `unsupported_query`; `identity.Directory.SearchHandles` and `posts.Reader.ByHashtag` are the only queries | Postgres FTS (Cloud SQL) or Typesense, fed from the post-create event; ranked Top and names | unsupported post queries > 30 % of post searches with > 1,000 post searches a day, **or** search reads > 15 % of daily Firestore reads |
| Display names (F2) | none | `SearchHandles` returns profiles; People merges behind `search.Service` | `users.nameKeys` (W4-11/12), then the engine above | the founder's "yes", or People calls with 0 results > 30 % of People calls with > 300 People calls a day |
| Hashtag Media tab | post-filter over the tag entry and 30-post scans (`len(media) > 0`) | `SearchTab.MEDIA`; the MEDIA token is opaque | composite index `posts (hashtags CONTAINS, hasMedia ASC, createdAt DESC)` (gate file), after `opsctl backfill-has-media` | MEDIA calls returning fewer than 5 rows > 50 % of MEDIA calls with > 200 MEDIA calls a day, or the founder's request |
| Trends | one daily sweep inside `daily-maintenance`, distinct authors in memory, one doc | `search.TrendsRefresher`; `trends/current` read only through GetTrends; the cron host is wiring | the third Scheduler job, hourly (F1 A); then Pub/Sub-batched counters or a stream job | `trends_backlog` on 7 consecutive runs (posts a day > `TRENDS_MAX_POSTS_PER_RUN` 2,000, about 2,000 DAU), or the founder asks for hourly |
| Search caches | per-instance LRU (prefix 60 s, tag 60 s, trends 10 min) | small cache interfaces in `internal/search` with stated bounds | Memorystore (ADR) | tag-entry hit rate < 20 % with search reads > 15 % of daily reads, or max-instances above 3 |

IDs and hot docs: `trends/current` takes 1 write a day; no new collection can approach 500 writes/s; no counter is added.

## Proposed skill rows (follow-ups: `.claude/` is not edited in this PR)
- **F-1 `stage-ladder`:** add a "Search and trends" section with the five rows above.
- **F-2 `firestore-data-model`:** fix the prefix-search line to `where handleLower >= p and handleLower < succ(p)`
  (`succ` = the last character's next code point; the class is ASCII) and add:
  - collection row `trends/current` [search, ADR-0028]: the D6 shape; written only by the refresh (1 `Set` per run);
    read by GetTrends through a 10 min instance cache; `items` index-exempt (fieldOverride, W4-9); no user data, no
    eraser step, not exported.
  - operation rows: SearchPeople 7 / 22 cold, 0–2 warm, 0 writes; SearchPosts 33 cold (page 1, ≤ 30), 53 (page 50),
    23 / 53 older, 33 MEDIA scan, 0–3 warm, 0 writes; GetTrends 2 cold / 0–1 warm, 0 writes; trend refresh 1 + new posts
    (≤ 2,001), 1 write.
  - index note: no new composite; `ByHashtag` uses `hashtags CONTAINS, createdAt DESC`; `CreatedAfter` and
    `SearchHandles` use automatic single-field indexes; `trends.items` exempt.
- **F-3 `free-tier-budget`:** none required (no new service); `cost-model.md` gets the W4 rows from W4-23.

## Consequences
**Positive.** People and hashtag discovery at INR 0 idle and about INR 15 / 50 / 275 a month at 300 / 1,000 / 3,000
DAU, with no new service, no composite index and one gate-file exemption. Protected accounts are respected from day one.
Every Stage 2 move (engine, names, Media index, hourly trends, Memorystore) is a swap behind a named seam with a measured
trigger.

**Negative.** No full-text search, no display names, a Top tab that sees only the newest 30 tagged posts, daily trends
that can be empty at low volume, short or empty Media pages. Reads pass the free quota earlier (about 140 DAU instead of
156) and vCPU-s at about 1,031 DAU, so the 1,000 DAU column is close to the vCPU line. Sockpuppet rings of 3 can push a
tag until the denylist catches it.

**Revisit when** a stage-ladder trigger fires; when W4-23 measures reads per call more than 25 % off this table; when
the founder answers F1 to F8 differently; or when an offensive tag needs the denylist more than once a month.

## Handoff
- **architect:** W4-2 in this PR. Follow-ups F-1 and F-2 (skill rows) in a `.claude/` PR the founder approves.
- **backend-developer:** W4-3 flags, config (D9), limits, skeleton (`make proto`, generated code); W4-4
  `SearchHandles` (D11); W4-5 People (D2) and W4-7 load `testdata/search_query_grammar.json` (D1 step 8); W4-6 `ByHashtag` / `CreatedAfter` (D11, projection never cached); W4-7 and
  W4-8 tabs (D3, D5) through `posts.Audience` `SurfaceList`; W4-9 refresh (D6) with the guard row, runbook
  `docs/runbooks/search.md` and the `trends.items` override + ack (founder-gated); W4-9b wrapper (D7); W4-10 GetTrends.
  Log fields per D10.
- **frontend-developer:** W4-13 parser per D1 (the sigil is not counted in the 50, a one-character word is a tag but too short for people); its follow-up PR adds `testdata/search_query_grammar.json` (D1 step 8) and the Dart test; W4-14 to W4-18 per the plan;
  W4-19 renders `ListSuggestedUsers` from W3's repository and cache only (D12).
- **tester:** W4-20 flag matrix, D1 grammar table (0 reads per rejection), budgets above, block oracle byte identity,
  protected-author drops and the PROTECTED embed, D5 token binding, the D6 sweep (distinct authors, min, denylist,
  protected, `fresh` skip, cap and resume, 48 h jump), the D7 status matrix; W4-21 client matrix.
- **security-auditor:** W4-22: enumeration (D9), the block oracle, protected accounts in People and Posts, trend
  manipulation and offensive tags, no raw query in logs, local history, the wrapper route.
- **sre-performance:** W4-23: the W4 rows (36.6 reads, 5.1 requests, 41 KB, **and the vCPU-s line** this ADR adds), the
  three moved crossovers, the triggers, a k6 `search` scenario.
- **production-deployer:** W4-24: targeted dev plan for the flags and config, the override deploy, allowlist, the direct
  OIDC call to `/internal/cron/trends-refresh` with the opt-in grant (founder OK, removed after). Prod: nothing until the
  held release (ADR-0019).
