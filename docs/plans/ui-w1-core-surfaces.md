# UI W1: core surfaces (client-only)
Plan owner: planner · Stage 0 ($0) · **Client-only: 0 new RPCs, 0 Firestore reads/writes, no proto, Terraform or Firebase change** · Flag: the shell stays behind `ui_shell`; W1 changes are in-place polish of existing screens
Source: `docs/x_research/14_mvp_structured_plan.md` (W1), W0 plan `docs/plans/ui-w0-foundations.md`, ADR-0020 (Accepted).
Branches are stacked (`feat/ui-w1-N-<slug>` off the previous one); one ticket per PR; merge `origin/main` into the branch.

| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| W1-1 | PostCard: padding 16/12/16/12, action row (3 counted slots + right-aligned Share), 16dp icons in 48dp targets, like/repost colours, selected semantics | frontend-developer | S | **Done** (`post_card.dart`, `post_action_bar.dart`, tests) |
| W1-2 | "Show more" clamp (~6 lines) in `PostRichText`; tap expands in place; links stay tappable | frontend-developer | S | **Done** (`PostRichText.maxLines`, `kPostTextClampLines`; detail view unclamped) |
| W1-3 | Profile header: banner 3:1 placeholder band, avatar 133/88dp + ring, Edit pill 36dp, sticky header | frontend-developer | M | **Done** (3:1 banner, 133/88dp avatar + 4dp ring, 36dp Edit pill, actions below banner, sticky title = name + post count; search icon deferred until search exists) |
| W1-4 | Profile tabs Posts · Replies via `AppTabBar` (existing `GetUserTimeline`, cursor + limit 20) | frontend-developer | M | **Done** (`_ProfileTabs` over `AppTabBar`, equal width; Replies only with the `replies` sub-feature; per-tab `TimelineCubit`, own pending posts on Posts only) |
| W1-5 | Home header = `AppTabBar` with one tab "Following"; inline "N new posts" bar; drop duplicate composer Post button | frontend-developer | M | **Done** (top bar + one-tab `AppTabBar` "Following"; composer row without the Post button; the "N new posts" pill stays a floating overlay under the header, so it never shifts the list: deviation from "inline" to meet "no layout shift") |
| W1-6 | Notifications All / Mentions tabs (client filter of the loaded page), type colours, 3-line clamp | frontend-developer | M | **Done** (All / Mentions `AppTabBar`; Mentions = mention + reply rows of the loaded pages, gaps kept, "Look through older notifications" when older pages exist; like pink / repost green / accent icons; text clamped to 3 lines) |
| W1-7 | Settings master-detail >= 1200dp; mobile unchanged; deep-linkable nested routes | frontend-developer | M | **Done** (`ResponsiveScaffold.masterPane`, `SettingsList` + `SettingsDetailPlaceholder`; >= 1200dp new shell only; rows `go` into the detail pane, selected row highlighted; sub-routes unchanged so deep links work) |
| W1-8 | Skeletons with reserved avatar/media slots, `AppEmptyView` action slot, per-screen retry, offline banner | frontend-developer | M | **Done** (skeleton reserves avatar + 16:9 media slots and clips in bounded parents; `AppEmptyView.action` + `TimelineFeedView.emptyAction` (own empty profile: "Write a post"); shared `AppNoticeBanner` = offline/refresh-failed banner with Retry where retrying can help, replacing two private copies; per-screen retry already on every blocking error view) |
| W1-9 | Responsive matrix + text-scale audit at 360/600/1200 | tester | S | **Done** (matrix tests added to Home, Notifications, Profile and Settings: light/dark x 360/600/1200dp x text scale 1.0/1.3/2.0, no overflow, content column <= 600dp; shell and shared chrome were already covered by `test/support/theme_harness.dart` suites; the audit found no new defects) |

Cost line: 0 reads/writes per ticket (render and local filtering only); Replies (W1-4) reuses `GetUserTimeline` within the existing per-uid read budget.
Definition of done per ticket: widget tests in light and dark at 360/600/1200 via `test/support/theme_harness.dart`, `make ci` green, `docs/ui-catalog.md` and this table updated in the PR.

## Notes
- W1-1: Share is not offered yet (no handler), so the right-aligned slot is exercised by tests only (branch refreshed for review).
- W1-3: the profile app bar shows the display name and post count; the search icon waits for search. The name is also in the header (X fades it in on scroll; we keep it always visible).
- W1-5: the "N new posts" pill stays a floating overlay under the header (no layout shift) rather than an inline bar.
- W1-6: the Mentions tab filters the loaded pages (mention + reply rows); older pages are reachable with "Look through older notifications".
- W1-7: master-detail only in the `ui_shell` shell at >= 1200dp; below that, and with the flag off, Settings is unchanged.

## Slice status
W1-1 .. W1-9 done on stacked branches `feat/ui-w1-1-post-card` .. `feat/ui-w1-9-responsive-audit` (plus `docs/adr-0020-accepted`); one PR per ticket, merged in order. Follow-ups: pixel goldens on Linux CI; light-theme disabled/selected colours; profile banner upload (needs a media RPC).
