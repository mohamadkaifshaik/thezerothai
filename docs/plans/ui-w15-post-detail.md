# UI W1.5: post detail conformance (PD)

Status 2026-11-02: PD-1 done (#665); PD-2 in review; PD-3 queued (one PR at a time, founder 2026-11-02).

Source: x.com post page captured 2026-11-02 (desktop, dark, signed-in founder account, Chrome 156,
600px main column) with REA (passive screenshot and DOM) plus a CDP measurement script. CSS px are dp.
Screenshots stay local (third-party content). Our side was compared from the code, not from a run.
This closes the "post detail" part of backlog B-29; mobile width and the light theme were **not**
captured.

## Observed on X (MEASURED unless marked)

| Part | X |
|---|---|
| Header | back arrow (36 round) + "Post" 20/24 w700, sticky |
| Author | 40 avatar; name (15 w700, verified badge) over `@handle` (15, muted) on two lines; no relative time; Grok and `...` at the right |
| Text | 17/24, full column width (starts under the avatar's left edge, 566 wide in a 600 column), not clamped |
| Media | full width under the text, rounded |
| Time line | `9:11 PM · Nov 1, 2026 · 17.3K Views`, 15/20 muted, 16 below the media |
| Action row | rule above, 48 high, Reply 272 / Repost 38 / Like 134 / Bookmark 53 / Share spaced evenly (134 apart), Share flush right; glyphs larger than in list rows (ESTIMATED about 20) |
| Below the row | "Relevant ⌄" sort (14 w500 muted) left, "View quotes ›" right |
| Reply entry | inline under the post: viewer avatar 40, "Post your reply" 20 muted, Reply pill (grey until text), rule below; scrolls with the page |
| Replies | no heading; rows about 99 high for one line: name @handle · time, text 15, action row 20 high (reply, repost, like, views, bookmark, share) |

Not ours: Grok, views, "Relevant" ranking and "View quotes" (no backend yet).

## Tickets

| Ticket | Scope | Owner | Size | Status |
|---|---|---|---|---|
| PD-1 | Open post layout + reply entry: `PostCard(focal: true)` (two-line author, full-width 17/24 text and media, full time line, divided spread action row with Reply that focuses the composer, no tint); composer inline under the open post from 600dp up, docked below 600dp (mobile X not captured: our assumption); no "Replies" heading. Client only, flags unchanged (`posts`, `replies`, `engagement`). Cost: 0 RPCs added | frontend-developer | M | **Done** (#665) |
| PD-2 | Denser reply and feed rows: keep 48dp tap targets but stop them adding visible height (author row, action row), toward X's ~99dp one-line row. Shared `PostCard`, so Home, profile and search change too; goldens and layout tests updated | frontend-developer | M | **In review** (branch `feat/ui-w15-pd-2-denser-rows`): padding only, 148 -> 124dp for a one-line row with actions, every target still 48dp; the rest of the gap to ~99dp needs smaller or overlapping targets (founder decision) |
| PD-3 | Reply sort (Relevant / Recent) and "View quotes": needs a `GetThread` sort option and a quotes list RPC, so an architect ADR (read budget) and planner tickets first | planner + architect | L | Queued, needs founder go |

## Acceptance (PD-1)

- The open post shows name over `@handle`, no relative time, text in `AppFocalPost` type across the
  full width, the full time below, and a divided spread action row; list rows are unchanged.
- From 600dp the reply entry sits between the open post and the first reply and scrolls with them;
  below 600dp it stays docked; a draft survives crossing the width.
- Reply on the open post focuses the entry; with replies closed there is neither.
- Widget tests: `post_card_focal_test.dart` (the `forEachThemeAndWidth` widths x light / dark x 1.0 / 1.3 / 2.0 no
  overflow), `post_action_bar_test.dart` (spread, real counts at 328dp), `thread_layout_test.dart` (390 / 1440 and the
  599 / 600 boundary: placement, focus, draft across a resize, a sent reply leaves no draft).
- Known limit: mobile X was not captured; the docked composer below 600dp is our assumption.
