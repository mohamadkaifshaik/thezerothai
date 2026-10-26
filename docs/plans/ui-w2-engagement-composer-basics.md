# UI W2: engagement and composer basics
Plan owner: planner · Date: 2026-10-26 · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **One new backend surface (bookmarks: three RPCs in `EngagementService`, ADR-0023); everything else is client-only over existing RPCs** · Flags: new `FEATURE_BOOKMARKS`; existing `engagement` + `quotes`, `media`, `notifications`, `ui_shell`
Source: `docs/plans/roadmap.md` (W2 row, sections 3, 5, 7), `docs/x_research/14_mvp_structured_plan.md` (W2, cost rows; local, git-ignored), `docs/x_research/screens/history.md`, `05_component_library.md` row 9, `06_interaction_behaviors.md`, ADR-0018, ADR-0023 (Proposed; decisions D1-D9 and its cost table are the source for every bookmarks line below). Supersedes `docs/plans/phase1.md` decisions (2) quote UI and (3) hashtag UI (founder 2026-10-22).
Branches: `feat/ui-w2-N-<slug>` off `main` (not stacked: the backend chain and the client-only tickets run in parallel); one ticket per PR; merge `origin/main` into the branch.

## What exists already (verified on `main` 44843a9)
| Feature | Backend | Client | W2 delta |
|---|---|---|---|
| Bookmarks | none: no proto, collection or flag (`lifecycle_collections_guard_test.go` already uses `"bookmarks"` as its "new collection without a row" example) | none | ADR-0023: `AddBookmark` / `RemoveBookmark` / `ListBookmarks` in `dzeroth.engagement.v1.EngagementService` (engagement module), flag, UI |
| Share | none needed | the right-aligned slot in `PostActionBar` has no handler (backlog B-08); no `share_plus` in `app/pubspec.yaml` | client only |
| Alt text | done: `CreatePost.media_alt_texts` (1,000 chars), alt copied into the post's `MediaRef`s | `_AltTextDialog` in `attachment_grid.dart` ("+ ALT" / "ALT" badge), `PostMedia` uses alt as the image's semantics label | X-style editor + ALT chip on posted images |
| Quote UI | done behind `FEATURE_ENGAGEMENT` + `FEATURE_QUOTES` (`posts.proto` CreatePost; wire name `quotes` is in `GetMe.enabled_features`) | repost sheet "Quote" row, `/compose?quote=<id>` composer, embeds; creation hidden by the compile-time `kQuoteUiEnabled` (`--dart-define=QUOTE_UI`) | gate on the server flags instead |
| Hashtag tap-through | **no RPC** serves a hashtag feed (`timeline.proto` has Home and User only); the index `posts (hashtags CONTAINS, createdAt DESC)` is already declared | tap shows "Hashtags are coming soon." | **moved to W4** (decision below) |
| Push opt-in | done: `RegisterDevice` / `UnregisterDevice` (ADR-0017) | `PushCubit.canPrompt` / `enable()` and a "Turn on" sliver on Notifications; web unsupported | card, "Not now", denied path |

**Hashtag decision: tap-through moves to W4 (search), not built in W2.** Reasons: (1) no RPC exists, so it is new backend, not a client switch; (2) on X a hashtag tap opens the search results for `#tag` (Top / Latest), and that screen is a W4 capture gap (roadmap section 5), so W2 would invent a screen W4 replaces; (3) `hashtags array-contains` is a named scraping vector (`stage-ladder`), and its quota and rate limit belong in the same W4 search ADR as handle prefix search, which shares the threat and the read budget; (4) the composite index already exists, so waiting costs no extra gate-file change. W2 keeps the existing placeholder. Seam for W4: one hashtag-feed method behind the `timeline` (or `search`) interface with an opaque cursor, which the W4 results page reuses.

## Open questions (proposed default in bold; nothing blocks)
1. Founder: move hashtag tap-through to W4 as above? **Yes.**
2. Founder: canonical share host. **`https://dzeroth.com` (prod, Firebase Hosting custom domain) and `https://dzeroth-dev.web.app` (dev), derived from `FirebaseEnv`, override `--dart-define=PUBLIC_WEB_ORIGIN`.** Path: `/post/<19-digit id>` (`AppRouter.postPath`; Hosting rewrites `**` to `/index.html`). The web app has no `usePathUrlStrategy()` today, so it runs on hash URLs (`/#/post/<id>`). **Default: W2-9 switches web to path URLs**, so the link is `https://dzeroth.com/post/<id>`. Old `/#/...` links then open Home; only testers have them.
3. Founder: screen name. **"Bookmarks" (`/bookmarks`)**, one tab now; X calls it "History" with Bookmarks | Likes tabs, and the Likes tab is W3.
4. Founder: ADR-0023's four questions (its "Questions for the founder"; defaults in bold there).
   - **Doc shape:** Y, a thin doc that renders the live post.
   - **Viewer state:** B, a `userLikes.bookmarks[]` array, not client-only.
   - **Per-user cap:** 1,000, rather than 2,000 or 5,000.
   - **Rule-4 idempotency doc:** keep it.

   The planner's earlier architect questions (snapshot cleanup, viewer state, list counts, abuse limits) are answered in ADR-0023 D9, and the tickets below follow D1-D8.

| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| W2-1 | ADR-0023 + bookmark RPCs in `engagement.proto`; after founder Q2, `PostView.bookmarked_by_viewer` and the `userLikes.bookmarks` index exemption | architect | M | Todo |
| W2-2 | `make proto`, register `FEATURE_BOOKMARKS` and the bookmark config (quota, cap, rate limits) in config, registry, ceiling and Terraform vars; flag-guarded handlers in the engagement module | backend-developer | S | Todo |
| W2-3 | `engagement.Bookmarks` / `BookmarkRepo`: `AddBookmark` / `RemoveBookmark` (thin doc, idempotency doc, daily quota, cap 1,000, `userLikes.bookmarks[]`), viewer-state hydration | backend-developer | M | Todo |
| W2-4 | `ListBookmarks` (limit 20 / max 50, opaque cursor, live posts via `GetMany`, D6 drop rules, lazy prune, read budget) | backend-developer | M | Todo |
| W2-5 | Bookmarks lifecycle: `bookmarks` eraser step (after `scheduled`, before `identity`), export section, guard row + fixture rename, runbook | backend-developer | M | Todo |
| W2-6 | Client bookmark action: right group of the action row, optimistic toggle, toast, quota / cap errors | frontend-developer | M | Todo |
| W2-7 | Bookmarks screen `/bookmarks` + drawer and rail entry, live rows, short-page paging, empty state | frontend-developer | M | Todo |
| W2-8 | Share: menu (Copy link, Share via...), canonical URL helper, `share_plus` | frontend-developer | S | Todo |
| W2-9 | Shared link opens the post: web path URLs, target kept through splash, sign-in and onboarding (allowlisted paths) | frontend-developer | S | Todo |
| W2-10 | Alt text: X-style description editor + ALT chip on posted images | frontend-developer | M | Todo |
| W2-11 | Quote UI on: drop `kQuoteUiEnabled`, gate on `engagement` + `quotes` | frontend-developer | S | Todo |
| W2-12 | Push opt-in card (Home + Notifications), "Not now", denied state | frontend-developer | S | Todo |
| W2-13 | Bookmarks flag matrix, replay, authz and budget assertions; responsive matrix of the new UI | tester | M | Todo |
| W2-14 | Security review: bookmarks RPCs, share URL, `from` redirect | security-auditor | S | Todo |
| W2-15 | Cost report: ADR-0023 rows in `cost-model.md`, ListBookmarks load smoke, Hosting transfer per shared-link visit | sre-performance | S | Todo |
| W2-16 | Dev rollout: Terraform plan for `feature_bookmarks*`, dev allowlist (3 uids), smoke | production-deployer | S | Todo |

Order: W2-1, then W2-2, then W2-3 ‖ W2-4 ‖ W2-5, then W2-6 and W2-7 (they need W2-2's Dart client for code and W2-3 / W2-4 for the dev check). W2-8 to W2-12 are client-only and start at once, in parallel with the backend chain. W2-13 to W2-16 come last, with W2-14 and W2-15 before any flag leaves `off` in dev.
Cost line (ADR-0023 "Cost impact"; cold reads include the account-status interceptor):

| RPC | Reads cold / warm | Writes | Deletes |
|---|---|---|---|
| AddBookmark | 7 / 3 | 4 (bookmark, idempotency, quota, `userLikes`) | +1 TTL later |
| AddBookmark replay | 5 / 1 | 0 | 0 |
| RemoveBookmark | 2 / 1 | 2 | 1 (+1 TTL later) |
| ListBookmarks, page 20 / 50 | 43 / 103 (posts warm: 1 + page; empty: 2) | 0 | 1 per lazily pruned row, once |
| Viewer state on timelines, GetPost, GetThread | +0 with `engagement` on (+1 cold, cached 60 s, with only `bookmarks` on) | 0 | 0 |

- **Per DAU per day:** 18.2 reads, 1.4 writes, 0.5 deletes.
- **At 300 DAU:** 5,460 reads/day (+7.8% over the 69.7k baseline; all billed, because the product passes the free 50k at about 215 DAU), 420 writes and 150 deletes. That is about **INR 6/month** (reads INR 5.4, egress to India INR 0.8).
- **At other scales:** about INR 15/month at 600 DAU and INR 75/month at 3,000 DAU.
- **Client-only tickets:** 0 new reads or writes.
- **Not added:** no new GCP service, no composite index, no Vision units, no fixed cost (INR 0).
Definition of done per ticket: Go unit + emulator integration (`make test-int`, `budgettest.Assert` on every RPC) for backend; widget tests in light and dark at 360/600/1200 via `test/support/theme_harness.dart` for every new screen or widget; pixel goldens deferred (backlog B-01); `make ci` green; `docs/ui-catalog.md` / `docs/code-map.md` and this table updated in the PR.

## Tickets
**W2-1 ADR-0023 + proto** [depends: none]. ADR-0023 (Proposed) defines:
- the thin doc `users/{uid}/bookmarks/{postId}` = `{createdAt}`;
- the three RPCs `AddBookmark`, `RemoveBookmark` and `ListBookmarks`, added to `dzeroth.engagement.v1.EngagementService` with per-RPC cost comments (**no `bookmarks.v1` package**);
- the per-RPC table, the flag, the quota, cap and rate limits, the erasure and export, and the Stage 2/3 target with its trigger.

`buf lint` and `buf breaking` are clean. The founder accepts the ADR by merging it and answers its four questions. After founder Q2 = B, the architect adds `PostView.bookmarked_by_viewer = 6` to `posts.proto` (additive). The architect also adds the `userLikes.bookmarks` exemption (`indexes: []`) to `firebase/firestore.indexes.json` with its `firebase/field-overrides.ack` entry; **both are founder-gated files**. If Q2 = A, none of this is added, and the client-only fallback applies (ADR-0023 D3). Seam: `engagement.Bookmarks` / `BookmarkRepo` Go interfaces and an opaque cursor bound to the caller, so a later split into its own service changes no caller. Cost: the ADR table is the source for W2-3 to W2-5.

**W2-2 Generate + flag** [depends: W2-1]. Given `FEATURE_BOOKMARKS` unset, every bookmark RPC returns FAILED_PRECONDITION `FEATURE_DISABLED` (`flags.DisabledError`, metadata `feature=bookmarks`) with 0 reads. Given `allowlist` with a uid:
- `AddBookmark` needs the flag on for that caller.
- `ListBookmarks` and `RemoveBookmark` only need it to be not globally off (`Registry.GloballyOff`, the ADR-0021 pattern), so a user dropped from the allowlist can still list and remove.
- `GetMe.enabled_features` contains `bookmarks` for that uid only.

The flag is registered in `config.go` and in `flags.NewRegistry` (`apiserver.go`). These config values go into `config_test.go`'s env list, and the rate limits are mapped in `ratelimit_config.go`:

| Config | Value |
|---|---|
| `QUOTA_BOOKMARKS_PER_DAY` | 200 |
| `QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY` | 50 |
| `BOOKMARKS_MAX_PER_USER` | 1,000 |
| `RATE_LIMIT_BOOKMARKS_PER_MIN` | 30 (Add and Remove share it) |
| `RATE_LIMIT_BOOKMARKS_LIST_PER_MIN` | 10 | `scripts/promotion/flag-ceiling.json` gets `BOOKMARKS` in `flags` plus a dev entry `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}`, and no prod raise. **That file is founder-gated (CODEOWNERS)**, so the PR needs the founder's review. `feature_bookmarks`, `_allowlist` and `_percent` Terraform variables are added in `envs/dev` and `envs/prod` (copy `feature_quotes`), default `off`, and nothing is applied. `check-flag-registry.sh` passes. Flag: `FEATURE_BOOKMARKS`. Cost: 0.

**W2-3 Add / Remove** [depends: W2-2]. Given a post visible to the caller by the GetPost rules (`posts.Engagement.Viewable`), AddBookmark runs one transaction:
- It reads, in order, `idempotency/{hash}`, then `quotas/{uid}`, then `userLikes/{uid}`.
- It `Create`s the thin doc `{createdAt}` and the idempotency doc, charges `quotas.bookmarks`, and writes `ArrayUnion` into `userLikes.bookmarks` (field-level `Set` + `MergeAll`, never a whole-doc write, per ADR-0023 D3).
- A REPOST id bookmarks its original.
- A replay returns the stored result (5 cold / 1 warm reads, 0 writes).
- An existing bookmark is success with 0 writes and no quota charge.
- A missing, deleted, hidden or blocking-author post returns NOT_FOUND "post not found", byte-identical to GetPost.
- At 1,000 bookmarks (exact, from the array length) it returns `LIMIT_REACHED` `limit=bookmarks`.
- Over 200 adds a day (50 for accounts younger than 24 h) it returns `QUOTA_EXCEEDED` `quota=bookmarks`. The new `quota.Bookmarks` kind ships with its `Record` field and its `valueFor` / `increment` cases.

RemoveBookmark reads only the idempotency doc. It then runs `Delete(bookmark, Exists)`, `Create` on the idempotency doc and `ArrayRemove`. There is no visibility check and no quota; a missing bookmark is a 0-write no-op.

`ViewerSet` gains `bookmarked`, hydrated whenever `engagement` or `bookmarks` is on for the viewer. Over 30 calls/min per user returns RATE_LIMITED. A bookmark emits no notification and no `Events`, and nothing about it is visible to the post's author. Tests: unit, emulator integration, `budgettest` at 7 (Add) and 2 (Remove), flag off/allowlist/on, and replay after Remove. Observability: one slog line per call (`uid_hash`, outcome, `fs_reads`); Error Reporting on internal errors. Flag: `FEATURE_BOOKMARKS`. Seam: `engagement.Bookmarks` / `BookmarkRepo`; posts are read only through `posts.Engagement.Viewable`. Cost:

| RPC | Reads cold / warm | Writes | Deletes |
|---|---|---|---|
| AddBookmark | 7 / 3 | 4 | +1 TTL later |
| RemoveBookmark | 2 / 1 | 2 | 1 (+1 TTL later) |

**W2-4 List** [depends: W2-2]. Given 25 bookmarks, a first call returns the newest 20 and a `next_page_token`, and the second call returns 5 and `""`. `page_size` 0 gives 20, clamped to 50. A foreign or tampered token returns INVALID_ARGUMENT VALIDATION `page_token` with 0 reads. The cursor is bound to `bookmarks|<uid>` with a 24 h TTL.

Each page runs `orderBy(createdAt DESC, __name__ DESC)` (automatic single-field index, so no index-file change), then one cache-first `posts.Reader.GetMany` of the page's ids, and returns **live** `PostView`s with current counts and viewer flags. It drops, per ADR-0010 D6 Home column:
- missing posts;
- `!Visible()` (takedown, suspended author);
- posts whose author, or a QUOTE's embedded author, is in the caller's `blocked`, `blockedBy` or `muted` (`graph.Reader.Snapshot`).

Pages may be short, so `next_page_token` stays set while there are more docs. A missing post's bookmark is pruned once: one best-effort batch deletes the doc and does `ArrayRemove`, skipped under `DEGRADED_MODE=readonly`. Hidden and blocked rows are kept, so a restore or an unblock brings them back.

The RPC is `NO_SIDE_EFFECTS` and charged to the per-uid daily read budget (the `guard_test.go` check); 103 is under `ReadBudgetMaxCallReads`. The caller can only ever read their own collection. Observability: one log line with `rows_dropped` by cause (missing, hidden, blocked, muted) and `rows_pruned`. Tests: as W2-3, plus `budgettest` at 43 (page 20) and 103 (page 50). Flag: `FEATURE_BOOKMARKS` (not globally off).

Seam: read path. Server side: no instance list cache and no since or removed_ids tokens (private, per user); posts come from the 60 s post cache. Staleness bound: a deleted or taken-down post disappears on the next open; a cached post is at most 60 s stale; blocks and mutes take up to 60 s across instances. Stage 2/3 (ADR-0023 stage ladder): a Cloud SQL `bookmarks` table, or post tombstones on the event bus feeding a cleanup consumer. The trigger is ListBookmarks above 15% of daily Firestore reads, or the §6 Firestore trigger, sustained 7 days.

Cost: 43 / 103 cold reads per page of 20 / 50 (posts warm: 1 + page; empty: 2); 0 writes, except 1 delete per pruned row, once.

**W2-5 Lifecycle** [depends: W2-2]. Given an account is deleted, a new eraser step `bookmarks` (`engagement.BookmarkEraser`) erases its `users/{uid}/bookmarks` subcollection:
- The step is registered **after `scheduled` and before `identity`**, and both lists in `lifecycle_wiring_test.go:217` are updated.
- The step name is persisted in `deletionJob.step`, so it is appended and never folded into engagement's checkpoint.
- It pages by `__name__` in pages of ≤ 500, with a `Limit` (rule 5), and is resumable.

The export gets a new `bookmarks` section, appended after `scheduled`: `{"bookmarks":[{"postId","bookmarkedAt"}]}`, newest first. It never includes the post's content. The `engagement` section and its golden file are unchanged.

`lifecycle_collections_guard_test.go` gets the real T11 row `bookmarks` (`erasedByStep: bookmarks`). That test uses `"bookmarks"` as its example of an unregistered collection (lines 321, 371 and 380), so **rename that fixture** to another unused name; `rowFor("bookmarks")` now finds a row.

When a bookmarked post is deleted, taken down or its author is purged, **nothing fans out**: no collection-group query, no fieldOverride and no post-delete, takedown or purge change. The W2-4 list check hides the row, and a deleted post's row is pruned lazily on the owner's next open (ADR-0023 D6; the residue is a post id under the owner's own path). Runbook: `docs/runbooks/bookmarks.md` (kill switch, prune behaviour, the residue). Flag: the eraser, the export and the prune are never flag-gated. Cost:

| Path | Reads | Deletes |
|---|---|---|
| Eraser | 1 per doc (minimum 1); at the cap, 1,000 over 2 invocations | 1 per doc; at the cap, 1,000 |
| Export | 1 per doc (minimum 1); ≤ 70 KB at the cap | 0 |

**W2-6 Bookmark action** [depends: W2-2 for code, W2-3 for the dev check]. The action row follows X: reply, repost and like keep their slots, and **bookmark + share sit right-aligned** (`05_component_library.md` row 9). The 16 dp outline icon goes filled and accent when bookmarked, inside a 48 dp target. Semantics are "Bookmark" / "Bookmarked". The toggle is optimistic, with rollback and `engagementErrorMessage`-style text on error. It uses one idempotency key per intent, toggles are serialised per post (latest intent wins), and a REPOST row sends the original's id. Friendly text covers `LIMIT_REACHED bookmarks` ("You can save up to 1,000 posts"), `QUOTA_EXCEEDED bookmarks` and `FEATURE_DISABLED bookmarks`. The initial state comes from `PostView.bookmarked_by_viewer` once W2-1 adds it (founder Q2 = B); until then, or if Q2 = A, it comes from the local set (toggles plus list pages). With `bookmarks` off the icon is absent. Capture: **the bookmark toast was not captured**. Default: a snackbar "Added to Bookmarks" with a "View" action (`/bookmarks`), and "Removed from Bookmarks" with no action. The founder's capture may adjust it. Flag: `bookmarks` (`kFeatureBookmarks`), and the icon appears only where the action row does, i.e. with `engagement` on too. Seam: the "Bookmarked" state comes from one client `BookmarksRepository` overlay (server flag when present, otherwise the local set), never from a widget, so either Q2 answer changes no caller. Cost: 1 call per tap. Add is 7 cold / 3 warm reads and 4 writes; Remove is 2 / 1 reads, 2 writes and 1 delete. Viewer state on feeds adds 0 reads with `engagement` on.

**W2-7 Bookmarks screen** [depends: W2-2 for code, W2-4 for the dev check]. `/bookmarks` needs only `posts`. List and Remove work while `bookmarks` is not globally off (ADR-0023 D5), so a user dropped from the allowlist still reaches what they saved; a FEATURE_DISABLED answer shows a "not available" state, as the Scheduled list does. The entry points need `bookmarks`. The screen has an `AppBackHeader` titled "Bookmarks" and a one-tab `AppTabBar` (bookmark icon + label, as `screens/history.md` §2). The body is live `PostCard` rows (current counts and the engagement row), not snapshots. Each open replaces page 1 (no merge, no since token). Paging prefetches at `kPrefetchFraction` and keeps following `next_page_token` through short pages until it is empty. A row the server dropped (deleted, taken down, blocked or muted author) simply does not appear. The empty state uses `AppEmptyView` ("Save posts for later" with our own copy). Un-bookmarking removes the row, with an undo snackbar. Entry points: an `AppDrawer` row "Bookmarks", plus a rail destination at >= 600 dp. Tests: widget tests at 360/600/1200, light/dark, text scale 1.0/1.3/2.0, and flag-off routing. Search-in-bookmarks, "Clear all" and the Likes tab are out of scope. Flag: `bookmarks` (shell placement also `ui_shell`). Seam: `BookmarksRepository` keeps the list in session memory only (no drift table; cleared on sign-out under `SessionEpoch`). A later offline cache changes no caller. Staleness bound: fresh on every open (W2-4 bounds). Cost: 1 ListBookmarks per open plus scroll pages, at 43 cold reads per page of 20 (the ADR assumes 0.4 pages per DAU per day).

**W2-8 Share** [depends: W2-9 for the path-URL form; code can start at once]. Tapping share opens a bottom sheet under 600 dp and an anchored menu at 600 dp and above. It has **Copy link** (clipboard plus the toast "Copied to clipboard") and **Share via...** (`share_plus`, the native sheet; the row is hidden where the platform has none, e.g. desktop web without `navigator.share`). The URL is `postShareUrl(postId)` = origin (question 2) + `AppRouter.postPath(id)`; for a REPOST row it is the original's id. `share_plus` is a new pub dependency (licence noted in the PR). Capture: **the share menu was not captured**. Default: X-conformant rows over `SheetOptionRow` / `AppMenuItemRow`, with no "Send via DM" (W7) and no "Bookmark" row. The founder's capture may adjust it. Closes backlog B-08. Flag: `ui_shell`. The action row renders only with `engagement` on (`PostCard.engagementEnabled`), so share is reachable only inside `engagement`, and it ramps with it. Cost: 0 RPCs. The recipient's open costs the existing GetPost / GetThread rows; Hosting transfer is in W2-15.

**W2-9 Shared link opens the post** [depends: none]. Web uses path URLs (`usePathUrlStrategy()` in the web entry point; Hosting already rewrites `**` to `/index.html`). Given a signed-in **or** signed-out visitor cold-opens `/post/<id>`, the target is kept through every `_redirect` hop: the splash while auth is `unknown` (today any location becomes `/`, then Home), sign-in, the email-verification state and onboarding. They land on that post, not Home. Only paths matching `^/post/\d{19}$`, `^/u/[^/]+$` and `^/profile/[^/]+$` are kept; anything else (absolute URLs, `//host`, other routes) goes Home. Tests: router unit tests for each `_redirect` status, including "cold open while auth is unknown"; a check that Firebase Auth's `/__/auth/` handler paths still work on web. Flag: none (a navigation fix; rollback = revert). Cost: 0.

**W2-10 Alt text** [depends: none]. The composer's "+ ALT" opens a description editor: full-screen under 600 dp and a centred dialog above, as `schedule_dialog.dart` does. It shows the image preview, a field with `CharacterCounter` against `kMaxAltTextLength` (1,000), a Save pill (`AppPillButton`) and Cancel, and it returns focus to the tile. On posted images with alt text, an "ALT" chip shows bottom-start on each `PostMedia` tile (48 dp target). Tapping it shows the description in a sheet; the image's semantics label stays the alt text. Capture: **the alt-text dialog was not captured**. Default: X-conformant layout as above with our own copy. The founder's capture may adjust it. Flag: `media` (editor); the chip renders wherever posted images render. Cost: 0 (alt is already sent with CreatePost / SchedulePost).

**W2-11 Quote UI** [depends: none]. Given `GetMe.enabled_features` contains `engagement` and `quotes`, the repost sheet offers Quote and `/compose?quote=<id>` works. If either is missing, Quote is absent and the route shows the existing "not available" state. `kQuoteUiEnabled` and its dart-define are removed, and the `docs/ui-catalog.md` line ("post-MVP") is corrected. A server FEATURE_DISABLED `quotes` still hides it through `PostsFeatureGate`. Rendering of quotes and reposts is unchanged. Records the reversal of `phase1.md` decision (2). Flag: `FEATURE_QUOTES` + `FEATURE_ENGAGEMENT` (existing, dev ceiling allowlist 3). Cost: the existing CreatePost quote row (17 cold / 2 warm reads, 5 writes, `posts.proto`); W2-15 adds a calls/DAU line.

**W2-12 Push opt-in card** [depends: none]. Given `PushState.canPrompt` and no "Not now" in the last 30 days (`AppSettingEntries`, per uid), an `AppSurface` card shows: the title "Turn on notifications", one line of copy, a "Turn on" pill and "Not now". It sits at the top of Notifications (replacing the current sliver) and once above the Home feed. "Turn on" calls `PushCubit.enable()`. On a grant the card disappears; on a denial it changes to a one-line hint ("Notifications are off in your device settings") on Notifications only. The card never shows on web or on iOS until the Apple launch. Capture: not captured; X-conformant default, adjustable. Flag: `notifications`. Cost: no new RPC; a grant triggers at most one existing `RegisterDevice` (cost-model §2 row).

**W2-13 Tests** [depends: W2-3, W2-4, W2-5, W2-6, W2-7]. Integration tests cover:
- flag modes off/allowlist/percent/on, including list and remove for a user dropped from the allowlist;
- replay, and replay after Remove;
- concurrency (10 parallel adds → 1 doc, quota charged once);
- cap and quota;
- authz (no path reads another user's bookmarks; cursor tampering);
- NOT_FOUND byte-identity;
- the ADR-0023 D2 drop matrix (deleted, takedown, restore, suspended, DELETING kept, blocks in both directions, mute, QUOTE embedded author);
- prune exactly once;
- eraser and export;
- `budgettest` at 7 / 2 / 43 / 103. The client side gets the responsive matrix for W2-6 to W2-12. Coverage on `internal/` stays at 70% or more. Cost: 0 (emulators only).

**W2-14 Security review** [depends: W2-3, W2-4, W2-5, W2-8, W2-9]. A threat model for new owner-only reads and writes:
- private-list authz (the path comes from the token uid; the cursor is caller-bound);
- AddBookmark is no new block oracle (the GetPost NOT_FOUND bytes);
- the ADR-0023 D4 abuse arithmetic (30/min × 3 instances, the 200/day quota, the 1,000 cap);
- the `userLikes` field-level write rule (D3);
- export and erasure completeness. It also covers the share URL (no tokens or uids in it) and the `from` allowlist (open-redirect proof). Findings are fixed or ticketed before any dev allowlist. Cost: 0.

**W2-15 Cost report** [depends: W2-3, W2-4]. Adds the ADR-0023 rows (+18.2 reads, +1.4 writes, +0.5 deletes per DAU) and the quote calls/DAU line to `docs/reviews/cost-model.md` §2-§3. Runs an emulator load smoke of ListBookmarks (`make loadtest`). Measures the web bundle bytes a first-time visitor from a shared link downloads, against Hosting's 360 MB/day free transfer (§5 Hosting column). It names the ADR-0023 trigger: ListBookmarks above 15% of daily Firestore reads, or the §6 Firestore trigger, sustained 7 days. Cost: 0 (emulators; no cloud load test).

**W2-16 Dev rollout** [depends: W2-13, W2-14, W2-15, ADR-0023 merged]. Show the founder a dev Terraform plan for `feature_bookmarks*` and the bookmark quota, cap and rate-limit env vars (targeted, per `pending.md` 3.10). If Q2 = B, also show the Firestore field override `userLikes.bookmarks`. Apply only on OK, with the allowlist set to 3 test uids, then a dev smoke: add, list, remove, flag off. Prod: no change (the prod apply is on hold, `pending.md` 1.2). Cost: the dev smoke is a handful of reads and writes inside the dev project's free quota.

## Rollout, kill switch, risks
- Targets (Stage 0, 300 DAU): ListBookmarks p95 < 400 ms warm (cold start < 1.5 s); AddBookmark / RemoveBookmark p95 < 500 ms; the list's page 1 is replaced on every open.
- Ramp: `FEATURE_BOOKMARKS` never ramps beyond `FEATURE_ENGAGEMENT` (the action row needs it). Dev allowlist (3) → founder decision for prod at MVP launch (allowlist → percent 5 → 25 → 100 → on; each step a Terraform change plus a tagged revision, ADR-0019). Rollback trigger: error rate on bookmarks RPCs above 2% for 15 min, or reads per DAU above twice the W2-15 model. Kill switch: `FEATURE_BOOKMARKS=off`; the data stays and no migration is needed. Client-only tickets roll back with their flag (`ui_shell`, `media`, `notifications`, `quotes`) or by revert.
- Risks:
  - The list costs 43 cold reads a page, about twice the roadmap estimate; a hidden post costs its read on every open until it is restored or removed.
  - Rows vanish and return when the user blocks or mutes the author and then undoes it.
  - The 1,000 cap is below what heavy X users have.
  - The "Bookmarked" state is stale across devices only if founder Q2 = A.
  - A whole-doc `userLikes` write would empty the bookmark set (W2-3, W2-14). shared links landing on Home after the splash or sign-in hop (W2-9); Hosting transfer from shared-link web visits (W2-15); uncaptured visuals (defaults stated per ticket).

## Out of scope
- For You (separate ADR).
- Bookmark counts on posts (no counter, so no counter seam is needed).
- History "Likes" tab (W3).
- Bookmark folders, search in bookmarks and "Clear all".
- Hashtag feed and hashtag results page (W4).
- Link previews and Open Graph tags for shared links (no server rendering at Stage 0).
- A public signed-out post page (a new unauthenticated read and scraping vector; needs an ADR).
- Android App Links and iOS universal links (`assetlinks.json`).
- "Send via DM" (W7).
- A views count.

Research gaps: the share menu, bookmark toast and alt-text dialog were not captured (`docs/plans/roadmap.md` section 5, W2 row). The tickets use the X-conformant defaults above and do not wait. Any founder capture adjusts them in a follow-up PR.
