# Product roadmap: X-parity UI programme and everything-in-MVP waves
Plan owner: planner · Date: 2026-10-23 (wording 2026-10-26) · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU) · **Planning document only: no code, proto, Firebase or infra change.**
This is the canonical, tracked roadmap. It supersedes the phase list in `.claude/skills/mvp-roadmap/SKILL.md` where they differ, and decisions (1)-(3) of `docs/plans/phase1.md`.

The underlying research lives in `docs/x_research/` (REA captures of x.com, 2026-10-22). That folder is **git-ignored** (`.gitignore:34`) because it holds screenshots with private messages and third-party posts, so it stays on the founder's machine only. Everything this roadmap needs from it is restated below; nothing here links into it as a requirement.

## 1. Inputs and rules
- Founder decisions 2026-10-22: match **only X's colours** (dark `#000/#e7e9ea/#71767b/#2f3336`, light `#fff/#0f1419/#536471/#eff3f4`, accent `#1d9bf0`; no indigo, no gradient; own icons, copy and logo); Home = **Following only**; **everything in the feature inventory enters the MVP**, delivered through flagged waves; DMs v1 = server-mediated pull + push, **no E2E**; W8 = **UI shells only**, payments / ads / video each need a future approved ADR; GIF = device upload now, Klipy picker only after terms are verified; trends from **our own** hashtag counters; the 2026-10-18 deferrals of search, quote UI and hashtag UI are **reversed**.
- `CLAUDE.md` still rules: free tier first and per use past it (no fixed fee; Stage 0 is about INR 434/month at 300 DAU), scale to zero, per-RPC read/write budgets, a server flag per user-facing feature, ADR before any fixed-cost item, founder approval for any prod apply or traffic shift. Every wave builds on the Stage 0 rung of the `stage-ladder` skill and protects its seams; a rung moves only on a measured trigger, by ADR.
- Evidence labels: the research docs use MEASURED / A11Y / ESTIMATED / NOT VERIFIED. Mapping to the request vocabulary: MEASURED = MEASURED, A11Y = OBSERVED, ESTIMATED = ESTIMATED, NOT VERIFIED = UNKNOWN; INFERRED is used where a conclusion was drawn from several observations. Dimensions are screenshot px / 1.25 = dp (Windows 125 %). No private X API, algorithm or source was inspected or copied.

## 2. Where we are (checked against `main` b6b0ce9 and merged PRs)
| Area | State |
|---|---|
| Backend modules (Go) | identity, graph, posts, timeline, engagement, media, notifications, moderation built and wired, each behind a flag. **search and admin not built.** |
| Protos | common, identity, graph, posts, timeline, engagement, media, notifications, moderation. No search, bookmarks, lists, messaging proto. |
| Flags | `ACCOUNT_LIFECYCLE, ENGAGEMENT, GRAPH, MEDIA, NOTIFICATIONS, POSTS, PROFILE_SNAPSHOT, QUOTES, REMOVED_IDS, REPLIES, REPORTS, UI_SHELL`. Dev ceilings: `GRAPH` and `POSTS` on, the rest allowlist (3 uids; `UI_SHELL` raised in #240). Prod flag state was not re-checked for this document; see `docs/runbooks/` and the release notes. |
| UI wave W0 foundations (#226, ADR-0020 Accepted) | **Merged.** X colour system, tokens, `AppTabBar`, `AppTopBar`, `AppDrawer`, `AppBottomBar`, `ResponsiveScaffold`, Appearance setting. Deferred items are in `docs/plans/backlogs.md` section A. |
| UI wave W1 core surfaces (#229-#237) | **Merged** (W1-1..W1-9): post card, Show more, profile header + Posts/Replies tabs, Home Following tab, Notifications All/Mentions, Settings master-detail, skeleton/empty/error slots, responsive matrix. |
| Milestone M1 "Looks right" | **Not formally exited.** Its exit criteria are golden tests in light and dark at 3 widths plus a founder visual review against the captures. Pixel goldens are deferred (B-01: baselines must be generated on Linux CI) and the founder review has not been recorded. |
| Rollout | `ui_shell` is dev allowlist (3 uids), off in prod. No UI wave is live for real users. |

## 3. Your priority table mapped to waves, with verified status
Status uses IMPLEMENTED / PARTIAL / MISSING / UNKNOWN (= needs verification or capture), judged from merged code and PRs, not from screenshots.

| Pri | X feature | Wave | Status in our repo | Research evidence | What is left |
|---|---|---|---|---|---|
| P0 | Application shell | W0 (done) | **IMPLEMENTED** behind `ui_shell`, dev only. Responsive 360/600/1200 tested. | MEASURED (desktop + 400 dp mobile, dark; light on 8 of ~26 screens) | Pixel goldens (B-01); light-theme disabled/selected colours (B-02); breakpoints between 400 and 1536 dp UNKNOWN; hover/pressed/focus UNKNOWN; ramp the flag (B-20). |
| P0 | Home timeline | W1-5 (done) + W2 | **PARTIAL.** Following-only feed, composer row, new-posts pill, Show more, skeletons all done. | MEASURED / A11Y | Bookmark and Share on the card (W2); custom list tabs wait for Lists (W5). "For you" is out of scope by decision. |
| P0 | Post details | **W1.5 (new)** | **PARTIAL.** Thread view and reply composer exist and were restyled in #221. | **UNKNOWN: post detail was not captured** (listed under "Not observed"). | Capture first, then a client-only conformance slice. Do not invent measurements. |
| P0 | Post composer | **W1.5 (new)** + W2/W6 | **PARTIAL.** Text 280, up to 4 images, signed upload, SafeSearch, restyled (#221). Quote UI backend exists. | **UNKNOWN: composer modal not captured.** Inline composer row on Home is MEASURED. | Capture first. Then alt text, quote UI (W2), polls / schedule / drafts / GIF / reply audience (W6). |
| P0 | Profiles | W1-3/4 (done) + W3 | **PARTIAL.** Header (3:1 band, 133/88 dp avatar), Edit pill, Posts and Replies tabs, edit profile, followers/following lists done. | MEASURED for the viewer's own profile; **other users' profiles UNKNOWN**. | Cover image upload (B-03, needs ADR), Media / Reposts / Likes tabs, pinned post, profile meta, sticky tabs (B-05, B-06). |
| P1 | Search and Explore | W4 | **MISSING.** No search module or proto. | Explore captured on desktop; **search suggestions and results UNKNOWN** | ADR + budget table; Firestore prefix and `array-contains`; trends from own hashtag counters via one scheduled sweep. |
| P1 | Notifications | W1-6 (done) | **IMPLEMENTED** for the web model: All / Mentions (client filter), unread, type icons, push. | MEASURED | Server-side type filter only if the client filter proves too costly; push opt-in card; iOS push waits for the Apple launch. |
| P1 | Bookmarks / History | W2 | **MISSING.** | History screen captured on desktop | ADR-0023 (Proposed, 2026-10-26) + three RPCs in `EngagementService`: thin `users/{uid}/bookmarks/{postId}` doc rendering the live post (no snapshot), list limit 20, cap 1,000; History tab for Likes in W3. |
| P1 | Following system | W3 | **PARTIAL.** Follow / unfollow / block / mute, followers and following lists, follow-request RPCs exist in `graph.proto`. | MEASURED (own profile) | "Follows you" chip, follow-requests screen, who-to-follow card (capped reads, never a scan). Verify what the app already surfaces before planning. |
| P2 | Messaging | W7 | **MISSING.** | Chat captured on desktop; conversation view only partly seen | Capture before UI work; ADR with cost table; v1 server-mediated pull + push, rate caps, no E2E. |
| P2 | Lists and Communities | W5 | **MISSING.** | Both captured on desktop | Capture mobile; moderation story for communities; per-list timeline budget. |
| P3 | Spaces and advanced / premium | W8 (premium shell only) | **Spaces: OUT OF SCOPE** (founder 2026-10-23). Premium: shell only. | – | Nothing for Spaces. Premium stays a read-only shell. |

## 4. Wave plan (numbering follows the founder-reviewed `14_mvp_structured_plan.md`)
Each wave: planner plan in `docs/plans/`, architect ADR + proto + indexes where noted, a flag, a reads/writes table, `sre-performance` cost report, then deployer and reviewer gates. 🔒 = cost or rule gate.

| Wave | Theme | Backend | Gate | Status |
|---|---|---|---|---|
| W0 | Foundations | none | $0 | **Done** (#226) |
| W1 | Core surfaces | none | $0 | **Done** (#229-#237); M1 exit review pending |
| **W1.5** | **Capture and conform: post detail, composer modal, other users' profile, light-theme gaps** | none | $0 | **New, next.** Step 1 is a founder-driven capture session (section 5); step 2 is a client-only plan from what is actually observed. |
| W2 | Engagement and composer basics: bookmarks, share, alt text, quote UI, hashtag tap-through, push opt-in card | bookmarks RPCs and collection (alt text already exists end to end: client conformance only) | per-RPC budgets | **Planned in detail** (2026-10-26): `docs/plans/ui-w2-engagement-composer-basics.md`, W2-1..W2-16 Todo, bookmarks per ADR-0023; hashtag tap-through proposed to move to W4 (plan question 1) |
| W3 | Profile and graph completion: cover, Media / Reposts / Likes tabs, pin, who-to-follow, follow requests UI, "Follows you", profile meta | cover media kind, media filter + index, likes list, pin field, suggestion query with read cap | per-RPC budgets | **Planned in detail** (2026-10-26): `docs/plans/ui-w3-profile-graph-completion.md`, W3-1..W3-38 Open. Part A (W3-1..W3-24) per ADR-0024 (to be written, W3-1): banner, location, website, pin, Reposts / Media tabs, Likes as an owner-only History tab, "Follows you", who-to-follow, sticky tabs. Part B (W3-25..W3-38), private accounts and follow requests, needs ADR-0025 (W3-3): the follow-request RPCs are stubs today and ADR-0008 D1 deferred private accounts, so the founder must reverse that (plan question 1). About INR 27/month at 300 DAU for Part A |
| W4 | Discovery: search (people, hashtags), suggestions, Explore, trends; hashtag tap-through (proposed move from W2 on 2026-10-26, founder decision pending: W2 plan question 1) | search module; trend counters via one scheduled sweep (Cloud Scheduler has 3 free jobs) | 🔒 no external news/trends feed | **Planned in detail** (2026-10-26): `docs/plans/ui-w4-discovery-search.md`, W4-1..W4-24 Open (W4-11/W4-12 conditional on founder F2); search module, `FEATURE_SEARCH` + `FEATURE_TRENDS`, ADR-0024 (or next free) to write; handle prefix + `#tag` only (full-text deferred with a trigger), trends default piggyback on `daily-maintenance` (no new Scheduler job, founder F1); who-to-follow query owned by W3, rendered on Explore by W4; reversal of the 2026-10-18 deferral confirmed |
| W5 | Lists and Communities, custom Home tabs | lists + communities modules | moderation scope for communities | **Planned in detail** (2026-10-26): `docs/plans/ui-w5-lists-communities.md`, W5-1..W5-40 (plus W5-25b, W5-26b) Open. Part A (W5-1..W5-19): Lists (private by default, member cap 150 so a list timeline is at most 5 chunks of Home's pull-merge, same `since` cursor and caches) and custom Home tabs (Following + up to 5 pinned, synced via `GetMe`), `FEATURE_LISTS`, ADR-0027 (or next free, W5-1). Part B (W5-20..W5-40): public Communities (members post, members-only replies, owner/moderator/member/banned, community moderators hide posts from the community view only; platform reports and takedowns still apply; creation limited to a `COMMUNITY_CREATORS` allowlist), `FEATURE_COMMUNITIES`, ADR-0028 (or next free, W5-20). No new GCP service, no index-file change in the default design (one fallback index if the community feed query fails its check against the dev Firestore). About INR 15 / 52 / 260 a month at 300 / 1,000 / 3,000 DAU (+38.1 reads per DAU) |
| W6 | Composer extras: polls, scheduled posts, drafts (local first), GIF, reply audience | poll storage + vote RPC, one sweep job | 🔒 GIF provider terms; scheduling stays on one sweep job | Planned |
| W7 | Messaging v1 | messaging module; pull + FCM push | 🔒 realtime and E2E are the cost cliffs; E2E is a future ADR | **Planned in detail (2026-10-27)**: `docs/plans/ui-w7-messaging.md`, W7-1..W7-24 Open. 1:1 only. Per-user `dmInbox` / `dmRequests` entries, no composite index (six index exemptions, a gate-file change). Mutual follows go to the Inbox, everyone else to capped requests (founder F2). Delivery is a backing-off `since` poll on a visible thread plus a push-only FCM `message` type; no realtime and no E2E (stage-ladder row "Direct messages" with triggers). Tombstones on account deletion (F3). `FEATURE_MESSAGING`; ADR-0029 or the next free number (W7-1). About INR 12 / 58 / 480 a month at 300 / 1,000 / 3,000 DAU (polling CPU is the 3,000 line). The conversation-view capture is optional: the UI uses X-like defaults |
| W8 | Creator, Premium, Ads, Calls | none (shells) | 🔒 payments, ads, video and live audio each need a future approved ADR | Planned as read-only shells |
W2 to W3 may run in parallel with W4 once W1.5 is planned. W5 to W8 follow in order of dependency and risk.

### Suggested order of work (next 4 steps)
1. **Close M1:** record the founder's visual review of the merged W0/W1 screens and add the Linux-CI golden job (B-01). Decide the `ui_shell` ramp (B-20); a ramp needs a Terraform plan shown to the founder first.
2. **W1.5 capture session** (section 5), then a W1.5 client plan.
3. **W2 plan** by the planner, with the bookmarks ADR drafted by the architect.
4. **W3 plan** after the W2 ADR, reusing the media pipeline for covers.

## 5. Research gaps to close before building (needs the founder; no screenshot is committed)
REA capture times out on tabs that are not the active tab of their window, so each capture needs the founder to open and focus the tab. Not captured yet and required before the matching work:

| Needed for | Capture |
|---|---|
| W1.5 | Post detail (desktop + mobile, dark + light); composer modal (empty, with text, near limit, with media, discard prompt); another user's profile (follow / following / blocked / protected states) |
| W2 | Share menu; bookmark toast; alt-text dialog |
| W4 | Search box focused (suggestions), results tabs (Top / Latest / People / Media), empty results |
| W5 | Lists and Communities on mobile |
| W7 | Conversation view; new-message flow |
| All | Hover, pressed and focus states; breakpoints between 400 and 1536 dp; computed fonts; light theme on the ~18 uncaptured screens |

## 6. Risks
| Risk | Mitigation |
|---|---|
| Scope explosion (everything in MVP) | one wave at a time, flags default off, the founder decides which flags are ON at launch |
| Free-tier overrun from search, lists, DMs | per-RPC budget tables in ADRs, caps in code (`CLAUDE.md` rule 11), degraded-mode switch |
| Building P0 surfaces from guesses | W1.5 captures first; unobserved states are UNKNOWN, never filled in |
| Visual drift without goldens | M1 exit needs the Linux golden job and the founder review |
| Copying X too closely | only colours and structure follow X; own icons, copy, names; no Grok / Premium / ads upsell surfaces |
| Credit window (ADR-0022, until 2026-12-24) treated as a budget for new features | the credit lifts no 🔒 gate; anything built in the window must run at Stage 0 cost after 2026-12-24 (no realtime, video, external search, paid GIF provider, App Check web without its own ADR) |

## 7. Founder decisions (2026-10-23)
| # | Question | Decision |
|---|---|---|
| Q1 | Spaces (live audio) | **Dropped from the project.** No shell, no research, no ticket. |
| Q2 | W1.5 capture-then-conform slice ahead of W2 | Accepted (default) |
| Q3 | M1 visual review and `ui_shell` ramp | Default: the founder records the review after the Linux golden job lands; `ui_shell` stays dev allowlist until then; any ramp needs a Terraform plan shown first |
| Q4 | Accent text on light | **Switch to X's `#1d9bf0`** (replaces the `#1478bd` default). Implementation: an ADR-0020 amendment plus a small theme ticket. Caution: `#1d9bf0` on white is about 3:1, below WCAG AA (4.5:1) for small text, so the ticket must keep link underlines or weight cues and the accessibility review must record the exception. |

## 8. Documents this roadmap updates or supersedes
`.claude/skills/mvp-roadmap/SKILL.md` (phases), `docs/plans/phase1.md` (decisions 1-3), `docs/plans/backlogs.md` (wave numbers, B-20), `.claude/skills/flutter-modern-ui/SKILL.md` (palette), `docs/adr/0020-ui-colour-system-follows-x.md` (needs the Q4 amendment), and, locally, `docs/x_research/` files 07, 13, 14 and the README.
