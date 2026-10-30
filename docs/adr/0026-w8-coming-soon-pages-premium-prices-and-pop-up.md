# 0026. W8 coming-soon pages, Premium prices and pop-up
Status: Accepted (founder, 2026-10-28, in the session that implements W8; Q1 taken at its default: the prod
ceiling is recorded in this ADR and `docs/runbooks/shells.md`, not in `flag-ceiling.json`)
Date: 2026-10-28
Deciders: architect (proposal); founder (decisions F1–F8 of 2026-10-28; merging this ADR's PR is the acceptance). No fixed
monthly cost is added, so no cost approval is recorded here.

## Context
- **Plan:** `docs/plans/ui-w8-shells.md` (planner, 2026-10-27; founder decisions F1–F8 recorded 2026-10-28), ticket W8-10.
  W8 is four client-only pages: Creator tools `/creator-studio`, Premium `/premium`, Advertise `/advertise` and Calls
  `/calls`. They make 0 RPCs and 0 Firestore reads, writes or deletes, and add no proto, index, package, GCP service or
  fixed cost. One new client-only flag, `FEATURE_SHELLS` (wire name `shells`), is registered like `ui_shell`.
- **The rules this touches.** `docs/plans/roadmap.md` records two founder rules:
  - founder decisions of 2026-10-22: only X's colours are copied, and icons, copy, logo and names stay our own (ADR-0020
    Context says the same: "no Grok/Premium/ads surfaces are copied");
  - the risk row "Copying X too closely": "own icons, copy, names; no Grok / Premium / ads upsell surfaces".
  The 2026-10-27 plan defaults kept both rules: a Premium page with no price and no plan names, shown as a normal page,
  with prod `off`.
- **Founder decisions of 2026-10-28** (plan section "Founder decisions"):

  | # | Decision |
  |---|---|
  | F1 | All four shells exist (`kVisibleShells` = all four), each says "Coming soon" |
  | F2 | Premium shows two plans: **Plus ₹235/month** and **Premium ₹850/month**, both incl. GST. Prod is accepted: the `shells` prod ceiling is `on`. All platforms (web, Android, iOS); the founder accepts the store-review risk |
  | F3 | "Coming soon" is shown on every page; still no date, no countdown, no urgency |
  | F4 | Advertise contact `comingsoon@dzeroth.com`; the mailbox does not exist yet, so the "Email us" button ships off |
  | F5 | Wide screens (600 dp and up): a rail-only "More" item opens a menu of the shells; the account chip menu is unchanged |
  | F6 | (a) Entries only in the new `ui_shell` layout; none in the legacy chrome |
  | F7 | Premium is a pop-up over the current page, opened only when the user taps Premium, never automatically |
  | F8 | Creator tools shows followers, following, posts and join month from the `GetMe` profile already in memory |

- F2 (shown prices and the plan name "Premium") and F7 (a pop-up over the feed) reverse the two roadmap rules for W8.
  The plan's A1 asks whether that needs an ADR. It does: the change adds no contract or cost, but it reverses a recorded
  founder rule and puts a price page in prod before payments exist. Reviewers need one place that says what the pop-up
  may show.
- **Stage:** Stage 0, credit mode until 2026-12-24 (ADR-0022). Nothing in W8 is credit-funded, and nothing bills after
  2026-12-26.
- **Measured numbers:** none apply. W8 has no request path. The only cost is the web bundle (plan section Cost).

## Options
### A. Keep the roadmap rules (the 2026-10-27 defaults)
An informational Premium page with no price, no plan names, not a pop-up, and prod `off`.
- Pros: no reversal, the lowest store-review and consumer-protection risk, and nothing to keep in step with a future
  price.
- Cons: the founder rejected it on 2026-10-28.
- Cost: INR 0 idle, about INR 0 / 0 / 2 a month at 300 / 1,000 / 3,000 DAU (web bundle only).

### B. The founder's decisions, bounded for W8 only  *(chosen)*
The F1–F8 decisions, with the guardrails of D2 to D6 below.
- Pros: users see the planned prices and every future destination. Nothing can be bought, reserved or signed up for. The
  exception is scoped to W8 and enforced by tests (copy guard, tap-only test).
- Cons: store review may reject a build (Apple 2.1 placeholder content; Apple 3.1.1 and Google Play payments policy for
  digital subscriptions; Play minimum functionality). A shown price can be read as an offer, and it can go stale before
  Payments exists. "Premium" as a name follows X.
- Cost: as A. The pop-up and plan cards are a few KB more on the bundle, inside the plan's 15–30 KB estimate.

### C. Prices plus an interest capture (waitlist, "notify me", reservation)
- Pros: it would measure demand before the Payments ADR.
- Cons: it collects personal data with no privacy basis in the Privacy Policy. It reads as a pre-sale, the "subscription
  trap" and "false urgency" risk under India's consumer-protection rules on dark patterns. It needs a write path, an RPC,
  a quota and an eraser.
- Cost: 1 write and 1 read per sign-up, plus an RPC. Small, but a new public write.
- Rejected. The plan lists it as out of scope; adding it is a scope change for the founder.

## Cost impact
- **Fixed monthly cost added: INR 0.** No GCP resource, topic, Scheduler job, index, secret or package. The credit window
  of ADR-0022 lifts nothing, and nothing here bills after 2026-12-26.
- **Free-tier quota consumed** (plan section Cost; method `free-tier-budget` §2 and `cost-model.md` §5):

  | Item | Delta |
  |---|---|
  | Firestore reads / writes / deletes | 0 / 0 / 0 per DAU per day. The screens take no repository; Creator tools reads `OnboardingBloc.state.profile` |
  | Cloud Run requests, vCPU-s | 0; `GetMe` is not called more often |
  | `GetMe` response, egress to India | +8 bytes (`"shells"` in `enabled_features`) per `GetMe` for callers the flag is on for; negligible |
  | Vision units, Pub/Sub, Scheduler, Secret Manager, GCS | 0 |
  | Firebase Hosting transfer (web bundle) | estimated +15–30 KB gzip on `main.dart.js`, downloaded once per web release by each web visitor whatever the flag. W8-8 measures it |

- **Per-RPC budget rows:** none. W8 adds no RPC.
- **When a free quota runs out:** W8 alone never exhausts one. The bundle line shares the Hosting transfer allowance
  (360 MB/day), which the whole product passes at about 2,731 DAU (`cost-model.md` §4). Below that the line is free.
- **INR per month** (900 web DAU at 3,000 DAU, 30 % web share; 30 KB × 4.3 prod web releases a month; Hosting $0.15/GB
  past the free transfer; INR 95/USD):

  | DAU | 300 (Stage 0 target) | 600 (2×) | 1,000 | 3,000 (10×) |
  |---|---|---|---|---|
  | W8 | INR 0 | INR 0 | INR 0 | about INR 1.6 (rounded to 2) |

  Past 2,731 DAU it grows by about INR 0.55 per 1,000 DAU.
- **Abuse as cost:** there is no public read or write, so there is no new per-user quota or per-instance rate limit. The
  pages work in `DEGRADED_MODE=readonly`.
- **Trigger that justifies it:** none needed (no fixed cost and no stage move). Deferred loading of the shell screens is
  considered only if W8-8 measures a bundle delta above 60 KB gzip.

## Stage ladder
- **Stage 0 choice:** each future feature (paid tier, creator insights, creator monetisation, advertising, calls) is a
  shell: a fixed route and one entry in the `shellEntries` descriptor, behind `shells` + `ui_shell`, with no backend.
- **Seams that keep it swappable:**
  - the route constants `AppRouter.creatorStudioPath`, `premiumPath`, `advertisePath`, `callsPath`;
  - the `ShellKind` entries in `shellEntries`, the only place a shell is named. A real feature moves the entry's gate to
    its own flag and swaps the route's builder; the drawer and the More menu do not change;
  - `kPremiumPlans`, the only place a price lives. It becomes server-provided plan data with Payments. No client code
    reads an "entitlement";
  - `CreatorInsightsGroup` and `CreatorProgramsGroup`, which are separate widgets;
  - the `timeline` interface, the only place a feed is merged. An ad slot goes behind it, never into a handler or widget;
  - W7's conversation header, where a call action would go.
- **Stage 2/3 targets and triggers:** `.claude/skills/stage-ladder/SKILL.md`, section "Locked features (shell only)",
  added with this ADR (the plan's Scope table, A2). Each real feature needs its own future ADR, numbered when written:
  Payments, Creator payouts (after Payments), Ads, Calls (after the Real-time row has moved). Creator insights needs a
  plan, and an ADR only if it adds a collection. Impressions need the Counters row's ADR.

## Decision
Option B. The founder decisions F1–F8 of 2026-10-28 are accepted as recorded in the plan. They reverse the roadmap
rules "own names" and "no Grok / Premium / ads upsell surfaces" **for W8 only**, and only as far as D2 says. The Premium
pop-up may show the two planned prices with "Coming soon" and nothing to act on (D3, D4). `FEATURE_SHELLS` gets a prod
ceiling of `on`, reaching users only where `ui_shell` is also on (D5, D7). The founder accepts the store-review risk for
all platforms (D6). The Advertise mail link stays off until the mailbox exists (D8). Payments, creator payouts, ads and
calls each still need their own accepted ADR (D9).

### D1. Scope of the decision
Client-only. No proto, no Firestore model or index change, no RPC, no server code beyond the flag registration (W8-1).
No `CLAUDE.md` non-negotiable rule bends: the change ships behind a server flag (`flag-rollout`), stores no data and
has no write path. What changes is a roadmap rule, which is a founder rule rather than a constitution rule.

### D2. What is reversed, and what is not
- **Reversed for W8:**
  - the plan names "Plus" and "Premium" and the page label "Premium" (F2);
  - a Premium pop-up over the current page that shows prices (F2, F7);
  - "Coming soon" wording on every shell (F3).
- **Not reversed:**
  - no X logo, brand marks, brand strip or icons (Material outline icons only);
  - our own labels "Creator tools" and "Advertise" (not "Creator Studio" and "Ads");
  - no Grok, anywhere;
  - no feature checklist per plan and no Monthly/Annual toggle;
  - no X CTA hierarchy and no calendar-style Calls toolbar;
  - no ad slot or "Promoted" label in any feed.
- **Every other wave:** the roadmap rules stand unchanged. Another surface that wants an X name or an upsell pattern
  needs its own founder decision and ADR.

### D3. What the Premium pop-up may and may not show (W8-5), until the Payments ADR is Accepted
- **May show:**
  - that Premium is coming soon;
  - the two plan names and their monthly prices from `kPremiumPlans`: **Plus ₹235/month** and **Premium ₹850/month**,
    each followed by "incl. GST" and a "Coming soon" pill;
  - why paid plans are planned (running costs);
  - the line "No payment details are asked for anywhere in the app."
- **May not show:**
  - any other amount: an annual price, a discount, an introductory or launch price, or a "free trial";
  - any purchase, reservation or sign-up affordance: "Subscribe", "Upgrade", "Buy", "Get", "Join the waitlist",
    "Notify me", "Pre-order", "Reserve";
  - a form, field, checkbox or consent prompt;
  - a link to any external payment page, or any external `https` link (store anti-steering rules);
  - any date, urgency or scarcity: "limited", "early bird", "only today", a countdown;
  - any feature list that reads as an offer;
  - X's logo or brand marks.
- **Interaction:** the only button is Close (×). The plan cards are static text, not buttons. Escape, system Back and a
  barrier tap also close it.
- **Prices:** shown inclusive of GST. They are formatted from paise with the `en_IN` rupee format and live only in
  `kPremiumPlans` (`app/lib/features/shells/domain/premium_plans.dart`). Changing a price is a one-line, reviewed PR, and
  the founder approves it as copy.
- **Enforcement:** the W8-8 copy guard fails on `subscribe|upgrade|buy|trial|waitlist|notify me|pre-order|reserve|limited|early bird|/year|annual`,
  on any date, and on any `₹` amount that is not in `kPremiumPlans` or is outside the Premium pop-up. The founder approves
  the final strings in the W8-5 PR (F3).

### D4. Tap-only (F7)
The pop-up opens only when the user taps the Premium entry (drawer row or More menu item). No code path opens it on
launch, resume, feed load, scroll, after a post or on a timer. When `/premium` is the first location (typed URL, reload,
cold start), the router redirects to `/home` and opens nothing. `/premium` is not in `AppRouter.deepLinkTarget`. W8-8
enforces this with a structural test (only `shell_entries.dart` pushes `premiumPath`) and widget tests (launch, resume,
Home and scroll never open it). An automatic pop-up over the feed is the "nagging" and interface-interference pattern
that consumer-protection rules on dark patterns name, so a failure of this test is a rollback trigger.

### D5. `FEATURE_SHELLS` ceilings
- dev: `allowlist`, at most 3 uids, percent 0;
- prod: up to `on` (F2). The prod ramp is allowlist, then `on`; a percent ramp of informational pages buys nothing.
- Every prod step is a Terraform change plus a `v*` tag, a `production-reviewer` GO and `promote-prod` (ADR-0019).
  Agents never apply prod or dispatch `promote-prod` on their own.
- **Where the prod ceiling is recorded (founder question Q1 below).** `scripts/promotion/flag-ceiling.json` has no
  `envs.prod` block today, and no prod workflow reads it. `check-flag-registry.sh` requires every env block to list
  every flag, so W8-1 cannot add a single `SHELLS` prod entry as the 2026-10-28 plan first said (it asked to copy an
  existing prod `on` entry; none exists). The plan now matches. Until an `envs.prod` block exists, the prod ceiling `on` is recorded in this ADR and in
  `docs/runbooks/shells.md`.
- Kill switches: `FEATURE_SHELLS=off` (all four, on the next `GetMe`), or removing one kind from `kVisibleShells` by PR
  (web next deploy, mobile next store build).
- Retire: `NewRetired` once every shell is replaced; the name `shells` is never reused.

### D6. Store-review risk, accepted by the founder for all platforms
On 2026-10-28 the founder accepted the store-review risk for web, Android and iOS. The relevant guidelines are Apple 2.1
(placeholder content), Apple 3.1.1 and Google Play's payments policy (store billing for digital subscriptions; steering
to outside payment), and Google Play's minimum-functionality policy. Mitigations:
- no buy button and no external link, so nothing steers to outside payment;
- if a store rejects a build, drop the cited kind from `kVisibleShells` for that store build (web keeps it), or set
  `shells` off;
- before the prod raise, W8-9 restates the current wording of those guidelines for the founder.
- A rejection is a rollback trigger, not a reason to change the copy without the founder.

### D7. Entries only in the new layout (F6)
Every entry point (drawer row, rail "More" item and its menu) needs `shells` **and** `ui_shell`. Routes need `shells`
only, and a typed URL with `shells` off redirects to `/home`. `ui_shell` has no prod ceiling today, so in prod the
pages reach users only once `ui_shell` is also raised there. That is a separate founder decision, not made here. Until
then, `shells` can sit at `on` in prod with no visible effect.

### D8. Advertise contact
The address is `comingsoon@dzeroth.com` (F4). The mailbox does not exist (2026-10-28), so `kAdvertisingContactEmail`
ships as `null` and the page shows no contact affordance. Once the founder confirms the mailbox receives mail
(`docs/plans/ui-w8-shells.md`), a one-line PR sets it. The button then opens
`mailto:comingsoon@dzeroth.com?subject=Advertising%20enquiry` through `url_launcher`, with an empty body and no account
data. It should be a dedicated alias with a spam filter, never a personal inbox.

### D9. Each real feature needs its own ADR (unnumbered; numbered when written, the highest existing plus one)
- **Payments**: store billing, a web payment provider (a stack exception the ADR must justify), receipt verification,
  entitlements owned by `identity`, GST and invoicing, refunds, Indian recurring-payment mandate rules, what may be
  paywalled (never safety or privacy features). `/premium` and `kPremiumPlans` are replaced behind its own flag. No
  billing package is added before it.
- **Creator payouts**: after Payments.
- **Ads**: consent and privacy (DPDP Act, App Tracking Transparency, Play Data safety), labelling, advertiser review,
  needs Payments. Any ad slot goes behind the `timeline` interface.
- **Calls**: after the `stage-ladder` Real-time row has moved. The TURN/SFU relay is a fixed or per-GB cost that needs
  the founder's approval.

  No number is reserved here (A3). The W4 to W7 plans name 0026 to 0029 as planned numbers, and each says "or the next
  free number". This ADR took 0026 as the highest existing plus one, so W4's ADR takes the next free number when its PR
  opens.

### Plan questions answered (W8-10)
- **A1.** Yes, W8 needs an ADR: this one. It records a reversal of founder rules and a prod price page, not a contract.
- **A2.** The five rows are confirmed with two wording changes, and added to the skill under "Locked features (shell
  only)": "your decision" reads "the founder's decision", and "Coming soon" replaces "not available". Calls states that
  it depends on the Real-time row.
- **A3.** No number is reserved for the future feature ADRs.

### Questions for the founder (default in bold)
- **Q1. Where the `SHELLS` prod ceiling lives.** **Default: in this ADR and `docs/runbooks/shells.md` only;
  `flag-ceiling.json` stays dev-only.** Prod is already gated by the tag ruleset, the required reviewer and the
  production-reviewer GO (ADR-0019). Alternative: a first `envs.prod` block in `flag-ceiling.json` that covers **every**
  flag, plus the prod Cloud Run shape (max 3, min 1 under credit mode until 2026-12-24) and the allowed tags. That is a
  cross-wave gate-file change for `production-deployer` with your review, and wiring `validate-revision.sh` into
  `release-prod.yml` is a separate workflow change. It is outside W8.

## Consequences
- **Positive:**
  - users see every future destination and the planned prices, with nothing to buy, reserve or sign up for;
  - each future feature has a fixed route, entry and seam to land in;
  - the exception is written down and tested, and limited to W8.
- **Negative:**
  - a possible store rejection, accepted by the founder (D6);
  - a shown price can go stale or differ from what Payments later charges (one constant, a reviewed PR; Payments
    replaces it with server data);
  - users may expect the features soon because every page says "coming soon" (no dates, no promise of when);
  - "Premium" follows X's name.
- **Follow-up work:**
  - W8-1 registers the flag with the dev ceiling only, and records the prod ceiling per Q1;
  - W8-5 merges only after this ADR is Accepted;
  - W8-9 restates the store guideline wording before the prod raise;
  - legal advice on the final Premium copy and price display rides with the Terms of Service review (`docs/plans/roadmap.md` section 9, item 3.9);
  - the "Email us" switch-on waits for the mailbox.
- **Revisit when:**
  - a store rejects a build;
  - a user report or reviewer finding says a shell reads as an offer someone can buy, or the pop-up opened without a tap
    (rollback, then revisit D3/D4);
  - the founder changes a price or adds a plan feature list (copy change in `kPremiumPlans`, and a D3 amendment if it
    adds a new kind of content);
  - the Payments ADR is accepted (this ADR is then superseded for Premium).

## Handoff
- **backend-developer (W8-1):**
  - `flags.LoadSpec("SHELLS", "shells", flags.Off)` on one line in `config.go`, plus `config.FeatureShells` in
    `flags.NewRegistry`;
  - `"SHELLS"` in the ceiling `flags` list and the dev entry `{"mode": "allowlist", "max_allowlist": 3, "max_percent": 0}`;
  - no `envs.prod` block unless the founder picks the Q1 alternative;
  - Terraform `feature_shells*` in both envs, default `off`;
  - `docs/runbooks/shells.md` records "prod ceiling `on`, ADR-0026 D5".
- **frontend-developer:**
  - W8-2: entries and routes per D4 and D7 (`/premium` only by `push`, redirect as first location, no `deepLinkTarget`
    change);
  - W8-5: the pop-up exactly per D3, with `kPremiumPlans` as the only price source;
  - W8-6: `kAdvertisingContactEmail = null` with a comment naming the address and `docs/plans/ui-w8-shells.md` (D8);
  - W8-4 and W8-7 per the plan; no billing, ads, WebRTC or permission package.
- **tester (W8-8):** the copy guard regex and amount rule of D3, the tap-only structural and widget tests of D4, the
  `shells` × `ui_shell` × `kVisibleShells` matrix, the 0-RPC test, and the bundle delta.
- **security-auditor (W8-9):** no data collection, no permission, no package; copy against D3; tap-only per D4; the store
  guideline restatement of D6. No new public read or write exists, so no threat model.
- **production-deployer (W8-11):** dev allowlist (3 uids that have `ui_shell`); prepare, never apply, the prod
  `feature_shells` change (allowlist, then `on`), and say in the hand-off that it is visible only once `ui_shell` is on
  in prod (D7).
- **sre-performance:** no per-RPC row. One line for `docs/reviews/cost-model.md`: "W8 web bundle +15–30 KB gzip,
  INR 0 / 0 / 2 a month at 300 / 1,000 / 3,000 DAU (Hosting transfer past about 2,731 DAU)". Replace it with the W8-8
  measurement.
- **code-reviewer:** no repository or `ApiClient` import under `app/lib/features/shells/`, no `GetMe` call added, shell
  paths and labels named only in `shellEntries` and `AppRouter`, prices only in `kPremiumPlans`.
