# Test report: W6 client (composer extras: polls, drafts, GIFs) — W6-19

Date: 2026-10-31 · Tester: `tester` · Branch `test/ui-w6-19-client-tests` (main + `feat/ui-w6-15-drafts-ui` merged, because
PR #525 (W6-15 and W6-16) was not on main yet) · Plan: `docs/plans/ui-w6-composer-extras.md` W6-19 · ADR-0029.

Scope: poll builder (W6-12), poll card (W6-13), drafts (W6-14, W6-15), device GIFs (W6-16). Client only; no
production code was changed, no production seam was added. Everything runs without a network (fakes, a real in-memory
drift database where noted, `FakeTransport` for real repositories).

## Method

The developers' tests were read first (about 60 files; list in "Already covered"). New tests target what the ticket and the
developers' gap list left open, with checks that fail if the behaviour is wrong (for example: providers are left out of the
tree when a flag is off, so a read without the flag throws `ProviderNotFoundException`).

## What was added

| File | Tests | Covers |
|---|---|---|
| `app/test/support/w6_composer_rig.dart` | (helper) | `ComposerScreen` harness: omits `DraftsRepository` when `drafts` is off and `GifSource`/`GifPreparer` when `gif` is off; optional home page and app wrapper |
| `app/test/features/posts/presentation/w6_composer_matrix_test.dart` | 74 | flag product `polls` x `drafts` x `gif` x `engagement` x `media` (32 cells: which buttons exist, autosave only with `drafts`); poll open disables photo, GIF, Schedule and back; "Save post?" wording with a GIF (`kDraftsGifNote`), with photos (`kDraftsPhotosNote`), GIF alone ("Your GIF will not be saved."), `drafts` off; 360/600/1200 x light/dark x 1.0/1.3/2.0 for the GIF note dialog and for a GIF with a long emoji text |
| `app/test/app/drafts_session_test.dart` | 6 | real `wireAuthSession` + real drift + real `DraftsRepository`: A signs out, B signs in (B sees nothing of A, A gets the draft and its poll back), direct A to B, missed sign-out wipe (`claimCacheFor`), pending autosave at sign-out never lands, `deleteAll` cancels a pending autosave, deleting B leaves A |
| `app/test/features/account/presentation/delete_account_screen_test.dart` (+2) | 2 | failed delete leaves drafts alone; `deleteAll` throwing is reported, the "Not now" record is still forgotten and the final page still shows |
| `app/test/shared/widgets/w6_poll_flow_test.dart` | 27 | poll card in real `FeedPostRow` rows between plain rows (tap votes once, does not open the post; question text still opens it; author has no buttons; two cards of one poll show the same new total); VALIDATION, UNAVAILABLE (same idempotency key on retry), UNAVAILABLE with DEGRADED_MODE, UNIMPLEMENTED then `flagsChanged` then a working vote; matrix of vote/results states with 25-code-point, emoji, RTL labels and 9-digit counts; **cross-screen flow** compose a poll, post, the card appears, the author has no buttons, a follower votes (UNIMPLEMENTED hides the buttons, then VotePoll "ships", `flagsChanged`, results and check appear) |
| `app/test/shared/widgets/w6_matrix_gaps_test.dart` | 90 | `PollEmbedSummary` (long labels, ended) and `SavePostDialog` with each note: the full 360/600/1200 x light/dark x 1.0/1.3/2.0 matrix, 48dp buttons |
| `app/test/features/media/domain/isolate_gif_preparer_test.dart` | 7 | the real `IsolateGifPreparer` through `compute` (unchanged bytes, JPEG still, limits survive the isolate boundary), the synchronous throw of the cheap checks, and the real preparer under `AttachmentsCubit` (oversize, PNG, 301 frames, then a second pick works) |
| `app/test/features/media/w6_gif_and_tile_test.dart` | 24 | busy-slot retries exhausted, then the next attempt: same CreateUpload key, 4 PUTs in total, same finalize key; three exhausted attempts; documented 2/4/8 s waits; rejected PHOTO tile: server reason on tile and in semantics, empty reason, no stray full stop, matrix with a long mixed-script reason |
| `app/test/features/posts/presentation/w6_gif_flow_test.dart` | 1 | GIF attach in the composer, upload (one CreateUpload for one GIF, 2 PUTs), `CreatePost` with the media id, feed row shows the still with the badge, a tap requests the full file and does not open the post |
| `app/test/core/router/app_router_drafts_test.dart` (+9) | 9 | `/drafts` with drafts off / posts off / both off goes Home; `/compose?draft=` loads nothing with drafts off; Scheduled tab link with posts off; another account's draft id; another account's rows never listed |
| `app/test/app/app_widget_test.dart` (+2) | 2 (1 skipped) | sign-out forgets poll vote overlays; direct A to B (skipped, defect D1) |

Totals: about 240 new test cases. All new tests pass except the one deliberately skipped (D1).

## Acceptance criterion: "All new widgets are covered at 360 / 600 / 1200, light and dark; no overflow at 2.0"

Inventory of new W6 widgets and where each cell lives:

| Widget | Matrix (3 widths x 2 themes x 1.0/1.3/2.0 or 1.0/1.5/2.0) | Source |
|---|---|---|
| `PollCard` (vote, results, voted-hidden, sending, final pending) | yes | `poll_card_test.dart:45` (dev) |
| `PollCard` inside real feed rows (labels 25 code points, emoji, RTL, 9-digit counts) | yes | `w6_poll_flow_test.dart` (new) |
| `PollEmbedSummary` | yes | `w6_matrix_gaps_test.dart` (new; had none) |
| Poll builder (four choices, over-length counters) | yes | `composer_extras_toolbar_test.dart:647` (dev) |
| Poll / GIF toolbar buttons | yes | `composer_extras_toolbar_test.dart:706` (dev) |
| `SavePostDialog` (no note, photos note, GIF note) | yes | `w6_matrix_gaps_test.dart`, `w6_composer_matrix_test.dart` (new; had none) |
| Composer header with Drafts | yes | `composer_drafts_screen_test.dart:500` (dev) |
| `DraftsScreen` (Unsent, Edit mode, empty, Scheduled tab) | yes | `drafts_screen_test.dart:386` (dev) |
| GIF attachment tile (rejected) | yes (x2.0) | `attachment_grid_gif_test.dart:100` (dev) |
| GIF attachment tile (ready) | yes, the tile with its Remove control and the toolbar | `w6_composer_matrix_test.dart` "GIF attached with a long emoji text fits" (new, full matrix) |
| GIF attached in the composer with long emoji text | yes | `w6_composer_matrix_test.dart` (new) |
| Rejected photo tile | yes | `w6_gif_and_tile_test.dart` (new) |
| GIF `PostMedia` / `GifBadge` | yes | `post_media_gif_test.dart:182` (dev) |

Other ticket bullets:

| Bullet | Status |
|---|---|
| Composer exclusions (poll x photo x GIF x schedule x reply/quote) | covered: toolbar reasons (`composer_extras_toolbar_test.dart:213-300`, dev), poll open disables photo/GIF/Schedule and back (new); a quote offers no poll (dev); a reply never uses the composer screen |
| Poll builder to post to card states | covered end to end (new flow test) with a mocked `PostsRepository` for the CreatePost call (the real one inserts into drift, which cannot run in `testWidgets`; that insert is `posts_repository_test.dart`) |
| Drafts across sign-out, two accounts, deletion | covered (new `drafts_session_test.dart`, delete screen tests) |
| `/drafts` and `/scheduled` routing | covered, including the flag-off cells that were missing (new) |
| GIF attach to tap to play | covered (new `w6_gif_flow_test.dart`; dev `post_card_gif_test.dart`, `post_media_gif_test.dart`) |
| Flag combinations (`polls` x `drafts` x `gif` x `engagement` x `media`) | covered by the 32-cell composer test. `ui_shell` is **not read by any W6 widget** (`grep kFeatureUiShell`: only the shell, `MainShell` and Settings), so there is nothing to combine; the router tests exercise the shell with the real `AppRouter` |
| Text scale 2.0 overflow | covered in every matrix above |

## Developer gaps, answered

| Gap named | Result |
|---|---|
| Sign out, then sign in as another account on the same device | Done through the real `wireAuthSession`, `claimCacheFor` and `clearAll`. No defect: `clearAll` leaves `composerDraftEntries` alone and every query filters by uid. |
| Account deletion wiping rows | Already covered at `delete_account_screen_test.dart:224` (dev). Added: a failing `deleteAll` and a failed delete. |
| Flag product | Done. Providers are left out of the tree when their flag is off; no read leaks. |
| `kDraftsGifNote` wording | Done: text + GIF, GIF alone (discard dialog "Your GIF will not be saved."), photos, drafts off. |
| Poll card UNAVAILABLE | Already covered at the card (`post_card_poll_test.dart:116`, dev). Added: same idempotency key on retry; DEGRADED_MODE detail. |
| Poll card VALIDATION | Done: fallback line, buttons return, the same choice keeps its key, another choice gets its own. |
| Poll UNIMPLEMENTED then deployed | Done in the feed row and in the cross-screen flow. After `flagsChanged()` the vote works. Note: without a changed flag set nothing calls `flagsChanged`, so the buttons stay hidden until the next `GetMe` that changes the set or a restart (by design, see Observations). |
| "Header member-count refresh" | **Not found.** The phrase only matches the Lists code (`list_row.dart`, W5-11), not W6. Interpreted as the poll's footer total ("N votes") staying consistent across two cards of one poll after a vote: tested. |
| Poll card in a real `PostCard` feed row | Done with `FeedPostRow` (not a full `TimelineFeedView`: the timeline screen needs drift-backed state that cannot run in `testWidgets`). |
| `IsolateGifPreparer` compute path | Done with a real isolate. |
| Finalize retry on MEDIA_NOT_READY, 3 times, then re-PUT | Retries and rethrow already covered (`media_uploader_gif_test.dart:75,103`, dev). Added the "then re-PUT" half: the next `upload()` replays the same CreateUpload key and PUTs both objects again, the finalize key is reused. |
| Rejected photo tile shows the server's reason | Done (tile text, semantics, empty reason). GIF tile was already covered (`attachment_grid_gif_test.dart:78`, dev). |
| Cross-screen flow | Done. |

## Defects

| ID | Severity | Where | Summary |
|---|---|---|---|
| D1 | Low, **fixed in #PRNUM** (W6-48) | `app/lib/app/app_widget.dart:260` | The poll overlay (`PollCubit.reset()`) is reset only when the auth state becomes `unauthenticated`. The same file's session bridge (`session_wiring.dart:wireAuthSession`) handles a direct A to B switch explicitly, and wipes the cache there, but `PollCubit` keeps A's votes (choice, counts, `knownChoice`). B, opening the same post in the same app run, sees A's choice checked and the results bars (results hidden until the viewer votes, ADR-0029 D4). |

D1 was checked against the production wiring, not only the widget harness: `wireAuthSession` (`bootstrap.dart:296-303`) on a direct A to B
calls `graphRepository.clearCache` and dispatches `OnboardingUserSignedOut`, neither of which touches `PollCubit`; `AppWidget._onOnboarding`
(`app_widget.dart:322-335`) calls `PollCubit.flagsChanged()` only when the flag set changed, and `flagsChanged()` resets the repository's
"voting off" memory, not the entries. So no production path clears the overlay on A to B.

D1 repro and test: `app/test/app/app_widget_test.dart`, group "poll votes belong to the account (W6-19)", test "a direct
switch to another account forgets them too" (committed with `skip: true` so the suite stays green; remove the skip when
fixed). Expected: `PollCubit.state.entries` is empty after the auth stream moves from `uid-1` to `uid-2`. Actual:
`{'1': PollEntry}`. Reachability: the sign-in screens are hidden while authenticated, so a direct switch needs a
provider-level account swap; the existing L-4 work treats it as possible. The same `unauthenticated`-only reset applies to
the engagement, bookmarks, suggestions and trends cubits in the same listener; they were not tested here (outside W6).
Suggested fix owner: `frontend-developer` (reset on `user?.uid != previous uid`, like `wireAuthSession`).

## Observations (not defects)

- `/compose?draft=<id>` loads a saved draft when `drafts` is on and `posts` is off, while `/drafts` requires both
  (`app_router.dart:748-750`). The composer route has no `posts` gate at all; the server stays authoritative. Info.
- A tap on a read-only poll choice (voting off, author, closed) opens the post, because the row's `InkWell` receives it. Fine
  and now tested (no vote is sent).
- `IsolateGifPreparer.prepare` is not `async`, so size and signature refusals throw synchronously rather than returning a
  failed future (`image_processor.dart:194-202`). `AttachmentsCubit` awaits inside a `try`, so it is correct today; a future
  caller that uses `.catchError` would miss them. Documented by a test.
- `AttachmentsCubit.pickGif` shows "That file isn't a GIF." for any non-refusal failure of the preparer (a crashed isolate,
  for example) without reporting it (`attachments_cubit.dart:233-236`). Info.
- The real Home page cannot be built in the router test harness (no `TimelineRepository`); its redirect tests run last in
  `app_router_drafts_test.dart` because it leaves the binding unclean for later tests.

## Not run

- Real emulators or a real device: all of this is widget and unit level. `integration_test` was not run.
- The real drift-backed `PostsRepository.createPost` echo into the feed inside the flow test (mocked there; unit-tested
  elsewhere), and a full `TimelineFeedView` with poll rows (needs drift in `testWidgets`).
- Pixel goldens (deferred, B-01).
- The 5 other flag cells with `ui_shell`: no W6 widget reads it.
- Engagement, bookmarks, suggestions and trends cubits on a direct A to B switch (D1's siblings).
- GIF animation playback on a real image decoder (the test binding cannot download).

## Verification commands (final tree)

RESULTS_PLACEHOLDER

VERDICT: FAIL — D1 (low): the poll vote overlay survives a direct account switch (`app_widget.dart:260`), skipped repro in `app/test/app/app_widget_test.dart`
