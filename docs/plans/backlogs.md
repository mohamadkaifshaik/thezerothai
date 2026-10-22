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
| B-20 | Ramp the `ui_shell` flag: dev allowlist -> percent -> on | `FEATURE_UI_SHELL` is default off everywhere; ceiling in `scripts/promotion/flag-ceiling.json` is `off` (raise by reviewed PR). Roll back by setting it off. See `docs/runbooks/ui-shell.md` |
| B-21 | Terraform: apply the new `feature_ui_shell*` variables in dev, later prod | Plan first, apply only on explicit founder "yes"; no prod apply without approval |
| B-22 | Decide whether ADR-0020 follow-ups need their own ADR (light-state colours) | ADR-0020 is Accepted (2026-10-22) |

## C. Later waves (from `14_mvp_structured_plan.md`; each needs plan + server flag, ADRs where noted)
| ID | Wave | Scope | Gate |
| --- | --- | --- | --- |
| B-30 | W2-W3 | Explore/search (handle prefix, hashtags, trends from own data), quote UI, hashtag UI, media on profile (Media tab) | Reverses the 2026-10-18 deferrals (confirmed 2026-10-22); backend budgets per `free-tier-budget` |
| B-31 | W4 | Bookmarks, lists, history, notifications settings | Plan + Firestore model |
| B-32 | W5 | Custom list tabs on Home, communities | Plan + ADR |
| B-33 | W6 | Direct messages v1: server-mediated pull + push, **no E2E** | ADR (cost math); E2E encryption is a future ADR |
| B-34 | W7 | GIFs: device GIF upload now; Klipy search picker only after its terms are verified (Tenor API shut down 2026-06-30, Giphy is paid in production) | Terms check |
| B-35 | W8 | Creator studio, premium, ads, calls: **UI shells only** | Payments, ads and video each need a future approved ADR before any real implementation |

## D. Process
- One ticket per PR, behind a server flag when user-facing, `make ci` green, ui-catalog and plan statuses updated in the PR.
- Never format or regenerate `app/lib/gen`.
