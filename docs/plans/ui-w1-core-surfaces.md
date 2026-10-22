# UI W1: core surfaces (client-only)
Plan owner: planner · Stage 0 ($0) · **Client-only: 0 new RPCs, 0 Firestore reads/writes, no proto, Terraform or Firebase change** · Flag: the shell stays behind `ui_shell`; W1 changes are in-place polish of existing screens
Source: `docs/x_research/14_mvp_structured_plan.md` (W1), W0 plan `docs/plans/ui-w0-foundations.md`, ADR-0020 (Accepted).
Branches are stacked (`feat/ui-w1-N-<slug>` off the previous one); one ticket per PR; merge `origin/main` into the branch.

| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| W1-1 | PostCard: padding 16/12/16/12, action row (3 counted slots + right-aligned Share), 16dp icons in 48dp targets, like/repost colours, selected semantics | frontend-developer | S | **Done** (`post_card.dart`, `post_action_bar.dart`, tests) |
| W1-2 | "Show more" clamp (~6 lines) in `PostRichText`; tap expands in place; links stay tappable | frontend-developer | S | Todo |
| W1-3 | Profile header: banner 3:1 placeholder band, avatar 133/88dp + ring, Edit pill 36dp, sticky header | frontend-developer | M | Todo |
| W1-4 | Profile tabs Posts · Replies via `AppTabBar` (existing `GetUserTimeline`, cursor + limit 20) | frontend-developer | M | Todo |
| W1-5 | Home header = `AppTabBar` with one tab "Following"; inline "N new posts" bar; drop duplicate composer Post button | frontend-developer | M | Todo |
| W1-6 | Notifications All / Mentions tabs (client filter of the loaded page), type colours, 3-line clamp | frontend-developer | M | Todo |
| W1-7 | Settings master-detail >= 1200dp; mobile unchanged; deep-linkable nested routes | frontend-developer | M | Todo |
| W1-8 | Skeletons with reserved avatar/media slots, `AppEmptyView` action slot, per-screen retry, offline banner | frontend-developer | M | Todo |
| W1-9 | Responsive matrix + text-scale audit at 360/600/1200 | tester | S | Todo |

Cost line: 0 reads/writes per ticket (render and local filtering only); Replies (W1-4) reuses `GetUserTimeline` within the existing per-uid read budget.
Definition of done per ticket: widget tests in light and dark at 360/600/1200 via `test/support/theme_harness.dart`, `make ci` green, `docs/ui-catalog.md` and this table updated in the PR.

## Notes
- W1-1: Share is not offered yet (no handler), so the right-aligned slot is exercised by tests only.
