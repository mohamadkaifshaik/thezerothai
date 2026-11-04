# Articles implementation

The core article workflow is available through **More → Articles** on desktop and **Articles** in the phone drawer, behind the existing `posts` capability. The route is `/compose/articles`.

Profiles include an Articles tab after Posts, Replies, Reposts and Media. The tab row scrolls horizontally by swipe; existing capability flags still govern Replies, Reposts and Media. Articles uses a separate, chronologically paged server feed of original published article posts, with the normal visibility checks.

The profile feed uses the indexed `posts.hasArticle` field, set on newly written original article roots. Deploy its Firestore composite index before using this feed. If an earlier version of this branch was deployed and already stored article posts, those roots require a `hasArticle: true` backfill before they appear in the profile Articles tab. This task has not deployed any project version.

Implemented: owner-scoped draft library, create/delete, revision-checked autosave, structured text formatting, cover upload, draft preview/focus, publication dialog with caption/reply policy, durable publication retry, timeline/quote/repost previews, routed full reader and conversation link. Article bodies are fetched separately from bounded feed previews. Published reads use the linked post's existing audience checks. Account export and erasure include article records.

The source contract lives in `proto/dzeroth/articles/v1/articles.proto`; clients were generated with the repository's pinned Buf configuration. The API server registers the new service using its protected interceptor chain. Deploy the updated Firestore index configuration and API alongside the client. No deployment is performed by this change.

Publication freezes a draft before invoking normal post creation with a stable idempotency key. A trusted article claim joins the existing post transaction: article publication state, root post and preview, media attachment, quota and idempotency commit together. A lost response cannot leave a public root pointing at an unpublished body. Replaying after normal idempotency expiration cannot create another root because the article claim rejects an already published record. The client preserves the publication identity across a reload. External CreatePost requests cannot supply the trusted claim.

## Observed reference

REA CLI 6.8.0 connected to the owner-provided Chrome CDP endpoint. REA MCP tools were unavailable in this session. The editor, draft/preview/focus states, insertion dialogs, publish dialog, successful publication, profile timeline card, full reader, reader Focus and More menu were inspected. The owner supplied the body for the live publication, which remains at https://x.com/fan_of_ur_s/status/2117800917030584423 under the title “Narendra Modi: A Polarizing Legacy”.

The detailed evidence ledger is local at `docs/reviews/x-articles-study-2026-11-04.md` (the repository ignores new `docs/` files). Raw captures remain in OS temp and are not committed. Home's sampled For you viewport did not show the newly published own article; the observed card-to-reader transition was from the profile timeline.

## Remaining parity work

Status: **future development**. X parity remains incomplete; the items below are follow-up work, not part of the completed core article workflow.

This is the core workflow, not complete X parity. Advanced inline media/GIF/post/link-preview embeds, tables and LaTeX are not implemented. Published article editing/unpublishing, cover cropping, X-specific analytics/boosting/monetization, and an inline reply thread inside the standalone article reader remain outside this implementation. Replies and engagement remain available through the linked ordinary post conversation. Browser capture timing, initial loading states and the account's available entitlements limit the reference coverage.

Do not enable unsupported blocks by accepting arbitrary HTML. Add structured wire validation, ownership/reservation lifecycle, renderer/editor behavior and tests together.

## Verification

Profile Articles follow-up: the 147-test profile/feed regression batch passed, along with the 240-case profile layout matrix and 36 final geometry/empty-state checks. Backend timeline/post/article/API suites and actual Firestore query-boundary tests passed.

Whole-app Flutter analysis passed with no issues. The article suite passed 17 tests, including rich-text editing, autosave failure/retry, publishing/reader navigation, session-switch protection and feature gating. Shell/card regression batches passed 76 and 38 tests respectively. Desktop and phone editor/reader and publication-dialog PNGs were rendered with the app theme and visually inspected under `app/build/artifacts/` (ignored build output).

Backend article/post/API-server/media suites and Buf lint passed. The final actual Firestore emulator run passed 11 tests (two integration tests and nine unit tests), covering persistence, export/erasure, quota rollback, atomic root/body publication, replay, stale publication after idempotency removal, and owned cover resolution/claim with consistent immediate and persisted preview URLs. The emulator was stopped after the run. This is local verification; no staging or production deployment was performed.
