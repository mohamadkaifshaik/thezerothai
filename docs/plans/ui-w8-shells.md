# UI W8: Creator, Premium, Ads and Calls as read-only shells
Plan owner: planner · Date: 2026-10-27 · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **Client-only:** four informational screens, 0 RPCs, 0 Firestore reads, writes or deletes, no proto, no Firebase or index change, no new package, no new GCP service, no fixed cost · Flags: new `FEATURE_SHELLS` (wire name `shells`, client-only, registered on the server like `ui_shell` so `GetMe.enabled_features` reports it); existing `ui_shell` (navigation chrome)

Source:
- `docs/plans/roadmap.md`: the W8 row ("Creator, Premium, Ads, Calls | none (shells) | payments, ads, video and live audio each need a future approved ADR"), founder decisions 2026-10-22 ("W8 = UI shells only, payments / ads / video each need a future approved ADR"), Q1 2026-10-23 (Spaces dropped: no shell, no research, no ticket), the risk row "only colours and structure follow X; own icons, copy, names; no Grok / Premium / ads upsell surfaces";
- `docs/x_research/01_screen_inventory.md` §10 (Premium sign-up modal) and §11 (Creator Studio), `screens/premium-modal.md`, `screens/creator-studio.md`, `screens/ads-manager-setup.md`, `screens/calls.md`, `05_component_library.md` row 18 (empty state with icon disc and CTA), `08_navigation_flows.md` (Calls, Premium, Creator Studio and Ads live in the phone's avatar drawer; Premium opens as a modal over Home; ads are on a separate origin), `07_functionality_inventory.md` (Calls, Premium / creator / ads: out of scope at Stage 0), `14_mvp_structured_plan.md` (W8 row: "UI shells without a paid backend (read-only, 'coming soon'/waitlist) until the founder approves an ADR (payments provider, video infra is fixed-cost: SFU/TURN)"). All local and git-ignored;
- `docs/plans/ui-w0-foundations.md` (D3, W0-10: how `ui_shell` was registered), `docs/runbooks/ui-shell.md`, `docs/plans/ui-w6-composer-extras.md` (`FEATURE_DRAFTS`, the second client-only flag), `docs/plans/ui-w5-lists-communities.md` and `docs/plans/ui-w7-messaging.md` (format, the nav decisions, shared files);
- `docs/ui-catalog.md` (`AppDrawer`, `AppAccountChip`, `MainShell`, `AppBackHeader`, `AppEmptyView`, `AppSurface`, `AppSectionHeader`, `SettingsList` / `SettingsRow`, `AppRouter`, `isFeatureEnabled`, the theme harness);
- skills `flag-rollout`, `reuse-first`, `flutter-feature`, `stage-ladder`, `free-tier-budget`.

Branches: `feat/ui-w8-N-<slug>` off `main` (not stacked); one ticket per PR; merge `origin/main` into the branch.

## Questions for the founder (proposed default in bold; nothing blocks W8-1, W8-2, W8-3 or W8-10)
- **F1. Which shells to show at all.** One flag cannot choose between four screens: `FEATURE_SHELLS` turns all of them on or off for a caller. Which shells exist is therefore a **code decision**, not a ramp decision: one client constant, `kVisibleShells` (a set of `ShellKind`), lists the shells that get an entry point and a route. Changing it is a one-line PR. It ships with the next web deploy and the next store build. **Default: all four in the set.** The flag stays at the dev allowlist (F2), so only testers see them. Alternative: show only Creator tools and Calls, and hide Premium and Advertise until each one's ADR exists.
- **F2. Is Premium shown to anyone before pricing exists?** **Default: no.** The dev ceiling is allowlist 3 and **there is no prod entry**, so `shells` stays `off` in prod. Any prod raise needs three things:
  - your explicit decision;
  - the store-policy check in Risks;
  - your sign-off on the final copy.

  The roadmap forbids "Premium / ads upsell surfaces". So the Premium and Advertise pages are informational only: no price, no button, no form (F3).
- **F3. Copy tone and names.** **Default tone:** plain, factual and in our own words, with no exclamation marks, no "coming soon", no date and no promise. Every page says what is not available, why, and what still works.
  - **Default names** (the roadmap rule is "own names"): "Creator tools" (X says "Creator Studio"), "Premium" (a generic word; the page never uses X's plan names "Plus" or "Premium+"), "Advertise" (X says "Ads"; the route is `/advertise`, see W8-6), and "Calls".
  - Alternatives: keep X's labels "Creator Studio" and "Ads", or a neutral "Supporters" for Premium.
  - The exact strings live in each screen ticket. You approve them in that ticket's PR.
- **F4. The Advertise contact address.** **Default: none.** Without an address the page shows no contact affordance at all. If you name one, it should be a dedicated alias such as advertise@ on our domain, not a personal inbox: an address shown in the app is public and will get spam. The page then shows one "Email us" text button that opens `mailto:` through the existing `url_launcher`. The subject is fixed and the body is empty, so no uid or handle goes into the mail. The address is a single constant, `kAdvertisingContactEmail`, null by default.
- **F5. Entry points on wide screens (600 dp and up).** The drawer exists only below 600 dp. From 600 dp up, the only overflow menu is the account chip's popup (Profile / Settings / Sign out). **Default: the account chip menu gets the visible shells**, under a divider, between Settings and Sign out. This adds no rail item, and the rail is already growing with W4 Explore, W5 Lists and Communities, and W7 Messages. Alternative: a rail "More" item, as on X desktop, that opens the same list. That is a nav-structure change better made once for W5's rows too; it is out of scope here and noted in Risks.
- **F6. Legacy chrome (`ui_shell` off).** **Default: no entry point.** Every entry needs `shells` **and** `ui_shell`, the W5 and W7 pattern. With `ui_shell` off, the routes still work for a caller with `shells` on (typed URL on web) and still redirect Home with `shells` off.
- **F7. Premium as a page or a modal.** X opens Premium as a paywall modal over Home (`premium-modal.md`). **Default: a normal page** in the shell like the other three. A modal over the feed is the upsell pattern we avoid, and a page is simpler to test.
- **F8. Creator tools numbers.** **Default: show the four numbers the app already holds** from the last `GetMe`: followers, following, posts and the join month. Every engagement-type figure is a static "Not available yet" row, never a fake 0. Alternative: a fully static page with no numbers.

## What exists already (verified on `main` 434099a)
| Piece | State | W8 delta |
|---|---|---|
| Shell navigation | `MainShell`: bar and rail Home, Notifications (flag), History (rail-only, `bookmarks`), Profile; `AppDrawer` (phones) rows Profile / History / Settings / Sign out; `AppAccountChip` popup (600 dp and up) Profile / Settings / Sign out; `AppSideColumn` links (1200 dp and up) Settings / Privacy Policy. `_selectedTab` falls back to Home for any unknown location | shell rows in the drawer and chip menu from one descriptor list; `_selectedTab` returns none on a shell route |
| Routing | `AppRouter`: one `go_router`, ShellRoute children (e.g. `bookmarksPath`), per-flag redirects (`_bookmarksFlagRedirect` …), `deepLinkTarget` allowlist (`/post/…`, `/u/…`, `/profile/…`) | four ShellRoute children, `_shellsFlagRedirect`; **no** `deepLinkTarget` change |
| Client-only flags | `ui_shell` (`kFeatureUiShell`, `config.FeatureUIShell`, `flags.LoadSpec("UI_SHELL", "ui_shell", flags.Off)`, Terraform `feature_ui_shell*`, ceiling dev allowlist 3, runbook `ui-shell.md`); `drafts` planned the same way (W6) | `shells` registered the same way |
| Grouped rows | `SettingsGroup` / `SettingsRow` (`features/settings/presentation/widgets/settings_group.dart`): **feature-local** ("the Settings screen is the only place that groups rows this way"); a row with no `onTap` is static text with no chevron; `trailing` renders only with `onTap` | moved to `shared/widgets/`, plus a value or pill on static rows (W8-3) |
| Empty state | `AppEmptyView` (icon, title, optional subtitle, optional `action`) | reused for the hero of each page |
| Status pill | none (X's "Ineligible" / "New" pills, `creator-studio.md` §3) | a small `AppStatusPill` (W8-3) |
| Profile numbers | `OnboardingBloc.state.profile` (from `GetMe`): `followers_count`, `following_count`, `posts_count`, `created_at` (`identity.proto` `Profile` fields 9–12); the drawer already reads it with 0 RPCs | Creator tools reads the same object |
| Mail links | `url_launcher ^6.3.3` already in `app/pubspec.yaml` | `mailto:` only if F4 names an address; no new package |
| Captures | Creator Studio MEASURED (desktop, dark), Premium modal MEASURED (desktop, dark), Ads Manager setup MEASURED (separate origin), Calls empty state MEASURED (desktop, dark); none on mobile or in light theme | X-conformant structure with our own copy; mobile and light are X-like defaults |

## Goal & user value
People who open the drawer or the account menu find the same destinations X users expect: creator tools, a paid tier, advertising and calls. Each one gives an honest answer instead of nothing: what is not available yet, why, and what works today. Creator tools also gives a small real value at no cost: your own follower, following and post counts in one place. For us the value is the seam. Each future feature has a fixed route and entry point to land in, and swapping the shell for the real feature changes no caller.

## Scope / Out of scope
**In scope (Stage 0 rung):**
- **Four client-only screens,** inside the shell, each reachable from one drawer row (under 600 dp) and one account chip menu item (600 dp and up):
  - **Creator tools** `/creator-studio`. A read-only overview with the grouped structure of inventory §11: your account at a glance, insights, programs. Numbers come only from the `GetMe` profile already in memory; everything else is a static "Not available yet" row. No monetisation control, no toggle, no link to earnings.
  - **Premium** `/premium`. An informational page about a possible future paid tier. No price, currency, plan names, feature checklist or billing toggle. No subscribe, upgrade, trial, waitlist or "notify me" affordance, and no link to any external purchase page.
  - **Advertise** `/advertise`. An informational page for advertisers. No ad manager, no form, no account setup. One `mailto:` text button only if you name an address (F4); otherwise no contact affordance.
  - **Calls** `/calls`. A settings-style page saying voice and video calls are not available, and why. No permission prompt, no new platform permission (AndroidManifest, Info.plist, web), no WebRTC or calling package.
- **One client-only flag** `FEATURE_SHELLS` and its registration (server config, registry, ceiling, Terraform, runbook). One descriptor list, `shellEntries`, drives the drawer rows, the chip menu items and the route redirect. `kVisibleShells` chooses which shells exist (F1).
- **Accessibility, the responsive matrix, the flag-off matrix** and a "0 RPCs" test (W8-8).
- **The stage-ladder rows** for the four future features: Stage 0 = shell, the seam, the Stage 2/3 target with its ADR, and the trigger (table below; W8-10 adds them to the skill).

**Explicitly not built (any of these is a change of scope that needs you):** a waitlist or email capture (`14_mvp_structured_plan.md` mentions "waitlist"; it would collect personal data and imply a pre-sale), a pricing table, a payment sheet, store billing or in-app-purchase packages, an ad slot or "Promoted" label in any feed, analytics events or screen-view tracking (the app has Crashlytics only, and W8 adds nothing to it), push notifications, a server RPC of any kind, anything about live audio or Spaces (dropped, Q1).

**Stage 0 choice, seam and Stage 2/3 target, per future feature** (proposed `stage-ladder` rows; W8-10 adds them under a "Locked features (shell only)" heading; each real feature needs a future ADR, **numbered when written**, the highest existing plus one: W3–W7 have already claimed 0024–0029 as planned numbers, and W5 and W6 both name 0028):

| Concern | Stage 0 (W8) | Seam to protect now | Stage 2/3 target (future ADR) | Trigger (measured, or a recorded founder decision) |
|---|---|---|---|---|
| Paid tier (Premium) | informational shell, no price, no purchase path | route `AppRouter.premiumPath`, the `ShellKind.premium` entry; no client code reads an "entitlement" | **Payments ADR:** store billing for digital goods in the apps (Google Play Billing; Apple In-App Purchase after the Apple launch), a web payment provider (not GCP, so a stack exception the ADR must justify), server-side receipt verification and store notifications through Pub/Sub, an entitlements doc owned by `identity`, GST and invoicing, refund and cancellation policy, consumer-protection disclosures, recurring-payment mandate rules for Indian cards, what may be paywalled (never safety or privacy features) | your decision to charge, **plus** a measured need: the Stage 0 bill (`cost-model.md` §5) above INR 3,000/month for 2 consecutive months (about 3,000 DAU), or no funding after the credit expires (`pending.md` 1.14) with more than 1,000 DAU |
| Creator insights (numbers beyond the profile counts) | four profile numbers from `GetMe` (0 reads) + static rows | `ShellKind.creatorStudio` route; the "Insights" group is one widget, so real rows replace placeholders without touching the page frame | **Insights plan (no ADR if no new collection):** an `InsightsService` summarising the counters already on your own recent posts (bounded reads, instance-cached). **Impressions** need a write per view, which is the `stage-ladder` Counters row (batched or sharded counters, its own ADR) | at least 50 accounts with more than 1,000 followers, or your request; impressions only when the Counters row's ADR exists |
| Creator monetisation (earnings, subscriptions to creators) | the "Programs" group reads "Not available" | same route; no control exists to remove | **Creator payouts ADR** (after Payments): revenue share, a payouts provider, KYC, tax withholding, eligibility rules, fraud and chargebacks | Payments live in prod **and** your decision |
| Advertising | informational shell, optional `mailto:` (F4) | route `/advertise`; the `timeline` interface stays the only place a feed is merged (an ad slot later goes behind it, never in a handler or widget) | **Ads ADR:** direct-sold promoted posts vs an ad-network SDK, consent and privacy (India's DPDP Act, iOS App Tracking Transparency, Play Data safety), ad labelling, advertiser verification and ad review, payments (needs Payments), brand safety, the Privacy Policy change | sustained DAU above 20,000 for 30 days (the Stage 2 boundary; below it ad revenue does not cover ad review and legal cost), or a signed advertiser budget you want to accept |
| Calls (1:1 voice and video) | "not available" page, no permission, no package | route `AppRouter.callsPath`; a later call action would go in W7's conversation header (calls start from a conversation, never from a new public surface); W8 changes nothing in W7 | **Calls ADR**, after the `stage-ladder` Real-time row has moved (calls need a signalling channel, which Stage 0 does not have): WebRTC on the clients, signalling, STUN, a TURN relay (relay egress is billed per GB; a TURN VM or SFU is a **fixed cost** and `CLAUDE.md` lists the matching services as not used), call push (Android high-priority FCM; iOS PushKit and CallKit after the Apple launch), block and spam rules, call metadata in export and erasure, an emergency-calls disclaimer | W7 messaging live with messaging DAU above 30 % of DAU for 30 days, **and** the Real-time row's trigger met, **and** your decision to accept the fixed or per-GB relay cost |

**Out of scope (this wave):** everything in the "Stage 2/3 target" column above; a rail "More" item (F5 alternative); X's Premium modal styling, brand strip and plan cards; X's split-panel Ads Manager layout (`ads-manager-setup.md` §5: a separate product); X's calendar-style Calls toolbar; Business (X's drawer has it; not in the roadmap); Grok (never).

## Non-functional targets (Stage 0, 0–300 DAU; credit mode to ~3k DAU changes nothing here)
- **Latency:** no network wait. Each page renders from memory in its first frame after navigation: no skeleton, no spinner, no RPC. The navigation targets of the app (p95 timeline read < 400 ms) are unaffected.
- **DAU:** independent of DAU; the flag is dev allowlist only (3 uids) until you decide F2.
- **Staleness bounds (every cached read):**
  | Read | Bound |
  |---|---|
  | Creator tools: followers, following, posts, joined month | **as of the last `GetMe` the app made** (app start, resume, the flag gates' refresh: about 4 per DAU per day per the W7 model). The page never calls `GetMe` or `GetProfile`, has no pull to refresh, and says so in a footnote ("As of your last refresh"). A follow made on another device can be missing for that long |
  | Flag `shells` | as of the last `GetMe`; a server change reaches a running client on its next `GetMe` (the `ui_shell` runbook rule) |
- **Accessibility (every screen):**
  - one header node per page title and per group title;
  - static rows read once as "<title>, <value or 'not available yet'>". No row is a button unless it opens something; the only tappable element in W8 is the optional `mailto:` button;
  - nothing conveyed by colour alone: the status pill has text, and its tint and label meet 4.5:1 in both themes (the Q4 caveat: `#1d9bf0` text on white is about 3:1, so the pill uses `accentText` or the muted tone on the raised surface);
  - 48 dp targets;
  - no overflow at text scale 2.0: the row's pill moves under the title instead of clipping;
  - the drawer rows and menu items announce their label once (the `_DrawerRow` pattern).
- **Responsive matrix (each screen):** 360 dp (bottom bar + drawer, page edge to edge, entry in the drawer), 600 dp (icon rail, page in the 600 dp column between hairlines, entry in the chip menu), 1200 dp (extended rail, side column, entry in the chip menu); light and dark; text scale 1.0 / 1.3 / 2.0. `theme_harness.dart` covers 1.0 and 1.3 today, so the tickets pass 2.0 explicitly, as W7 does.

## Cost (required)
Method: `free-tier-budget` §2 (one row per RPC: reads, writes, Cloud Run ms, calls per DAU) and the marginal method of `docs/reviews/cost-model.md` §5 (W2 lines). **W8 adds no RPC, so there is no row to add:**

| Item | W8 delta | Why |
|---|---|---|
| Firestore reads / writes / deletes | **0 / 0 / 0** per DAU per day | the screens take no repository; Creator tools reads `OnboardingBloc.state.profile`, which the app already loaded through `GetMe` |
| Cloud Run requests and vCPU-s | **0** | no RPC; `GetMe` is not called more often |
| `GetMe` response | +8 bytes (`"shells"` in `enabled_features`) for callers the flag is on for, 0 for everyone else | the flag registry reports enabled names only |
| Vision units, Pub/Sub, Scheduler, Secret Manager | **0** | nothing new |
| New packages | **0** | `url_launcher` is already a dependency; no billing, ads, WebRTC or permission package |
| New GCP service, fixed cost | **none** | |
| Web bundle (Firebase Hosting transfer) | estimated +15–30 KB gzip on `main.dart.js` for four static screens and their strings. Every web visitor downloads it whatever the flag (dart2js has one bundle), but only once per web release (`cost-model.md` §11: a returning visitor re-downloads `main.dart.js` only after a release) | priced at the margin (§1 web share 30 %, §5 note: about 4.3 prod web releases a month, §7 Hosting $0.15/GB past 360 MB/day, which §4 puts at about 2,731 DAU): 300 and 1,000 DAU are inside the free transfer, so **INR 0**; at 3,000 DAU, 900 web DAU × 30 KB × 4.3 releases ≈ 0.11 GB a month ≈ $0.017 ≈ **INR 1.6 a month** (upper estimate). W8-8 measures the real delta with the §11 build method and records it in its PR |

**W8 total: about INR 0 / 0 / 2 a month at 300 / 1,000 / 3,000 DAU** (all of it the web bundle line). No quota crossover moves. The Stage 0 bill stays as `cost-model.md` §5 states it (about INR 441 at 300 DAU with W2). **No `sre-performance` ticket:** there is no new RPC and no hot read path. `code-reviewer` checks the cost line in W8-1 and W8-2: no repository import in `features/shells/`, no `GetMe` call added.

## Flags
- **`FEATURE_SHELLS`** (wire name `shells`, Go `config.FeatureShells`, Dart `kFeatureShells` in `app/lib/features/shells/domain/shells_feature_flag.dart`).
  - **Client-only:** no RPC is gated by it, because there is none. Registered with `flags.LoadSpec("SHELLS", "shells", flags.Off)` in `config.go` and in `flags.NewRegistry` in `apiserver.go`, so `GetMe.enabled_features` reports it (exactly like `ui_shell` and the planned `drafts`).
  - **Gates:** every shell entry point (drawer rows, chip menu items) needs `shells` **and** `ui_shell` (F6); every shell route needs `shells` (a typed URL with the flag off redirects Home); `kVisibleShells` (F1) removes a shell's entry and route entirely.
- **Ceiling** (`scripts/promotion/flag-ceiling.json`, **founder-gated file, CODEOWNERS**): add `"SHELLS"` to `flags`. Add the dev entry `"SHELLS": {"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}`. **No prod entry or raise** (F2). `check-flag-registry.sh` fails unless the `LoadSpec` names and the ceiling list match exactly, so both go in the same PR (W8-1).
- **Terraform:** `feature_shells`, `feature_shells_allowlist` and `feature_shells_percent` in `infra/terraform/envs/{dev,prod}/variables.tf`, and the three env entries in `envs/{dev,prod}/main.tf`. Copy `feature_ui_shell*`. Default `off`. Nothing is applied in this plan.
- **Ramp:** dev allowlist (3 uids, who must also have `ui_shell` on), and nothing more. A prod ramp is F2: allowlist, then straight to `on` (a percent ramp of informational pages buys nothing). Each step is a Terraform change plus a tagged revision (ADR-0019).
- **Kill switches:**
  - `FEATURE_SHELLS=off`, deployed: every entry disappears and every route redirects Home on the client's next `GetMe`.
  - One shell only: remove it from `kVisibleShells` by PR. Web takes it on the next deploy; mobile on the next store build, so the server flag is the fast switch for all four.
  - No data exists, so nothing needs a migration or an eraser.
- **Retire:** when every shell has been replaced by its real feature (section "How each shell is replaced"), remove the env vars, keep the name reported as retired (`NewRetired`), and never reuse `shells`.

## Abuse & security surface
- **New public reads or writes:** none. No RPC, no Firestore, no Storage, no new endpoint. Nothing new to scrape or enumerate.
- **Data collection:** none.
  - No form, text field, checkbox or consent prompt on any shell.
  - No analytics event; the app has none beyond Crashlytics, and W8 adds no Crashlytics key or log.
  - The optional `mailto:` (F4) carries a fixed subject and an empty body, with no uid, handle or device data. The user's own mail app sends it, so we receive only what they choose to write.
- **Permissions:** none added. The Calls page never calls a permission API, and the platform manifests are unchanged (W8-9 checks the diff of `android/`, `ios/` and `web/`).
- **Links:**
  - the shell routes are **not** added to `AppRouter.deepLinkTarget` (a cold-opened `/premium` lands on Home after sign-in, by design);
  - no external `https` link, so no off-store purchase link and no anti-steering problem;
  - `mailto:` goes through `url_launcher` only when an address is set.
- **Misleading-claims surface (the real risk of W8):**
  - the Premium and Advertise copy must not read as an offer;
  - no price, no "free trial", no urgency (no countdown, no "limited"), no testimonial, no feature promise, no date;
  - the copy is reviewed by `security-auditor` (W8-9, privacy and claims) and approved by you in the screen PRs (F3).
  - India's consumer-protection rules on dark patterns (false urgency, subscription traps) are the reason for these rules; legal advice on the final copy rides with the Terms of Service review (`pending.md` 3.9).
- **Degraded mode, service pause:** unaffected (no RPC). The pages stay reachable in `DEGRADED_MODE=readonly`. Under the ADR-0022 pause the whole app shows `ServicePausedView`, as today.

## How each shell is replaced when its real feature ships (the seam)
- **One descriptor, one route, one entry per shell.**
  - `shellEntries` (`app/lib/features/shells/domain/shell_entries.dart`) is a list of `ShellEntry {kind, icon, label, path, isVisible(context)}`. `AppDrawer` and `AppAccountChip` render it, and `AppRouter` uses the same `kind → path` mapping for its redirect.
  - `AppRouter.creatorStudioPath`, `premiumPath`, `advertisePath` and `callsPath` are the only route constants.
  - No other file names a shell route or label. Code review checks this (`grep` for the paths outside the router and the descriptor).
- **Replacing a shell changes neither caller.** The real feature keeps the path and the entry, and changes only two things:
  1. The entry's `isVisible` moves from `shells` to the real flag, for example `premium` or `calls`.
  2. The route's page builder renders the real screen when the real flag is on, and the shell otherwise. A user outside the real feature's ramp still sees the honest shell, not a dead link.

  When the real flag reaches `on`, the shell page and its `ShellKind` are deleted in the real feature's PR. The drawer and chip menu do not change.
- **Per shell:**
  - **Creator tools.** The "Insights" and "Programs" groups are separate widgets (`CreatorInsightsGroup`, `CreatorProgramsGroup`). Insights v1 replaces only the first one, and the page frame and "Your account" group stay. Monetisation replaces the second after the Payments and Creator payouts ADRs.
  - **Premium.** After the Payments ADR, `/premium` becomes the purchase or manage-subscription page behind its own flag. Any store-billing package arrives with that ADR, never earlier.
  - **Advertise.** After the Ads ADR, `/advertise` becomes either the advertiser entry page or a link-out to a separate advertiser origin (X runs its ad tools on a separate origin). Feeds get an ad slot only through the `timeline` interface.
  - **Calls.** After the Calls ADR, `/calls` becomes call history, and the call action appears in W7's conversation header. The "not available" page goes away.

## Dependencies & open questions
**Dependencies:**
- Your answers to F1–F8; each has a default, and only W8-6's mailto waits on F4 (default none).
- **Nav-file merge order.** W8-2 edits `app_drawer.dart`, `app_account_chip.dart`, `main_shell.dart` and `app_router.dart`, the same files as W4-17 (Explore), W5-11 and W5-31 (Lists and Communities), W7-19 (Messages) and W3-18. Merge one at a time; whichever lands second merges `origin/main`. The shell rows go **after** all feature rows and before Settings in the drawer, so they never reorder another wave's rows.
- **W3 "Joined" formatter.** If W3's profile-meta ticket has merged a "Joined <Month YYYY>" helper, W8-4 reuses it. If not, W8-4 adds `formatJoinedMonth` to `app/lib/shared/format/` with a catalog line, and W3 reuses it (`reuse-first`).
- **No dependency on W7.** The Calls page does not link to Messages. A "Send a message instead" action can be added when `messaging` exists; it is a one-line follow-up and not part of W8.

**Questions for @architect (W8-10):**
- **A1. Does W8 need an ADR?** **Proposal: no.** No contract, data, service or cost changes; it is a client-only flag on the `ui_shell` / `drafts` precedent; the decisions are in this plan. If you disagree, a short ADR replaces W8-10 and takes the next free number.
- **A2. The stage-ladder rows** (table in Scope): confirm the wording, the triggers and the heading "Locked features (shell only)" in `.claude/skills/stage-ladder/SKILL.md`, and that Calls sits behind the Real-time row.
- **A3. Future ADR numbering:** none is reserved by W8. The W5 and W6 plans both name 0028 as a planned number; whichever ADR PR opens second takes the next free number (their plans already say "or the next free number").

## Milestones
1. **M8.1 Wiring:** W8-1 (server flag registration) ‖ W8-2 (client flag, descriptor, entries, routes, stub pages) ‖ W8-3 (shared grouped rows and status pill) ‖ W8-10 (stage-ladder rows).
2. **M8.2 Screens:** W8-4 ‖ W8-5 ‖ W8-6 ‖ W8-7.
3. **M8.3 Verify and roll:** W8-8 (tests), W8-9 (privacy and claims check), W8-11 (dev rollout). Prod: no change (F2).

| ID | Ticket | Owner | Size | Depends | Parallel with W3–W7? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| W8-1 | `FEATURE_SHELLS` registration: `config.go` `LoadSpec` + test, `NewRegistry`, `flag-ceiling.json` (gate), Terraform vars, runbook | backend-developer | S | — | **yes, start now**; shared files serialise with W3-4, W3-25, W4-3, W5-3, W5-22, W6-4, W7-4 | Open |
| W8-2 | Client flag, `shellEntries` + `kVisibleShells`, drawer rows, chip menu items, `_selectedTab` none, four routes + `_shellsFlagRedirect`, stub pages | frontend-developer | M | — (client tests inject `enabled_features`) | **yes, start now**; nav files serialise with W3-18, W4-17, W5-11, W5-31, W7-19 | In review |
| W8-3 | Move `SettingsGroup` / `SettingsRow` to `shared/widgets/`, value and pill on static rows, new `AppStatusPill`, catalog lines | frontend-developer | S | — | **yes, start now**; `settings_screen.dart` serialises with any wave adding a Settings row | Open |
| W8-4 | Creator tools screen | frontend-developer | M | W8-2, W8-3 | yes (own files) | Open |
| W8-5 | Premium screen | frontend-developer | S | W8-2 | yes (own files) | Open |
| W8-6 | Advertise screen (+ optional `mailto:`, F4) | frontend-developer | S | W8-2; F4 for the button | yes (own files) | Open |
| W8-7 | Calls screen | frontend-developer | S | W8-2, W8-3 | yes (own files) | Open |
| W8-8 | Client tests: matrix, flag-off and visibility matrix, 0-RPC test, copy guard, bundle delta | tester | M | W8-4 to W8-7 | yes | Open |
| W8-9 | Privacy and claims check (no data collection, no permission, no dependency, copy) | security-auditor | S | W8-4 to W8-7 | yes | Open |
| W8-10 | Stage-ladder rows "Locked features (shell only)"; A1–A3 answered | architect | S | — | **yes, start now** (skill file only) | Open |
| W8-11 | Dev rollout: targeted Terraform plan, allowlist, smoke at 3 widths | production-deployer | S | W8-1, W8-8, W8-9 | serialise dev applies with W3–W7 rollouts | Open |

Order:
1. W8-1 ‖ W8-2 ‖ W8-3 ‖ W8-10, all at once.
2. W8-4 ‖ W8-5 ‖ W8-6 ‖ W8-7 once W8-2 (and W8-3 for W8-4 and W8-7) has merged. Each touches only its own screen file and test.
3. W8-8 and W8-9, then W8-11. The flag leaves `off` in dev only after W8-9.

**Can start right away (no dependency):** W8-1, W8-2, W8-3 and W8-10. All four can run concurrently with W3 to W7 work. Only the shared files below need one-at-a-time merging.

**Shared files that must serialise (one PR at a time; the second merges `origin/main`):**
| Shared file | W8 ticket | Also touched by |
|---|---|---|
| `backend/pkg/platform/config/config.go` (+ its test env list), `backend/internal/apiserver/apiserver.go` (`flags.NewRegistry` line) | W8-1 | W3-4, W3-25, W4-3, W5-3, W5-22, W6-4, W7-4 |
| `scripts/promotion/flag-ceiling.json` (**gate, founder review**) | W8-1 | the same flag tickets |
| `infra/terraform/envs/{dev,prod}/variables.tf`, `envs/{dev,prod}/main.tf` (`feature_*` vars and env entries) | W8-1 | the same flag tickets |
| `app/lib/core/widgets/app_drawer.dart`, `app/lib/core/widgets/app_account_chip.dart`, `app/lib/core/router/main_shell.dart` (shell navigation) | W8-2 | W3-18, W4-17, W5-11, W5-31, W7-19 |
| `app/lib/core/router/app_router.dart` (routes, redirects) | W8-2 | W3-18, W4-15, W4-17, W5-11, W7-14, W7-15, W7-17, W7-19 |
| `app/lib/features/settings/presentation/settings_screen.dart`, `widgets/settings_group.dart` (moved) | W8-3 | any wave adding a Settings row (W3, W6, W7 settings entries) |
| `docs/ui-catalog.md` | W8-2, W8-3, W8-4 | every UI ticket (append-only lines; resolve by keeping both) |

**Definition of done per ticket:**
- Client: widget tests at 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0, via `test/support/theme_harness.dart`, for every new screen and widget. Pixel goldens stay deferred (B-01).
- Backend (W8-1): the config test and `check-flag-registry.sh`; `make ci` green.
- `docs/ui-catalog.md` updated for shared items.
- This table's Status and `docs/pending.md` row 3.17 updated in the PR.

## Tickets

### W8-1 — `FEATURE_SHELLS` registration  [owner: backend-developer] [size: S] [depends: —]  Status: Open
- **Description.** Follow `FEATURE_UI_SHELL` line for line (W0-10):
  - `config.go`: a `FeatureShells flags.Spec` field with a doc comment ("client-only UI flag … no RPC is gated by it"), and `flags.LoadSpec("SHELLS", "shells", flags.Off)` on **one line**, because `check-flag-registry.sh` parses it.
  - `shells_test.go`, a copy of `ui_shell_test.go`: off by default, `on` overrides, `bogus` fails startup. Add the env names to the test env list.
  - `apiserver.go`: add `cfg.FeatureShells` to `flags.NewRegistry`.
  - `scripts/promotion/flag-ceiling.json`: `"SHELLS"` in `flags`, and the dev entry allowlist 3, percent 0. **No prod entry.** If any fixture in `scripts/promotion/test/` enumerates the flag list, update it in the same PR.
  - Terraform: `feature_shells*` variables (with validations) and env entries in `envs/dev` and `envs/prod`, default `off`. Not applied.
  - `docs/runbooks/shells.md`, modelled on `ui-shell.md`: the gates, cost 0, ramp, rollback, and the failure mode "a shell visible to a user outside the allowlist" (roll back the flag).
- **Acceptance criteria.**
  - Given `FEATURE_SHELLS` unset, when the API starts, then the startup `feature_flags` line lists `shells` as off and `GetMe.enabled_features` never contains `shells`.
  - Given `FEATURE_SHELLS=allowlist` with one uid, then `GetMe.enabled_features` contains `shells` for that uid only.
  - Given an invalid value, then startup fails.
  - Given `scripts/promotion` checks, then `check-flag-registry.sh` passes against `config.go`, the ceiling and both `main.tf` files.
- **Test notes.** Flag modes off / allowlist / percent / on through the existing registry tests (no new RPC to test); `terraform fmt -check` and `validate`.
- **Observability.** The startup `feature_flags` line; nothing else.
- **Budget.** 0 reads, 0 writes (flags are env vars; ADR-0008 D6).
- **Flag.** Adds `FEATURE_SHELLS` (default `off`; dev ceiling allowlist 3; no prod ceiling).
- **Seam.** The flag is only a client gate; when a real feature ships, it gets its own flag. `shells` is retired with `NewRetired` and never reused.

### W8-2 — Client flag, entry points and routes  [owner: frontend-developer] [size: M] [depends: —]  Status: In review
- **Description.**
  - `kFeatureShells = 'shells'` in `app/lib/features/shells/domain/shells_feature_flag.dart` (doc comment as `kFeatureUiShell`'s; never hardcode the string elsewhere).
  - `app/lib/features/shells/domain/shell_entries.dart`:
    - `enum ShellKind {creatorStudio, premium, advertise, calls}`;
    - `kVisibleShells` (F1, default all four);
    - `ShellEntry {kind, icon, label, path}`;
    - `shellEntriesFor(BuildContext)`, which returns the visible entries only when `shells` **and** `ui_shell` are on (F6).
    - Icons are Material outline glyphs, not X's: `Icons.insights_outlined`, `Icons.workspace_premium_outlined`, `Icons.campaign_outlined`, `Icons.call_outlined`. Labels per F3.
  - **Drawer:** one `_DrawerRow` per entry, after every feature row and before Settings, preceded by a 1 dp divider. Tap closes the drawer, then `go(path)`.
  - **Account chip menu:** the same entries as `PopupMenuItem`s after a `PopupMenuDivider`, between Settings and Sign out (F5). They use `AppMenuItemRow` (icon + label) so the icon is excluded from semantics.
  - **`MainShell._selectedTab`:** returns null (no selected destination) on a shell route, instead of falling back to Home.
  - **`AppRouter`:**
    - `creatorStudioPath = '/creator-studio'`, `premiumPath = '/premium'`, `advertisePath = '/advertise'`, `callsPath = '/calls'`, as ShellRoute children (like `bookmarksPath`), each built only when its kind is in `kVisibleShells`;
    - `_shellsFlagRedirect`: any of the four paths redirects to `/home` unless `shells` is on for the caller;
    - **no** `deepLinkTarget` change.
  - **Stub pages.** `app/lib/features/shells/presentation/{creator_studio,premium,advertise,calls}_screen.dart`, each an `AppMainColumn` with an `AppBackHeader` (title = label; Back pops, else `go('/home')`) over an `AppEmptyView` "Not available yet". W8-4 to W8-7 replace the body, so those tickets edit only their own file.
  - Catalog lines: `ShellEntry` / `shellEntriesFor` / `kVisibleShells` / `kFeatureShells`, and the `AppDrawer` / `AppAccountChip` lines extended.
- **Acceptance criteria.**
  - Given `shells` and `ui_shell` on at 360 dp, when the drawer opens, then four rows appear after the feature rows and before Settings, in the order Creator tools, Premium, Advertise, Calls, each opening its page.
  - Given the same at 600 and 1200 dp, when the account chip menu opens, then the same four items sit between Settings and Sign out.
  - Given `shells` off, or `ui_shell` off, then no shell row or menu item at any width.
  - Given `shells` off, when `/premium` (or any shell path) is opened by URL, then the app lands on `/home`.
  - Given `kVisibleShells = {calls}`, then only Calls has an entry and a route; `/premium` is an unknown route (the router's existing not-found handling).
  - Given a shell page at 600 / 1200 dp, then no rail destination is selected.
  - Given a cold start on `/calls` while signed out, then after sign-in the app opens Home, not `/calls` (no stash).
- **Test notes.**
  - Widget tests at 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0, for the drawer and the chip menu with entries.
  - A flag matrix `shells` × `ui_shell` × `kVisibleShells` (injected for the test).
  - Router redirect tests per path.
  - A `deepLinkTarget` table row asserting the four paths return null.
- **Observability.** None (client-only; no analytics).
- **Budget.** 0 RPCs; `shellEntriesFor` reads `enabled_features` already in memory.
- **Flag.** `shells` + `ui_shell` (entries), `shells` (routes).
- **Seam.** `shellEntries` and the four path constants are the only places a shell is named. A real feature swaps the entry's gate and the route's builder and changes no caller (section "How each shell is replaced").

### W8-3 — Shared grouped rows and status pill  [owner: frontend-developer] [size: S] [depends: —]  Status: Open
- **Description.** `reuse-first` step 3, generalise and move:
  - `SettingsGroup` and `SettingsRow` move from `features/settings/presentation/widgets/settings_group.dart` to `app/lib/shared/widgets/settings_group.dart`, names unchanged. The Settings screen's imports are updated, and the old file is deleted (no re-export shim).
  - Two backward-compatible extensions:
    - a static row (no `onTap`) may show an optional `value` widget at the end (a count or a pill); today `trailing` is ignored without `onTap`, and that stays so;
    - at text scale ≥ 1.3, or when the value does not fit, it moves under the subtitle instead of clipping.
  - A new `AppStatusPill` (`app/lib/shared/widgets/app_status_pill.dart`), because nothing in the catalog fits: X's "Ineligible" / "New" pill (`creator-studio.md` §3: full-round, about 22 dp tall, a tinted fill, a short label). Tokens only: a raised-surface fill with the muted label, or `accentText` for an "info" tone. It meets 4.5:1 in both themes, carries no semantics of its own, and the row's label includes its text.
  - Catalog: the `SettingsList` line points at the new location, plus new lines for `SettingsGroup` / `SettingsRow` (shared) and `AppStatusPill`.
- **Acceptance criteria.**
  - Given the Settings screen, then its existing widget tests pass unchanged (same rows, same semantics, same master-detail selection).
  - Given a static row with a `value`, then the row is one non-button semantics node reading "<title>, <value text>".
  - Given text scale 2.0 at 360 dp, then no overflow.
- **Test notes.** Existing Settings tests plus new tests for the static value row and the pill, light and dark, three widths, three text scales.
- **Observability.** —
- **Budget.** 0.
- **Flag.** None (shared widgets).
- **Seam.** One grouped-row implementation for Settings and every shell, with no feature-local copy.

### W8-4 — Creator tools screen  [owner: frontend-developer] [size: M] [depends: W8-2, W8-3]  Status: Open
- **Description.** `/creator-studio`, the grouped structure of inventory §11 in our own words:
  - `AppBackHeader` "Creator tools" (F3).
  - Intro line (muted): "A home for creator features. For now it shows your account at a glance."
  - **Group "Your account"** (`SettingsGroup`, static rows with `value`): Followers, Following and Posts, as counts formatted the way the profile header formats them, and Joined (month and year, from `created_at`; reuse W3's helper or add `formatJoinedMonth`, see Dependencies). All four come from `OnboardingBloc.state.profile`. With no profile loaded the group is omitted, never zeros.
  - **Group "Insights"** (`CreatorInsightsGroup`): Impressions, Engagements, Profile visits, Top posts. Each is a static row with the `AppStatusPill` "Not available yet". There is no number, not even 0 or "—".
  - **Group "Programs"** (`CreatorProgramsGroup`): "Earnings from posts" and "Creator subscriptions", each a static row with the pill "Not available" and the subtitle "Nothing to sign up for."
  - **Footnote (muted):** "Counts are as of your last refresh."
  - No pull to refresh, no button, no link out.
- **Capture.** Creator Studio is MEASURED on desktop dark only (`creator-studio.md`). The 57 dp row pitch, the 20 dp icon and the group titles follow it. Mobile and light are X-like defaults.
- **Acceptance criteria.**
  - Given a profile with 12 followers, 3 following, 40 posts, joined October 2026, then the four rows read those values.
  - Given no profile in `OnboardingBloc`, then the "Your account" group is absent and the page still renders.
  - Given any state, then no RPC is sent (W8-8 counts).
  - Given a screen reader, then "Impressions, not available yet" is read once and no row is announced as a button.
  - Given text scale 2.0 at 360 dp, then no overflow.
- **Test notes.** Widget tests at 360 / 600 / 1200, light and dark, 1.0 / 1.3 / 2.0, with a seeded `OnboardingBloc` (profile present and absent); semantics.
- **Observability.** —
- **Budget.** 0 RPCs, 0 reads (the profile is already in memory). Staleness as stated in Non-functional targets.
- **Flag.** `shells` (route); `shells` + `ui_shell` (entry).
- **Seam.** `CreatorInsightsGroup` and `CreatorProgramsGroup` are separate widgets, so insights v1 and monetisation each replace one group without touching the page.

### W8-5 — Premium screen  [owner: frontend-developer] [size: S] [depends: W8-2]  Status: Open
- **Description.** `/premium`, a normal page in the shell (F7), not a modal:
  - `AppBackHeader` "Premium" (F3).
  - Hero: `AppEmptyView`-style, with an icon disc (`workspace_premium_outlined`), the title "There's no paid plan" and the subtitle "We're considering an optional paid plan to help cover running costs. Nothing is for sale today and there's nothing to sign up for."
  - One `AppSurface` card titled "What this means for you", with three short lines: "Your account works the same." · "No payment details are asked for anywhere in the app." · "If a paid plan ever exists, it will be announced in the app first."
  - **Nothing else:**
    - no price or currency;
    - no plan names or feature checklist;
    - no Monthly/Annual toggle;
    - no button of any kind;
    - no link out.
  - The final strings are your call in this PR (F3). The lines above are defaults. The last one is a commitment, so drop it if you would rather not promise it.
- **What the page may and may not say until the Payments ADR is accepted** (recorded here for reviewers):
  - **May:** that no paid plan exists, that one is being considered, and why (running costs).
  - **May not:**
    - any price, currency, discount or "free trial";
    - any purchase or reservation affordance ("Subscribe", "Upgrade", "Get", "Join the waitlist", "Notify me", "Pre-order");
    - a link to any external payment page: store rules require store billing for digital goods inside the apps and restrict steering to outside payment;
    - any urgency or scarcity;
    - any feature list that reads as an offer;
    - X's plan names or brand marks.
- **Capture.** The Premium modal is MEASURED (desktop dark), but only its structure is relevant. **We deliberately do not copy it:** no modal, no plan cards, no billing toggle, no CTA hierarchy.
- **Acceptance criteria.**
  - Given the page, then no widget is a button except Back.
  - Given the page's text, then the copy guard (W8-8) finds no match for `subscribe|upgrade|trial|waitlist|notify me|pre-order|price|₹|\$|/month|/year`.
  - Given 360 / 600 / 1200 dp, light and dark, and 1.0 / 1.3 / 2.0, then no overflow.
- **Test notes.** Widget tests over the matrix, the copy guard and semantics: the title is a header, and the card lines are read in order.
- **Observability.** —
- **Budget.** 0.
- **Flag.** `shells` (route); `shells` + `ui_shell` (entry); F2: no prod.
- **Seam.** `AppRouter.premiumPath` and `ShellKind.premium`. The Payments ADR's screen replaces this page behind its own flag, and no billing package is added before that ADR.

### W8-6 — Advertise screen  [owner: frontend-developer] [size: S] [depends: W8-2; F4 for the button]  Status: Open
- **Description.** `/advertise` (not `/ads`: content blockers' URL lists commonly match `/ads` paths, and a hard reload of `/ads` on web could be blocked):
  - `AppBackHeader` "Advertise" (F3).
  - Hero: icon disc (`campaign_outlined`), the title "Advertising isn't available", and the subtitle "We don't sell ads or promoted posts today, and there are no ads in your timeline."
  - **Contact (F4), only if `kAdvertisingContactEmail` is non-null:**
    - a muted line, "Want to talk about advertising later?";
    - a 48 dp text button "Email us" that opens `mailto:<address>?subject=Advertising%20enquiry` via `url_launcher` (no body, no account data);
    - if `launchUrl` returns false: a snackbar "Couldn't open your email app" with the address shown as selectable text.
  - **Default (null): no contact affordance at all.**
  - No form, no account setup, no country or timezone fields (X's Ads Manager is a separate product, `ads-manager-setup.md`).
- **Acceptance criteria.**
  - Given `kAdvertisingContactEmail == null`, then the page has no button except Back.
  - Given an address, then one "Email us" button whose launched URI is exactly `mailto:<address>?subject=Advertising%20enquiry`, verified with a fake launcher.
  - Given a launcher that fails, then the snackbar shows and the address is selectable.
  - The copy guard passes.
- **Test notes.** Widget tests over the matrix; a fake `url_launcher` platform (the `url_launcher_platform_interface` dev dependency is already there) for both address states.
- **Observability.** None. A failed launch is a user-visible snackbar, not a Crashlytics event.
- **Budget.** 0.
- **Flag.** `shells` (route); `shells` + `ui_shell` (entry).
- **Seam.** `AppRouter.advertisePath` and `ShellKind.advertise`. The Ads ADR decides whether this becomes a link-out or a real page; feeds stay untouched until an ad slot goes behind the `timeline` interface.

### W8-7 — Calls screen  [owner: frontend-developer] [size: S] [depends: W8-2, W8-3]  Status: Open
- **Description.** `/calls`, a settings-style page:
  - `AppBackHeader` "Calls".
  - Hero (`AppEmptyView`, icon disc `call_outlined`): the title "Calls aren't available" and the subtitle "Voice and video calls need servers that run all the time, even when nobody is calling. We haven't built them because of what that would cost."
  - Group "Calls" (`SettingsGroup`, static rows): "Voice calls" and "Video calls", each with the pill "Not available".
  - **No mention of live audio or Spaces** (dropped, Q1), no action, no permission request, and no calling, WebRTC or permission package. `android/`, `ios/` and `web/` are not touched.
- **Capture.** The Calls empty state is MEASURED (desktop dark): an icon disc, a bold title and a muted subtitle in a rounded card. Our `AppEmptyView` covers it. X's calendar toolbar and "New Call" / "Schedule" buttons are deliberately absent.
- **Acceptance criteria.**
  - Given the page, then no button except Back and no call to any permission API (the W8-8 fake records none).
  - Given the PR diff, then `app/pubspec.yaml`, `android/`, `ios/` and `web/` are unchanged.
  - Given the matrix, then no overflow.
- **Test notes.** Widget tests over the matrix and semantics; the reviewer checks the diff paths.
- **Observability.** —
- **Budget.** 0.
- **Flag.** `shells` (route); `shells` + `ui_shell` (entry).
- **Seam.** `AppRouter.callsPath` and `ShellKind.calls`. After the Calls ADR, `/calls` becomes call history, and calls start from W7's conversation header; this page is deleted.

### W8-8 — Client tests  [owner: tester] [size: M] [depends: W8-4 to W8-7]  Status: Open
- **Description.** The cross-screen matrix:
  - **Responsive:** every shell page and every entry point at 360 / 600 / 1200, light and dark, 1.0 / 1.3 / 2.0, with no overflow (`expectNoOverflow`).
  - **Flag-off matrix:**
    - `shells` off → no drawer row (360) and no chip menu item (600, 1200), and each of the four paths redirects to `/home`;
    - `ui_shell` off → no entry at any width;
    - each single-kind `kVisibleShells` → exactly that entry and route.
  - **0 RPCs:** pump each page with a counting fake transport behind `ApiClient` (or with no repository providers at all; whichever the harness supports), open it, wait for settle, and assert 0 calls. A structural test asserts that no file under `app/lib/features/shells/` imports a `data/` repository or `ApiClient`.
  - **Copy guard:** a test that walks the text of the Premium and Advertise pages and fails on the forbidden words of W8-5. It runs on every future copy change.
  - **Semantics:** headers, static rows read once, only Back and the optional "Email us" are buttons.
  - **Bundle delta:** build web release before and after the wave with the `cost-model.md` §11 command, and record the gzip and brotli delta of `main.dart.js` in the PR (expected 15–30 KB gzip; flag it to the planner if it is above 60 KB).
- **Acceptance criteria.** Every acceptance criterion of W8-2 to W8-7 has a named test; `make ci` is green; the bundle delta is recorded.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `shells` × `ui_shell` × `kVisibleShells`.
- **Seam.** The structural no-repository test keeps the 0-cost claim true as the shells change.

### W8-9 — Privacy and claims check  [owner: security-auditor] [size: S] [depends: W8-4 to W8-7]  Status: Open
- **Description.** A short review, not a threat model (no new surface), covering:
  - no data collection (no field, form, consent, analytics event or Crashlytics key);
  - no RPC and no repository import;
  - no new package (`pubspec.yaml` diff empty) and no platform permission (`android/`, `ios/`, `web/` diff empty);
  - the shell routes are absent from `deepLinkTarget`;
  - the `mailto:` construction (fixed subject, no account data) if F4 names an address;
  - the Premium and Advertise copy against the "may not" list of W8-5 (urgency, price, purchase or reservation affordance, steering link);
  - a note for the founder on the store-policy check before any prod raise (Risks).
- **Acceptance criteria.** A short report in `docs/reviews/` (or a section of the wave's review record) with no open finding above Low, and an explicit line "W8 collects no personal data".
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Confirms `shells` has no prod ceiling (F2).
- **Seam.** Confirms the shells name their routes only through `shellEntries` and `AppRouter`.

### W8-10 — Stage-ladder rows  [owner: architect] [size: S] [depends: —]  Status: Open
- **Description.**
  - Answer A1–A3 in the PR description.
  - Add a heading "Locked features (shell only)" to `.claude/skills/stage-ladder/SKILL.md`, with the five rows of this plan's Scope table: paid tier, creator insights, creator monetisation, advertising, calls. Each row gets its Stage 0 shell, seam, Stage 2/3 target, the future ADR it needs (unnumbered) and its trigger.
  - Add one line to the skill's "How each agent uses this": "a locked feature moves only by its own accepted ADR; its shell is the placeholder".
  - No ADR file, unless A1 says one is needed.
- **Acceptance criteria.** Every row names a seam and a measured trigger or a recorded founder decision; Calls states that it depends on the Real-time row; no ADR number is reserved.
- **Test notes.** None (docs). `code-reviewer` checks the seam and trigger lines.
- **Observability.** —
- **Budget.** 0.
- **Flag.** —
- **Seam.** Defines the seams that W8-2 to W8-7 build.

### W8-11 — Dev rollout  [owner: production-deployer] [size: S] [depends: W8-1, W8-8, W8-9]  Status: Open
- **Description.**
  - Show the founder a **targeted** dev Terraform plan (`pending.md` 3.10: a full dev apply is unsafe; a targeted apply must also name `-target=module.budget.google_pubsub_topic.billing_alerts`) for `feature_shells*` only.
  - Apply on OK, with the allowlist set to the 3 test uids that already have `ui_shell`.
  - Smoke on dev web at 360, 600 and 1200 dp:
    - the four entries appear for an allowlisted uid and not for another account;
    - each page opens and Back returns;
    - `/premium` typed by a non-allowlisted account lands on Home;
    - the browser's network panel shows no API call while on a shell page.
  - Prod: no change (F2).
- **Acceptance criteria.** The dev smoke passes; `pending.md` 3.17 updated with the dev state.
- **Test notes.** —
- **Observability.** The startup `feature_flags` line of the new dev revision shows `shells` in allowlist mode.
- **Budget.** 0 reads (one `GetMe` per smoke session, already counted).
- **Flag.** Dev: `feature_shells` allowlist (3 uids); prod stays `off`.
- **Seam.** —

## Rollout plan
- **Dev:** allowlist (3 uids with `ui_shell`), after W8-9.
- **Prod:** none in this plan (F2). A later raise needs:
  - your decision recorded in `pending.md` 3.17;
  - the store-policy check (Risks);
  - your sign-off on the final copy;
  - a ceiling PR (gate file).

  Then allowlist, then `on`, each step a Terraform change plus a tagged revision (ADR-0019).
- **Rollback triggers:**
  - any user report or reviewer finding that a shell reads as an offer or a promise;
  - a store review rejection citing placeholder content;
  - a crash on a shell route (Crashlytics);
  - a shell visible to a non-allowlisted account.
- **Kill switch:** `FEATURE_SHELLS=off` and deploy. Entries disappear and routes redirect on the next `GetMe`, with no data to migrate. One shell: remove it from `kVisibleShells` by PR.

## Risks
| Risk | Mitigation |
|---|---|
| Store review rejects "coming later" screens. Apple's App Completeness guideline (2.1) asks that placeholder and temporary content be removed before submission; Google Play has a minimum-functionality policy | dev only by default (F2); before any prod raise, verify the current wording of both stores' guidelines and either keep `shells` off in prod or ship only shells that read as complete informational pages (F1) |
| A shell reads as an upsell or a pre-sale, against the roadmap rule "no Premium / ads upsell surfaces" and consumer-protection rules on dark patterns | no price, button, form, urgency or feature promise; the copy guard test; W8-9 review; your copy sign-off; legal advice with the Terms review (`pending.md` 3.9) |
| Someone adds a waitlist or "notify me" later, collecting personal data with no privacy basis | explicitly out of scope; the copy guard fails on "waitlist" and "notify me"; adding a field is a scope change for you |
| Users expect the feature soon because the entry exists | no dates and no "coming soon"; each page states what works today; F1 can hide any shell |
| Creator tools counts are mistaken for analytics or look stale | only four profile numbers, each labelled; the "As of your last refresh" footnote; insights rows say "Not available yet", never 0 |
| Copying X too closely (names, plan cards, modal, calendar toolbar) | our own names (F3), Material icons, no plan cards, no modal, no calendar; only structure follows X |
| Merge conflicts in shell navigation with W3, W4, W5 and W7 | the shared-file table; shell rows always last before Settings; one nav PR at a time |
| The account chip menu grows long as waves add items | 4 items under a divider; the rail "More" item (F5 alternative) is the later fix, best decided once with W5's rows |
| A real feature lands but a shell page lingers, or two routes exist for one feature | the seam rule: the real feature keeps the path and entry, swaps the builder, and deletes the shell in the same PR; `shells` is retired with `NewRetired` when the last shell goes |
| Web bundle grows for every visitor | measured in W8-8 (expected 15–30 KB gzip, about INR 2 a month at 3,000 DAU, 0 below about 2,731 DAU); deferred loading only if the delta exceeds 60 KB |
