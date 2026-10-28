# UI W8: Creator, Premium, Ads and Calls as read-only shells
Plan owner: planner · Date: 2026-10-27 · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **Client-only:** four informational screens, 0 RPCs, 0 Firestore reads, writes or deletes, no proto, no Firebase or index change, no new package, no new GCP service, no fixed cost · Flags: new `FEATURE_SHELLS` (wire name `shells`, client-only, registered on the server like `ui_shell` so `GetMe.enabled_features` reports it; dev ceiling allowlist 3; prod `on` accepted by the founder 2026-10-28, recorded in ADR-0026 because `flag-ceiling.json` has no prod block); existing `ui_shell` (navigation chrome) · Founder decisions F1–F8 recorded 2026-10-28 (section below); the Premium prices and pop-up are recorded in ADR-0026 (W8-10, Accepted 2026-10-28)

Source:
- `docs/plans/roadmap.md`: the W8 row ("Creator, Premium, Ads, Calls | none (shells) | payments, ads, video and live audio each need a future approved ADR"), founder decisions 2026-10-22 ("W8 = UI shells only, payments / ads / video each need a future approved ADR"), Q1 2026-10-23 (Spaces dropped: no shell, no research, no ticket), the risk row "only colours and structure follow X; own icons, copy, names; no Grok / Premium / ads upsell surfaces";
- `docs/x_research/01_screen_inventory.md` §10 (Premium sign-up modal) and §11 (Creator Studio), `screens/premium-modal.md`, `screens/creator-studio.md`, `screens/ads-manager-setup.md`, `screens/calls.md`, `05_component_library.md` row 18 (empty state with icon disc and CTA), `08_navigation_flows.md` (Calls, Premium, Creator Studio and Ads live in the phone's avatar drawer; Premium opens as a modal over Home; ads are on a separate origin), `07_functionality_inventory.md` (Calls, Premium / creator / ads: out of scope at Stage 0), `14_mvp_structured_plan.md` (W8 row: "UI shells without a paid backend (read-only, 'coming soon'/waitlist) until the founder approves an ADR (payments provider, video infra is fixed-cost: SFU/TURN)"). All local and git-ignored;
- `docs/plans/ui-w0-foundations.md` (D3, W0-10: how `ui_shell` was registered), `docs/runbooks/ui-shell.md`, `docs/plans/ui-w6-composer-extras.md` (`FEATURE_DRAFTS`, the second client-only flag), `docs/plans/ui-w5-lists-communities.md` and `docs/plans/ui-w7-messaging.md` (format, the nav decisions, shared files);
- `docs/ui-catalog.md` (`AppDrawer`, `AppAccountChip`, `MainShell`, `AppBackHeader`, `AppEmptyView`, `AppSurface`, `AppSectionHeader`, `SettingsList` / `SettingsRow`, `AppRouter`, `isFeatureEnabled`, the theme harness);
- skills `flag-rollout`, `reuse-first`, `flutter-feature`, `stage-ladder`, `free-tier-budget`.

Branches: `feat/ui-w8-N-<slug>` off `main` (not stacked); one ticket per PR; merge `origin/main` into the branch.

## Founder decisions (2026-10-28; these replace the proposed defaults of 2026-10-27)
The founder answered F1–F8 on 2026-10-28. Where an answer differs from the 2026-10-27 default, the ticket text below already follows the answer.

| # | Question | Decision 2026-10-28 | What it changes |
|---|---|---|---|
| F1 | Which shells exist | **All four** (Creator tools, Premium, Advertise, Calls), each with a "Coming soon" message | `kVisibleShells` = all four (unchanged) |
| F2 | Premium shown before payments exist; prod | **Prices are shown:** "Plus" **₹235/month** and "Premium" **₹850/month**, both **inclusive of GST**. **Prod is accepted** up to `on` (recorded in ADR-0026 and the runbook; `flag-ceiling.json` has no prod block for any flag). **All platforms** (web, Android, iOS): the store-review risk is accepted by the founder | W8-5 shows a price card with no buy button; W8-1 records the prod decision in the runbook; Rollout and Risks below |
| F3 | Tone | **"Coming soon" is shown** on every page. Still no date, no countdown and no urgency | every hero says "coming soon"; the status pills read "Coming soon"; the copy guard keeps forbidding dates and urgency |
| F4 | Advertise contact | **`comingsoon@dzeroth.com`**. The mailbox **does not exist yet** (2026-10-28), so `kAdvertisingContactEmail` stays `null` and no "Email us" button ships until the founder confirms the mailbox receives mail (`pending.md` 3.17). Turning it on is then a one-line PR | W8-6 builds and tests both states; ships with the address off |
| F5 | Wide-screen entry (600 dp and up) | **A "More" item in the side rail** (rail-only, like History). It opens a menu of the visible shells. The account chip menu stays Profile / Settings / Sign out | W8-2 adds the rail item and menu instead of chip menu items |
| F6 | Legacy chrome (`ui_shell` off) | **(a) New layout only.** No entry in the old layout. Because `ui_shell` has no prod ceiling today, the pages reach prod users only once `ui_shell` is also raised in prod (a separate decision) | entries need `shells` **and** `ui_shell` (unchanged); the prod raise of `shells` waits on `ui_shell` |
| F7 | Premium as page or pop-up | **A pop-up over the current page (usually the feed), opened only when the user taps Premium.** Never shown automatically (not on launch, resume, feed load, scroll or after any action) | W8-5 is a dialog route; W8-8 adds a structural test that only the entry taps open it |
| F8 | Creator tools numbers | **Yes:** followers, following, posts and join month from the profile already in memory | unchanged |

**What these decisions reverse, and the ADR that records it.** The roadmap's founder decisions of 2026-10-22 and its risk row say "own names" and "no Grok / Premium / ads upsell surfaces". F2 (shown prices, X's plan name "Premium") and F7 (a pop-up over the feed) reverse those rules for W8. That reversal is recorded in [ADR-0026](../adr/0026-w8-coming-soon-pages-premium-prices-and-pop-up.md) (W8-10, Proposed), which the founder accepts. W8-5 merges only after that ADR is Accepted.

## What exists already (verified on `main` 434099a; rechecked on `main` 29bd1fc, 2026-10-28)
| Piece | State | W8 delta |
|---|---|---|
| Shell navigation | `MainShell`: bar and rail Home, Notifications (flag), History (rail-only via `AppNavDestination.railOnly`, `bookmarks`), Profile; `AppDrawer` (phones) rows Profile / History / Settings / Sign out; `AppAccountChip` popup (600 dp and up) Profile / Settings / Sign out; `AppSideColumn` links (1200 dp and up) Settings / Privacy Policy. `_selectedTab` falls back to Home for any unknown location | shell rows in the drawer and a rail-only "More" item with a menu (F5), from one descriptor list; `_selectedTab` returns More on a shell route; the chip menu is unchanged |
| Routing | `AppRouter`: one `go_router`, ShellRoute children (e.g. `bookmarksPath`), per-flag redirects (`_bookmarksFlagRedirect` …), `deepLinkTarget` allowlist (`/post/…`, `/u/…`, `/profile/…`) | four ShellRoute children, `_shellsFlagRedirect`; **no** `deepLinkTarget` change |
| Client-only flags | `ui_shell` (`kFeatureUiShell`, `config.FeatureUIShell`, `flags.LoadSpec("UI_SHELL", "ui_shell", flags.Off)`, Terraform `feature_ui_shell*`, ceiling dev allowlist 3, runbook `ui-shell.md`); `drafts` planned the same way (W6) | `shells` registered the same way |
| Grouped rows | `SettingsGroup` / `SettingsRow` (`features/settings/presentation/widgets/settings_group.dart`): **feature-local** ("the Settings screen is the only place that groups rows this way"); a row with no `onTap` is static text with no chevron; `trailing` renders only with `onTap`; `selected` (master-detail highlight) and `showChevron` exist since the 1200 dp Settings layout and must survive the move | moved to `shared/widgets/`, plus a value or pill on static rows (W8-3) |
| Empty state | `AppEmptyView` (icon, title, optional subtitle, optional `action`) | reused for the hero of each page |
| Status pill | none (X's "Ineligible" / "New" pills, `creator-studio.md` §3) | a small `AppStatusPill` (W8-3) |
| Joined formatter | `formatJoinedMonth` and the "Joined …" helper in `app/lib/shared/format/joined_date.dart` (merged with W3) | W8-4 reuses it |
| Profile numbers | `OnboardingBloc.state.profile` (from `GetMe`): `followers_count`, `following_count`, `posts_count`, `created_at` (`identity.proto` `Profile` fields 9–12); the drawer already reads it with 0 RPCs | Creator tools reads the same object |
| Mail links | `url_launcher ^6.3.3` already in `app/pubspec.yaml` | `mailto:` only if F4 names an address; no new package |
| Captures | Creator Studio MEASURED (desktop, dark), Premium modal MEASURED (desktop, dark), Ads Manager setup MEASURED (separate origin), Calls empty state MEASURED (desktop, dark); none on mobile or in light theme | X-conformant structure with our own copy; mobile and light are X-like defaults |

## Goal & user value
People who open the drawer or the rail's "More" menu find the same destinations X users expect: creator tools, a paid tier, advertising and calls. Each one says plainly that it is coming soon and what works today. Premium also shows the planned prices (Plus ₹235/month, Premium ₹850/month, incl. GST), with nothing to buy yet. Creator tools also gives a small real value at no cost: your own follower, following and post counts in one place. For us the value is the seam. Each future feature has a fixed route and entry point to land in, and swapping the shell for the real feature changes no caller.

## Scope / Out of scope
**In scope (Stage 0 rung):**
- **Four client-only screens,** inside the shell, each reachable from one drawer row (under 600 dp) and one item of the rail's "More" menu (600 dp and up, F5):
  - **Creator tools** `/creator-studio`. A read-only overview with the grouped structure of inventory §11: your account at a glance, insights, programs. Numbers come only from the `GetMe` profile already in memory; everything else is a static row with a "Coming soon" pill. No monetisation control, no toggle, no link to earnings.
  - **Premium** `/premium`. A **pop-up over the current page**, opened only by tapping Premium (F7). It says Premium is coming soon and shows two plan cards: **Plus ₹235/month** and **Premium ₹850/month**, "incl. GST" (F2). No feature checklist, no billing toggle, no subscribe, upgrade, buy, trial, waitlist or "notify me" affordance, and no link to any external purchase page. Its only button is Close.
  - **Advertise** `/advertise`. Says advertising is coming soon. No ad manager, no form, no account setup. One "Email us" `mailto:comingsoon@dzeroth.com` text button, **off until the mailbox exists** (F4); until then no contact affordance.
  - **Calls** `/calls`. A settings-style page saying voice and video calls are coming soon. No permission prompt, no new platform permission (AndroidManifest, Info.plist, web), no WebRTC or calling package.
- **One client-only flag** `FEATURE_SHELLS` and its registration (server config, registry, ceiling, Terraform, runbook). One descriptor list, `shellEntries`, drives the drawer rows, the rail "More" menu and the route redirect. `kVisibleShells` chooses which shells exist (F1).
- **Accessibility, the responsive matrix, the flag-off matrix** and a "0 RPCs" test (W8-8).
- **The stage-ladder rows** for the four future features: Stage 0 = shell, the seam, the Stage 2/3 target with its ADR, and the trigger (table below; W8-10 adds them to the skill).

**Explicitly not built (any of these is a change of scope that needs you):** a waitlist or email capture (`14_mvp_structured_plan.md` mentions "waitlist"; it would collect personal data and imply a pre-sale), a feature checklist per plan, an annual price, a payment sheet, store billing or in-app-purchase packages, an ad slot or "Promoted" label in any feed, analytics events or screen-view tracking (the app has Crashlytics only, and W8 adds nothing to it), push notifications, a server RPC of any kind, anything about live audio or Spaces (dropped, Q1).

**Stage 0 choice, seam and Stage 2/3 target, per future feature** (proposed `stage-ladder` rows; W8-10 adds them under a "Locked features (shell only)" heading; each real feature needs a future ADR, **numbered when written**, the highest existing plus one: W3–W7 have already claimed 0024–0029 as planned numbers, and W5 and W6 both name 0028):

| Concern | Stage 0 (W8) | Seam to protect now | Stage 2/3 target (future ADR) | Trigger (measured, or a recorded founder decision) |
|---|---|---|---|---|
| Paid tier (Premium) | coming-soon pop-up with the two planned prices (F2), no purchase path | route `AppRouter.premiumPath`, the `ShellKind.premium` entry; no client code reads an "entitlement" | **Payments ADR:** store billing for digital goods in the apps (Google Play Billing; Apple In-App Purchase after the Apple launch), a web payment provider (not GCP, so a stack exception the ADR must justify), server-side receipt verification and store notifications through Pub/Sub, an entitlements doc owned by `identity`, GST and invoicing, refund and cancellation policy, consumer-protection disclosures, recurring-payment mandate rules for Indian cards, what may be paywalled (never safety or privacy features) | your decision to charge, **plus** a measured need: the Stage 0 bill (`cost-model.md` §5) above INR 3,000/month for 2 consecutive months (about 3,000 DAU), or no funding after the credit expires (`pending.md` 1.14) with more than 1,000 DAU |
| Creator insights (numbers beyond the profile counts) | four profile numbers from `GetMe` (0 reads) + static rows | `ShellKind.creatorStudio` route; the "Insights" group is one widget, so real rows replace placeholders without touching the page frame | **Insights plan (no ADR if no new collection):** an `InsightsService` summarising the counters already on your own recent posts (bounded reads, instance-cached). **Impressions** need a write per view, which is the `stage-ladder` Counters row (batched or sharded counters, its own ADR) | at least 50 accounts with more than 1,000 followers, or your request; impressions only when the Counters row's ADR exists |
| Creator monetisation (earnings, subscriptions to creators) | the "Programs" group reads "Coming soon" | same route; no control exists to remove | **Creator payouts ADR** (after Payments): revenue share, a payouts provider, KYC, tax withholding, eligibility rules, fraud and chargebacks | Payments live in prod **and** your decision |
| Advertising | coming-soon page, `mailto:` off until the mailbox exists (F4) | route `/advertise`; the `timeline` interface stays the only place a feed is merged (an ad slot later goes behind it, never in a handler or widget) | **Ads ADR:** direct-sold promoted posts vs an ad-network SDK, consent and privacy (India's DPDP Act, iOS App Tracking Transparency, Play Data safety), ad labelling, advertiser verification and ad review, payments (needs Payments), brand safety, the Privacy Policy change | sustained DAU above 20,000 for 30 days (the Stage 2 boundary; below it ad revenue does not cover ad review and legal cost), or a signed advertiser budget you want to accept |
| Calls (1:1 voice and video) | coming-soon page, no permission, no package | route `AppRouter.callsPath`; a later call action would go in W7's conversation header (calls start from a conversation, never from a new public surface); W8 changes nothing in W7 | **Calls ADR**, after the `stage-ladder` Real-time row has moved (calls need a signalling channel, which Stage 0 does not have): WebRTC on the clients, signalling, STUN, a TURN relay (relay egress is billed per GB; a TURN VM or SFU is a **fixed cost** and `CLAUDE.md` lists the matching services as not used), call push (Android high-priority FCM; iOS PushKit and CallKit after the Apple launch), block and spam rules, call metadata in export and erasure, an emergency-calls disclaimer | W7 messaging live with messaging DAU above 30 % of DAU for 30 days, **and** the Real-time row's trigger met, **and** your decision to accept the fixed or per-GB relay cost |

**Out of scope (this wave):** everything in the "Stage 2/3 target" column above; other waves' rows in the "More" menu (W5 and later decide their own); X's Premium modal styling, brand strip, plan feature lists and Monthly/Annual toggle; X's split-panel Ads Manager layout (`ads-manager-setup.md` §5: a separate product); X's calendar-style Calls toolbar; Business (X's drawer has it; not in the roadmap); Grok (never).

## Non-functional targets (Stage 0, 0–300 DAU; credit mode to ~3k DAU changes nothing here)
- **Latency:** no network wait. Each page renders from memory in its first frame after navigation: no skeleton, no spinner, no RPC. The navigation targets of the app (p95 timeline read < 400 ms) are unaffected.
- **DAU:** independent of DAU. Dev allowlist (3 uids) first; prod up to `on` is accepted (F2), but reaches only users who also have `ui_shell` (F6).
- **Staleness bounds (every cached read):**
  | Read | Bound |
  |---|---|
  | Creator tools: followers, following, posts, joined month | **as of the last `GetMe` the app made** (app start, resume, the flag gates' refresh: about 4 per DAU per day per the W7 model). The page never calls `GetMe` or `GetProfile`, has no pull to refresh, and says so in a footnote ("As of your last refresh"). A follow made on another device can be missing for that long |
  | Flag `shells` | as of the last `GetMe`; a server change reaches a running client on its next `GetMe` (the `ui_shell` runbook rule) |
- **Accessibility (every screen):**
  - one header node per page title and per group title;
  - static rows read once as "<title>, <value or 'coming soon'>". No row is a button unless it opens something; the only tappable elements on the pages are Back, the Premium pop-up's Close, and the `mailto:` button once enabled;
  - nothing conveyed by colour alone: the status pill has text, and its tint and label meet 4.5:1 in both themes (the Q4 caveat: `#1d9bf0` text on white is about 3:1, so the pill uses `accentText` or the muted tone on the raised surface);
  - 48 dp targets;
  - no overflow at text scale 2.0: the row's pill moves under the title instead of clipping;
  - the drawer rows and "More" menu items announce their label once (the `_DrawerRow` pattern); the More rail item announces "More, menu";
  - the Premium pop-up is a modal dialog: focus moves into it, its title is the first header, Escape / system Back / barrier tap close it, and focus returns to the entry that opened it.
- **Responsive matrix (each screen):** 360 dp (bottom bar + drawer, page edge to edge, entry in the drawer), 600 dp (icon rail, page in the 600 dp column between hairlines, entry in the rail's More menu), 1200 dp (extended rail, side column, entry in the rail's More menu); the Premium pop-up is full-screen below 600 dp and a centred card at most 600 dp wide from 600 dp up; light and dark; text scale 1.0 / 1.3 / 2.0. `theme_harness.dart` covers 1.0 and 1.3 today, so the tickets pass 2.0 explicitly, as W7 does.

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
| Web bundle (Firebase Hosting transfer) | estimated +15–30 KB gzip on `main.dart.js` for four static screens, the More menu and their strings. Every web visitor downloads it whatever the flag (dart2js has one bundle), but only once per web release (`cost-model.md` §11: a returning visitor re-downloads `main.dart.js` only after a release) | priced at the margin (§1 web share 30 %, §5 note: about 4.3 prod web releases a month, §7 Hosting $0.15/GB past 360 MB/day, which §4 puts at about 2,731 DAU): 300 and 1,000 DAU are inside the free transfer, so **INR 0**; at 3,000 DAU, 900 web DAU × 30 KB × 4.3 releases ≈ 0.11 GB a month ≈ $0.017 ≈ **INR 1.6 a month** (upper estimate). W8-8 measures the real delta with the §11 build method and records it in its PR |

**W8 total: about INR 0 / 0 / 2 a month at 300 / 1,000 / 3,000 DAU** (all of it the web bundle line). No quota crossover moves. The Stage 0 bill stays as `cost-model.md` §5 states it (about INR 441 at 300 DAU with W2). **No `sre-performance` ticket:** there is no new RPC and no hot read path. `code-reviewer` checks the cost line in W8-1 and W8-2: no repository import in `features/shells/`, no `GetMe` call added.

**Bundle delta (W8-8).** Measured 2026-10-28 with the `cost-model.md` §11 build (`flutter build web --release --dart-define=USE_EMULATORS=false --dart-define=FIREBASE_ENV=dev --dart-define=API_BASE_URL=/api`, Flutter 3.47.5), once at the merge base with `origin/main` (`main` 8c43279, before W8, in a temporary worktree) and once at the W8 tip (W8-1 to W8-7; `pubspec.yaml` and `pubspec.lock` unchanged). Sizes by Node `zlib` (gzip level 6, brotli quality 11), `main.dart.js` only:

| `main.dart.js` | raw | gzip | brotli |
|---|---|---|---|
| before W8 (8c43279) | 4,926,092 | 1,398,507 | 1,059,585 |
| with W8 | 4,943,761 | 1,404,053 | 1,063,554 |
| **delta** | **+17,669** | **+5,546 (5.4 KB)** | **+3,969 (3.9 KB)** |

The delta is **below** the 15–30 KB gzip estimate above and far under the 60 KB flag line, so the estimate was conservative. At 3,000 DAU the web-bundle line scales to about 900 web DAU × 5.5 KB × 4.3 releases ≈ 0.02 GB a month, under INR 0.5; the INR 1.6 figure stands as an upper bound. Other build files (fonts, wasm, `canvaskit/`) were not compared.

## Flags
- **`FEATURE_SHELLS`** (wire name `shells`, Go `config.FeatureShells`, Dart `kFeatureShells` in `app/lib/features/shells/domain/shells_feature_flag.dart`).
  - **Client-only:** no RPC is gated by it, because there is none. Registered with `flags.LoadSpec("SHELLS", "shells", flags.Off)` in `config.go` and in `flags.NewRegistry` in `apiserver.go`, so `GetMe.enabled_features` reports it (exactly like `ui_shell` and the planned `drafts`).
  - **Gates:** every shell entry point (drawer rows, the rail "More" item and its menu) needs `shells` **and** `ui_shell` (F6); every shell route needs `shells` (a typed URL with the flag off redirects Home); `kVisibleShells` (F1) removes a shell's entry and route entirely.
- **Ceiling** (`scripts/promotion/flag-ceiling.json`, **founder-gated file, CODEOWNERS**): add `"SHELLS"` to `flags`. Add the dev entry `"SHELLS": {"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}`. The file has no prod block for any flag, so the founder's prod `on` (F2) lives in ADR-0026 and `docs/runbooks/shells.md`; the raise itself is a Terraform change plus a `v*` tag, a production-reviewer GO and `promote-prod` (ADR-0019). `check-flag-registry.sh` fails unless the `LoadSpec` names and the ceiling list match exactly, so both go in the same PR (W8-1).
- **Terraform:** `feature_shells`, `feature_shells_allowlist` and `feature_shells_percent` in `infra/terraform/envs/{dev,prod}/variables.tf`, and the three env entries in `envs/{dev,prod}/main.tf`. Copy `feature_ui_shell*`. Default `off`. Nothing is applied in this plan.
- **Ramp:** dev allowlist (3 uids, who must also have `ui_shell` on). Prod (F2): allowlist, then straight to `on` (a percent ramp of informational pages buys nothing). The prod `on` step reaches anyone only once `ui_shell` is on in prod (F6); until then it can sit at `on` harmlessly or wait. Each step is a Terraform change plus a tagged revision (ADR-0019).
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
  - The `mailto:` (F4, off until the mailbox exists) carries a fixed subject and an empty body, with no uid, handle or device data. The user's own mail app sends it, so we receive only what they choose to write.
- **Permissions:** none added. The Calls page never calls a permission API, and the platform manifests are unchanged (W8-9 checks the diff of `android/`, `ios/` and `web/`).
- **Links:**
  - the shell routes are **not** added to `AppRouter.deepLinkTarget` (a cold-opened `/premium` lands on Home after sign-in, by design);
  - no external `https` link, so no off-store purchase link and no anti-steering problem;
  - `mailto:` goes through `url_launcher` only when `kAdvertisingContactEmail` is set.
- **Misleading-claims surface (the real risk of W8):**
  - the Premium pop-up shows prices (F2), so it must not read as something you can buy today: every plan card says "Coming soon", there is no purchase, reservation or waitlist affordance, and the only button is Close;
  - the prices are shown inclusive of GST ("₹235/month, incl. GST"), as Indian consumer rules expect of a displayed price; the two prices live in one constant (`kPremiumPlans`) so a change is one line and reviewed;
  - no "free trial", no urgency (no countdown, no "limited", no "early bird"), no testimonial, no feature promise, no date, anywhere;
  - the pop-up opens only on tap (F7): a pop-up shown by itself over the feed is the dark-pattern risk, and W8-8 fails if any code path other than the entry taps opens it;
  - the copy is reviewed by `security-auditor` (W8-9, privacy and claims) and approved by you in the screen PRs (F3).
  - India's consumer-protection rules on dark patterns (false urgency, subscription traps) are the reason for these rules; legal advice on the final copy rides with the Terms of Service review (`pending.md` 3.9).
- **Degraded mode, service pause:** unaffected (no RPC). The pages stay reachable in `DEGRADED_MODE=readonly`. Under the ADR-0022 pause the whole app shows `ServicePausedView`, as today.

## How each shell is replaced when its real feature ships (the seam)
- **One descriptor, one route, one entry per shell.**
  - `shellEntries` (`app/lib/features/shells/domain/shell_entries.dart`) is a list of `ShellEntry {kind, icon, label, path, isVisible(context)}`. `AppDrawer` and the rail's "More" menu (`AppMoreMenu`) render it, and `AppRouter` uses the same `kind → path` mapping for its redirect.
  - `AppRouter.creatorStudioPath`, `premiumPath`, `advertisePath` and `callsPath` are the only route constants.
  - No other file names a shell route or label. Code review checks this (`grep` for the paths outside the router and the descriptor).
- **Replacing a shell changes neither caller.** The real feature keeps the path and the entry, and changes only two things:
  1. The entry's `isVisible` moves from `shells` to the real flag, for example `premium` or `calls`.
  2. The route's page builder renders the real screen when the real flag is on, and the shell otherwise. A user outside the real feature's ramp still sees the honest shell, not a dead link.

  When the real flag reaches `on`, the shell page and its `ShellKind` are deleted in the real feature's PR. The drawer and the More menu do not change.
- **Per shell:**
  - **Creator tools.** The "Insights" and "Programs" groups are separate widgets (`CreatorInsightsGroup`, `CreatorProgramsGroup`). Insights v1 replaces only the first one, and the page frame and "Your account" group stay. Monetisation replaces the second after the Payments and Creator payouts ADRs.
  - **Premium.** After the Payments ADR, `/premium` becomes the purchase or manage-subscription flow behind its own flag; `kPremiumPlans` becomes server-provided plan data. Any store-billing package arrives with that ADR, never earlier.
  - **Advertise.** After the Ads ADR, `/advertise` becomes either the advertiser entry page or a link-out to a separate advertiser origin (X runs its ad tools on a separate origin). Feeds get an ad slot only through the `timeline` interface.
  - **Calls.** After the Calls ADR, `/calls` becomes call history, and the call action appears in W7's conversation header. The coming-soon page goes away.

## Dependencies & open questions
**Dependencies:**
- F1–F8 are decided (2026-10-28). Open: the `comingsoon@dzeroth.com` mailbox (founder; only the W8-6 button waits on it), and the ADR acceptance before W8-5 merges.
- **Nav-file merge order.** W8-2 edits `app_drawer.dart`, `main_shell.dart`, `responsive_scaffold.dart` (if the More item needs an anchor) and `app_router.dart`, the same files as W4-17 (Explore), W5-11 and W5-31 (Lists and Communities), W7-19 (Messages) and W3-18. Merge one at a time; whichever lands second merges `origin/main`. The shell rows go **after** all feature rows and before Settings in the drawer, so they never reorder another wave's rows.
- **W3 "Joined" formatter.** Merged: W8-4 reuses `formatJoinedMonth` from `app/lib/shared/format/joined_date.dart` (`reuse-first`).
- **The "More" item is shared with later waves.** It is created by W8-2 with the shells as its only rows. W5 (Lists and Communities) and later waves that want a wide-screen overflow entry add their rows to the same menu **above** the shell rows; that is their tickets' call, not W8's.
- **No dependency on W7.** The Calls page does not link to Messages. A "Send a message instead" action can be added when `messaging` exists; it is a one-line follow-up and not part of W8.

**Questions for @architect (W8-10):**
- **A1. Does W8 need an ADR?** **Yes, since 2026-10-28.** No contract, data, service or cost changes, but F2 and F7 reverse recorded founder rules (roadmap 2026-10-22: "own names", "no Premium / ads upsell surfaces") and add a prod ceiling for a page that shows prices before payments exist. W8-10 writes it (Proposed); the founder accepts it. Answered: ADR-0026 (A1–A3 under its Decision).
- **A2. The stage-ladder rows** (table in Scope): confirm the wording, the triggers and the heading "Locked features (shell only)" in `.claude/skills/stage-ladder/SKILL.md`, and that Calls sits behind the Real-time row.
- **A3. Future ADR numbering:** none is reserved by W8. The W5 and W6 plans both name 0028 as a planned number; whichever ADR PR opens second takes the next free number (their plans already say "or the next free number").

## Milestones
1. **M8.1 Wiring:** W8-1 (server flag registration) ‖ W8-2 (client flag, descriptor, drawer rows, rail "More" menu, routes, stub pages) ‖ W8-3 (shared grouped rows and status pill) ‖ W8-10 (ADR and stage-ladder rows).
2. **M8.2 Screens:** W8-4 ‖ W8-5 ‖ W8-6 ‖ W8-7.
3. **M8.3 Verify and roll:** W8-8 (tests), W8-9 (privacy and claims check), W8-11 (dev rollout, then the prod raise through the release flow once `ui_shell` is in prod).

| ID | Ticket | Owner | Size | Depends | Parallel with W3–W7? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| W8-1 | `FEATURE_SHELLS` registration: `config.go` `LoadSpec` + test, `NewRegistry`, `flag-ceiling.json` (gate; dev allowlist 3; prod `on` recorded in ADR-0026, not the file), Terraform vars, runbook | backend-developer | S | — | **yes, start now**; shared files serialise with W3-4, W3-25, W4-3, W5-3, W5-22, W6-4, W7-4 | Done (#392) |
| W8-2 | Client flag, `shellEntries` + `kVisibleShells`, drawer rows, rail-only "More" item + `AppMoreMenu`, `_selectedTab` More, three page routes + the Premium dialog route + `_shellsFlagRedirect`, stub pages | frontend-developer | M | — (client tests inject `enabled_features`) | **yes, start now**; nav files serialise with W3-18, W4-17, W5-11, W5-31, W7-19 | Done (#392) |
| W8-3 | Move `SettingsGroup` / `SettingsRow` to `shared/widgets/`, value and pill on static rows, new `AppStatusPill`, catalog lines | frontend-developer | S | — | **yes, start now**; `settings_screen.dart` serialises with any wave adding a Settings row | Done (#392) |
| W8-4 | Creator tools screen | frontend-developer | M | W8-2, W8-3 | yes (own files) | Done (#392) |
| W8-5 | Premium pop-up with the two plan prices | frontend-developer | S | W8-2; merges after ADR-0026 is Accepted | yes (own files) | Done (#392) |
| W8-6 | Advertise screen (+ `mailto:comingsoon@dzeroth.com`, off until the mailbox exists) | frontend-developer | S | W8-2 (the button's switch-on waits on the mailbox) | yes (own files) | Done (#392) |
| W8-7 | Calls screen | frontend-developer | S | W8-2, W8-3 | yes (own files) | Done (#392) |
| W8-8 | Client tests: matrix, flag-off and visibility matrix, 0-RPC test, copy guard, tap-only pop-up test, bundle delta | tester | M | W8-4 to W8-7 | yes | Done (#392) |
| W8-9 | Privacy and claims check (no data collection, no permission, no dependency, copy) | security-auditor | S | W8-4 to W8-7 | yes | Done |
| W8-10 | ADR (Proposed) for the F2/F7 reversal; stage-ladder rows "Locked features (shell only)"; A1–A3 answered | architect | S | — | **yes, start now** (ADR and skill file only) | Done (ADR-0026 Accepted 2026-10-28) |
| W8-11 | Dev rollout (targeted Terraform plan, allowlist, smoke at 3 widths); prod raise prepared for the release flow | production-deployer | S | W8-1, W8-8, W8-9; prod also W8-10 Accepted and `ui_shell` in prod | serialise dev applies with W3–W7 rollouts | Prepared |

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
| `app/lib/core/widgets/app_drawer.dart`, `app/lib/core/router/main_shell.dart`, `app/lib/core/widgets/responsive_scaffold.dart` (shell navigation, the More item) | W8-2 | W3-18, W4-17, W5-11, W5-31, W7-19 |
| `app/lib/core/router/app_router.dart` (routes, redirects) | W8-2 | W3-18, W4-15, W4-17, W5-11, W7-14, W7-15, W7-17, W7-19 |
| `app/lib/features/settings/presentation/settings_screen.dart`, `widgets/settings_group.dart` (moved) | W8-3 | any wave adding a Settings row (W3, W6, W7 settings entries) |
| `docs/ui-catalog.md` | W8-2, W8-3, W8-4 | every UI ticket (append-only lines; resolve by keeping both) |

**Definition of done per ticket:**
- Client: widget tests at 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0, via `test/support/theme_harness.dart`, for every new screen and widget. Pixel goldens stay deferred (B-01).
- Backend (W8-1): the config test and `check-flag-registry.sh`; `make ci` green.
- `docs/ui-catalog.md` updated for shared items.
- This table's Status and `docs/pending.md` row 3.17 updated in the PR.

## Tickets

### W8-1 — `FEATURE_SHELLS` registration  [owner: backend-developer] [size: S] [depends: —]  Status: Done (merged in #392, 2026-10-28)
- **Description.** Follow `FEATURE_UI_SHELL` line for line (W0-10):
  - `config.go`: a `FeatureShells flags.Spec` field with a doc comment ("client-only UI flag … no RPC is gated by it"), and `flags.LoadSpec("SHELLS", "shells", flags.Off)` on **one line**, because `check-flag-registry.sh` parses it.
  - `shells_test.go`, a copy of `ui_shell_test.go`: off by default, `on` overrides, `bogus` fails startup. Add the env names to the test env list.
  - `apiserver.go`: add `cfg.FeatureShells` to `flags.NewRegistry`.
  - `scripts/promotion/flag-ceiling.json`: `"SHELLS"` in `flags` and the dev entry allowlist 3, percent 0. **Dev only:** the file has no `envs.prod` block for any flag, no prod workflow reads it, and `check-flag-registry.sh` requires every env block to cover every flag, so a SHELLS-only prod entry is impossible. The founder's prod `on` (F2) is recorded in ADR-0026 and `docs/runbooks/shells.md`; prod stays gated by ADR-0019 (tag, required reviewer, go/no-go). If any fixture in `scripts/promotion/test/` enumerates the flag list, update it in the same PR.
  - Terraform: `feature_shells*` variables (with validations) and env entries in `envs/dev` and `envs/prod`, default `off`. Not applied.
  - `docs/runbooks/shells.md`, modelled on `ui-shell.md`: the gates, cost 0, ramp (dev allowlist, prod allowlist then `on`, after `ui_shell`), rollback, and the failure modes "a shell visible to a user outside the allowlist" and "a store rejects a build over the shells" (flag off, or drop the kind from `kVisibleShells` for the next store build).
- **Acceptance criteria.**
  - Given `FEATURE_SHELLS` unset, when the API starts, then the startup `feature_flags` line lists `shells` as off and `GetMe.enabled_features` never contains `shells`.
  - Given `FEATURE_SHELLS=allowlist` with one uid, then `GetMe.enabled_features` contains `shells` for that uid only.
  - Given an invalid value, then startup fails.
  - Given `scripts/promotion` checks, then `check-flag-registry.sh` passes against `config.go`, the ceiling and both `main.tf` files.
- **Test notes.** Flag modes off / allowlist / percent / on through the existing registry tests (no new RPC to test); `terraform fmt -check` and `validate`.
- **Observability.** The startup `feature_flags` line; nothing else.
- **Budget.** 0 reads, 0 writes (flags are env vars; ADR-0008 D6).
- **Flag.** Adds `FEATURE_SHELLS` (default `off`; dev ceiling allowlist 3; prod `on` accepted by the founder, recorded in ADR-0026 and the runbook, not in the ceiling file).
- **Seam.** The flag is only a client gate; when a real feature ships, it gets its own flag. `shells` is retired with `NewRetired` and never reused.

### W8-2 — Client flag, entry points and routes  [owner: frontend-developer] [size: M] [depends: —]  Status: Done (merged in #392, 2026-10-28)
- **Description.**
  - `kFeatureShells = 'shells'` in `app/lib/features/shells/domain/shells_feature_flag.dart` (doc comment as `kFeatureUiShell`'s; never hardcode the string elsewhere).
  - `app/lib/features/shells/domain/shell_entries.dart`:
    - `enum ShellKind {creatorStudio, premium, advertise, calls}`;
    - `kVisibleShells` (F1, default all four);
    - `ShellEntry {kind, icon, label, path}`;
    - `shellEntriesFor(BuildContext)`, which returns the visible entries only when `shells` **and** `ui_shell` are on (F6).
    - `ShellEntry.opensAsDialog` is true for Premium only: its entries `push` the dialog route over the current page; the others `go`.
    - Icons are Material outline glyphs, not X's: `Icons.insights_outlined`, `Icons.workspace_premium_outlined`, `Icons.campaign_outlined`, `Icons.call_outlined`. Labels: "Creator tools", "Premium", "Advertise", "Calls".
  - **Drawer:** one `_DrawerRow` per entry, after every feature row and before Settings, preceded by a 1 dp divider. Tap closes the drawer, then `go(path)`.
  - **Rail "More" item (F5):** a new `_Tab.more` destination with `railOnly: true` (the History precedent: the phone bar leaves it out), icon `Icons.more_horiz` / label "More", last in the rail. It exists only when `shellEntriesFor` returns at least one entry. Selecting it does **not** navigate: it opens `AppMoreMenu` (`app/lib/core/widgets/app_more_menu.dart`), a `MenuAnchor`-style menu at the item listing the entries as `AppMenuItemRow`s (icon + label, icon excluded from semantics). If `ResponsiveScaffold` cannot anchor to a destination today, add an optional per-destination `onSelectedOverride` (or a key) there, backward-compatible. The account chip menu is **unchanged** (Profile / Settings / Sign out).
  - **`MainShell._selectedTab`:** returns `_Tab.more` on `/creator-studio`, `/advertise` and `/calls` (the rail shows More as selected), instead of falling back to Home. The Premium dialog leaves the page under it selected.
  - **`AppRouter`:**
    - `creatorStudioPath = '/creator-studio'`, `advertisePath = '/advertise'`, `callsPath = '/calls'`, as ShellRoute children (like `bookmarksPath`), each built only when its kind is in `kVisibleShells`;
    - `premiumPath = '/premium'`, a route on the **root** navigator whose `pageBuilder` returns a dialog page (barrier, modal), so a `push` from an entry draws it over the current page (F7). It is reachable only by `push`: when `/premium` is the first location (typed URL, reload, cold start) the redirect sends it to `/home` and does **not** open the pop-up;
    - `_shellsFlagRedirect`: any of the four paths redirects to `/home` unless `shells` is on for the caller;
    - **no** `deepLinkTarget` change.
  - **Stub pages.** `app/lib/features/shells/presentation/{creator_studio,advertise,calls}_screen.dart`, each an `AppMainColumn` with an `AppBackHeader` (title = label; Back pops, else `go('/home')`) over an `AppEmptyView` "Coming soon", and `premium_dialog.dart`, a dialog with a Close button and the same "Coming soon" body. W8-4 to W8-7 replace the body, so those tickets edit only their own file.
  - Catalog lines: `ShellEntry` / `shellEntriesFor` / `kVisibleShells` / `kFeatureShells`, `AppMoreMenu`, and the `AppDrawer` / `ResponsiveScaffold` lines extended.
- **Acceptance criteria.**
  - Given `shells` and `ui_shell` on at 360 dp, when the drawer opens, then four rows appear after the feature rows and before Settings, in the order Creator tools, Premium, Advertise, Calls, each opening its page.
  - Given the same at 600 and 1200 dp, then the rail's last item is "More"; when it is selected, a menu opens with the same four items in the same order, and the route does not change until an item is chosen.
  - Given the same at 360 dp, then the bottom bar has no More item.
  - Given the account chip menu at 600 / 1200 dp, then it is still Profile / Settings / Sign out.
  - Given Premium tapped from the drawer or the More menu while on Home, then a modal pop-up opens over the feed, and Close (or Escape, system Back, barrier tap) returns to the feed at the same scroll position.
  - Given `/premium` typed or reloaded on web, then the app lands on `/home` and no pop-up opens.
  - Given `shells` off, or `ui_shell` off, then no shell row, no More item and no menu item at any width.
  - Given `shells` off, when `/premium` (or any shell path) is opened by URL, then the app lands on `/home`.
  - Given `kVisibleShells = {calls}`, then only Calls has an entry and a route; `/premium` is an unknown route (the router's existing not-found handling).
  - Given a shell page (not Premium) at 600 / 1200 dp, then More is the selected rail destination.
  - Given a cold start on `/calls` while signed out, then after sign-in the app opens Home, not `/calls` (no stash).
- **Test notes.**
  - Widget tests at 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0, for the drawer rows, the More item and its menu, and the Premium dialog route.
  - A flag matrix `shells` × `ui_shell` × `kVisibleShells` (injected for the test).
  - Router redirect tests per path, including `/premium` as a first location.
  - A `deepLinkTarget` table row asserting the four paths return null.
- **Observability.** None (client-only; no analytics).
- **Budget.** 0 RPCs; `shellEntriesFor` reads `enabled_features` already in memory.
- **Flag.** `shells` + `ui_shell` (entries), `shells` (routes).
- **Seam.** `shellEntries` and the four path constants are the only places a shell is named; `AppMoreMenu` takes a list of entries, so later waves add rows without editing it. A real feature swaps the entry's gate and the route's builder and changes no caller (section "How each shell is replaced").

### W8-3 — Shared grouped rows and status pill  [owner: frontend-developer] [size: S] [depends: —]  Status: Done (merged in #392, 2026-10-28)
- **Description.** `reuse-first` step 3, generalise and move:
  - `SettingsGroup` and `SettingsRow` move from `features/settings/presentation/widgets/settings_group.dart` to `app/lib/shared/widgets/settings_group.dart`, names unchanged. The Settings screen's imports are updated, and the old file is deleted (no re-export shim).
  - Two backward-compatible extensions:
    - a static row (no `onTap`) may show an optional `value` widget at the end (a count or a pill); today `trailing` is ignored without `onTap`, and that stays so;
    - at text scale ≥ 1.3, or when the value does not fit, it moves under the subtitle instead of clipping.
  - A new `AppStatusPill` (`app/lib/shared/widgets/app_status_pill.dart`), because nothing in the catalog fits: X's "Ineligible" / "New" pill (`creator-studio.md` §3: full-round, about 22 dp tall, a tinted fill, a short label). Tokens only: a raised-surface fill with the muted label, or `accentText` for an "info" tone. It meets 4.5:1 in both themes, carries no semantics of its own, and the row's label includes its text. W8 uses it with the label "Coming soon" (F3).
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

### W8-4 — Creator tools screen  [owner: frontend-developer] [size: M] [depends: W8-2, W8-3]  Status: Done (merged in #392, 2026-10-28)
- **Description.** `/creator-studio`, the grouped structure of inventory §11 in our own words:
  - `AppBackHeader` "Creator tools" (F3).
  - Intro line (muted): "Creator tools are coming soon. For now this shows your account at a glance."
  - **Group "Your account"** (`SettingsGroup`, static rows with `value`): Followers, Following and Posts, as counts formatted the way the profile header formats them, and Joined (month and year, from `created_at`, via the existing `formatJoinedMonth`). All four come from `OnboardingBloc.state.profile`. With no profile loaded the group is omitted, never zeros.
  - **Group "Insights"** (`CreatorInsightsGroup`): Impressions, Engagements, Profile visits, Top posts. Each is a static row with the `AppStatusPill` "Coming soon". There is no number, not even 0 or "—".
  - **Group "Programs"** (`CreatorProgramsGroup`): "Earnings from posts" and "Creator subscriptions", each a static row with the pill "Coming soon" and the subtitle "Nothing to sign up for yet."
  - **Footnote (muted):** "Counts are as of your last refresh."
  - No pull to refresh, no button, no link out.
- **Capture.** Creator Studio is MEASURED on desktop dark only (`creator-studio.md`). The 57 dp row pitch, the 20 dp icon and the group titles follow it. Mobile and light are X-like defaults.
- **Acceptance criteria.**
  - Given a profile with 12 followers, 3 following, 40 posts, joined October 2026, then the four rows read those values.
  - Given no profile in `OnboardingBloc`, then the "Your account" group is absent and the page still renders.
  - Given any state, then no RPC is sent (W8-8 counts).
  - Given a screen reader, then "Impressions, coming soon" is read once and no row is announced as a button.
  - Given text scale 2.0 at 360 dp, then no overflow.
- **Test notes.** Widget tests at 360 / 600 / 1200, light and dark, 1.0 / 1.3 / 2.0, with a seeded `OnboardingBloc` (profile present and absent); semantics.
- **Observability.** —
- **Budget.** 0 RPCs, 0 reads (the profile is already in memory). Staleness as stated in Non-functional targets.
- **Flag.** `shells` (route); `shells` + `ui_shell` (entry).
- **Seam.** `CreatorInsightsGroup` and `CreatorProgramsGroup` are separate widgets, so insights v1 and monetisation each replace one group without touching the page.

### W8-5 — Premium pop-up  [owner: frontend-developer] [size: S] [depends: W8-2; merges after ADR-0026 is Accepted]  Status: Done (merged in #392, 2026-10-28)
- **Description.** `/premium`, a **modal pop-up over the current page** (F7), opened only from the Premium entry (drawer row or More menu item):
  - Below 600 dp a full-screen dialog; from 600 dp a centred `AppSurface` card at most 600 dp wide over a scrim. Header: title "Premium" and a Close (×) button, the only button.
  - Hero: icon disc (`workspace_premium_outlined`), title "Premium is coming soon", subtitle "Optional paid plans to help cover running costs. Nothing is for sale yet." (founder 2026-10-28, review L-1)
  - **Two plan cards** from one constant, `kPremiumPlans` in `app/lib/features/shells/domain/premium_plans.dart` (name, price in paise, period), rendered side by side from 600 dp and stacked below:
    - **Plus**: "₹235/month", "incl. GST", pill "Coming soon";
    - **Premium**: "₹850/month", "incl. GST", pill "Coming soon".
    The amounts are formatted from paise with the `en_IN` rupee format (no decimals for whole rupees). A card is static text, not a button, and has no feature list (none was decided; adding one is a copy change for the founder).
  - Footer (muted): "No payment details are asked for anywhere in the app."
  - **Never shown automatically:** no code path other than the two entry taps pushes `premiumPath` (no launch, resume, feed-load, scroll, post or timer trigger). W8-8 enforces it.
  - The strings above are the defaults; the founder approves the final copy in this PR (F3).
- **What the pop-up may and may not say until the Payments ADR is accepted** (recorded here for reviewers):
  - **May:** Premium is coming soon; the two plan names and their monthly prices incl. GST from `kPremiumPlans`; why (running costs).
  - **May not:**
    - any other price, an annual price, a discount, an introductory or launch price, or a "free trial";
    - any purchase or reservation affordance ("Subscribe", "Upgrade", "Buy", "Get", "Join the waitlist", "Notify me", "Pre-order", "Reserve");
    - a link to any external payment page (store rules require store billing for digital goods inside the apps and restrict steering to outside payment);
    - any date, urgency or scarcity ("limited", "early bird", "only today", a countdown);
    - any feature list that reads as an offer;
    - X's logo or brand marks (the name "Premium" is the founder's choice, F2).
- **Capture.** The Premium modal is MEASURED (desktop dark): only its structure (a modal with plan cards) is followed. We deliberately do not copy its brand strip, feature checklist, Monthly/Annual toggle or CTA hierarchy.
- **Acceptance criteria.**
  - Given Premium tapped on Home, then the pop-up opens over the feed; Close, Escape, system Back and a barrier tap each close it and leave the feed where it was.
  - Given the pop-up, then the only button is Close; the plan cards are not buttons.
  - Given the pop-up's text, then it contains "₹235/month" and "₹850/month", each followed by "incl. GST", and "coming soon".
  - Given the copy guard (W8-8), then it finds no match for `subscribe|upgrade|buy|trial|waitlist|notify me|pre-order|reserve|limited|early bird|/year|annual` and no other `₹` amount than those in `kPremiumPlans`.
  - Given 360 / 600 / 1200 dp, light and dark, and 1.0 / 1.3 / 2.0, then no overflow (the cards stack at 2.0).
  - Given a screen reader, then focus moves to the dialog title, each card reads once as "Plus, ₹235 a month including GST, coming soon", and focus returns to the entry on close.
- **Test notes.** Widget tests over the matrix, the copy guard, the `kPremiumPlans` formatting, semantics and focus return.
- **Observability.** —
- **Budget.** 0.
- **Flag.** `shells` (route); `shells` + `ui_shell` (entry); prod up to `on` (F2).
- **Seam.** `AppRouter.premiumPath`, `ShellKind.premium` and `kPremiumPlans`. The Payments ADR's flow replaces this pop-up behind its own flag, plan data then comes from the server, and no billing package is added before that ADR.

### W8-6 — Advertise screen  [owner: frontend-developer] [size: S] [depends: W8-2; the button's switch-on waits on the mailbox]  Status: Done (merged in #392, 2026-10-28)
- **Description.** `/advertise` (not `/ads`: content blockers' URL lists commonly match `/ads` paths, and a hard reload of `/ads` on web could be blocked):
  - `AppBackHeader` "Advertise" (F3).
  - Hero: icon disc (`campaign_outlined`), the title "Advertising is coming soon", and the subtitle "We don't sell ads or promoted posts yet, and there are no ads in your timeline."
  - **Contact (F4), only if `kAdvertisingContactEmail` is non-null.** The decided address is `comingsoon@dzeroth.com`, but the mailbox does not exist yet (2026-10-28), so the constant ships as `null` with a comment naming the address and `pending.md` 3.17. Once the founder confirms the mailbox receives mail, a one-line PR sets it:
    - a muted line, "Want to talk about advertising?";
    - a 48 dp text button "Email us" that opens `mailto:<address>?subject=Advertising%20enquiry` via `url_launcher` (no body, no account data);
    - if `launchUrl` returns false: a snackbar "Couldn't open your email app" with the address shown as selectable text.
  - **While null: no contact affordance at all.**
  - No form, no account setup, no country or timezone fields (X's Ads Manager is a separate product, `ads-manager-setup.md`).
- **Acceptance criteria.**
  - Given `kAdvertisingContactEmail == null`, then the page has no button except Back.
  - Given the address `comingsoon@dzeroth.com` (test override), then one "Email us" button whose launched URI is exactly `mailto:comingsoon@dzeroth.com?subject=Advertising%20enquiry`, verified with a fake launcher.
  - Given a launcher that fails, then the snackbar shows and the address is selectable.
  - The copy guard passes.
- **Test notes.** Widget tests over the matrix; a fake `url_launcher` platform (the `url_launcher_platform_interface` dev dependency is already there) for both address states.
- **Observability.** None. A failed launch is a user-visible snackbar, not a Crashlytics event.
- **Budget.** 0.
- **Flag.** `shells` (route); `shells` + `ui_shell` (entry).
- **Seam.** `AppRouter.advertisePath` and `ShellKind.advertise`. The Ads ADR decides whether this becomes a link-out or a real page; feeds stay untouched until an ad slot goes behind the `timeline` interface.

### W8-7 — Calls screen  [owner: frontend-developer] [size: S] [depends: W8-2, W8-3]  Status: Done (merged in #392, 2026-10-28)
- **Description.** `/calls`, a settings-style page:
  - `AppBackHeader` "Calls".
  - Hero (`AppEmptyView`, icon disc `call_outlined`): the title "Calls are coming soon" and the subtitle "Voice and video calls aren't available yet. You can still reach people by replying to or mentioning them."
  - Group "Calls" (`SettingsGroup`, static rows): "Voice calls" and "Video calls", each with the pill "Coming soon".
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

### W8-8 — Client tests  [owner: tester] [size: M] [depends: W8-4 to W8-7]  Status: Done (merged in #392, 2026-10-28)
- **Description.** The cross-screen matrix:
  - **Responsive:** every shell page and every entry point at 360 / 600 / 1200, light and dark, 1.0 / 1.3 / 2.0, with no overflow (`expectNoOverflow`).
  - **Flag-off matrix:**
    - `shells` off → no drawer row (360), no More rail item (600, 1200), and each of the four paths redirects to `/home`;
    - `ui_shell` off → no entry at any width;
    - each single-kind `kVisibleShells` → exactly that entry and route.
  - **0 RPCs:** pump each page with a counting fake transport behind `ApiClient` (or with no repository providers at all; whichever the harness supports), open it, wait for settle, and assert 0 calls. A structural test asserts that no file under `app/lib/features/shells/` imports a `data/` repository or `ApiClient`.
  - **Copy guard:** a test that walks the text of all four pages and the More menu and fails on the forbidden words of W8-5, on any date, and on any `₹` amount outside the Premium pop-up or not in `kPremiumPlans`. It runs on every future copy change.
  - **Tap-only pop-up (F7):** a structural test that `premiumPath` is pushed only from `shell_entries.dart` (the entry taps), plus widget tests that launch, resume, opening Home and scrolling the feed never open it.
  - **Semantics:** headers, static rows read once; the only buttons are Back, the pop-up's Close and (when enabled) "Email us".
  - **Bundle delta:** build web release before and after the wave with the `cost-model.md` §11 command, and record the gzip and brotli delta of `main.dart.js` in the PR (expected 15–30 KB gzip; flag it to the planner if it is above 60 KB).
- **Acceptance criteria.** Every acceptance criterion of W8-2 to W8-7 has a named test; `make ci` is green; the bundle delta is recorded.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Under test: `shells` × `ui_shell` × `kVisibleShells`.
- **Seam.** The structural no-repository test keeps the 0-cost claim true as the shells change.

### W8-9 — Privacy and claims check  [owner: security-auditor] [size: S] [depends: W8-4 to W8-7]  Status: Done (`docs/reviews/security-review-w8.md`; M-1 fixed, L-1 open for the founder)
- **Description.** A short review, not a threat model (no new surface), covering:
  - no data collection (no field, form, consent, analytics event or Crashlytics key);
  - no RPC and no repository import;
  - no new package (`pubspec.yaml` diff empty) and no platform permission (`android/`, `ios/`, `web/` diff empty);
  - the shell routes are absent from `deepLinkTarget`;
  - the `mailto:` construction (fixed subject, no account data), tested with the address on even though it ships off;
  - all four pages' copy against the "may not" list of W8-5 (urgency, other prices, purchase or reservation affordance, steering link), and the shown prices against the GST-inclusive rule;
  - the tap-only rule of the Premium pop-up (F7);
  - a note for the founder restating the accepted store-review risk (Risks) and the current wording of Apple 2.1 / 3.1.1 and Google Play's payments and minimum-functionality policies at the time of the prod raise.
- **Acceptance criteria.** A short report in `docs/reviews/` (or a section of the wave's review record) with no open finding above Low, and an explicit line "W8 collects no personal data".
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Confirms the `shells` prod ceiling matches the founder decision (F2) and that entries still require `ui_shell`.
- **Seam.** Confirms the shells name their routes only through `shellEntries` and `AppRouter`.

### W8-10 — ADR and stage-ladder rows  [owner: architect] [size: S] [depends: —]  Status: Done (ADR-0026 Accepted 2026-10-28)
- **Description.**
  - Answer A1–A3 in the PR description.
  - **ADR (Proposed)**, the next free number: "W8 coming-soon pages, Premium prices and pop-up". It records the founder decisions of 2026-10-28 (F1–F8), the reversal of the roadmap rules "own names" and "no Premium / ads upsell surfaces" for W8 only, what the Premium pop-up may and may not show (W8-5), the prod decision `on` (outside the ceiling file), the accepted store-review risk, and that payments still need their own ADR. Cost section: INR 0 / 0 / 2 a month (this plan). The founder accepts it; W8-5 merges after that. The roadmap risk row is updated in the same PR to point at it.
  - Add a heading "Locked features (shell only)" to `.claude/skills/stage-ladder/SKILL.md`, with the five rows of this plan's Scope table: paid tier, creator insights, creator monetisation, advertising, calls. Each row gets its Stage 0 shell, seam, Stage 2/3 target, the future ADR it needs (unnumbered) and its trigger.
  - Add one line to the skill's "How each agent uses this": "a locked feature moves only by its own accepted ADR; its shell is the placeholder".
- **Acceptance criteria.** The ADR exists as Proposed with a cost section; every stage-ladder row names a seam and a measured trigger or a recorded founder decision; Calls states that it depends on the Real-time row; no number is reserved for the future feature ADRs.
- **Test notes.** None (docs). `code-reviewer` checks the seam and trigger lines.
- **Observability.** —
- **Budget.** 0.
- **Flag.** —
- **Seam.** Defines the seams that W8-2 to W8-7 build.

### W8-11 — Dev rollout, prod raise prepared  [owner: production-deployer] [size: S] [depends: W8-1, W8-8, W8-9; prod also W8-10 Accepted and `ui_shell` in prod]  Status: Prepared (commands in `docs/runbooks/shells.md`; the founder runs them after #392 merges)
- **Description.**
  - Show the founder a **targeted** dev Terraform plan (`pending.md` 3.10: a full dev apply is unsafe; a targeted apply must also name `-target=module.budget.google_pubsub_topic.billing_alerts`) for `feature_shells*` only.
  - Apply on OK, with the allowlist set to the 3 test uids that already have `ui_shell`.
  - Smoke on dev web at 360, 600 and 1200 dp:
    - the four entries appear for an allowlisted uid (drawer at 360, rail More menu at 600 / 1200) and not for another account;
    - each page opens and Back returns; Premium opens as a pop-up over the feed and Close returns to it;
    - `/premium` typed by a non-allowlisted account lands on Home;
    - the browser's network panel shows no API call while on a shell page.
  - **Prod (F2, accepted):** prepare the prod Terraform change for `feature_shells` (allowlist, then `on`) and hand it to the founder. It is applied only with the founder's OK and ships through a `v*` tag, a production-reviewer GO and `promote-prod` (ADR-0019). It is useful only once `ui_shell` is on in prod (F6); the deployer says so in the hand-off.
- **Acceptance criteria.** The dev smoke passes; the prod change is prepared, not applied; `pending.md` 3.17 updated with the dev state.
- **Test notes.** —
- **Observability.** The startup `feature_flags` line of the new dev revision shows `shells` in allowlist mode.
- **Budget.** 0 reads (one `GetMe` per smoke session, already counted).
- **Flag.** Dev: `feature_shells` allowlist (3 uids); prod: `off` until the founder applies the prepared change.
- **Seam.** —

## Rollout plan
- **Dev:** allowlist (3 uids with `ui_shell`), after W8-9.
- **Prod (accepted by the founder 2026-10-28, F2):** the ceiling (W8-1) allows `on`. The raise needs:
  - ADR-0026 Accepted and your sign-off on the final copy (W8-5 PR);
  - `ui_shell` on in prod (F6, a separate decision), otherwise nobody sees an entry;
  - allowlist, then `on`, each step a Terraform change plus a `v*` tag, a production-reviewer GO and `promote-prod` (ADR-0019), all platforms (web and the next store builds).
- **Rollback triggers:**
  - any user report or reviewer finding that a shell reads as an offer someone can buy, or a pop-up shown without a tap;
  - a store review rejection citing placeholder content;
  - a crash on a shell route (Crashlytics);
  - a shell visible to a non-allowlisted account.
- **Kill switch:** `FEATURE_SHELLS=off` and deploy. Entries disappear and routes redirect on the next `GetMe`, with no data to migrate. One shell: remove it from `kVisibleShells` by PR.

## Risks
| Risk | Mitigation |
|---|---|
| Store review rejects "coming soon" screens or shown prices for a subscription not sold through store billing. Apple's App Completeness guideline (2.1) asks that placeholder content be removed; Apple 3.1.1 and Google Play's payments policy require store billing for digital subscriptions; Google Play has a minimum-functionality policy | **risk accepted by the founder for all platforms (2026-10-28)**. No buy button or external link, so nothing steers to outside payment. If a store rejects a build: drop the cited kind from `kVisibleShells` for the store build (web keeps it), or set `shells` off; W8-9 restates the current guideline wording before the prod raise |
| The Premium pop-up with prices reads as a pre-sale or an upsell (the roadmap rule "no Premium / ads upsell surfaces" is reversed for W8 by the founder, recorded in ADR-0026) and India's consumer-protection rules on dark patterns and price display | tap-only (F7, tested), "Coming soon" on every card, prices incl. GST, no purchase affordance, no urgency, no date; the copy guard test; W8-9 review; your copy sign-off; legal advice with the Terms review (`pending.md` 3.9) |
| The shown prices go stale or differ from what Payments later charges | one constant `kPremiumPlans`; a change is a one-line reviewed PR; the Payments ADR replaces it with server-provided plan data |
| `comingsoon@dzeroth.com` gets spam once public | ships off until the mailbox exists; use a dedicated alias with a spam filter, never a personal inbox |
| Someone adds a waitlist or "notify me" later, collecting personal data with no privacy basis | explicitly out of scope; the copy guard fails on "waitlist" and "notify me"; adding a field is a scope change for you |
| Users expect the feature soon because every page says "coming soon" (F3, founder decision) | no dates and no promise of when; each page states what works today; F1 can hide any shell |
| Creator tools counts are mistaken for analytics or look stale | only four profile numbers, each labelled; the "Counts are as of your last refresh" footnote; insights rows say "Coming soon", never 0 |
| Copying X too closely (names, plan cards, modal, calendar toolbar) | "Premium" and a pop-up are founder decisions (F2, F7); otherwise our own names, Material icons, no X brand marks, no feature checklist, no billing toggle, no calendar |
| Merge conflicts in shell navigation with W3, W4, W5 and W7 | the shared-file table; shell rows always last before Settings; one nav PR at a time |
| The rail "More" menu becomes a catch-all as later waves add rows | W8 creates it with the four shells only; each later wave's plan decides its own rows (above the shells) |
| A real feature lands but a shell page lingers, or two routes exist for one feature | the seam rule: the real feature keeps the path and entry, swaps the builder, and deletes the shell in the same PR; `shells` is retired with `NewRetired` when the last shell goes |
| Web bundle grows for every visitor | measured in W8-8 (expected 15–30 KB gzip, about INR 2 a month at 3,000 DAU, 0 below about 2,731 DAU); deferred loading only if the delta exceeds 60 KB |
