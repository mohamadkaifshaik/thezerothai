# Security review: W4 search, trends and Explore (W4-22)

**Reviewer:** security-auditor · **Date:** 2026-10-31 · **Reviewed:** `origin/main` at `e3e28c23`, a read-only snapshot. The search code is unchanged since `be90d1bd`; the one commit in between is W7-35, a client change.

**Scope:** the W4-22 ticket items:
- handle enumeration and hashtag scraping;
- the block oracle in People and Posts, and protected accounts;
- query logging;
- trend manipulation and offensive-tag exposure;
- local recent-search storage on a shared device;
- the composite cron route;
- the `nameKeys` note (F2 = no);
- the stage-ladder rate-limit multiplication and scraping vectors;
- the ADR-0028 D9 abuse table.

**Code read:**
- `backend/internal/search/*` (People, Posts, the tag and prefix caches, the trends refresher, store, service and cron route)
- `backend/internal/identity/search_handles.go`
- `backend/internal/posts/{api,audience,service,repo_firestore}.go` (`ByHashtag`, `CreatedAfter`, `Visible`, `Audience.Decide`, `NewSnapshotAudience`)
- `backend/internal/posts/text/text.go` (the D8 hashtag grammar)
- `backend/internal/apiserver/{apiserver,routes,ratelimit_config,daily_maintenance}.go`
- `backend/pkg/platform/config/{search,limits,config}.go` and `pkg/platform/cursor/cursor.go`
- `app/lib/features/search/**`, `app/lib/core/network/api_client.dart`, `app/lib/core/router/app_router.dart` (the `/search` and `/explore` redirects)
- `app/android/app/src/main/AndroidManifest.xml` (W7-35 backup exclusion)
- `infra/terraform/envs/{dev,prod}/main.tf` (`app_check_mode`)
- `docs/runbooks/search.md`
- ADR-0028, ADR-0025 (counts and replies), and the plan's "Abuse & security surface" section

**Run:** `GOWORK=off go test ./internal/search/... ./internal/posts/text/...`, both ok.

**Not run:**
- emulator integration tests, `govulncheck` and `osv-scanner`;
- nothing against dev or prod.

W4-20 and W4-21 (tester) are still Open, so no authz test results were available. Every finding comes from reading the code.

## 1. Threat model (STRIDE)

**Assets:**
- The user directory: uid, handle, display name, avatar, verified and `is_private` (the `AuthorSnapshot` rows People returns).
- Posts by protected authors, and posts hidden from a viewer by a block, a mute or a takedown.
- Block state (ADR-0008 D9: a blocker must look like a missing user).
- The trends list, which every caller with `trends` on sees.
- Search queries, which carry intent and are sensitive (health, politics, a person's name).
- The cost budget: the INR 25,000 credit cap and the free 50k reads a day, already passed at about 140 DAU per ADR-0028.

| STRIDE | Threat | Control in the code | Result |
|---|---|---|---|
| **S**poofing | Searching as another user; forged page tokens; calling the cron route from the internet | The uid comes from the Firebase ID token only (`server.go` `call`). Tokens are AEAD-sealed with the binding `search\|uid\|tag\|tab` and a 24 h TTL (`cursor.DecodeAt`, `cursor.TTL`). TOP refuses any token. `/internal/cron/*` sits behind the OIDC verifier (`routes.internal`, `apiserver.go:510-516, 613-614`; `config.Load` refuses to start outside `ENV=local` without audience and allowed emails). | Holds. App Check is `monitor` (L-3) |
| **T**ampering | Poisoning the shared prefix or tag cache; rewriting `trends/current` | Both caches hold raw rows filled only by the server's own queries, and filtering runs per viewer after the cache. `trends/current` is written only by the refresher (1 `Set`) and Firestore rules are deny-all. | Holds |
| **R**epudiation | Who pushed a tag; who removed one | The refresher logs counts only and no uid, by design. The denylist is an env var, so its change history is the Terraform history. | Holds. No runtime moderation trail; M-1 adds one |
| **I**nformation disclosure | Protected posts to strangers; block oracle; query text in logs; history on a shared device | `posts.Audience` `SurfaceList` on every row. D6 block and mute filtering, including a QUOTE's embedded author. `blockedByOverflow` fails closed. The sweep skips protected and hidden posts. Request lines carry `query_kind` and `query_len`, never the text. Recent searches are kept per uid, wiped on sign-out, under the W7-35 owner stamp, and excluded from Android backup. | **L-1** (hidden-row count), **L-2** (People limit-gap), Info items |
| **D**enial of service / cost | Scraping reads; request floods on cached reads; cache churn | Per-procedure buckets, `search_daily`, the read budget, max-instances 3, degraded mode (all three RPCs are `NO_SIDE_EFFECTS`) | **L-4** (GetTrends has no daily cap) |
| **E**levation / abuse of reach | Pushing a tag to every user's Explore; an offensive or illegal tag shown to everyone | Distinct authors, `TRENDS_MIN_AUTHORS` 3, the sweep-time denylist, `FEATURE_TRENDS=off` | **M-1** (no fast removal; the denylist is easy to bypass), **M-2** (3 accounts of any age are enough) |

### Effective limits (per instance × 3 max instances)

| Limit | Per instance | Effective | Store |
|---|---|---|---|
| SearchPeople bucket (`RATE_LIMIT_SEARCH_PEOPLE_PER_MIN`) | 30/min | 90/min | memory |
| SearchPosts bucket (`RATE_LIMIT_SEARCH_POSTS_PER_MIN`) | 20/min | 60/min | memory |
| `search_daily` (both RPCs, `SEARCH_CALLS_PER_DAY`) | 300/day | 900/day | memory |
| GetTrends | the 60/min default bucket, **no daily cap** | 180/min = 259,200 calls/day | memory (L-4) |
| Read budget (ADR-0010 D5) | 2,000 reads/uid/day (+ one call ≤ 269 in flight) | about 6,000 reads/uid/day | memory |
| Prefix entry / tag entry | 2,000 / 500 entries, 60 s | 3 cold copies | memory |
| Trends instance copy | 1 doc read per 10 min | ≤ 432 reads/day | memory |

All in-memory caps reset when an instance is recycled (scale to zero, a new revision). The daily figures are therefore a floor on what one account gets, not a ceiling. ADR-0028 D9 states the same multiplication.

**Worst rows per account per day:**
- **People:** 900 × 20 = **18,000 handle rows**. At Stage 0 user counts (≤ 3,000) one account walks the whole directory in an afternoon. Each row is the public `AuthorSnapshot` (uid, handle, display name, avatar, verified, `is_private`); no bio, email or counts.
- **Posts:** bounded by the read budget. LATEST at page_size 50 costs 53 reads for 50 posts, so about 5,600 posts a day per account across 3 instances.
- **Scraping cost:** 6,000 reads a day × $0.035/100k ≈ INR 0.2 a day, **about INR 6 per account-month**. Ten accounts cost about INR 60 a month. Scraping is a privacy question here, not a cost one.

## 2. Findings

No Critical or High finding.

I checked the one High candidate and it is not a finding. `ByHashtag` returns replies, and `Audience.Decide` checks only the author and the embedded author, so a public user's tagged reply to a protected account's post reaches strangers. ADR-0025 decides exactly that (line 226: "A reply by a public account to P's post is public. It shows 'Replying to @P' and its own text, never P's"), so search matches the thread and profile paths.

### M-1 (Medium): an offensive or abusive trend has no fast removal path, and the denylist is easy to bypass
**Where:**
- `trends_refresh.go:294-300`: `rank` applies `TRENDS_DENYLIST` **only at sweep time**. GetTrends (`trends_service.go:87-124`) serves `trends/current` as stored, with no denylist check.
- With F1 = B the sweep runs once a day. `TRENDS_MIN_INTERVAL` (12 h, `trends_refresh.go:186-190`) skips any earlier re-run as `fresh`, including a manual OIDC call to `/internal/cron/trends-refresh` (only a `backlog` run escapes it).
- `docs/runbooks/search.md:61-63` (4.3) says to add the tag and deploy, and that "it applies at the next run". To remove it now, it says to "delete `trends/current` (console or an operator script)". No operator script exists (`backend/cmd/opsctl` has no trends command), so this means a hand delete in the prod console. If the next nightly run starts before the denylist deploy lands, it writes the tag straight back.
- In prod, "deploy" means a `v*` tag that only the founder can create, `release-prod`, a production-reviewer GO and `promote-prod` (ADR-0019). The kill switch `FEATURE_TRENDS=off` goes the same way.
- The plan (F6) says the denylist "hides a tag at the next deploy". The code hides it at the first sweep after the deploy, up to 24 h later.
- **Matching is exact on a weaker normalisation than the stored tag:**
  - `config/search.go:64-69` and `normaliseTag` trim, lower-case and strip `#`, but apply **no NFC**. Stored tags are NFC (`text.Hashtags`), so an entry typed in decomposed form (for example `cafe` + U+0301) never matches.
  - The D8 grammar allows U+200C and U+200D inside a tag (`text.go:231-233`). `#slur` with a zero-width joiner inserted is a different tag that renders identically and is not on the denylist. The same goes for an `_` inserted, a digit appended, or a Cyrillic or Greek homoglyph.

**Attack:**
1. Three accounts (see M-2) post a slur, a harassment hashtag aimed at a named person (for example `#<victim-name>isa...`), a scam or a coded tag.
2. It appears in Explore's top 10 and the desktop "What's happening" card for every caller with `trends` on, for up to 24 h + 10 min.
3. The operator adds it to the denylist. The ring switches to the zero-width-joiner variant. The next run publishes that one, and it looks identical on screen.
4. Until the change deploys through the prod release flow, the only immediate lever is a hand console delete, which the next run can undo.

**Impact:** reputational harm and a safety harm to a targeted person. India's IT Rules 2021 expect fast takedown on notice; the product has no tool that meets that for this surface.

**Cost scenario:** none. The sweep's reads are unchanged.

**Fix (W4-25, backend-developer + an architect dated note on ADR-0028 D6):**
1. **A runtime hide list in its own document, `trends/hidden`** (the same search-owned collection, `{tags: [tag], updatedAt}`, no uid). A new `opsctl trends hide|unhide <tag>` writes it with `ArrayUnion` / `ArrayRemove` through `search.TrendsStore` and prints an audit line.
   - GetTrends filters it at serve time. It is read through its own 10 min instance copy, +1 cached read per instance per 10 min (at most 432 a day), so a hide is live everywhere within 10 minutes.
   - The sweep reads it and drops hidden tags in `rank`, but **never writes it**. A hide therefore cannot race the sweep's whole-document `Set` of `trends/current`, and runbook 4.2's "delete `trends/current`" keeps working without erasing the hide list.
   - Do **not** put `hidden` inside `trends/current`. The refresher reads `prev` and then `Set`s the whole document, so a hide that lands between the two would be overwritten, and the 4.2 delete would wipe the list (and make a later `hide` fail NotFound). If it must live there, the sweep's `Put` needs an `UpdateTime` precondition from its read plus one retry, and runbook 4.2 must reset the watermark fields instead of deleting the document.
   - No deploy and no console click; it is operator data, like `admin/config`. Give `tags` an index exemption, or keep it under 100 entries.
2. **Apply `TRENDS_DENYLIST` at serve time in GetTrends as well**, so a deploy takes effect within 10 minutes instead of at the next sweep.
3. **Match on a skeleton:** NFC, lower-case, U+200C/U+200D removed, `_` removed. Do this for the denylist, the hidden list and the stored tag alike, and normalise the env entries with the same function (`text.Normalize` plus the fold). Optional: the Unicode confusables skeleton (UTS #39) for Latin, Cyrillic and Greek.
4. Rewrite runbook 4.3 to use `opsctl trends hide`.

**Gate:** before `trends` leaves the allowlist in prod (prod percent). It is not needed for the dev allowlist (test accounts only).

### M-2 (Medium): three accounts of any age are enough to put a tag in front of everyone
**Where:**
- `trends_refresh.go:238-253, 297`: a tag needs `TRENDS_MIN_AUTHORS` (3) distinct authors in the window, and items rank by authors, then posts.
- An author needs a verified email and a profile. The new-account post quota (20 a day) is far more than the 1 post each it takes.
- App Check is `monitor` in both envs (`envs/dev/main.tf:352`, `envs/prod/main.tf:347`), so the accounts can be driven by a script.
- ADR-0028 lists "sockpuppet rings of 3 or more" as an accepted residual. Its Risks table names the mitigation, "weight by account age", as needing reads and an ADR.

**Attack:**
1. At Stage 0 volume (hundreds of posts a day), organic tags rarely reach 3 distinct authors; the runbook calls an empty list "by design".
2. A ring of 3 fresh Google accounts posting the same tag once each is therefore very likely **rank 1** on every Explore for the day.
3. Combined with M-1, it stays up for a day or more.

**Cost scenario:** none to us. The attacker pays 3 sign-ups.

**Fix (W4-26, architect note on ADR-0028 D6 + backend-developer):**
1. **Count only established authors.** After the in-memory count, take the authors of tags that pass `TRENDS_MIN_AUTHORS`. Read them with one `identity.Directory.GetProfiles` per 50 uids (cache-first, system budget) and drop:
   - authors whose `CreatedAt` is younger than `TRENDS_MIN_ACCOUNT_AGE` (proposed 72 h);
   - authors who are not ACTIVE.
   Then re-apply the minimum.
   - Cost: at most one read per distinct candidate author per run. Cap it, for example at 500, and treat the rest as unverified. That is ≤ 500 reads a day, about INR 0.5 a month, not charged to any user.
   - `identity.Profile` already carries `CreatedAt`.
2. **Interim, config only:** set `TRENDS_MIN_AUTHORS` to 5 in prod tfvars for the launch (production-deployer, in the plan-then-OK).
3. Optional: show trends only once at least N tags qualify, so a lone ring tag is not the whole list.

**Gate:** before `trends` leaves the allowlist in prod (prod percent).

### L-1 (Low): `next_page_token` reveals how many posts under a tag the caller cannot see
**Where:**
- `service_posts.go:281-285`: LATEST page 1 cuts the **unfiltered** entry at `page_size` and sets `more = len(entry) > n || len(entry) == 30`.
- `:270-272`: an older page sets `more = len(rows) == limit` on the unfiltered query.
- `:241-243`: a token is issued whenever `more` is true.
- ADR-0028 D3 says "a short page reveals nothing", which holds only for a fixed page size.

**Attack:**
1. The caller sends `page_size` 1, 2, 3 and so on for a tag and watches whether a token comes back.
2. Comparing that with the rows they can see gives the exact number of hidden rows among the newest 30, and among each older page.
3. Hidden rows are posts by protected authors they do not follow, by accounts that block them, by accounts they block or mute, and taken-down posts.
4. Polling a distinctive tag that a protected account uses (`#janesdiary`) shows when that account posts with it.

**Impact:** low. ADR-0025 keeps a protected account's post count public, and the attacker has to guess the tag. Attribution to a specific blocker needs a second account, which ADR-0008 D9 already accepts as the limit of block oracles.

**Cost scenario:** none. The probes are ordinary SearchPosts calls (0 extra reads), charged to the caller under `search_daily` and the read budget.

**Fix (W4-27, backend-developer, +0 reads):**
- On the entry path, filter first, then cut to `page_size`.
- Issue the page-1 token when the entry is full (30) or more rows were kept than returned. Resume from the last **returned** row.
- Floor `page_size` at 10 for SearchPosts (values 1 to 9 read as 10), so older pages leak at most a "≥ 10 left" bit.
- Add a W4-20 test: the same tag with hidden rows, page_size 1 to 30, gives identical token presence to a tag without them.

**Gate:** before `search` leaves the allowlist in prod.

### L-2 (Low, accept): People's `(prefix, limit)` gap shows that a hidden handle exists
**Where:** `people.go:134-142, 162-183`. The cache key is `(prefix, limit)`, the directory returns `limit` raw rows, and the filter runs afterwards. If limit k returns k − 1 rows but limit k + 1 returns k rows, a hidden account (one that blocks the caller, or a suspended or deleting one) sorts among the first k.

**Cost scenario:** none. Each probe is one SearchPeople call (at most 22 reads), charged to the caller under `search_daily` and the read budget.

**Why Low and accept:**
- `CheckHandleAvailability` already answers "is this handle taken" to anyone (rate-limited, `check_handle_daily`).
- ADR-0008 D9 accepts that a second account defeats any block oracle.
- The answer for a blocker stays byte-identical to the answer for a missing user at every limit, which is what D9 requires.

**Optional fix:** fetch 20 per prefix and slice after filtering. This also removes the 20× cache churn from varying `limit`. It costs up to +15 cold reads per typeahead call (+22 reads per DAU at the plan's 1.5 calls), so I do not recommend it now. Record the accepted residual in the ADR-0028 D2 text.

### L-3 (Low, pre-existing): App Check is not enforced, so search is scriptable with any account
**Where:** `app_check_mode = "monitor"` in both envs (`envs/dev/main.tf:352`, `envs/prod/main.tf:347`). ADR-0006 keeps web App Check an open decision. The plan and ADR-0028 D9 say all three RPCs "need App Check plus an ID token"; in effect they need an ID token only.

**Scenario:**
- A script with one verified account harvests the whole directory: 18,000 rows a day, uid to handle.
- The uids are the input to the attacks W7-22 listed. H-1 is fixed (W7-28, merged). **L-7 (reversible `conversation_hash`) is still open in W7-34**, so a harvested uid list lets anyone with `logging.viewer` map conversation hashes to pairs.
- Scraping the posts of public tags is bounded per account by the read budget, at about INR 6 per account-month.

**Fix:**
- No W4 code change.
- Correct the plan and ADR-0028 D9 wording ("App Check is verified; enforcement is `monitor` until ADR-0006 decides").
- Keep W7-34 a prod blocker as it is.
- Founder: the ADR-0006 App Check decision (section 4).

### L-4 (Low, cost): GetTrends has a per-minute bucket but no daily cap
**Where:** `ratelimit_config.go:132-205` (`PerProcedure` from 132, `DailyCaps` from 171). GetTrends has no `PerProcedure` entry and no `DailyCaps` entry, so it gets the 60/min default bucket only. On the warm path it reads nothing: the account-status interceptor read is cached (established in W7-22 M-1: "the account-status interceptor read is cached, so the ADR-0010 D5 read budget never binds") and the trends copy lives 10 min. The read budget therefore never binds. Had that read not been cached, the read budget would hold GetTrends to about 6,000 calls a day and this finding would mostly disappear.

**Attack:** one verified account loops GetTrends at 180/min across 3 instances: 259,200 calls a day, 7.89M a month. This is the W7-22 M-1 shape, with requests and vCPU instead of writes.

**Cost scenario** (W7-22 M-1's prices for the same 7.89M calls; INR 95/USD; `cost-model.md` §7, marginal):

| Line | INR per account-month |
|---|---|
| Cloud Run requests, 7.89M | 300 |
| vCPU at 20 ms per call / at the model's 0.1 s | 360 / 1,800 |
| Firestore | 0 |
| **Total** | **about 660 to 2,100** |

- Ten accounts cost INR 6,600 to 21,000 a month, most of the credit cap. Max-instances 3 bounds the rate, not the bill.

**This class is not new.** Every warm, 0-read RPC on the default bucket (GetMe with warm caches, for example) already allows it. GetTrends is the cheapest call of the class and new in W4.

**Fix:**
- W4-28 (backend-developer, config only): a `trends_daily` DailyCap, `TRENDS_CALLS_PER_DAY`, default 200. The client calls GetTrends about twice a day behind a 5 min cache. That is 600 a day at 3 instances, about INR 1 to 5 per account-month.
- Systemic, proposed to sre-performance (not a W4 gate): a global per-uid daily request cap over every procedure, for example 20,000, with a `requests_daily` limit name and a log-based alert. It closes the class for all warm reads at once.

**Gate:** W4-28 before `trends` leaves the allowlist in prod.

### Info (verified, no finding)
- **Grammar and 0-read rejections:** `parseQuery` checks UTF-8, then applies NFC, trim and lower-case, rejects `\p{Cc}` and bidi controls, and enforces 50 code points after the sigil. The posts tag is decided by the same `text.Hashtags` extractor that stores tags. Rejections and unsupported queries read nothing beyond the interceptor. The raw body is capped by `limits.MaxRequestBytes` (256 KiB) before NFC runs, so normalising the whole string first is a bounded CPU cost.
- **Range query:** `prefixSucc` replaces the last rune with its successor and refuses `MaxRune` or an invalid rune ("no match", never an open range). People prefixes are ASCII `[a-z0-9_]` anyway.
- **Block and mute filtering:** People drops non-ACTIVE accounts and `BlockedBy`. It keeps accounts the caller blocks or mutes, with the relationship set. On `BlockedByOverflow` it keeps only the caller and accounts the caller follows. Posts applies D6 to the author and to a QUOTE's embedded author, then `Audience.Decide(SurfaceList)`, which fails closed with UNAVAILABLE when the protected set is stale. The caller's own posts are kept. The 60 s graph snapshot means a fresh block shows up to 60 s late, as on Home.
- **Protected accounts:** listed in People with `is_private` (D2.5, as on X); only `AuthorSnapshot` fields are returned. The trends sweep skips protected authors with the set loaded fail-closed (`trends_refresh.go:230-236, 242`).
- **Takedowns:** a tag entry holds the post objects loaded at fill time, and `opsctl` runs in another process. A takedown therefore reaches a warm entry **within the 60 s TTL**, not "at once" as ADR-0028 D3 says. That is a wording fix only: the bound is the stated 60 s, and the sweep re-checks `Visible()`.
- **Tokens:** sealed, bound to `search|uid|tag|tab`, 24 h TTL. A first-page cursor and any token on TOP are refused. A foreign, tampered or expired token, or one used on another tag or tab, is VALIDATION `page_token` with 0 reads.
- **Logs:**
  - Request lines carry `query_kind`, `query_len`, `tab`, `results`, `dropped_*`, `cache_hit` and `fs_reads`: no query, tag, prefix or uid (`uid_hash` only, from `mw.Logging`). No request body is logged anywhere in `mw` or `logger`.
  - The trends lines carry counts only.
  - `mapErr` and `RedactErr` redact the caller uid. The search queries' errors carry document paths, not query values.
  - Cosmetic: People logs `query_len` in bytes of the raw string, Posts in code points of the body.
- **Connect GET:** connect-go serves `NO_SIDE_EFFECTS` procedures over HTTP GET too, with the message in the URL query string, and Cloud Run's request log records the full URL. The Flutter transport uses POST (`connectrpc` default, `api_client.dart:32`), so user queries never reach a URL today. A hand-made GET logs only the attacker's own query. Keep `useHttpGet` off; a one-line client test would pin it.
- **Cron route:** `/internal/cron/daily-maintenance` (wrapper) and `/internal/cron/trends-refresh` are both registered through `routes.internal`, behind the OIDC verifier (audience plus allowed service-account emails); there is no new public route. The handlers are POST only. The wrapper returns the backstop's captured status only; a trends error or panic is reported and never changes it. The trends step has its own deadline (`min(10 s, 28 s − elapsed)`, skipped below 3 s) and recovers its own panics.
- **Degraded mode:** all three RPCs are `NO_SIDE_EFFECTS`, so they keep answering under `DEGRADED_MODE=readonly`. The refresher skips (`readonly`) and the list freezes.
- **Memory:** the worst case is 500 tag entries × 30 posts (including a quote's embedded copy) at a few KB each, under about 75 MB, plus 2,000 × 20 profiles, about 10–20 MB. That fits in 512 MiB, but these caches stack with the timeline caches. `sre-performance` should watch instance memory in W4-23.
- **Client:**
  - Results render as Flutter widgets, with no HTML. Trend rows and recent searches are `Text`.
  - `/search?q=` is built with `Uri(queryParameters:)`, so it is encoded.
  - Opening a `/search` link does not record a recent search; only a submit from the field does (`app_search_field.dart:150, 169` → `search_suggestions_cubit.dart:179-181`).
  - Recent searches are keyed per uid (`recent_searches_store.dart:38`), dropped by the session-epoch guard after sign-out, wiped by `clearAll`, covered by the W7-35 owner stamp, and excluded from Android Auto Backup and device transfer (`AndroidManifest.xml`, `data_extraction_rules.xml`).
  - Residual, accepted: on the web, the `/search?q=` address with the query stays in the browser history after sign-out. The Privacy Policy line in section 4 covers it.
- **`nameKeys` (F2 = no, nothing built):** if F2 becomes yes, then:
  - display-name search makes people findable by their real name, so the Privacy Policy must say so;
  - `nameKeys` lives on `users/{uid}` and is erased with it;
  - it can stay out of the export (it is derived from the exported display name);
  - it must not be added to the `AuthorSnapshot`;
  - W4-11 should be reviewed with an opt-out question ("Let others find me by name") for the founder.

## 3. Ticket items, explicit verdicts
| W4-22 item | Verdict |
|---|---|
| Handle enumeration (cap 20, no paging, 2-character minimum, 30/min × 3, `search_daily` 300 × 3, read budget) | **Holds as configured:** 18,000 public rows per account per day. L-3 (App Check monitor) and L-2 (limit gap, accepted) |
| Hashtag scraping (sealed cursors, page ≤ 50) | **Holds:** about 5,600 posts per account per day, about INR 6 per account-month. L-1 (hidden-row count) |
| Block oracle, People and Posts | **Holds:** byte-identical to a missing user at each request; overflow fails closed. L-1 and L-2 are count and gap residuals |
| Protected accounts | **Holds:** Audience on every row; the sweep skips protected authors; replies to protected posts follow ADR-0025 |
| Query logging | **Holds:** no raw text in any log line; Connect GET is Info |
| Trend manipulation and offensive tags | **M-1, M-2** |
| Local recent searches on a shared device | **Holds** (per uid, wiped, owner-stamped, backup-excluded); the web browser history residual is accepted |
| Composite cron route | **Holds:** OIDC, POST, backstop status only, no new public route |
| `nameKeys` | Not built (F2 = no); conditions above if it is |

## 4. Founder actions
1. **Privacy Policy lines** (with the W7-22 list, before any non-team user):
   - "Search looks up accounts by their @handle and posts by hashtag. We do not store what you search for on our servers. Your recent searches stay on your device and are deleted when you sign out. On the web, the browser history may keep the search page address."
   - "Every account, including protected accounts, can be found by @handle. A protected account shows only its public profile in search."
   - "Trends are computed from public posts. Posts by protected accounts are never counted, and no personal data is stored with a trend."
2. **ADR-0006:** decide when App Check moves from `monitor` to `enforce` (web App Check is the open part). Until then, the per-account limits in this review are the only bot control (L-3).
3. **Prod launch values:** `TRENDS_MIN_AUTHORS` 5 (M-2 interim), and decide who reviews the trends list in the first weeks. A daily glance at Explore is enough at Stage 0.
4. **Prod ceiling:** keep `trends` allowlist-only in prod until W4-25, W4-26 and W4-28 are merged. `search` waits only for W4-27.

## 5. Proposed tickets (the planner assigns final numbers; W4-24 is the highest existing)

| ID | Finding | Owner | Size | Gate |
|---|---|---|---|---|
| W4-25 | M-1: a separate `trends/hidden` doc written only by `opsctl trends hide\|unhide` (`ArrayUnion` / `ArrayRemove`, audit line; the sweep never writes it; lifecycle guard row "no user data"); serve-time denylist and hidden filter in GetTrends; skeleton matching (NFC, ZWJ/ZWNJ and `_` folded) for the denylist, hidden list and tags; runbook 4.3 rewrite; ADR-0028 D6 dated note | architect (note) + backend-developer | S | Before `trends` leaves the allowlist in prod |
| W4-26 | M-2: `TRENDS_MIN_ACCOUNT_AGE` (72 h) and ACTIVE check on the authors of candidate tags (one `GetProfiles` per 50, ≤ 500 reads per run, system budget); interim `TRENDS_MIN_AUTHORS` 5 in prod tfvars | architect (note) + backend-developer; production-deployer for tfvars | S | Before `trends` leaves the allowlist in prod |
| W4-27 | L-1: filter-then-cut on the entry path, token from the last returned row, `page_size` floor 10; W4-20 test for identical token presence | backend-developer (+ tester) | S | Before `search` leaves the allowlist in prod |
| W4-28 | L-4: `trends_daily` DailyCap (`TRENDS_CALLS_PER_DAY`, default 200) + guard test row | backend-developer | XS | Before `trends` leaves the allowlist in prod |
| — | L-3 wording in the plan and ADR-0028 D9; ADR-0028 D3 "at once" → "within 60 s"; L-2 accepted residual in D2 | architect / planner | XS | Follow-up, docs |
| — | Systemic per-uid daily request cap over all procedures (the class behind L-4) | sre-performance + backend-developer | S | Follow-up; not a W4 gate |

## 6. Verdict

**Dev allowlist: GO** for `search` and `trends`, on these conditions:
- (1) W4-25 to W4-28 are added to the plan before the flags leave `off` in dev.
- (2) The dev allowlist holds test accounts only (ceiling `max_allowlist` 6).

**Dev percent:** not possible today. `scripts/promotion/flag-ceiling.json` sets `max_percent: 0` for both flags (founder-gated). If the founder raises it, nothing here blocks a dev percent, which holds test data only.

**Prod:** allowlist GO after the held release. Before `search` goes to percent: W4-27. Before `trends` goes to percent: W4-25, W4-26 and W4-28, the section 4 Privacy Policy lines, and `trends` never ahead of `search`.

SECURITY: CLEAR
