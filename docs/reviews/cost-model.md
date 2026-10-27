# Cost model — v0.3 (design estimate; Graph and Posts/Timeline rows use emulator-measured numbers, no production data yet)
Owner: sre-performance (maintains actuals weekly). Seeded by: architect, 2026-09-26, from ADR-0002…0007 and the protos.
Updated 2026-09-30 (T21): Graph rows re-based on `docs/archive/reviews/loadtest-graph.md` (T18) and the T16a/T16b `budgettest` ceilings; see `cost-report-v0.2.0.md` §Graph.
Updated 2026-10-06 (posts-and-timeline T25): Post/Timeline rows re-based on emulator measurements; see `cost-report-posts-timeline.md`. Whole product 191 to 230.0 reads/DAU (released scope 192.9; ADR-0010 forecast 182.6).
Updated 2026-10-09 (P8 T21): rows 35-36 replaced from `cost-report-account-lifecycle.md` (derived from code, not yet measured). Whole-product totals in row 69 and §3-§5 are not yet rewritten: delta +1.1 reads, +0.3 writes, +0.0 deletes per DAU (231.1 reads/DAU; free read quota at about 216 DAU); regenerate at the next weekly update. New fixed line: ADR-0011 C4 alert about $0.39/month, prod only.
Updated 2026-10-23 (ADR-0022, sre-performance handoff): verified prices replace the §7 upper bounds (Firestore asia-south1 $0.035 / $0.104 / $0.012 per 100k, Vision 2 units per image, alerting free before 2027-09-01, INR 95 per USD +/-5%); §4 Firestore overage and the Vision row, §5 and §7 re-priced; new §10 daily gross burn line. Usage inputs are unchanged (230.0 reads/DAU in §2/§3; ADR-0022 uses 232.3 = 230.0 + 1.1 P8 + 1.23 ADR-0021, a +1% difference that is inside the rounding of the tables below). Changes are marked `2026-10-23 ADR-0022`.
Updated 2026-10-26 (W2-15, sre-performance): ADR-0023 bookmarks rows and the W2-11 quote line added to §1-§3, §5, §6, §9; new §11 holds the ListBookmarks emulator smoke and the shared-link web bundle measurement. The W2 delta is **additive**: §2/§3 keep 230.0 reads/DAU and §5 keeps 232.3 (ADR-0022 inputs); the W2 delta (+18.7 reads, +1.7 writes, +0.7 deletes per DAU, flags off until W2-16) is stated on top of both and priced at the margin. Changes are marked `2026-10-26 W2-15`.
Updated 2026-10-27 (W3-23, sre-performance): ADR-0024 Part A (profile tabs, likes list, pins, banners, "Follows you", who to follow) added to §1-§6, §9 and the new §12 (emulator runs on alternate ports and the repository budget tests; nothing was run against a cloud project). The delta is **additive** on top of the W2 delta and, as for W2, leaves the §2/§3 base (230.0 reads/DAU) and the ADR-0022 inputs of §5 (232.3) untouched: Part A is **+51.5 reads, +0.06 writes, +0.005 deletes, +2.3 requests per DAU per day, +0.30 Vision units per DAU-month and +1.34 MB of banner egress per DAU-month** (the ADR-0024 plan said +40.2 reads; the whole difference is the who-to-follow call mix, §2 notes). Whole product with W2 and Part A: 300.2 reads/DAU, free read quota out at about 167 DAU. The who-to-follow line is 11.9% of all reads against its own 10% trigger (§6). Stage 0 bill with W2 and Part A: about INR 471 / 1,711 / 3,773 at 300 / 1,000 / 3,000 DAU, W3 Part A alone about INR 30 / 58 / 275, idle +0. Changes are marked `2026-10-27 W3-23`.
Method: `free-tier-budget` §2. Every RPC comment in `proto/` carries the same worst/typical numbers; change both together.

## 1. Assumptions (replace with measured values after the first 100 users)
| Assumption | Value | Why / sensitivity |
|---|---|---|
| Sessions (app opens) per DAU/day | 4 | drives GetMe, refreshes |
| Home refreshes per DAU/day | 8 (pull + resume; auto-refresh ≥ 60 s apart) | each costs `C` = ceil((F+1)/30) reads even if empty |
| Median following F | 60 → C = 3 incl. self; measured 2-4 reads overhead/refresh (graph cold 4, warm 3, all warm 2); modelled 4. `userLikes` is not read until P5 and is not in any row | a user following 300 pays ~11/refresh |
| Posts per DAU/day (incl. replies) | 1.0 (30% replies) | conservative; lurker-heavy apps see 0.2–0.5 |
| New followee posts seen per DAU/day | 60 (each read once via `since`) | biggest single read line; scales with F × activity |
| Older pages (infinite scroll) per DAU/day | 1 × 20 items | |
| Likes / reposts / follows per DAU/day | 5 / 0.3 / 0.5 | likes dominate writes |
| Images per DAU/day | 0.2 (≈ 0.15 upload calls) | drives GCS + Vision |
| Vision units per image (2026-10-23 ADR-0022) | **2**: the full image and its thumbnail are both screened (`VISION_SCREEN_THUMB` default true, set true in prod and dev Terraform; `backend/internal/media/service.go` `finalizeOne`: `units := int64(1); if s.ScreenThumb { units = 2 }`) | 0.2 images x 2 x 30.42 days = **12.17 units per DAU-month** (was 6 at 1 unit per image). Setting `VISION_SCREEN_THUMB=false` halves it |
| Instance cache hit rate | ~50% for users/graph/post docs (assumption; never measured, no traffic yet) | low at Stage 0: few concurrent users, scale-to-zero empties caches |
| Avg billable Cloud Run time per request | 0.1 s at 1 vCPU (low concurrency, little overlap) | conservative: overlap at higher traffic lowers it |
| Avg API response (binary proto, gzip) | 6 KB | |
| Image sizes | thumb ≈ 40 KB, full ≈ 250 KB, avatar thumb ≈ 4 KB; pair stored ≈ 300 KB | |
| Uncached image GETs per DAU/day | ~30 (20 thumbs, 10 avatars) + 3 full views | client disk cache for repeats |
| Web share of DAU | 30% (Hosting transfer counts web API via rewrite + static) | mobile calls `run.app` directly (ADR-0007) |
| Bookmarks per DAU/day (2026-10-26 W2-15, ADR-0023 assumptions) | 0.3 AddBookmark, 0.1 RemoveBookmark, 0.3 first-page opens of `/bookmarks` and 0.1 older pages (page size 20, the client default); posts mostly not in the instance cache; plus an assumed 0.02 no-op or retried Add/Remove calls (5% of 0.4) at 1 write each | the list is 16.9 of the 18.7 reads/DAU W2 adds; the ADR-0023 trigger (15% of daily reads) needs about 2.2x this list usage |
| Quote calls per DAU/day (2026-10-26 W2-15, W2-11 assumption) | 0.05 (5% of the 1.0 posts/DAU, about one sixth of the 0.3 reposts); added on top of the posts line, not carved out of it | W2-11 shows Quote under the existing `engagement` + `quotes` flags (dev allowlist 3); a quote is a root post for feeds, so carving it out of the 1.0 would lower the delta by 0.11 reads, 0.2 writes, immaterial |
| Shared-link web visitors (2026-10-26 W2-15, W2-8/W2-9) | not a per-DAU line: first-time visitors per day against the Hosting headroom, §5 and §11 | a visitor who is not signed in downloads the whole bundle once and makes no API call |
| Profile tabs, likes list, pins, banners (2026-10-27 W3-23, ADR-0024 call mix) | per DAU per day: 0.30 Media-tab and 0.15 Reposts-tab first-page opens, 0.2 first-page opens of History > Likes, 0.6 `GetPost` of a pinned post, 0.03 `UpdateProfile` with extras, 0.005 banner uploads, 2 `GetProfileRelationship` (replacing 2 of the 3 `GetRelationships` calls, net +0.5 read each), 0.05 deleted posts that reach the pin job | tabs and the likes list have no instance result cache, so every open reads its page; the 15% tabs-plus-likes trigger needs about 3.6x this usage |
| Who-to-follow call mix (2026-10-27 W3-23) | 1.0 `ListSuggestedUsers` per DAU per day (W3-19 keeps the result 24 h per account on the device), 95% of them cold on the server (the 1 h per-viewer entry only helps a second device or a re-login within the hour); of the cold calls 85% friends of friends (42 reads) and 15% curated (12 reads: accounts that follow fewer than 3, or whose graph yields fewer than 3 candidates) | **replaces the ADR's flat planning 25, a mix with about half the calls warm.** The line is 35.7 reads/DAU and 11.9% of all reads, above the 10% trigger of §6 |
| `[planned]` rows | engagement + notifications modules, not yet in `proto/` | included so the Phase 1 total is honest |

## 2. Per-RPC budget (Firestore reads/writes per call; worst from proto comments, typical used for totals)
| RPC | reads worst / typical | writes worst / typical | deletes (eventual) | Cloud Run ms (warm, est.) | calls/DAU/day | reads/DAU | writes/DAU | deletes/DAU |
|---|---|---|---|---|---|---|---|---|
| IdentityService.GetMe | 2 / 1 | 0 | 0 | 15 | 4 | 4.0 | 0 | 0 |
| IdentityService.GetProfile | 4 / 1 | 0 | 0 | 20 | 3 | 3.0 | 0 | 0 |
| IdentityService.CreateProfile | 2 / 2 | 3 / 3 | 0 | 80 | 0.05 | 0.1 | 0.15 | 0 |
| IdentityService.CheckHandleAvailability | 1 / 1 | 0 | 0 | 15 | 0.15 | 0.15 | 0 | 0 |
| IdentityService.UpdateProfile (+snapshot job ≤ 100 posts) | 2 + 100 / 12.5 avg | 1 + 100 / 12.5 avg | 0 | 40 (+job) | 0.02 | 0.25 | 0.25 | 0 |
| IdentityService.ChangeHandle | 2 / 2 | 2 / 2 (+job) | 1 | 60 | ~0 | ~0 | ~0 | ~0 |
| IdentityService.DeleteAccount (+job; reference account P 300, O = I = 100, derived, `cost-report-account-lifecycle.md`) | 2 + job (P+O+I+...) / **513** (2 RPC + 2 gated + 509 work) | 1 + 300 / **301** | **505** | 30 (+ job about 10 vCPU-s) | 0.001 | 0.51 | 0.30 | 0.51 |
| IdentityService.RequestAccountExport / GetAccountExport (+job; reference account, derived) | 2 / 1 + job 703 + 3 polls = **708** | 2 + 2 (job: lease claim, status) = **4** | 1 (TTL, 7 d) | 30 (+ job about 20 vCPU-s) | 0.001 | 0.71 | 0.004 | 0.001 |
| GraphService.Follow (created; ADR-0008 A2: 4 cold / 2 warm) | 4 / **4 measured** (3.96–3.98 mean, T18) | 5 / 5 | 0 | 60 (server p95 6–17 ms on emulator) | 0.5 | 2.0 | 2.5 | 0 |
| GraphService.Unfollow (own 0 reads; the 1 read is the caller's status-interceptor profile read after Follow's `Forget`) | 0 own / **1 logged** | 3 / 3 | 1 / 1 | 40 | 0.1 | 0.1 | 0.3 | 0.1 |
| GraphService.GetRelationships (≤ 50 ids) | 1 / 0.5 planning (0.11 measured warm pool) | 0 | 0 | 10 | 3 | 1.5 | 0 | 0 |
| GraphService.ListFollowers / ListFollowing (page 20) | 102 (page 50) / **30.5** planning = mid of 20.16 warm and 40–42 cold (measured) | 0 | 0 | 70 | 0.3 | 9.15 | 0 | 0 |
| GraphService.Block | 3 / 3 (T16a) | 5 / 3 | 2 / 0 | 60 | 0.02 | 0.06 | 0.06 | ~0 |
| GraphService.Unblock | 1 / 1 (T16a) | 2 / 2 | 0 | 30 | 0.005 | ~0 | 0.01 | 0 |
| GraphService.Mute (3 reads after T26; 2 until then) | 3 / 3 | 2 / 2 | 0 | 30 | 0.02 | 0.06 | 0.04 | 0 |
| GraphService.Unmute | 1 / 1 (T16a) | 1 / 1 | 0 | 30 | 0.005 | ~0 | ~0 | 0 |
| GraphService.ListBlockedUsers / ListMutedUsers | 51 / 10 | 0 | 0 | 40 | 0.02 | 0.2 | 0 | 0 |
| GraphService.ListFollowRequests / RespondToFollowRequest (flag-off stubs) | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 |
| **Graph slice subtotal** | | | | | **≈ 4.0 req** | **≈ 13.1** (was 10.2) | **≈ 2.9** (was 3.35) | **≈ 0.1** |
| PostService.CreatePost (root; reads exclude the interceptor) | 14 / **2.2** planning (measured 2 warm; +1 per uncached mentioned handle, 3 cold instance, 5 cold with 2 mentions) | 4 / 4 (measured) | 1 (idempotency TTL) | 80 | 1.0 | 2.2 | 4.0 | 1.0 |
| PostService.CreatePost, replay / reused key | 14 / 1 warm (measured); 3 on a cold instance (users + idempotency + post) | 0 | 0 | 30 | — | — | — | — |
| PostService.DeletePost (own post) | 2 / **1** (measured 1 cold, 0 warm, 1 on a no-op or another user's post) | 1 / 1 (0 on no-op, measured) | 1 / 1 (0 on no-op) | 40 | 0.05 | 0.05 | 0.05 | 0.05 |
| PostService.GetPost | 4 / **1.0** (measured 3 cold: post + author + caller graph; 1 post miss with author+graph warm; 0 warm) | 0 | 0 | 15 | 1 | 1.0 | 0 | 0 |
| PostService.GetThread **[planned, P3, not released, not measured]** | 56 / 7.5 | 0 | 0 | 60 | 2 | 15.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — refresh overhead (no `userLikes` until P5) | 2 + C / **4** (measured 4 graph cold, 3 graph warm, 2 all warm; F=60) | 0 | 0 | 80 | 8 | 32.0 | 0 | 0 |
| ↳ new followee posts returned by refreshes | measured +1 read per returned post (new=1: 4, 8: 10, 20: 22) | 0 | 0 | — | 60 posts | 60.0 | 0 | 0 |
| ↳ settle-window re-reads (ADR-0010 D13) | measured unit: +1 read per re-delivered post; frequency derived, ≤ 0.1 per refresh | 0 | 0 | — | 8 | 1.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — older page | 269 (assert 268 + interceptor) / **40** (measured 40 mixed feed, 42 dense feed, 43 on a cold instance; **ADR planning 30, +33%: ADR-0010 revisit flagged**) | 0 | 0 | 120 | 1 | 40.0 | 0 | 0 |
| TimelineService.GetHomeTimeline — cold open | same / **36.5** (measured 30 mixed, 43 dense; midpoint; ADR 30) | 0 | 0 | 150 | 0.1 | 3.65 | 0 | 0 |
| TimelineService.GetUserTimeline (page 20) | 54 / **11** (measured 22 cold page, 0 warm first page, 20-22 page 2, 3 cold refresh with 0 new, 0-1 warm refresh; mix of cold and warm) | 0 | 0 | 50 | 2 | 22.0 | 0 | 0 |
| `AccountStatusInterceptor` caller read on posts/timeline requests (measured unit: 1 cold, 0 warm; mix derived) | 1 / 0 / 1 per home refresh, 0.5 on the other 5.15 requests | 0 | 0 | — | 13.15 req | 10.6 | 0 | 0 |
| **Posts + timeline subtotal (released in P1)** | | | | | **≈ 13.15 req** | **≈ 172.5** (ADR-0010: 162.2) | **≈ 4.05** | **≈ 1.05** |
| MediaService.CreateUpload | 2 / 1 | 6 / 3.3 | 1 (idempotency TTL) | 150 (signBlob ×2/image) | 0.15 | 0.15 | 0.5 | 0.15 |
| MediaService.FinalizeUpload | 5 / 1.7 | 5 / 2.7 | 0 | 800 (Vision + copies) | 0.15 | 0.25 | 0.4 | 0 |
| [planned] Like (+in-batch notification) | 1 / 0 | 4 / 4 | ~0.9 (notification TTL) | 40 | 5 | 0 | 20.0 | 4.5 |
| [planned] Unlike | 1 / 0 | 2 / 2 | 1 / 1 | 40 | 0.5 | 0 | 1.0 | 0.5 |
| [planned] Repost (+notification) | 2 / 0.5 | 5 / 5 | 0 | 60 | 0.3 | 0.15 | 1.5 | 0 |
| [planned] ListNotifications + mark seen | 21 / 10 | 1 / 0.5 | 0 | 40 | 2 | 20.0 | 1.0 | 0 |
| [planned] Pub/Sub push send (reply/mention/follow/repost) | 1 / 1 (device tokens) | 0 | 1 (notification TTL) | 100 | 1.3 | 1.3 | 0 | 1.3 |
| [planned] RegisterDevice (FCM token) | 0 | 1 / 1 | 0 | 20 | 0.1 | 0 | 0.1 | 0 |
| **W2 (2026-10-26 W2-15): bookmarks (ADR-0023) and quote UI (W2-11). Flags off in prod; emulator-measured where marked** | | | | | | | | |
| EngagementService.AddBookmark (new bookmark) | 7 cold ceiling (asserted; +2 for a REPOST id, +1 on blockedBy overflow) / **4** planning (ADR). Measured over 1,000 calls: 3 warm (950), 4 (40), 5 (10), mean 3.06 | 4 / 4 (measured) | 1 (idempotency TTL) | 40 | 0.3 | 1.2 | 1.2 | 0.3 |
| ↳ AddBookmark of an already bookmarked post, or a late retry (ADR-0023 dated note: the no-op stores the idempotency doc, **1 write, not 0**) | 7 cold / 3 warm; replay 5 cold / 1 warm | 1 / 1 (replay, at the cap or at the quota: 0) | 1 (TTL) | 30 | 0.02 (assumed, on top) | 0.06 | 0.02 | 0.02 |
| EngagementService.RemoveBookmark | 2 cold / 1 warm / **2** planning (interceptor, idempotency) | 2 / 2 (idempotency, userLikes; a no-op 1, a replay 0) | 1 + 1 TTL | 30 | 0.1 | 0.2 | 0.2 | 0.2 |
| EngagementService.ListBookmarks, page 20, **first page of an open** (interceptor 1, query 20, GetMany 20, caller graph 1, userLikes 1) | 43 / **43** cold (measured, 5 viewers x 1 pass); 20 when posts, graph and userLikes are cached (60 s) | 0 | 0 | 100 (emulator server ms: 174 cold, 4 warm) | 0.3 | 12.9 | 0 | 0 |
| ↳ ListBookmarks, page 20, later pages of the same open (older pages) | 40 cold (graph, userLikes, interceptor already cached) / 20 warm (measured); the terminal empty page of an exact multiple is 1 | 0 | 0 | 50 | 0.1 | 4.0 | 0 | 0 |
| ↳ ListBookmarks, page 50 (max; the client uses 20, so 0 calls in the mix) | 103 first page / 100 later page cold; 50 warm; empty 1 (measured) | 0 | 0 | 110 (emulator server ms: 176 first page cold) | 0 | 0 | 0 | 0 |
| ↳ ListBookmarks page that prunes a missing post | as above, 0 extra reads | 1 per page (userLikes field update) | 1 per pruned row, once | — | ~0 | ~0 | ~0 | ~0 |
| `PostView.bookmarked_by_viewer` on timelines, GetPost, GetThread (#310) | +0 with engagement on (the bookmarks flag never ramps beyond engagement); +1 cold per 60 s only with bookmarks on alone | 0 | 0 | — | — | 0 | 0 | 0 |
| Account deletion, eraser step `bookmarks` (reference account: 100 bookmarks) | 1 per doc, minimum 1 / **100** | 1 (field-level `userLikes` update on the last page) / 1 | 1 per doc / **100** | 30 (+ job) | 0.001 | 0.1 | ~0 | 0.1 |
| Account export, section `bookmarks` (reference account: 100 bookmarks) | 1 per doc, minimum 1 / **100** | 0 | 0 | 20 (+ job) | 0.001 | 0.1 | 0 | 0 |
| PostService.CreatePost, **quote** (`quote_of_post_id`, flags `engagement` + `quotes`; `posts.proto`) | 17 cold / 2 warm / **3.2** planning (root 2.2 + the visibility check, measured 3 cold / 0 warm = the GetPost row of 1.0) | 5 / 5 (+1 async notification write to the quoted author) = **6** | 2 (idempotency TTL + notification TTL) | 90 | 0.05 | 0.16 | 0.30 | 0.10 |
| **Total per DAU/day (whole product, incl. `[planned]` rows)** | | | | | **36.8 requests** | **≈ 230.0** (was 191) | **≈ 31.8** (was 32.6) | **≈ 7.65** |
| **W2 subtotal (bookmarks 18.56 reads + quote 0.16)** | | | | | **≈ 0.87 req** | **≈ 18.7** | **≈ 1.7** | **≈ 0.7** |
| **Total with W2 (the total row above + the W2 subtotal; used by the W2 lines of §3, §4, §5)** | | | | | **≈ 37.7 requests** | **≈ 248.7** | **≈ 33.5** | **≈ 8.4** |
| **W3 Part A (2026-10-27 W3-23): profile and graph completion (ADR-0024). Flags off everywhere until W3-24. Emulator-measured, §12; "cold" includes the account-status interceptor's read** | | | | | | | | |
| TimelineService.GetUserTimeline, tab MEDIA, page 20 (`profile_tabs`) | **24** cold (asserted, and measured with nothing cached anywhere: interceptor 1, target `users` 1, caller graph 1, `userLikes` 1, page 20); 54 at page 50 / **21** planning (measured 21 on the first tab call after the header's GetProfile, 20 after that, 23 when the target is already cached). Tabs have no result cache: a warm page still costs the page size | 0 | 0 | 55 (emulator server ms: 18 cold, 6-9 warm) | 0.30 | 6.3 | 0 | 0 |
| TimelineService.GetUserTimeline, tab REPOSTS, page 20 | same chain: **24** cold, 54 at page 50 / **21** planning (measured 20 on every call that follows a Media call; the embed filter reads nothing) | 0 | 0 | 55 | 0.15 | 3.15 | 0 | 0 |
| PostService.GetPost of a profile's pinned post (existing row above, planning 1.0) | 4 / **1.0** | 0 | 0 | 15 | 0.6 | 0.6 | 0 | 0 |
| IdentityService.UpdateProfile with banner, location, website or pin (`profile_extras`) | 4 cold = interceptor 1 + service 3 (`users` 1, banner media doc 1, pinned post 1; measured 3 / 1); bio only 1 + interceptor / **2** planning | 1 / 1 (the whole `users` doc is rewritten) | 0 | 40 | 0.03 | 0.06 | 0.03 | 0 |
| MediaService.CreateUpload + FinalizeUpload, purpose BANNER (one item, 2 Vision units) | Create 2 + Finalize 2 (service, measured) + 2 interceptor = **6** cold | 3 + 2 = **5** (measured) | 1 (idempotency TTL) | 150 + 800 | 0.005 | 0.03 | 0.025 | 0.005 |
| EngagementService.ListLikedPosts, page 20, first page of an open (`likes_list`) | 24 asserted ceiling; **23** cold (measured: interceptor 1, `userLikes` 1, caller graph 1, GetMany 20); later pages 20; page 50: 53 first, 50 later; empty array 2. Warm = the page's posts that are not in the 60 s post cache: **0** when all are (measured), 20 or 50 when none / **23** planning | 0 | 0 | 60 (emulator server ms: 34 first page, 7 later pages) | 0.2 | 4.6 | 0 | 0 |
| GraphService.GetProfileRelationship ("Follows you"; replaces the header's GetRelationships) | **4** on a fully cold instance (measured: interceptor 1, caller graph 1, target `users` 1, edge 1; the service alone is 3, or 2 with the target cached); **1** after the header's GetProfile (the edge, measured in 38 of 38 flows); **0** inside the 60 s pair cache; +1 on blockedBy overflow / **1** planning, +0.5 net over the replaced call | 0 | 0 | 10 | 2 | 1.0 (net) | 0 | 0 |
| GraphService.ListSuggestedUsers, friends of friends (`follow_suggestions`) | **42** cold, the hard cap (measured 42 in 5 of 6 concurrent first calls and also at 600 followees; 33 when other viewers had just cached some of the candidate profiles; interceptor 1, graph 1, edges 30, profiles 10); **0** warm inside the profile cache's 60 s, **1** after it (the interceptor), measured | 0 | 0 | 70 (emulator server ms: 70 cold, 2 warm) | see the mix row | | | |
| GraphService.ListSuggestedUsers, curated fallback (viewer follows fewer than 3, or fewer than 3 candidates) | **12** cold at the cap (measured 12 with a 12-id list: interceptor 1, graph 1, 10 profiles; 2 when another viewer had cached the same curated profiles within 60 s; the integration test's 8-id list, 5 usable, is the earlier "7"); 0 / 1 warm | 0 | 0 | 40 | see the mix row | | | |
| ↳ ListSuggestedUsers, planning mix (1 call per DAU per day: 95% cold, of those 85% friends of friends and 15% curated; 5% warm at 1) | **35.7** (ADR-0024 flat 25 assumed half the calls warm) | 0 | 0 | — | 1.0 | 35.7 | 0 | 0 |
| Pin clean-up, third step of the `post_delete` job (`identity.PinJobs`, never flag-gated) | **2** (fresh post-gone read 1, `users` in the transaction 1; measured through the real repos), 1 when the post still exists (refused) | 1 only when the deleted post was the pin (measured 2 reads / 1 write; otherwise 2 / 0) | 0 | 20 | 0.05 | 0.10 | ~0 | 0 |
| `hasMedia` on every post create path (W3-7) | +0 | +0 (an explicit bool in the post doc) | 0 | 0 | — | 0 | 0 | 0 |
| `opsctl backfill-has-media` (one-off per project, not per DAU) | 1 per post scanned | 1 per post lacking the key, text-only posts included (measured: 1,001 posts 1,001 reads / 667 writes; ≤ 5,000 writes per run; a rerun writes 0) | 0 | — | n/a | n/a | n/a | n/a |
| [planned, ADR-0024 Amendment 1 A4, not built, not in the subtotal] retire step for a replaced or removed banner / avatar (`PROFILE_MEDIA_RETIRE`) | 2 | 1 | 1 (TTL) | — | 0.01 | +0.02 | +0.01 | +0.01 |
| **W3 Part A subtotal** | | | | | **≈ 2.3 req** | **≈ 51.5** (ADR-0024: 40.2; the plan: 40.1) | **≈ 0.06** | **≈ 0.005** |
| **Total with W2 and W3 Part A (used by the W3 lines of §3, §4, §5)** | | | | | **≈ 40.0 requests** | **≈ 300.2** | **≈ 33.6** | **≈ 8.4** |

Home timeline = 136.7 reads/DAU/day (59% of all reads). Likes = 20 writes/DAU/day (63% of all writes).

W2 notes (2026-10-26 W2-15; emulator runs in §11, ADR-0023 "Cost impact" is the source of the call mix):
- **ListBookmarks matches the ADR: 43 and 103 on the first cold page, exactly.** Later cold pages of one open are 40 and 100 (the interceptor profile, caller graph and userLikes are cached for the rest of the open), so the per-open mean is below the ADR's flat 42 per page. Per DAU: 0.3 x 43 + 0.1 x 40 = **16.9** (ADR: 0.4 x 42 = 16.8). Warm (posts cached, inside the 60 s TTL) a page costs exactly the page size, 20 or 50, not "1 + page" as the proto comment and runbook say; "1 + page" stays the right ceiling when graph or userLikes have expired.
- **AddBookmark is 3 reads warm, not 5.** The 7 in the integration budget test is the cold ceiling and 5 is the replay ceiling; the planning 4 (ADR) holds (measured mean 3.06 with the target post and caller warm).
- **The no-op write (ADR dated note) does not move the per-DAU number**: the ADR's 1.4 writes counts every call as a success (4 or 2 writes), and a no-op is 1 write, so the no-op calls are an extra 0.02 calls/DAU at 1 write each, +0.02 writes/DAU. Writes: 1.40 to 1.42.
- Bookmarks alone (no quote): **+18.56 reads, +1.42 writes, +0.62 deletes, +0.82 requests per DAU per day**, against the ADR's 18.2 / 1.4 / 0.5 (+0.36 reads: the measured list +0.1, the no-op 0.06, the eraser and export 0.2; +0.12 deletes: the eraser 0.1, the no-op 0.02).
- Quote: 17 cold / 2 warm reads and 5 writes per `posts.proto`; the visibility check (+3 cold / +0 warm) is priced as the GetPost planning 1.0, so the planning read count is 2.2 + 1.0 = 3.2. The async quote notification adds 1 write and a TTL delete; its push-send read (0.05 reads/DAU) is not in the 1.3 notification line and is left out as immaterial. At 0.05 calls/DAU it adds 0.16 reads, 0.30 writes, 0.10 deletes per DAU. Rendering a quote or repost reads nothing extra (embedded snapshot).

W3 Part A notes (2026-10-27 W3-23; emulator runs and budget tests in §12, ADR-0024 "Cost impact" and Amendment 1 are the call-mix source):
- **What the implementations measured differently from the plan table** (the plan's Cost section is corrected to match):
  - `ListLikedPosts` is **23 cold at page 20 and 53 at page 50**, not 24 / 54 (the 24 / 54 are still asserted next to it as a ceiling). Later pages of one open are 20 / 50. A **warm** page costs the number of its posts that are not in the 60 s post cache (**0** when all are, measured; 20 / 50 when none), not "3". The planning 22 becomes **23** because a first page of an open is nearly always all uncached (the liked posts are old): +0.2 reads/DAU. Scrolling a viewer's whole 1,000-like list at page 50 is **53 + 19 x 50 = 1,003 reads** (50% of one instance's 2,000 daily read budget, INR 0.03).
  - **Pin clean-up is 2 reads per deleted post, not 1** (a fresh read that the post is gone, then `users/{uid}` in the transaction), 1 write only when the deleted post was the pin: +0.05 reads/DAU (0.10 instead of 0.05). ADR-0024 Amendment 1 A5 made the same correction. A message for a post that still exists is refused after the 1 read.
  - **`hasMedia` backfill writes every post that lacks the key**, text-only posts included (ADR: images only). It is a one-off: INR 1.3 per 10,000 posts (10,000 reads INR 0.33, 10,000 writes INR 0.99), and the 5,000-write cap per run keeps each run inside the 20,000 free writes/day.
  - `ListSuggestedUsers` measured **42 cold** (the cap, also at 600 followees: the cost does not grow with the number followed), **0 warm** inside the 60 s profile cache and **1** after it; the curated path is **12** at the cap (the earlier "7" is the integration test's 8-id list of which 5 were usable). `candidates` is 10 on every cold call in the runs. **The 25 was a call-mix assumption, not a measurement; see the next bullet.**
  - Tabs: **24 cold through the chain** at page 20 and 54 at page 50, as the plan said; the typical call is **21** (the first tab call after the header's GetProfile pays the `userLikes` read), 20 after that. Page 2 of a 60-row Media list is 10 reads (the rows left). The viral-profile load (300 calls at 15/s on one author's Media tab) read exactly 20 per call: reads grow linearly with calls because there is no tab cache.
  - `GetProfileRelationship`: **4** on a fully cold instance in the chain (the "3 cold" is the service alone: caller graph, target profile, edge; the interceptor is the fourth), **1** right after the header's GetProfile (the edge), **0** inside the 60 s pair cache. The planning 1.0 reads/DAU is net of the replaced GetRelationships (2 calls x (1 - 0.5)).
- **Who to follow is the finding of this report.** The ADR planned 1 call per DAU at a flat 25 reads, i.e. about half of the calls warm. The W3-19 client keeps the result 24 h per account, so a DAU makes about one call a day, and the server's 1 h per-viewer entry is expired by the next day: a warm server hit needs a second call by the same viewer on the same instance within the hour (a second device, a re-login). So almost every call is cold. At 5% warm and 85% friends of friends (42) / 15% curated (12) the planning value is **35.7**, not 25, and the line moves from 8.7% to **11.9% of all reads**, above its own 10% trigger (§6). The whole restatement (+11.4 reads/DAU) costs INR 3.4 / 11.4 / 34.3 a month more at 300 / 1,000 / 3,000 DAU than the ADR's 40.2; the money is small, the trigger is the issue.

| Suggestions call mix | reads per call | reads/DAU | share of all reads |
|---|---|---|---|
| ADR-0024: flat 25 (about half warm) | 25.0 | 25.0 | 8.7% of 288.9 |
| **Used: 5% warm, 85% friends of friends / 15% curated** | **35.7** | **35.7** | **11.9%** of 300.2 |
| All cold, all friends of friends | 42.0 | 42.0 | 13.7% of 306.5 |
| Used mix with a 48 h client cache (0.5 calls/DAU) | 35.7 | 17.8 | 6.3% of 282.4 |
| Used mix with `SUGGESTIONS_EDGE_LIMIT` 20 (cap 32) | 27.6 | 27.6 | 9.4% of 292.1 |

- The other rows move by +0.45 (tabs 21 not 20), +0.02 (banner Create + Finalize 6 not 2 reads per banner), +0.2 (likes 23 not 22) and +0.05 (pin job): +0.7 in all. The remaining +10.7 is the suggestions mix. Writes are 0.06 (UpdateProfile 0.03, banner 0.025, the pin write about 0), deletes 0.005 (the banner idempotency TTL), requests 2.29: both as the plan.
- The restated figure is a planning value, not a forecast: the call count, the warm share and the curated share are inputs with no traffic behind them. The first real number is the dev allowlist smoke of W3-24 (a handful of calls) and then `make cost` on the weekly actuals (§8).
Graph notes (T21, all from emulator runs; `loadtest-graph.md` is the source):
- **Follow is 4 reads, not the plan's 3.** After a successful Follow, `directory.Forget(caller, target)` evicts both
  profiles, and `AccountStatusInterceptor` re-reads the caller. Measured mean 3.96–3.98 (max 4). The 4 is the cold
  ceiling; on this run it is also the typical. ADR-0008 A2 planned 3, so this row is +0.5 reads/DAU over the ADR.
- **Unfollow logs 1 read, not 0.** The RPC's own batch is 0 reads / 3 writes / 1 delete. The 1 is the caller's
  interceptor profile read once a preceding Follow evicted it. It is counted here because `fs_reads` includes it;
  it slightly double-counts against the identity rows (a profile read the caller was going to pay anyway).
- **ListFollowers page 20 is 20.16 warm and 40-42 cold**; 30.5 is the midpoint (the model's ~50% hit-rate
  assumption, §1). The 20.16 came from a 100-caller / 5-target warm pool, so it is a floor, not a forecast.
- Block/Mute rows are the T16a `budgettest` ceilings; they are not in the k6 run (0.02 calls/DAU, immaterial).
  Mute's 3 depends on T26 (not merged as of this update); today's Mute is 2 reads.
- GetRelationships measured 0.11 mean on a warm pool (worst 2). 0.5 is kept, the planning value.

Posts/timeline notes (T25, emulator runs; `cost-report-posts-timeline.md` is the source; reads exclude the interceptor unless stated):
- **Measured values** are from the existing integration tests plus throwaway `-overlay` tests (not in the repo). Cache hit rates, the 60 new posts/DAU
  and the call mix are still model assumptions: there is no real traffic.
- **Older page is 40 (mixed feed) to 42 (dense feed), planning 30: +33% to +40%, above the 25% line.** With 61 authors (self + 60) the
  first chunk is self + 29, so there are three chunks and k = ceil(2p/3) = 14; once the small chunk is covered by author-recent, two
  chunks run at k = 20. This is the ADR-0004 over-read, priced higher than the ADR assumed. ADR-0010 lever ("`2p` to `1.5p`
  when older-page reads > 1.4 x page size") has fired: 40 / 20 = 2.0. Not applied (no code change in T25); flagged for P9.
- **Home refresh overhead is 4 only on a fully cold instance** (graph expired, author-recent empty). Graph warm is 3, all warm 2.
  Modelled 4 because refreshes are >= 60 s apart and `CACHE_TTL` is capped at 60 s.
- **New posts cost 1 read each** (measured exactly), so 60 posts/DAU = 60 reads/DAU. The count of 60 is an input, not a measurement.
- **Settle re-read**: measured unit is 1 read per re-delivered post; the frequency (about 0.1 per refresh) is derived, not measurable
  without traffic. Uniform arrivals would give about 0.01 per refresh, so 1.0/DAU is an upper bound.
- **`userLikes` is out of every timeline row until P5** (no read, no cache entry).
- **F = 5,000 measures 168 reads (169 with the interceptor) against the 269 ceiling.** The seeded shape has 8 real authors; the ceiling
  needs every chunk to fill k. The ceiling is an assertion bound, not a planning value.
- Unit costs are exact across runs (deterministic emulator, no variance), so "mean" = the value.

## 3. Firestore totals vs quota (80% line = 40k reads, 16k writes, 16k deletes per day)
Whole product, including the `[planned]` likes, notifications and GetThread rows (230.0 reads, 31.8 writes, 7.65 deletes per DAU):
| DAU | reads/day | % of 80% line | writes/day | % of 80% line | deletes/day | % of 80% line |
|---|---|---|---|---|---|---|
| 100 | 23.0k | 58% | 3.2k | 20% | 0.8k | 5% |
| 300 (Stage 0 target) | **69.0k** | **173% (138% of quota)** | 9.5k | 60% | 2.3k | 14% |

**Finding (whole product):** reads cross the 80% line at **~174 DAU** (was ~210) and the full free quota at **~217 DAU** (was ~262). Stage 0's
300-DAU target costs ≈ 19.0k reads/day over → ≈ **$0.20/month** at the verified asia-south1 read price of $0.035 per 100k (2026-10-23 ADR-0022; was $0.34 at the old $0.06 upper bound, $0.13 before that). Still pay-per-use with no step change, but the
"$0 up to 300 DAU" goal is **not** met on reads (2026-10-23 ADR-0022: nor on the whole bill: Stage 0 is about INR 434/month at 300 DAU, §5, mostly Vision and egress) without the §6 levers. Writes stay free to ~630 DAU (was ~614); deletes to ~2,600 DAU.
Where the +39.2 reads/DAU since the 191 came from, row by row: older page 23 to 40 (+17.0), interceptor line (+10.6, new line), refresh overhead 3 to 4 (+8.0),
cold open 2.3 to 3.65 (+1.35), settle re-reads (+1.0, new line), CreatePost 1.5 to 2.2 (+0.7), GetPost 0.5 to 1.0 (+0.5). The ADR-0010 corrections account for +28.9
(162.2 vs the old posts rows); the measured values add +10.3 on top.

**W2 delta (2026-10-26 W2-15): bookmarks + quote UI, flags off in prod until W2-16 and the MVP ramp.** Whole product with W2 on for every DAU = 248.7 reads, 33.5 writes, 8.4 deletes, 37.7 requests per DAU per day (230.0 + 18.7, 31.8 + 1.7, 7.65 + 0.7, 36.8 + 0.9). Rows are the §2 W2 block; only the DAU at which the W2 flags are on counts.
| DAU | reads/day | % of 80% line | writes/day | % of 80% line | deletes/day | % of 80% line |
|---|---|---|---|---|---|---|
| 100 | 24.9k | 62% | 3.4k | 21% | 0.8k | 5% |
| 300 (Stage 0 target) | **74.6k** | **187% (149% of quota)** | 10.1k | 63% | 2.5k | 16% |
| 1,000 | 248.7k | 622% | 33.5k | 209% | 8.4k | 52% |
- **The free read quota is now exhausted at about 201 DAU (was 217) and the 80% line (the 40k/day alert) at about 161 DAU (was 174).** Writes: quota at about 597 DAU (was 630), 80% line at about 477. Deletes: quota at about 2,390 (was 2,614).
- **Bookmarks alone (no quote UI): 248.6 reads, 33.2 writes, 8.3 deletes per DAU**; the crossovers are the same to the nearest DAU (201, 602, 2,420).
- **ListBookmarks is 16.9 of 248.7 reads = 6.8% of the daily reads** at the model's usage, against the ADR-0023 trigger of 15% (§6). The share reaches 15% at about 37 list reads per DAU, i.e. 2.2x the modelled list usage (about 0.9 list-page opens per DAU a day instead of 0.4), with the rest of the product unchanged.
- Cloud Run: W2 adds about 0.87 requests and 2.6 vCPU-s per DAU-month (0.87 x 0.1 s x 30.42); the first Cloud Run limit (vCPU-s, §4) moves from about 1,603 to about 1,566 DAU.

**W3 Part A delta (2026-10-27 W3-23): profile tabs, likes list, pins, banners, "Follows you", who to follow; four flags off everywhere until W3-24, then ramped per decision.** Whole product with W2 and Part A on for every DAU = 300.2 reads, 33.6 writes, 8.4 deletes, 40.0 requests per DAU per day (248.7 + 51.5, 33.5 + 0.06, 8.4 + 0.005, 37.7 + 2.3). Rows are the §2 W3 block; only the DAU at which the Part A flags are on counts.
| DAU | reads/day | % of 80% line | writes/day | % of 80% line | deletes/day | % of 80% line |
|---|---|---|---|---|---|---|
| 100 | 30.0k | 75% | 3.4k | 21% | 0.8k | 5% |
| 300 (Stage 0 target) | **90.1k** | **225% (180% of quota)** | 10.1k | 63% | 2.5k | 16% |
| 1,000 | 300.2k | 751% | 33.6k | 210% | 8.4k | 53% |
- **The free read quota is exhausted at about 167 DAU (W2 alone 201; the ADR's 40.2 gave 173) and the 80% line (the 40k/day alert) at about 133 DAU (W2 alone 161).** Writes: quota at about 596 DAU (unchanged in practice), 80% line at about 477. Deletes: quota at about 2,380.
- The prod alert "Firestore reads > 40k/day" therefore fires at about 133 DAU with every flag on (credit mode's 250k/day line, until 2026-12-22, at about 833 DAU, was 1,005): expected, it is the pay-per-use signal, not an incident. No alert policy is added or changed here.
- **Shares of the daily reads at the modelled usage:** who to follow 35.7 of 300.2 = **11.9%** (trigger 10%: already crossed, §6); tabs 9.45 and likes 4.6, together 14.05 = **4.7%** (trigger 15%: about 3.6x the modelled usage, with the rest unchanged); all of Part A 17.2%.
- Cloud Run: Part A adds 2.3 requests and 7.0 vCPU-s per DAU-month (2.29 x 0.1 s x 30.42); the first Cloud Run limit (vCPU-s, §4) moves from about 1,566 to about 1,475 DAU, requests from about 1,743 to about 1,643.
**Released scope (identity + graph + posts/timelines, after P1), the one that matters for the next release:**
20.4 + 172.5 = **192.9 reads**, 7.15 writes, 1.15 deletes, 24.45 requests per DAU. ADR-0010 forecast: 182.6 reads (**measured +5.6%**, within 25%).
| | ADR-0010 forecast | Re-based on measurements | Difference |
|---|---|---|---|
| Reads per DAU per day | 182.6 | **192.9** | +5.6% |
| Reads at 300 DAU | 54.8k (110% of free) | **57.9k (116% of free)** | +5.6% |
| Free quota runs out at | ≈ 274 DAU | **≈ 259 DAU** | -5.5% |
| 80% line (40k) crossed at | ≈ 219 DAU | **≈ 207 DAU** | -5.5% |
| Overage at 300 DAU | 4.8k reads/day, ≈ $0.09/month | **7.9k reads/day, ≈ $0.08/month** (2026-10-23 ADR-0022 price; was $0.14) | **+64% in dollars (+3.1k reads/day, +$0.05)** |
The reads figure is within 25% of the ADR. The dollar figure is not, only because overage is the small difference between two close numbers; it is 5 cents. It is
still inside founder decision D1 (pay-per-use), but the cause is one planning value above 25% (older page, +33%), so the k lever is flagged for P9 and the ADR-0010
revisit is triggered (`cost-report-posts-timeline.md`). At 300 DAU the identity + graph + posts scope costs 57.9k reads against a 40k alert threshold.
Writes: 2.1k/day at 300 DAU (11%), free to ~2,800 DAU. v0.2.0 (identity + graph only) is unchanged: 20.4 reads, ≈ 2,450 DAU.

## 4. Every free quota: where it runs out, and overage at 2× / 10× that DAU
Overage is for that line alone. Prices are the verified list prices in §7 (2026-10-23 ADR-0022; Firestore overage column re-priced from the old $0.06/$0.18/$0.02 bounds to $0.035/$0.104/$0.012 per 100k, i.e. x0.583 / x0.578 / x0.6).
| Quota (free per month) | Usage per DAU-month | Runs out at DAU | Overage $/month at 2× | at 10× |
|---|---|---|---|---|
| Firestore reads (1.5M = 50k/day) | 6,902 | **217** | $0.53 | $4.73 |
| Firestore writes (600k = 20k/day) | 952 | 630 | $0.62 | $5.62 |
| Firestore deletes (600k = 20k/day) | 230 | 2,614 | $0.07 | $0.65 |
| Firestore storage (1 GiB) | ≈ 6.4 KB/day (posts, likes, notifications with 90-day TTL) | ~1.5 years at 300 DAU | cents | cents |
| Cloud Run requests (2M, shared with dev; ~29k/month fixed: uptime + CI) | 1,104 | 1,786 | $0.79 | $7.10 |
| Cloud Run vCPU-s (180k, shared) | 110 | **1,603** (first Cloud Run limit) | $4.25 | $38.23 |
| Cloud Run GiB-s (360k, shared) | 55 | 6,495 | $0.90 | $8.07 |
| Cloud Run egress to India (free 1 GiB is North America only → effectively 0) | 6.6 MB | **0** (billed from day 1) | $0.23 at 300 DAU (1.93 GiB x $0.12) | $2.32 at 3k DAU |
| GCS Class A (5,000) | 24 (4 per image) | **208** | $0.03 | $0.23 |
| GCS Class B (50,000) | 918 (image views) | **54** | $0.02 | $0.18 |
| GCS storage (5 GB-months, US only) | 1.8 MB/month growth | ~9 months at 300 DAU | cents | ≈ $0.10/month per extra 5 GB |
| GCS egress (100 GB from NA) | 47 MB | 2,133 | $12.00 | $108.00 |
| Cloud Vision SafeSearch (1,000 units; paid $1.50 per 1,000 past it, cap 10,000 — ADR-0005). 2026-10-23 ADR-0022: **2 units per image** (full + thumbnail) | **12.17** (was 6) | free runs out at **82** (1,000 / 12.17; was 158–167); cap 10,000 reached at **822** (10,000 / 12.17 = 821.7, about 820) | $1.50 (2,000 units at 164 DAU, 1,000 paid) | $13.47 at 820 DAU (8,980 paid; the cap holds it at $13.50 beyond) |
| Firebase Hosting transfer (360 MB/day) | 4 MB | 2,731 | $1.62 | $14.58 |
| Pub/Sub (10 GiB) | ~80 KB (1 KB min per message) | > 100k | $0 | $0 |
| Cloud Logging (50 GiB/project) | 1.1 MB | ~47k | $0 | $0 |
| Cloud Scheduler (3 jobs/billing account) | 1 job used | n/a | $0 | $0 |
| Secret Manager (6 versions, 10k accesses) | 1 version, 1 access per instance start | n/a | $0 | $0 |
| Artifact Registry (0.5 GB) | 3 images × ~25 MB | n/a | $0 | $0 |

**W2 effect on the quota table (2026-10-26 W2-15, additive):** Firestore reads become 7,566 per DAU-month (248.7 x 30.42, was 6,902), free quota runs out at **201** DAU (was 217), overage $0.53/month at 2x (402 DAU) and $4.79 at 10x (2,010 DAU); writes 1,020 per DAU-month, out at 597; deletes 255, out at 2,390; Cloud Run vCPU-s 115 per DAU-month, out at about **1,566**; Cloud Run requests 1,130 per DAU-month, out at about 1,743 (was 1,786). Firebase Hosting (360 MB/day): the 4 MB per DAU-month line is unchanged here; the measured shared-link visitor (1.85 MB gzip, §5 and §11) is a separate line.
**W3 Part A effect on the quota table (2026-10-27 W3-23, additive on the W2 line above):** Firestore reads become 9,133 per DAU-month (300.2 x 30.42, was 7,566), free quota runs out at **167** DAU (was 201), overage $0.54/month at 2x (334 DAU) and $4.81 at 10x (1,670 DAU); writes 1,021 per DAU-month, out at 596; deletes 256, out at 2,380; Cloud Run vCPU-s 122 per DAU-month, out at about **1,475** (was 1,566); Cloud Run requests 1,200 per DAU-month, out at about 1,643 (was 1,743); Cloud Run egress to India +0.42 MB per DAU-month (always billed); GCS egress 48.3 MB per DAU-month (banners +1.34), out at about 2,069 DAU (was 2,133); GCS Class B 948 per DAU-month (banner views +30), out at about 53 DAU (was 54); Vision 12.47 units per DAU-month (banners +0.30), free units run out at **80** DAU (was 82) and the 10,000 cap is reached at **802** DAU (was 822). The two composite indexes add about 2 index entries per post: cents of storage, not priced.

### Read budget as an abuse bound (ADR-0010 D5 as amended; posts-and-timeline T24/T25)
The read-budget counters live in instance memory, so every bound is **per instance lifetime**. Numbers are the ADR/plan bounds (derived, not load-tested here).
The measured per-call costs above stay under them: the largest single call, F = 5,000 home, measures 168 reads against the in-flight hold M = 269.
| Actor | Bound | Reads | $ at the §7 price (re-priced 2026-10-23 ADR-0022: $0.035 per 100k reads) |
|---|---|---|---|
| Unverified (minted) password account, any RPC | 0-read verified-identity gate (`PROFILE_REQUIRED` / `EMAIL_NOT_VERIFIED` from token claims) | **0** | $0 |
| One verified account, one instance lifetime | `READ_BUDGET_PER_UID_PER_DAY` 2,000 + in-flight hold 269 - 1 | **2,308** | $0.0008 |
| One verified account, a day, steady state (<= 3 instances) | 3 x 2,308 | **<= 6,924** (13.8% of free) | ≈ $0.0024 |
| Same, rollout day (<= 6 instances) | 6 x 2,308 | <= 13,848 | ≈ $0.005 |
| Same, idle cycling (<= 90 lifetimes/day) | 90 x 2,308 | ≈ 208k | ≈ $0.07 |
| **Deliberate instance churn (residual R2), ceiling** (<= 270 lifetimes/day) | 270 x 2,308 | **≈ 623k per day** | ≈ $0.22/day |
| Verified sybils (residual R1) | per account x accounts | ≈ 8 accounts exhaust a day's free reads | ≈ $0.002/day each |
Detect with `jsonPayload.limit_name` (`read_budget_daily`, `read_budget_inflight`) split by `read_budget_key`, and the `read_budget_spent` field on every request
line; levers are in `docs/runbooks/abuse-spike.md` (T26). The bound is a hard stop on reads only for the account; the cost is cents, not a step change.

### W3 Part A abuse and risk bounds (2026-10-27 W3-23, from `docs/reviews/security-review-w3.md`, W3-22)
Dollar bounds at the §7 prices, INR 95. The reviewer's limits are per instance times the 3 instances of the Cloud Run cap; the read-budget counters are in memory, so a new instance starts at 0 (same caveat as the table above).
| Risk | Bound | Cost |
|---|---|---|
| One account at the daily read budget on any Part A read RPC (tabs, likes, relationship, suggestions) | 2,000 reads per instance per day x 3 = 6,000 | **INR 6.1 per account-month**; a 100-account ring INR 607 (2.4% of the INR 25,000 credit cap) |
| Suggestions storm (10/min, 50/day per instance, so 150 calls/day) | 150 x 42 = 6,300 reads, held to 6,000 by the read budget | the same INR 6.1 per account-month |
| Scrolling the whole 1,000-like list at page 50 | 1,003 reads (measured), half of one instance's budget | INR 0.03 per scroll |
| Viral profile: N viewers on one author's Media tab | linear, no cache: 20 reads per call (measured); 30/min per viewer per instance | 1,000 calls = 20,000 reads = INR 0.67 |
| **M-3** concurrent `FinalizeUpload` calls for one PENDING banner each screen it (2 units per screening) | about 7 concurrent on one instance, 21 at max-instances 3: 14 to 42 units per banner attempt instead of 2 | INR 2 to 6 per attempt; **bounded by the cap**: at most INR 1,283 a month at the Stage 0 cap (10,000 units), INR 5,558 at the credit-mode 40,000 cap (22% of INR 25,000). The harm is the cap spent early (12 to 36 accounts in a day), after which every upload is REJECTED or, under `unscreened_established`, published unscreened. Fix before `media` or `profile_extras` widens past an allowlist in prod; adds 1 write per finalize (under INR 1 a month at 3,000 DAU) |
| **L-4** `UpdateProfile` write flood (pre-existing, no daily cap, the whole `users` doc is rewritten) | 6,000 writes + 6,000 reads per account-day | **INR 24 per account-month** (INR 18 writes + 6 reads); 10 accounts INR 240; 3.3 accounts use the whole 20,000 free writes/day. Fix: a `profile_update_daily` cap and a 0-write no-op |
| **L-1** suggestions re-check of a warm hit against the snapshot | at most +1 read per warm call | INR 0.3 a month at 300 DAU if every call were warm; INR 0.02 at the 5% warm mix |
| **L-5** one account steering the friends-of-friends window | no read change (the query is a Limit 30) | INR 0; a quality and spam signal, watched by `source=fof` with `candidates` at 3 or fewer (§9) |
| ADR-0024 Amendment 1 A4 retire step (planned, not built) | 2 reads, 1 write, 1 TTL delete, 2 Class A per replaced or removed image | INR 0.1 at 300 DAU and 1.0 at 3,000 (ADR) |
## 5. Whole bill by DAU (Vision: every image screened at 2 units, paid past 1,000/month, capped at 10,000 - ADR-0005; re-priced 2026-10-23 ADR-0022)
Stage 0 as configured (min instances 0, Vision cap 10,000, sweep `*/5`). Verified prices (§7), 232.3 reads, 32.4 writes, 7.71 deletes per DAU (ADR-0022 inputs), 12.17 Vision units per DAU-month, INR 95 per USD. **The Stage 0 bill is not INR 0** at any DAU in this table: egress to India is billed from the first GiB, Vision is paid past 82 DAU, and Firestore reads pass the free quota at about 215 DAU.
| DAU | Firestore | Cloud Run (req + CPU + egress) | GCS (ops + egress) | Hosting | SafeSearch | Backups | **Total USD/month** | **INR/month (95)** | FX -5% / +5% |
|---|---|---|---|---|---|---|---|---|---|
| 100 | $0 | $0.08 (egress) | $0.02 | $0 | $0.33 (1,217 units) | $0.04 | **≈ $0.47** | **≈ 45** | 42 / 47 |
| 300 | $0.22 | $0.23 | $0.10 | $0 | $3.98 (3,650 units) | $0.04 | **$4.57** | **434** | 412 / 456 |
| 600 | $0.95 | $0.46 | $0.25 | $0 | $9.45 (7,300 units) | $0.04 | **≈ $11.15** | **≈ 1,059** | 1,006 / 1,112 |
| 1,000 | $2.36 | $0.77 | $0.44 | $0 | $13.50 (cap hit at 822 DAU) | $0.04 | **$17.12** | **1,626** | 1,545 / 1,707 |
| 3,000 | $9.42 | $6.57 (CPU 3.71 + requests 0.54 + egress 2.32) | $6.06 | $0.16 | $13.50 (cap) | $0.04 | **$35.74** | **3,396** | 3,226 / 3,566 |
Strict variant (Vision cap 1,000, no paid SafeSearch; uploads past the cap go to report-driven review): 300 DAU **$0.59 / INR 56**, 1,000 DAU **$3.61 / INR 343**, 3,000 DAU **$22.25 / INR 2,114**. Credit-mode profile (ADR-0022: service-level min instance 1 at $9.86, Vision cap 20,000 up to 1,300 DAU and 40,000 above, sweep every minute), for the 2026-10-23 to 2026-12-24 window only: 300 DAU **$14.44 / INR 1,371**, 1,000 DAU **$30.24 / INR 2,873**, 3,000 DAU **$85.54 / INR 8,127**; about INR 31 per day at 0 DAU. Source and arithmetic: `docs/plans/credit-runway-cost-model.md` §2-§3.
### W2 additions to the bill (2026-10-26 W2-15, priced at the margin)
Added to the table above, not merged into it. Each line is the extra bill with W2 on for every DAU, against the same bill without it, so a quota the product has already passed is billed in full and one it has not is billed only past the free line (reads are past the free quota at all three columns; writes pass it at about 600 DAU, deletes at about 2,400). Inputs: +18.7 reads, +1.7 writes, +0.7 deletes, +0.87 requests, +8.3 KB egress per DAU per day (the ADR's 8 KB of PostViews, plus the quote); Mumbai prices of §7, INR 95.
| INR per month | 300 DAU | 600 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|---|
| Firestore reads | 5.7 | 11.4 | 18.9 | 56.8 |
| Firestore writes | 0 | 1.4 | 5.2 | 15.5 |
| Firestore deletes | 0 | 0 | 0 | 0.8 |
| Cloud Run requests + vCPU-s | 0 | 0 | 0 | 21.1 (3.0 + 18.1; both quotas are passed by 3,000 DAU) |
| Egress to India | 0.8 | 1.7 | 2.7 | 8.2 |
| **W2 total** | **6.5** | **14.4** | **26.8** | **102.4** |
| of which the quote UI | 0.1 | 0.2 | 1.2 | 4.8 |
| **Stage 0 bill with W2, USD / INR** | **$4.64 / 441** (was 434) | $11.30 / 1,074 | **$17.40 / 1,653** (was 1,626) | **$36.82 / 3,498** (was 3,396) |
- **The ADR's "about INR 6 at 300 DAU" is confirmed: 6.4 for bookmarks alone (reads 5.7, egress 0.8), 6.5 with the quote UI.** The 1-write no-op does not change it: writes stay inside the free 20k/day at 300 DAU (10.1k with W2) and cost INR 1.4 more at 600.
- The ADR's 10x column (INR 75 at 3,000 DAU) is low by about 22: it calls Cloud Run "not binding", true to about 1,000 DAU, but at 3,000 DAU the request and vCPU-s quotas are already passed by the product (§4: 1,786 and 1,603 DAU), so the extra 0.87 requests and 2.6 vCPU-s per DAU are billed (INR 21). Bookmarks alone at 3,000 DAU: 97.6. At 600 DAU the ADR's 15 is 13.7 here (writes are priced at the margin).
- No fixed cost, no new resource. Nothing here changes the INR 25,000 credit cap arithmetic (§10): the W2 line is about 1% of the credit-mode bill at 3,000 DAU (INR 102 of 8,127).

### W3 Part A additions to the bill (2026-10-27 W3-23, priced at the margin, on top of the W2 block)
Added to the tables above, not merged into them, with the same method as the W2 block: each line is the extra bill with W3 Part A on for every DAU, against the same bill without it, so a quota the product (baseline plus W2) has already passed is billed in full and one it has not is billed only past the free line. Reads are past the free quota at all four columns, writes pass it at about 600 DAU, Vision's 10,000 cap is reached at about 800 DAU, GCS egress passes 100 GB at about 2,100 DAU, Cloud Run CPU and requests at about 1,500 and 1,600. Inputs: +51.5 reads, +0.06 writes, +0.005 deletes and +2.3 requests per DAU per day (§2), and per DAU-month +0.42 MB Cloud Run egress, +1.34 MB GCS egress, +0.304 Vision units and +30 GCS Class B GETs; Mumbai prices of §7, INR 95.
| INR per month | 300 DAU | 600 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|---|
| Firestore reads | 15.6 | 31.3 | 52.1 | 156.3 |
| Firestore writes + deletes | 0 | 0.1 | 0.2 | 0.5 |
| Vision SafeSearch (banners, Stage 0 cap 10,000) | 13.0 | 26.0 | 0 (at the cap) | 0 (at the cap) |
| GCS (egress + Class B) | 0.3 | 0.7 | 1.2 | 48.3 (44.8 + 3.5) |
| Cloud Run egress to India | 1.4 | 2.8 | 4.7 | 14.0 |
| Cloud Run requests + vCPU-s | 0 | 0 | 0 | 55.5 (7.9 + 47.6; both quotas are passed by 3,000 DAU) |
| **W3 Part A total** | **30.4** | **60.9** | **58.1** | **274.7** |
| of which who to follow (reads only) | 10.8 | 21.7 | 36.1 | 108.3 |
| **Stage 0 bill with W2 and W3 Part A, USD / INR** | **$4.96 / 471** (W2 only 441; baseline 434) | $11.95 / 1,135 (W2 only 1,074) | **$18.01 / 1,711** (W2 only 1,653; baseline 1,626) | **$39.72 / 3,773** (W2 only 3,498; baseline 3,396) |
| Credit-mode W3 Part A (Vision billed: 20,000 cap below 1,300 DAU, 40,000 above; ADR-0022) | 30.4 | 60.9 | **101.4** (Vision 43.3) | **404.7** (Vision 130.0) |
| Credit-mode bill with W2 and W3 Part A (§5 credit profile + W2 + Part A) | 1,408 | n/a | 3,001 | 8,634 |
| ADR-0024 Cost impact, Part A alone | 27 | 54 | 47 | 242 |
- **Idle (0 DAU): W3 Part A adds INR 0.** It adds no service, topic, Scheduler job, Terraform resource or fixed line, so the idle bill stays what §5 has: about INR 4 a month in Stage 0 (the weekly prod backups, $0.04) and about INR 31 a day in credit mode (the min instance, ADR-0022).
- **Against the ADR (INR 27 / 47 / 242): +3 / +11 / +33 a month, all of it Firestore reads from the who-to-follow call mix** (35.7 not 25). Everything else is within INR 1 of the ADR (the GCS egress and Cloud Run egress use 1,024 MB per GiB as §4 does; the ADR used 1,000).
- **Against the INR 434 / 1,626 / 3,396 of CLAUDE.md's honest target and ADR-0022** (the pre-W2 baseline, which this table stacks on): with W2 and Part A on for every DAU the Stage 0 bill is **about INR 471 / 1,711 / 3,773 a month at 300 / 1,000 / 3,000 DAU (+9% / +5% / +11%)**. Every line is pay per use, there is no fixed fee and no step; the baseline numbers in CLAUDE.md stay true for the scope they describe, and the line is worth updating when the flags ramp (not part of this PR).
- Vision is the only line that is not linear: Part A banners are INR 0 at 1,000 and 3,000 DAU in Stage 0 because the 10,000 cap is already reached, at the price of displacing 304 / 913 units a month of post-image screening to `VISION_EXHAUSTED_POLICY`. In credit mode the cap is not reached yet (12,470 units at 1,000 DAU, 37,423 at 3,000), so they are billed. Part A is 4.7% of the credit-mode bill at 3,000 DAU and does not move the INR 25,000 arithmetic of §10 (about +17 a day at 3,000 DAU with W2 included, against a line of 371).
**Firebase Hosting, shared-link visitors (W2-8 share, W2-9 path URLs).** A first-time visitor who opens `https://dzeroth.com/post/<id>` downloads the whole web bundle before anything renders; measured in headless Chrome against a local server mimicking Hosting (`flutter build web --release`, the CI flags, JS renderer; §11): **10 files, 5,937,835 bytes raw, 1,847,149 gzip, 1,453,193 brotli** (CanvasKit comes from gstatic and fonts from Google Fonts, so neither is Hosting transfer). The stale v0.1.0 figure was 0.75 MB per new visitor; the bundle is now about 2.5x that, 73% of it `main.dart.js` and 25% the drift `sqlite3.wasm` + `drift_worker.js`, which a signed-out visitor fetches too.
| First-time visitors/day inside 360 MB/day | gzip 1.85 MB | brotli 1.45 MB | gzip text + raw `.wasm` 2.24 MB | uncompressed 5.94 MB |
|---|---|---|---|---|
| 0 DAU (nothing else on Hosting) | 194 | 247 | 161 | 60 |
| 300 DAU (39 MB/day used by the 4 MB/DAU-month model) | **173** | 220 | 143 | 53 |
| 1,000 DAU (131 MB/day used) | **123** | 157 | 102 | 38 |
| 3,000 DAU (395 MB/day used, already over) | 0 | 0 | 0 | 0 |
- Past the free transfer a visitor costs $0.15/GB x 1.85 MB = INR 0.026, so **1,000 extra visitors in a day (a viral link) cost INR 26**, and the quota is not a cliff. Free headroom is thin only at 1,000 DAU and above: about 120 shared-link visitors a day.
- The 4 MB per DAU-month web model survives the measured bundle only for up to about 3 prod web releases a month: web API calls through the rewrite 2.06 MB (30% of DAU x 37.7 requests x 6 KB x 30.42), revalidating `no-cache` files 0.15 MB, plus 0.3 x 1.85 MB for each release a returning web DAU re-downloads. Weekly web releases (4.3 a month) make it 4.6 MB (+15%, Hosting at 3,000 DAU about $0.43, was $0.16).
- **The knob if the headroom gets thin**, cheapest first: (1) open the drift database only after sign-in (a signed-out visitor then skips `sqlite3.wasm` and `drift_worker.js`, 0.47 MB gzip, 25%); (2) split `main.dart.js` with deferred imports so the sign-in screen is small; (3) hashed names plus `max-age` on the wasm and worker. The watch signal is Hosting transfer above 80% of the day (288 MB) in the Firebase console, no alert policy; none of the three is needed at 300 DAU.

FX: INR 95 per USD is an assumption (mid-market 94.955 on 2026-10-23); +/-5% moves every INR figure by the same +/-5% (INR 90.25 to 99.75). INR billing accounts pay Google's INR SKU prices, which can differ from USD x 95. GST (18%) is not included and its applicability to this account is unverified.
Prod Firestore weekly backups (ADR-0007) are the $0.04 column (about 2 x 0.5 GiB x $0.035); the earlier tables omitted them.
Fixed monitoring line (decision 2026-10-10, R4; the only fixed lines in this table, not DAU-dependent):
prod keeps 4 alert policies (uptime, 5xx rate, Firestore reads, C4 Auth mutations); dev keeps none of the 3 older ones
(gated off in Terraform). Upper bound at the published $0.35 per metric reference per month plus $0.50 per million points
returned: about **$1.05 to $1.20/month** for prod's 3 older policies, plus **about $0.39/month** for C4 (ADR-0011),
so **about $1.45 to $1.60/month** in total (applies only once alerting is charged, see below). Uptime-check executions are inside the 1M free executions per project.
Verified 2026-10-23 (ADR-0022, Cloud Monitoring pricing page): alerting charges start no sooner than 2027-09-01, and billing, quota and uptime-metric policies are not charged. **So the fixed monitoring line above is $0 until 2027-09-01** and the $1.45 to $1.60/month upper bound applies only from that date; re-check before it.
Nothing else in this table is a fixed fee; every other line falls back to $0 with traffic. With paid SafeSearch at 2 units per image the $5 budget alert (ADR-0007; INR 500 is about $5.26) fires at about 320-330 DAU on this table (was about 520; interpolated between 300 DAU at $4.57 and 600 DAU at $11.15). Raise the budget amount or accept the alert as the signal (config change, not an ADR); ADR-0022 adds the credit-runway gross budget (§10).

## 6. Levers, cheapest first (use before any Stage 2 ADR)
0. **Older-page over-read: k from `2p` to `1.5p` (ADR-0010 reserve lever; its trigger has fired, older page = 2.0 x page).** Derived, not measured: two chunks at k = 15 instead of 20 saves ≈ 10 reads per older page, so ≈ -10 reads/DAU (back to ≈ 183 released). Needs a one-constant backend change and a re-run of the timeline budget tests; flagged for P9.
1. Notifications list via `since` + client cache (like the timeline): −15 reads/DAU → reads free to ~250 DAU.
2. GetThread first page 10 instead of 20; lazy "show replies": −5 reads/DAU.
3. Older-page prefetch only after the user scrolls past 70% (never on open): −5…10 reads/DAU.
4. Like notifications collapsed per post per hour (update one doc): writes/like 4 → ~3.3 at scale.
5. Cloud Run CPU: gzip and binary proto (already), avoid per-request allocations in the merge; raise concurrency
   overlap by keeping max instances at 3.
6. Image egress: keep thumbnails ≤ 40 KB; never load `url` in lists.
Scale-up triggers remain those in `free-tier-budget` §6 (Firestore > 1.5M reads/day ≈ 6.5k DAU on this model, or bill > $30/month ≈ 2.4k DAU on the 2026-10-23 ADR-0022 table in §5).
- **ADR-0023 trigger (2026-10-26 W2-15): ListBookmarks reads above 15% of the daily Firestore reads, or the Firestore trigger above (more than 1.5M reads/day or a bill above $30/month), sustained 7 days, needs an ADR for the Stage 2 saved-list design** (a `bookmarks(uid, post_id, created_at)` table joined server-side, or Memorystore; ADR-0023 stage ladder). Modelled share: 16.9 of 248.7 reads = **6.8%**; it reaches 15% at about 2.2x the modelled list usage (0.9 list-page opens per DAU a day). Plan rollback line (W2 plan, Rollout): bookmark reads per DAU above twice the model, i.e. above about 37. Measure it with the query in `docs/runbooks/bookmarks.md` "Cost trigger" (Logs Explorer filter plus a `gcloud logging read` + `jq` share; `make cost` prints the raw lines but no share column) and §9.
- **ADR-0024 triggers (2026-10-27 W3-23; `stage-ladder` rows "Who to follow" and "Profile tabs", plan Out of scope): any one, sustained 7 days, needs an ADR before the next step** (the architect writes it; `sre-performance` raises it). The rollback line of the plan is separate: reads per DAU on the Part A RPCs above twice the model (about 103), or an error rate above 2% for 15 minutes on a new RPC.

  | Trigger | Next rung (Stage 2/3 target, not built) | Modelled value | Fires at |
  |---|---|---|---|
  | **Suggestion reads above 10% of the daily Firestore reads** | a precomputed table refreshed by a batch job over a Firestore export (served at 1 read), then a ranking ADR | **35.7 of 300.2 = 11.9%: already above the line at the modelled usage** (the ADR's 25 gave 8.7%, 1.17x of headroom) | now; it needs suggestions 18% below the model to be under it |
  | Tabs plus likes list reads above 15% of the daily reads | a per-tab instance cache, then Memorystore with the Stage 2 timeline | 14.05 of 300.2 = 4.7% | about 3.6x the modelled tab and likes usage (about 2.3 first-page opens per DAU a day against 0.65 modelled) |
  | The `free-tier-budget` §6 Firestore trigger: more than 1.5M reads/day or a bill above $30/month | tighter caching, then Memorystore or Cloud SQL | 300.2 reads/DAU: 1.5M at about 4,996 DAU (6,030 with W2 alone); bill: about 2,105 DAU (W2 alone about 2,300; baseline about 2,400), by linear interpolation of the §5 points | not before about 2.1k DAU |

  - **The first row is a decision for the architect and the founder, not an incident, and it is cheap to fix before the flag ramps.** Levers, cheapest first, with the share each leaves (the others unchanged): a 48 h client cache instead of 24 h (a W3-19 constant; halves the calls, 17.8 reads/DAU, **6.3%**); `SUGGESTIONS_EDGE_LIMIT` 20 (a Terraform var; friends-of-friends cap 42 to 32, 27.6 reads/DAU, 9.4%); `SUGGESTIONS_HYDRATE_MAX` 7 (cap 39, 32.8, 11.0%, not enough alone); curated-only for accounts that follow fewer than 10; both of the first two together 13.8 reads/DAU, 5.0%. Or the architect moves the line (the plan has tabs plus likes at 15%). Until one of those is chosen, the trigger will read as "fired" in the first week of any ramp and should be read against the model, not as a regression: what matters is the measured share against 11.9% and whether `fs_reads` per call stays at or under 42.
  - What to watch (queries in §9; no new alert policy, no new log-based metric): `fs_reads` per Part A RPC (suggestions 42 cold / 12 curated / 0-1 warm, likes 23 / 53 first page, tabs 20-24 at page 20, relationship 0-4); the suggestions share of `document/read_count` daily; `source=fof` with `candidates` at 3 or fewer (L-5: a steering account or a sparse graph, not a cost change); `suggestions_cache_hit` (the 5% warm assumption); Vision units per day and the month's total against `VISION_MONTHLY_CAP` (`make cost`, `scripts/cost-vision.sh`), with BANNER finalizes against units (M-3: units above 2 per ready banner mean repeated screening).

## 7. Prices used (verified 2026-10-23, ADR-0022; sources and URLs in `docs/plans/credit-runway-cost-model.md` §1b)
Replaces the 2026-09-26 upper-bound prices from memory. Verify again before each stage change and after any Google pricing notice.
- Firestore **asia-south1 (Mumbai)**: $0.035 / 100k reads, $0.104 / 100k writes, $0.012 / 100k deletes (TTL deletes the same price, no free quota), $0.104 / GiB-month storage, backup $0.035 / GiB-month, restore $0.23 / GiB. Free 50k reads, 20k writes, 20k deletes per day and 1 GiB. (Was $0.06 / $0.18 / $0.02 / $0.18 upper bounds.)
- Cloud Run (request-based, asia-south1 is Tier 1): $0.000024 / vCPU-s active, $0.0000025 / vCPU-s idle min instance, $0.0000025 / GiB-s, $0.40 / million requests. Free 2M requests, 180,000 vCPU-s, 360,000 GiB-s per billing account, applied as a Tier 1 spend discount. Idle non-minimum instances and IAM-denied requests are not billed.
- Internet egress to India (Cloud Run, GCS): $0.12 / GiB, **always billed**: Cloud Run's free 1 GiB is North America only, and GCS's free 100 GB applies to egress from North America.
- GCS Standard us-central1: Class A $0.005 / 1k, Class B $0.0004 / 1k, $0.020 / GB-month.
- Cloud Vision SafeSearch: first 1,000 units / month free, then $1.50 / 1,000 units. **2 units per image** (full image + thumbnail, `VISION_SCREEN_THUMB=true`; verified in `backend/internal/media/service.go` `finalizeOne`). Cap-exhaustion DAU for a 10,000 cap = 10,000 / 12.17 units per DAU-month = about 820 (1,000 free units run out at about 82 DAU).
- Cloud Monitoring alerting: not charged before 2027-09-01; billing, quota and uptime-metric policies are not charged; 1M uptime executions free.
- Firebase Hosting: $0.15 / GB beyond 360 MB/day, 10 GB storage free then $0.026 / GB.
- Currency: INR 95.0 per USD (assumption, mid-market 94.955 on 2026-10-23), +/-5% sensitivity; GST 18% not included.

## 8. Actuals (sre-performance appends weekly)
| Week | DAU | reads/day | writes/day | deletes/day | CR requests/mo | CR vCPU-s/mo | GCS egress GB | Bill | Model error |
|---|---|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | — | — | — |

## 9. Dashboard notes (Logs Explorer; no new log-based metric, no new alert policy)
- Graph reads by operation (T21): `jsonPayload.graph_op!="" | sum fs_reads by graph_op`
  (Log Analytics form: `SELECT JSON_VALUE(json_payload.graph_op) AS graph_op, SUM(CAST(JSON_VALUE(json_payload.fs_reads) AS INT64)) ... GROUP BY graph_op`).
- **Works since PR #36** (updated 2026-09-30): every graph RPC's request line carries `graph_op`, `outcome`,
  `txn_attempts`, `graph_cache_hit`, `edges_removed` (Block) and `feature_disabled` (flag rejections) next to `rpc`,
  `fs_reads`/`fs_writes`/`fs_deletes` and `limit_name`; a WARN `graph_txn_contention` fires when `txn_attempts > 3`
  (`backend/internal/graph/observe.go`; queries in `docs/runbooks/graph.md` §3). Fallback for log lines older than that
  deploy: `jsonPayload.rpc:"GraphService" | sum fs_reads by rpc`.
- Still **not** emitted: `rows_filtered` and `hydration_misses` (lists), and `lazy_removed` (until T27 ships). The purge
  lines `graph_purge_batch` / `purge_missing_counterpart` exist but are written by `opsctl` on the operator's terminal,
  not by the `api` service, so they are not in Cloud Logging.
- Existing alerts (uptime, 5xx, Firestore reads > 40k/day) are unchanged; the graph adds no alert policy.
- **Posts and timeline (T25).** Same form as the graph query above. Fields on the request line: `rpc`, `fs_reads`, `fs_writes`, `fs_deletes`, `posts_op`
  (`create|get|delete`), `outcome` (`created|replay|found|not_found|deleted|noop:not_owner|rejected:<reason>`), `timeline_op` (`home|user`), `timeline_mode`
  (`cold|refresh|older|gap`), `page_size`, `graph_cache_hit`, `timeline_chunks`, `authors_from_cache`, `items_returned`, `read_budget_spent`.
  - **Reads by RPC, Post and Timeline:** `jsonPayload.rpc=~"PostService|TimelineService" | sum fs_reads by rpc`
    (Log Analytics form, only if enabled; it is not at Stage 0: `SELECT JSON_VALUE(json_payload.rpc) AS rpc, SUM(CAST(JSON_VALUE(json_payload.fs_reads) AS INT64)) AS reads, COUNT(*) AS calls ... WHERE JSON_VALUE(json_payload.rpc) LIKE '%PostService%' OR JSON_VALUE(json_payload.rpc) LIKE '%TimelineService%' GROUP BY rpc`).
  - By operation: `jsonPayload.posts_op!="" | sum fs_reads by posts_op` and `jsonPayload.timeline_op!="" | sum fs_reads by timeline_op, timeline_mode` (split `outcome` for posts).
  - The T25 revisit signal: mean `fs_reads` where `timeline_mode="older"` over 7 days, against 40 (modelled) and 30 (ADR). Above 1.4 x `page_size` means apply the k lever.
  - Per-user spread: `jsonPayload.read_budget_spent` (never a body or text; `uid_hash` only).
- **Notifications fan-out (N-1/N-2 hardening).** The Pub/Sub push handler's per-delivery line (`message="notification_delivery"`) now carries `rpc="internal.NotificationsFanout"`, `fanout_fs_reads` (equal to `fs_reads`, kept as its own project-level field), `push_throttled` and `created`/`pushed`; `make cost` prints `fanout_fs_reads`. **Totals:** daily Firestore reads = `sum(fs_reads) + sum(removal_log_reads)`; `removal_log_reads` (the detached shared removal-log refresh on `since_token` timeline refreshes) is logged separately and is not in `fs_reads`, while `fanout_fs_reads` duplicates `fs_reads` on the fan-out line and must not be added again. `make cost` prints both columns. Fan-out reads: `jsonPayload.rpc="internal.NotificationsFanout" | sum fanout_fs_reads`. Producer-side drops: `jsonPayload.message="notification_fanout_capped"` (count by `actor_hash`).
- No new log-based metric or alert policy. The existing "reads > 40k/day" alert fires at ≈ 207 DAU for the released scope (≈ 174 whole product).
- **Bookmarks (2026-10-26 W2-15).** The exact `rpc` string is `/dzeroth.engagement.v1.EngagementService/ListBookmarks` (from the smoke log, §11); the three bookmark RPCs also carry `engagement_op` (`add_bookmark`, `remove_bookmark`, `list_bookmarks`), `outcome`, and for the list `rows_returned`, `rows_dropped*`, `rows_pruned`, `posts_cache_hit`, `graph_cache_hit`. ListBookmarks reads: `jsonPayload.rpc="/dzeroth.engagement.v1.EngagementService/ListBookmarks" | sum fs_reads`; all bookmark reads: `jsonPayload.engagement_op=~"bookmark" | sum fs_reads by engagement_op`. The ADR-0023 trigger share (ListBookmarks reads / all Firestore reads, a 24 h window): the numerator is the first filter; the primary denominator is the Cloud Monitoring metric `firestore.googleapis.com/document/read_count` (daily sum, it includes cron, job and fan-out reads); the log cross-check sums `fs_reads` + `removal_log_reads` over every line that has `fs_reads` (the fan-out `notification_delivery`, the account jobs and the sweep log theirs on non-`request` lines, so a `message="request"` filter alone under-counts), without `fanout_fs_reads` (a duplicate) and without the WARN `scheduled_author_reads`. The one-line `gcloud` + `jq` form is in `docs/runbooks/bookmarks.md` "Cost trigger".
- **W3 Part A (2026-10-27 W3-23).** Request-line fields (all counts and enums, never uids): `GetUserTimeline` carries `tab` (`posts|replies|media|reposts`), `page_size`, `timeline_mode`, `graph_cache_hit`, `userlikes_cache_hit`; `ListLikedPosts` carries `engagement_op=list_liked_posts`, `rows_returned`, `rows_dropped*`, `posts_cache_hit`, `userlikes_cache_hit`; `GetProfileRelationship` carries `graph_op=profile_relationship`, `graph_cache_hit`, `followed_by_cache_hit`; `ListSuggestedUsers` carries `source` (`fof|curated|none`), `candidates` (uids sent to hydration, at most 10), `suggestions_cache_hit`, `graph_cache_hit`; `CreateUpload` / `FinalizeUpload` carry `purpose` and `vision_units`; the pin step of the `post_delete` job reports outcome `pin_cleared`, `noop` or `refused`. The exact `rpc` strings end in `/GetUserTimeline`, `/ListLikedPosts`, `/GetProfileRelationship`, `/ListSuggestedUsers`.
  - **Daily shares for the §6 triggers** (read-only, once a day while a Part A flag is on in prod, dev for the allowlist; the same shape and the same denominator as the ListBookmarks query in `docs/runbooks/bookmarks.md` "Cost trigger"; the primary denominator is the Cloud Monitoring metric `firestore.googleapis.com/document/read_count`, this log sum is the cross-check; tested on the §12 emulator logs):
    ```
    gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND jsonPayload.fs_reads:*' \
      --project=dzeroth-prod --freshness=1d --limit=200000 --format=json \
    | jq '[.[].jsonPayload | select(.message != "scheduled_author_reads")] | {all_reads: (map((.fs_reads // 0) + (.removal_log_reads // 0)) | add // 0), sug_reads: (map(select((.rpc // "") | endswith("/ListSuggestedUsers")) | (.fs_reads // 0)) | add // 0), tab_reads: (map(select(((.rpc // "") | endswith("/GetUserTimeline")) and ((.tab // "") == "media" or (.tab // "") == "reposts")) | (.fs_reads // 0)) | add // 0), like_reads: (map(select((.rpc // "") | endswith("/ListLikedPosts")) | (.fs_reads // 0)) | add // 0)} | .sug_share_pct = (if .all_reads == 0 then 0 else ((1000 * .sug_reads / .all_reads) | round / 10) end) | .tabs_likes_share_pct = (if .all_reads == 0 then 0 else ((1000 * (.tab_reads + .like_reads) / .all_reads) | round / 10) end)'
    ```
    Seven consecutive days with `sug_share_pct` above 10, or `tabs_likes_share_pct` above 15, fires the trigger (§6); read the first against the model's 11.9%, not against zero.
  - **Suggestions mix and the L-5 signal** (same `gcloud` line, then):
    ```
    jq '[.[].jsonPayload | select((.rpc // "") | endswith("/ListSuggestedUsers"))] | {calls: length, warm_hits: (map(select(.suggestions_cache_hit == true)) | length), cold: (map(select(.suggestions_cache_hit == false)) | length), fof: (map(select(.suggestions_cache_hit == false and .source == "fof")) | length), curated: (map(select(.suggestions_cache_hit == false and .source == "curated")) | length), fof_low_candidates: (map(select(.suggestions_cache_hit == false and .source == "fof" and (.candidates // 0) <= 3)) | length), mean_cold_reads: (([.[] | select(.suggestions_cache_hit == false) | (.fs_reads // 0)] | add // 0) / ([.[] | select(.suggestions_cache_hit == false)] | length | if . == 0 then 1 else . end))}'
    ```
    The model assumes `warm_hits / calls` about 5%, `curated / cold` about 15% and `mean_cold_reads` about 37 (0.85 x 42 + 0.15 x 12); a mean above 42 is a regression (`SUGGESTIONS_EDGE_LIMIT` and `SUGGESTIONS_HYDRATE_MAX` bound it); `fof_low_candidates` high relative to `fof` is L-5 (one followee steering the window, or a sparse graph), a quality signal with no cost change.
  - **Vision units per day** (M-3): `make cost PROJECT_ID=dzeroth-prod` prints the month's units against `VISION_MONTHLY_CAP` and today's from `vision_units` on FinalizeUpload lines. For banners, sum `vision_units` and count the lines with `purpose="BANNER"`: more than 2 units per ready banner on average means repeated screening (concurrent finalizes), which spends the cap early. Expected banner units: 0.30 per DAU-month.
  - **Per-RPC reads against the model** (cold / warm): `jsonPayload.rpc=~"GetUserTimeline|ListLikedPosts|GetProfileRelationship|ListSuggestedUsers" | sum fs_reads by rpc`, then mean per `rpc`, `tab` and `page_size`; the rollback line is Part A reads per DAU above twice the model, about 103.
  - No new log-based metric, alert policy or dashboard chart: the existing "reads > 40k/day" alert fires at about 133 DAU with every Part A flag on (§3).


## 10. Daily gross burn against the credit-runway line (2026-10-23 ADR-0022)
> Amendment 1 of ADR-0022 (2026-10-26): the cap is now 25,000 (INR 403/day to the pause, 391/day to 12-26). The arithmetic below keeps the 23,000 figure.

ADR-0022 funds a bounded window from the Google credit: `credit_spend_cap_inr` = INR 23,000 from 2026-10-23, paused on 2026-12-24 unless a RESUMED ADR is approved (cap formula `min(23,000, remaining credit - 2,000)`).
- **Straight line to the budget end (2026-12-26, 64 days):** 23,000 / 64 = **INR 359 per day** (359.4).
- **Straight line to the planned pause (2026-12-24, 62 days):** 23,000 / 62 = **INR 371 per day** (371.0). This is the line the ADR and `credit-runway-cost-model.md` §4 use; the cumulative line on day N is 371 x N.
- **Expected burn (credit mode, model):** about INR 31 per day at ~0 DAU, 45 at 300 DAU, 94 at 1,000 DAU, 267 at 3,000 DAU (cumulative 71% of the cap at 3,000 DAU by 12-24). Stage 0 as configured: 14 / 53 / 112 per day. Anything above the line means a knob or traffic is wrong, not that the plan is working.
- **How to read it (2 minutes a day, founder or sre-performance):** Cloud Console > Billing > Reports, billing account scope (not a project), date range 2026-10-23 to today, **Group by SKU**, in the Credits filter untick everything so the view is gross (promotional credit must not be subtracted, otherwise every figure reads INR 0). Currency INR. Read the cumulative total and divide by days elapsed, then compare with 371 x day. The SKUs that explain a miss: Cloud Run `CPU Allocation Time` / `Memory Allocation Time` and the min-instance (idle) SKUs, `Cloud Vision` SafeSearch units, Firestore `Read Operations` / `Write Operations` in Mumbai, `Networking` internet egress, Cloud Storage `Class B Operations`. Billing data lags by hours to more than a day, so the fast signals are the request-count alert and `make cost` (below), not this report.
- **Vision units:** `make cost PROJECT_ID=dzeroth-prod` prints units used this month (Firestore `admin/vision-YYYYMM` field `units`, UTC month) against `VISION_MONTHLY_CAP`, and units today (sum of `vision_units` on FinalizeUpload request lines since 00:00 UTC). Without gcloud/Firestore credentials it prints `needs gcloud/Firestore credentials` and exits 0 (`scripts/cost-vision.sh`). Each unit past the first 1,000 a month is INR 0.1425 (1.50 USD per 1,000 x 95).
- **Thresholds** on the credit budget are 10 / 25 / 50 / 75 / 90 / 100% of the cap (2026-10-29, 11-07, 11-23, 12-08, 12-17, 12-24 on the straight line); an alert that arrives earlier than its date is the trigger to look the same day (`docs/adr/0022-credit-funded-runway.md`).
- Weekly: append the cumulative gross burn, the line value for that day and the top 3 SKUs to §8 (Bill column).

## 11. W2-15 measurements (2026-10-26, emulators and a local build only; nothing was run against a cloud project)
Machine: Windows 11, 16 logical processors (Intel family 6 model 154), Go 1.26 API binary, k6 2.2.0, Firebase emulators (Firestore, Auth, Storage) on the `firebase.graph-loadtest.json` ports, headless Chrome 156. Emulator latency is indicative only.

### ListBookmarks smoke (`make loadtest SCENARIO=engagement_bookmarks_list`)
Scenario `loadtest/engagement_bookmarks_list.js`, reads from the API request log with `node loadtest/analyze_bookmarks.js api.log`. Setup: 10 viewers (5 pairs), 50 authors x 20 posts, each viewer bookmarks its own 100 posts (disjoint sets, so no viewer warms another's post cache), then 75 s idle (CACHE_TTL 60 s). Then each viewer pages its whole list twice (the first pass is cold, the second warm: even viewers at page size 20, odd viewers at 50), then 4 warm passes/s for 30 s over the 10 viewers.
API environment for the recorded run (nothing else changed from defaults): `FEATURE_POSTS=on FEATURE_BOOKMARKS=on FEATURE_ENGAGEMENT=on`, `RATE_LIMIT_PER_IP_PER_MIN=1000000`, `RATE_LIMIT_PRE_AUTH_IP_PER_MIN=1000000`, `RATE_LIMIT_POST_CREATE_PER_MIN=1000`, `QUOTA_NEW_ACCOUNT_POSTS_PER_DAY=1000`, `RATE_LIMIT_BOOKMARKS_PER_MIN=1000`, `QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY=1000`, `QUOTA_BOOKMARKS_PER_DAY=1000`, `RATE_LIMIT_BOOKMARKS_LIST_PER_MIN=100000`, `READ_BUDGET_PER_UID_PER_DAY=10000000` (the budget run keeps the default 2000); k6 `PAIRS=5 RATE=4`.
| Case (100 bookmarks per viewer) | calls | `fs_reads` | server ms p50 / p95 |
|---|---|---|---|
| page 20, cold, first page | 5 | **43** (43 every time) | 174 / 179 |
| page 20, cold, later pages (4 per pass) | 20 | **40** | 25 / 43 |
| page 20, cold, terminal empty page (100 is an exact multiple) | 5 | 1 | 9 / 13 |
| page 20, warm, first + later pages | 66 + 264 | **20** | 4 / 16 and 4 / 11 |
| page 20, warm, terminal empty page | 66 | 1 | 3 / 6 |
| page 50, cold, first page | 5 | **103** | 176 / 177 |
| page 50, cold, second page | 5 | **100** | 46 / 54 |
| page 50, cold, terminal empty page | 5 | 1 | 13 / 23 |
| page 50, warm, first + second page | 65 + 65 | **50** | 4 / 17 and 4 / 12 |
| page 50, warm, terminal empty page | 65 | 1 | 3 / 12 |
- Writes 0 on every call (nothing to prune), 0 ERROR lines, 0 failed requests, 141 of 141 k6 checks passed (every pass lists all 100 rows once).
- k6 client-side latency (includes the loopback): page 20 cold p50 34.8 ms / p95 185 ms (30 calls), page 50 cold 49.9 / 186 ms (15 calls), page 20 warm 4.9 / 13.9 ms, page 50 warm 5.5 / 22.7 ms. All under the 400 ms Stage 0 target; the cold first page is the slow one because it does 43 or 103 emulator reads.
- **The per-uid daily read budget is charged.** `read_budget_spent` rose by exactly `fs_reads` between consecutive requests of the same viewer in 626 of 626 pairs. Budget run (default `READ_BUDGET_PER_UID_PER_DAY` 2000): one viewer seeded 100 bookmarks (308 reads, 100 AddBookmark), then paged at 50: 103, then 50 per page; the call that crossed 2000 was served (spent 2,011) and the next one answered 429 `RESOURCE_EXHAUSTED` with `limit=read_budget_daily` at 0 reads (the 34th list call; 33 pages = 1,703 list reads). So a user at the 1,000 cap reading 50-row cold pages exhausts the day's budget in about 19 pages, or about 100 pages of 20 once the posts are warm.
- AddBookmark in the same run (seeding, 1,000 calls): 3 reads in 950 calls, 4 in 40, 5 in 10 (mean 3.06), 4 writes each. CreatePost in setup: 2 or 3 reads.

### Web bundle for a first-time shared-link visitor
`flutter build web --release --dart-define=USE_EMULATORS=false --dart-define=FIREBASE_ENV=dev --dart-define=API_BASE_URL=/api` (the deploy-dev flags; Flutter 3.47.5, the CI pin, revision 6a19cca564; built from `main` at 46b9e0f, which has **neither W2-8 (`share_plus`) nor W2-9 (path URLs)**, so web share adds an unmeasured delta to `main.dart.js` and the `/post/<id>` load is otherwise unchanged; dart2js, CanvasKit renderer from gstatic; 81 s). The fetch list is what a fresh Chrome profile requested from a static server over `app/build/web` that rewrites unknown paths to `index.html` (as Hosting does) for 25 s on `/post/1234567890123456789`; anything not requested from that server (CanvasKit from `www.gstatic.com`, Google Fonts) is not Hosting transfer. The service worker is Flutter's self-unregistering stub, so there is no precache. Sizes by Node `zlib` (gzip level 6, brotli quality 11); request and response headers (about 4 KB over 10 requests) are not counted.
| File | raw | gzip | brotli |
|---|---|---|---|
| `main.dart.js` | 4,779,804 | 1,355,678 | 1,029,239 |
| `sqlite3.wasm` (drift, fetched at start-up even signed out) | 748,686 | 360,168 | 314,419 |
| `drift_worker.js` | 370,672 | 109,598 | 89,964 |
| `assets/fonts/MaterialIcons-Regular.otf` (tree-shaken) | 16,796 | 9,323 | 8,303 |
| `flutter_bootstrap.js` | 13,093 | 5,178 | 4,478 |
| `icons/Icon-192.png` | 5,292 | 5,213 | 5,170 |
| `index.html` (the rewritten `/post/<id>`) | 1,548 | 763 | 532 |
| `manifest.json`, `favicon.png`, `assets/FontManifest.json` | 1,944 | 1,228 | 1,088 |
| **Total, 10 files** | **5,937,835** | **1,847,149** | **1,453,193** |
Not counted: `canvaskit/` (25 MB in the build, deployed to Hosting but never requested: `flutter_bootstrap.js` loads CanvasKit from gstatic), `flutter.js` (not requested), `NOTICES`. `drift_worker.js` was requested twice by the browser against a server with no cache headers; it is counted once. Whether Hosting compresses `.wasm` and `.otf` was not verified (docs say it compresses with gzip or brotli when the browser accepts it); the §5 table therefore also shows the gzip-text, raw-`.wasm` case (2,235,667 bytes). A returning visitor sends conditional GETs for the `no-cache` files (`index.html`, `main.dart.js`, `flutter_bootstrap.js`, per `firebase.json`) and re-downloads `main.dart.js` only after a prod web release.

### What was not measured
- A signed-in session's web transfer (sign-in needs real Firebase Auth); the 4 MB per DAU-month line is still the model's, with the 6 KB per API call the doc has used.
- Cold-start and Cloud Run CPU for the bookmark RPCs (emulators only; the Cloud Run ms column is an estimate), and the instance cache hit rate (no traffic).
- Add/Remove/List on a cold Firestore instance in the cloud; the dev smoke after the W2-16 apply (a handful of reads) is the first real number.

## 12. W3-23 measurements (2026-10-27, emulators and the repository's own budget tests only; nothing was run against a cloud project)
Machine: Windows 11, 16 logical processors, Go 1.27.0 toolchain building the API from `main` fcd0145 (W3-4 to W3-19 merged), k6 2.2.0, Node for the analyzer, firebase-tools 15.31.0 with Firestore, Auth, Pub/Sub and Storage on the alternate ports of `firebase.graph-loadtest.json` (18080 / 19099 / 18085 / 19199) and the API on :18081, so another session's suite on 8080 was never touched; torn down afterwards. Emulator latency is indicative only.
Scenario `loadtest/profile_w3_part_a.js` (new, one file, `MODE=tabs|likes|suggestions`; header documents every knob), reads from the API request log with `node loadtest/analyze_w3_part_a.js api.log`. A fresh API process per run (cold caches), `CACHE_TTL` 60 s, `SUGGESTIONS_CACHE_TTL` 1 h.
API environment for every run: `ENV=local FEATURE_POSTS=on FEATURE_GRAPH=on FEATURE_ENGAGEMENT=on FEATURE_PROFILE_TABS=on FEATURE_LIKES_LIST=on FEATURE_FOLLOW_SUGGESTIONS=on RATE_LIMIT_PER_IP_PER_MIN=1000000 RATE_LIMIT_PRE_AUTH_IP_PER_MIN=1000000 RATE_LIMIT_USER_TIMELINE_PER_MIN=100000 RATE_LIMIT_LIKES_LIST_PER_MIN=100000 RATE_LIMIT_SUGGESTIONS_PER_MIN=100000 RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN=100000`. Seeding only: `RATE_LIMIT_POST_CREATE_PER_MIN=100000 QUOTA_POSTS_PER_DAY=100000 QUOTA_NEW_ACCOUNT_POSTS_PER_DAY=100000 RATE_LIMIT_LIKES_PER_MIN=100000 QUOTA_LIKES_PER_DAY=100000 QUOTA_NEW_ACCOUNT_LIKES_PER_DAY=100000` (tabs, likes), plus `READ_BUDGET_PER_UID_PER_DAY=10000000` (likes, suggestions; **the tabs run kept the default 2000**) and `RATE_LIMIT_GRAPH_FOLLOW_PER_MIN=100000 QUOTA_FOLLOWS_PER_DAY=100000 QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY=100000 GRAPH_MUTATIONS_PER_DAY=100000 SUGGESTED_USER_IDS=<12 uids from node loadtest/analyze_w3_part_a.js --curated-ids 12>` (suggestions). The Media tab selects on `hasMedia`, which only the image-upload path writes, so setup patches it through the Firestore emulator's REST API (no Vision path involved).

### Tabs, relationship (`MODE=tabs`: 1 author with 60 media posts, 30 plain posts, 60 reposts; 40 viewers)
Setup idles 65 s so every cache is cold. A solo VU runs first (viewer 0 on the Media tab, viewer 1 on `GetProfileRelationship` of another account), then 38 viewers do the profile-open flow, then a viral load of 15 calls/s for 20 s on the Media tab.
| Case | calls | `fs_reads` | server ms p50 / p95 |
|---|---|---|---|
| Media p20, nothing cached anywhere (solo) | 1 | **24** | 18 |
| Media p20, second call | 1 | 20 | 6 |
| GetProfile of the author (the header; target cached by then) | 38 | 2 | 22 / 63 |
| GetProfileRelationship, nothing cached (solo) | 1 | **4** | 2 |
| GetProfileRelationship, repeat | 1 | **0** | 1 |
| GetProfileRelationship right after GetProfile | 38 | **1** | 27 / 58 |
| Media p20, first tab call after the header's calls | 38 (+ 1 later first call) | **21** (one `userLikes` read) | 59 / 88 |
| Media p20, later calls (second call of the flow, then the viral load) | about 340 | **20** | 7 / 12 (viral) |
| Reposts p20, first and second call | 38 + 38 | **20** and **20** | 58-61 / 90-99 |
| Media p50, first page (odd viewers) | 19 | **50** | 31 / 90 |
| Media p50, second page (the 10 rows left) | 19 | **10** | 18 / 32 |
- 0 writes, 0 ERROR lines, 0 failed requests, `read_budget_spent` rose by exactly `fs_reads` between consecutive calls in 531 of 531 pairs, and the largest `read_budget_spent` of any account in the run was 466 (the default limit is 2000). The k6 thresholds held: Media warm p95 88.8 ms, viral p95 14.8 ms (both under 400).
- **The viral profile is linear**: 300 calls on one author's Media tab read 6,000 documents in 20 seconds, 20 each, because the tabs have no result cache. At the per-viewer 30/min limit and 3 instances a single viewer cannot read more than 90 pages a minute (1,800 reads).
- The 54 at page 50 cold and the 24 / 54 ceilings are the chain budget tests below (`profile_tabs_integration_test.go`); the k6 run shows the warm and typical figures.

### Likes list (`MODE=likes PAIRS=2 LIKES=60 CAP_LIKES=1000`)
4 viewers with 60 likes of their own authors' posts (disjoint, so no viewer warms another's posts) plus one viewer at the 1,000 cap; setup idles 75 s; each pass lists every like once (k6 check green on all 9 passes).
| Case | calls | `fs_reads` | server ms p50 / p95 |
|---|---|---|---|
| page 20, cold, first page | 2 | **23** | 34 |
| page 20, cold, later pages (2 per viewer) | 4 | **20** | 7 / 8 |
| page 20, immediate second pass (all 20 posts of each page cached) | 6 | **0** | 1-3 |
| page 50, cold, first page | 2 (+ the cap viewer) | **53** | 37 / 40 |
| page 50, cold, second page (the 10 rows left) | 2 | **10** | 7 / 8 |
| page 50, immediate second pass | 4 | **0** | 2-3 |
| the cap viewer: 1,000 likes, 20 pages at 50 | 20 | **53** then 19 x **50** = **1,003** | 4-5 |
- 0 writes, 0 ERROR lines; the read budget was charged exactly (35 of 35 pairs). A scroll of the whole capped list is 1,003 reads, half of one instance's default 2000; at the default 10/min limit it takes two minutes.

### Suggestions (`MODE=suggestions`: 6 viewers each following 30 accounts, the 30 followees follow 4 of 60 candidates each, 12 curated uids, 3 viewers who follow nobody; then `FOLLOWEES=600 VIEWERS=1 CURATED_VIEWERS=0`)
Call 1 immediately after a 65 s settle, call 2 straight after, call 3 after 65 s (the 60 s profile cache expired, the 1 h suggestion entry not).
| Case | calls | `fs_reads` | source / `candidates` | server ms p50 / p95 |
|---|---|---|---|---|
| friends of friends, cold (6 concurrent first calls) | 6 | **42** x 5, 33 x 1 | `fof` / 10 | 70 / 73 |
| friends of friends, call 2 (suggestion entry) | 6 | **0** | cache hit | 2 / 4 |
| friends of friends, call 3 (after the 60 s profile cache) | 6 | **1** | cache hit | 19 / 23 |
| curated, cold (3 viewers, 12 ids) | 3 | **12** x 1, **2** x 2 (the curated profiles had just been cached by the first viewer) | `curated` / 10 | 20 / 23 |
| curated, call 2 | 3 | **0** | cache hit | 2 |
| **600 followees**: cold / call 2 / call 3 | 1 + 1 + 1 | **42** / 0 / 1 | `fof` / 10 | 193 / 1 / 10 |
- 0 writes, 0 ERROR lines, the read budget charged exactly (15 of 15 pairs, 2 of 2 at 600 followees). The cap does not grow with the number followed (30 and 600 followees both read 42). All six first calls of the run were concurrent, which is why only one of them saw profiles cached by the others (33); with few concurrent users at Stage 0 the typical cold call is 42.

### Budget tests re-run on the same emulators (`go test -tags=integration -v`, the repository's `budgettest` lines; output kept with the run)
| Test | Measured |
|---|---|
| `TestProfileTabsChain_*` (real `Build` chain, fresh reader) | GetUserTimeline media and reposts **24** at page 20, **54** at page 50, 20 warm, 0 on a rejected token, 1 (interceptor) on a flag refusal |
| `TestListLikedPostsChain_*` | **23** page 20, **53** page 50, 5 for the 5 rows of a warm second page, 2 for an empty array, 10 with dropped rows, 0 on a bad token |
| `TestListSuggestedUsers_*` and the chain test | friends of friends **42** (41 in the service + interceptor), warm 0 (+ interceptor 1), curated 6 (+ 1) in the 8-id test world |
| `TestW311_GetProfileRelationship_*` | **3** nothing cached, **2** target profile cached, **1** after the header's GetProfile, **0** warm, 1 for a non-follower's first edge read, 3 on an overflowed caller, 1 for a target that blocked the caller |
| `TestUpdateProfile_Integration_ExtrasBudget` | banner + location + website + pin **3 reads / 1 write**; bio only 1 / 1; clear all 1 / 1; flag off 0 / 0 |
| `TestIntegration_BannerBudgetsAndResolver` | CreateUpload BANNER **2 reads / 3 writes**; FinalizeUpload BANNER cold **2 reads / 2 writes** and 2 Vision units; ResolveBanner 1 read |
| `TestBackfillHasMedia_*` | reads = posts scanned, writes = posts lacking the key (667 of 1,001 in the production-page-size test), a rerun 0, at most 5,000 writes per run |
| throwaway overlay test of `identity.PinJobs` through the real posts and identity repos (not in the repository) | deleted post that is not the pin **2 reads / 0 writes**; the pin **2 / 1**; redelivery 2 / 0; post still exists (refused) **1 / 0** |

### What was not measured
- Cloud Run CPU and memory for the new RPCs and cold-start time (emulators only; the Cloud Run ms column is an estimate), and the instance cache hit rate (no traffic): the call mix of §1 (95% cold suggestions, 85/15 fof/curated) is an input.
- A cold-start wave, a notification fan-out burst and a post receiving 50 likes/s: not Part A shapes (Part A adds no write fan-out and no counter); the shapes that are, a viral profile on the Media tab and a user following 600 accounts, are above.
- The composite indexes (`posts` hasMedia and kind, W3-2) are not enforced by the emulator: the dev smoke after W3-24 must show them READY, and the first real `fs_reads` per tab call comes from there.
- `GetPost` of a pinned post and `FinalizeUpload` through Vision in the chain (existing RPCs; the W3-24 dev smoke is a handful of real calls).
