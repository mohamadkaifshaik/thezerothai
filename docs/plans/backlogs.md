# Backlogs: UI work not done yet
Single place for everything deferred from the X-research UI programme (W0 `docs/plans/ui-w0-foundations.md`, W1 `docs/plans/ui-w1-core-surfaces.md`, waves `docs/x_research/14_mvp_structured_plan.md` which is local/git-ignored). Founder decisions of 2026-10-22 apply (X colours only; everything enters the MVP via waves; DMs v1 server-mediated, no E2E). Pick items up by id; move an item into its own plan when started and delete it here. Last updated 2026-10-22.

## A. Leftovers from W0/W1 (small, client-only)
| ID | Item | Why deferred | Needs |
| --- | --- | --- | --- |
| B-01 | Pixel goldens (light/dark x 360/600/1200) | Baselines must be generated on the Linux CI runner; the harness already supports `RUN_GOLDENS=1` | CI job to generate/commit baselines |
| B-02 | Light-theme disabled-pill and selected-row colours | Not observed on X yet; marked "to confirm" in `app_theme.dart` | Capture on x.com light theme (tab must be the active tab of its window) |
| B-03 | Profile banner upload (replace the flat 3:1 band) | No media RPC for covers | architect: ADR + proto + media-pipeline change |
| B-04 | Profile header search icon | Search does not exist yet | Search wave |
| B-05 | Profile app-bar name fades in only after the header name scrolls away | Needs scroll tracking; name is currently always visible in both places | Small frontend ticket |
| B-06 | Profile: keep scroll position and a sticky tab bar when switching Posts/Replies | Each tab is its own feed, switching returns to the top | Frontend ticket (nested scroll / `NestedScrollView`) |
| B-07 | Home "Following" tab is the only tab | Custom list tabs arrive with Lists | Lists wave |
| B-08 | Share action on posts (the right-aligned slot exists, no handler) | No share target defined | Product decision (copy link / OS share) |
| B-09 | Mentions tab: decide whether quotes count; load more automatically while filtered | Only mention + reply rows are included; empty filtered view offers a manual "look through older" button | Product decision |
| B-10 | "N new posts" as an inline bar | Kept as a floating pill to avoid layout shift | Revisit only if the founder wants inline |
| B-11 | Capture remaining light-theme tabs for the research docs | REA capture times out on non-active tabs | Founder opens each tab |

## B. Rollout and release gates (founder / deployer)
| ID | Item | Notes |
| --- | --- | --- |
| B-20 | Ramp the `ui_shell` flag: dev allowlist -> percent -> on | `FEATURE_UI_SHELL` is default off everywhere; dev ceiling in `scripts/promotion/flag-ceiling.json` is `allowlist` with 3 uids (#240); prod is not raised (raise by reviewed PR). Roll back by setting it off. See `docs/runbooks/ui-shell.md` |
| B-21 | Terraform: apply the new `feature_ui_shell*` variables in dev, later prod | Plan first, apply only on explicit founder "yes"; no prod apply without approval |
| B-22 | Amend ADR-0020: accent text on light becomes X's `#1d9bf0` (founder 2026-10-23, replaces `#1478bd`); then a small theme ticket. `#1d9bf0` on white is about 3:1, below AA for small text: keep underline/weight cues and record the accessibility exception | ADR-0020 is Accepted (2026-10-22) |

## C. Later waves (numbering follows `docs/plans/roadmap.md`, which follows `14_mvp_structured_plan.md`; each needs plan + server flag, ADRs where noted)
| ID | Wave | Scope | Gate |
| --- | --- | --- | --- |
| B-29 | W1.5 | Capture post detail, composer modal and another user's profile on x.com, then a client-only conformance plan | Founder opens each tab for REA; no spec is invented for unobserved states |
| B-30 | W2 | Bookmarks, share, alt text, quote UI, hashtag tap-through, push opt-in card | Reverses the 2026-10-18 deferrals (confirmed 2026-10-22); ADR + budgets per `free-tier-budget` |
| B-31 | W3 | Cover image, Media / Reposts / Likes tabs, pinned post, who-to-follow, follow-requests UI, "Follows you" | ADR for cover and likes list; read cap for suggestions |
| B-32 | W4 | Search (handle prefix, hashtags), suggestions, Explore, trends from own hashtag counters | Search module ADR; one scheduled sweep; no external news feed |
| B-33 | W5 | Lists, custom Home tabs from lists, communities | Plan + ADR; moderation story for communities |
| B-34 | W6 | Polls, scheduled posts (one sweep job), drafts, GIFs (device upload now; Klipy picker only after terms are verified; Tenor API shut down 2026-06-30, Giphy is paid in production), reply audience | Terms check for GIF |
| B-35 | W7 | Direct messages v1: server-mediated pull + push, **no E2E** | ADR (cost math); E2E is a future ADR |
| B-36 | W8 | Creator studio, premium, ads, calls: **UI shells only** (Spaces dropped by the founder 2026-10-23) | Payments, ads and video each need a future approved ADR |

## D. Process
- One ticket per PR, behind a server flag when user-facing, `make ci` green, ui-catalog and plan statuses updated in the PR.
- Never format or regenerate `app/lib/gen`.
