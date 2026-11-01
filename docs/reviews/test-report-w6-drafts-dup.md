# Test report: W6-38 drafts duplicate-publication matrix

Ticket: W6-38 (ADR-0029 Amendment 1, A4, PR #544). Status: **In review** (this PR). The W6-38 plan row lives in #544; it
is not on main yet, so no plan row is edited here.
Fixed by: W6-39 in #560 (persist the send key on the draft row). W6-38 itself changed no production code.

Tests: `app/test/features/posts/presentation/bloc/composer_drafts_dup_publish_test.dart`
Fake server: `app/test/support/fake_posts_server.dart`

## Method

- Cubit level, `test()` with a real in-memory drift database (drift stalls inside `testWidgets`' fake-async zone).
  `ComposerCubit` + `AttachmentsCubit` + `DraftsRepository` are the production classes.
- `FakePostsServer implements PostsRepository`. It records every key, dedups by key, answers the same key with another
  body as `IdempotencyKeyReusedException`, and can **drop** (commit, then `NetworkException`) or **hold** (commit, then
  never answer = killed in flight) the response. Rules it models, with their backend source:
  - replay is looked up before media: `backend/internal/posts/repo_create.go` `createAttempt` (idempotency `Get` first,
    then `LoadForPost`);
  - key reuse with another body: `repo_create.go` `ErrIdempotencyKeyReused`, `service_scheduled.go` `answerStored`;
  - CreatePost media is single use: `backend/internal/media/attach.go:87` (`d.PostID != ""` is refused);
  - **SchedulePost validates media but does not attach it**: `repo_scheduled.go` (`MediaIDs` comment: "not attached or
    reserved"); the publish sweep attaches (`FakePostsServer.publishDue`).
- A **kill** closes the cubits, cancels the autosave timers and rebuilds a new `DraftsRepository` over the same database;
  the held response is never completed (a late success would run `discardDraft()`, which is "screen closed", not "killed").
  G2 uses a `DraftsRepository` subclass whose `delete` never finishes (test-only, no production seam).
- Reopen mirrors the screen: `initialDraft` from `repo.read` (`composer_screen.dart` ~line 195); a reopened draft has no
  media (F8, asserted in the test).
- The G tests assert only server-side effect (`accepted.length == 1`), so they pass unchanged after W6-39.
- Cells: {CreatePost, SchedulePost} x {none, photo, GIF}. **Schedule + GIF is not reachable**: the composer ignores a
  schedule time while a GIF is held (`rules.schedule`, tested in "a GIF cannot be scheduled") and the server refuses it
  (`ErrGifNotSchedulable`, `service_scheduled.go:260`).

## Matrix

Run before W6-39: `flutter test --no-pub <file>` = 24 pass, 25 skipped (after W6-39 all pass, none skipped). `--run-skipped`: all 25 G tests fail with
`Expected: length 1, Actual: [Accepted, Accepted]` (two items on the server) = reproduced.

| Case | Cells | Verdict | Severity | After W6-39 |
|---|---|---|---|---|
| S1 double tap sends once | 5 | **confirmed safe** (one request, one upload reservation) | n/a | held |
| S2 retry after a lost response, same key | 5 | **confirmed safe**, also with media: one `createUpload` and one `finalizeUpload` over both sends | n/a | held |
| S3 row removed only after success | 5 x 2 | **confirmed**: row present in flight and after a failure, gone after success (post and schedule) | n/a | held |
| S4 media attached once | post+photo, post+GIF, schedule+photo | **confirmed for CreatePost** (edited send refused `MEDIA_NOT_READY`). **Only partly true for SchedulePost**: media is not claimed at schedule time, two items can be accepted, only the first can publish (`publishDue`) | see G3 | held |
| G1 kill after the request left, reopen | 5 | **confirmed** (reproduced) | High: text duplicate posts or publishes. With media, the duplicate is text-only (F8), so it is a visible second post | fixed in #560: the claim reuses the stored key, the server replays |
| G2 kill after success, before local delete | 5 | **confirmed** (reproduced) | Low to Medium: small window, same effect as G1 | fixed in #560: replay returns the existing post, then the row goes |
| G3 edit after a lost response | post+none, schedule+none, schedule+photo | **confirmed** (reproduced). **Refuted for post+photo and post+GIF**: the server refuses the attached media, no duplicate (that is S4) | Medium (post), Low (schedule+photo: the second item fails at publish and shows as FAILED) | fixed in #560: the edit is sent under the stored key; a changed body gets IDEMPOTENCY_KEY_REUSED and a dialog |
| G4 two composers, one draft | 5 | **confirmed** (reproduced) | Medium (web tabs) | fixed in #560 where tabs share one database; residual on browsers without SharedWorker (below) |
| **G5 (new)** stale composer posts a draft another composer already sent | 5 | **new, confirmed** (reproduced) | Medium | fixed in #560: the claim refuses a row that is gone |
| **G6 (new)** other kind after a lost response (schedule then Post now, or Post then Schedule) | 2 (no media) | **new, confirmed** (reproduced); the architect lists it only as a warning in the fix | Medium | fixed in #560: refuse and ask; "send anyway" is the user's explicit choice |

## New findings and corrections to the analysis

- **G5, a hole in the proposed fix.** Success deletes the row. W6-39's "claim or reuse the key in one local transaction"
  finds no row, so a second composer still holding the old content mints a fresh key and posts again. The claim must
  **refuse when the row is gone** ("already sent"). Test skipped with that note.
- **G6.** Switching kind (schedule to Post now) after an ambiguous send cannot reuse the key (the `s:` prefix and time are
  in the intent). Today one tap adds the other kind. The test expects one tap to add nothing, which the fix's "warns before
  minting a new key" satisfies.
- **Analysis error in the fix list ("MEDIA_NOT_READY proves nothing was created").** It does not. G3 with a photo or GIF is
  exactly a landed send followed by `MEDIA_NOT_READY` (the edited send under a new key finds the media already attached,
  `attach.go:87`). Clearing the key there loses the evidence. Treat MEDIA_NOT_READY as ambiguous (keep the key) or explain
  it to the user; the test `S4 post + photo/GIF` currently pins the raw error.
- **S4 is weaker for SchedulePost than the architect states** (see matrix).
- **Media-only drafts:** an image-only post has no draft row (empty text), so G1/G2/G4 cannot arise for it; the media cells
  all carry text.
- **Not refuted:** G1 to G4 all happen as described (text-only duplicates once the media is gone).

## What was not run or checked

- Widget/`ComposerScreen` level: the tests build the cubit the way the screen does (`initialDraft`, same constructor
  flags) but do not pump the screen or `DraftsScreen(now:)`. Drift cannot run in `testWidgets`' fake-async zone, and the
  `FakeDraftsRepository` has no kill.
- Real-backend behaviour: the fake models the rules cited above; no emulator or Go test was run. The Go suites for S4
  (`media/*_integration_test.go`, `posts/service_scheduled_integration_test.go`) were not re-run.
- Web (answered by W6-39, see below): whether two browser tabs share one SQLite. Was open: whether W6-39's local transaction closes
  G4 across tabs is unverified.
- Replies and quotes (no draft row), poll drafts, and the 23 h key window are out of scope.
- Integration tests on devices/emulators: none.

VERDICT: PASS (S1-S4 hold as scoped above; G1-G6 reproduced and pinned as skipped tests for W6-39)

## W6-39 outcome (what the fix does and what stays open)

Rules as built (`DraftsRepository.claimSend` / `clearSend`, `ComposerCubit`):

- Claim in one local transaction, after the `submitting` emit and before any upload (a refusal costs no Vision units).
  A row with a key of the same kind inside its window: reuse it, whatever the content now is. No key: mint one.
- Window: 23 h for a post, publish time + 7 days for a schedule. The start is set at the first mint and never refreshed.
  Past it: refuse (`unconfirmed`), the user may "Post anyway" with a new key.
- Row gone and this instance had seen it (G5): refuse. Row never stored (a Post inside the 2 s autosave delay): the
  claim stores the draft with its key.
- Other kind pending (G6): refuse and ask. Replaying the stored key would send what the user just switched away from,
  and the earlier body (media ids, alt texts) is not stored. "Send anyway" mints a new key. The pending key is never
  sent to the other RPC (separate key spaces on the server).
- Clear only a freshly minted key whose first use was VALIDATION, FEATURE_DISABLED or EMAIL_NOT_VERIFIED, or a send that
  stopped at the upload step. Everything else keeps it, including MEDIA_NOT_READY, QUOTA_EXCEEDED, LIMIT_REACHED, and
  any of the three on a reused key.
- `updatedAt` is not touched by a claim or a clear (W6-45).
- IDEMPOTENCY_KEY_REUSED on a claimed key: dialog "An earlier version of this post was sent" (View profile, Post this
  version too).
- S4 test changed: `post + photo/GIF` now ends in the "earlier version sent" dialog (the stored key makes the server
  answer IDEMPOTENCY_KEY_REUSED before it looks at the media), still exactly one item accepted.

### Web: do two tabs share one database?

Read from drift 2.35.2 (`WasmStorageImplementation`, `wasm_setup.dart`); not run in a browser.

- Shared by all tabs, one connection, so the claim transaction serialises across tabs: `opfsShared` (Firefox) and
  `sharedIndexedDb` (browsers with SharedWorker: Chrome and Edge on desktop, Safari 16+).
- `opfsLocks` is also safe but needs COOP and COEP headers; `firebase.json` sets neither, so it is not used.
- `unsafeIndexedDb` is chosen when there is no SharedWorker (notably Chrome on Android, to be verified on a device).
  Drift documents it as unable to prevent data races between tabs: each tab has its own copy. G4 is then NOT closed
  across tabs: both tabs can claim different keys.
- Residual G4 on web without SharedWorker: Medium in impact (a duplicate text post), Low in likelihood (the same draft
  open and sent in two tabs of a mobile browser). Accepted for now. Mitigations if wanted: a `BroadcastChannel` or Web
  Lock around the claim (needs its own ticket).

### Other residuals

- A user who clears the whole text after an ambiguous send deletes the row (`_write` removes an empty draft) and with
  it the pending key. Low.
- The `kMaxDrafts` eviction can delete the oldest row while it holds a pending key. Low.
- A stale composer whose autosave runs after another composer sent the draft recreates the row without a key. The
  next send of that stale composer then claims a fresh key (the row exists). Low to Medium; needs the same draft open
  twice plus an edit. Not covered by G5, which assumes no edit in the stale composer.
- The `NetworkException` copy still says "Your post was not sent" although the send may have landed. Copy change left
  for a separate ticket.
- A quota answer keeps the key (ADR-0021 m1), so a user who returns after 23 h gets the "couldn't confirm" prompt even
  though nothing was created. Accepted by the amendment.
- S4 for SchedulePost media stays Low and is not changed here.
- Not run: a browser (Chrome, Firefox, Safari), a device, the real backend.
