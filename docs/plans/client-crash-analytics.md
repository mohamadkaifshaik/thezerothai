# Client crash reporting and usage analytics (Firebase Crashlytics, Google Analytics for Firebase)
Plan owner: planner · Date: 2026-11-01 (updated 2026-11-02: TEL-10 follow-ups TEL-17 to TEL-20, founder decisions F12 and F13) · Stage 0 (free tier, per use past it; about INR 434/month at 300 DAU, `docs/reviews/cost-model.md` §5, ADR-0022) · **Client-only:** two Firebase SDKs in the Flutter app, a consent card and two Settings switches. 0 RPCs, 0 Firestore reads, writes or deletes, no proto, no index, no new GCP resource, no fixed cost · Flags: new `FEATURE_CRASH_REPORTING` (`crash_reporting`) and `FEATURE_ANALYTICS` (`analytics`), both client-only (registered like `ui_shell`, `drafts` and `shells` so `GetMe.enabled_features` reports them) · Roadmap: not a wave; tracked in `docs/plans/roadmap.md` section 9, item 3.23

> **Founder decision (2026-11-01, verbatim):** "plan to add crashlytics and google analytics and update the policy before it ships"

Sources:
- `CLAUDE.md` (prime directive; rule 10 privacy; rule 11 cost caps; "Stop and ask the founder"; the reference architecture already lists **Crashlytics** under "Crash reporting"; Google Analytics is **not** listed);
- `app/web/privacy.html` (W6-55 refresh, #584), ADR-0011 Q10 (f) and its note of 2026-11-01, `docs/runbooks/account-deletion.md`;
- `app/pubspec.yaml`, `app/lib/app/bootstrap.dart`, `app/lib/app/session_wiring.dart`, `firebase.json`, `.github/workflows/release-prod.yml`, `app/android/**`, `app/ios/Runner/Info.plist`;
- skills `free-tier-budget`, `flag-rollout`, `flutter-feature`, `security-checklist`, `production-readiness`, `observability`, `stage-ladder`; the plan format of `docs/plans/ui-w8-shells.md` and `docs/plans/ui-w6-composer-extras.md`.

Branches: `feat/tel-N-<slug>` (docs: `docs/tel-N-<slug>`) off `main`, not stacked; one ticket per PR; merge `origin/main` into the branch.

## Questions for the founder (proposed default in bold; nothing blocks TEL-1, TEL-2 or TEL-14)
**Answered 2026-11-01, all at the defaults** (founder, verbatim: "TEL plan defaults all ok, go ahead"); recorded as decided in ADR-0032 ("Founder decisions").
- **F1. Consent.** India's DPDP Act treats consent as the main basis for processing. Consent must follow a notice, be a clear affirmative action, and be as easy to withdraw as to give. (How the DPDP Rules phase this in is for legal advice; this is not legal advice.)
  - **Default (A): opt-in for both.** The card is shown once per account on each Android device, at the top of Home, using the push opt-in card pattern. It has two switches, "Send crash reports" and "Share usage statistics", **both off**. "Save" keeps what you switched on; "Not now" keeps both off and is not asked again. Settings › Privacy & safety has the same two switches at any time.
  - (B) Crash reports on by default with an opt-out switch in Settings and a one-time notice; analytics opt-in. Near-full crash coverage, but on-by-default is not a "clear affirmative action", so the policy would have to name another basis. Legal review would decide.
  - (C) Both on by default with opt-outs. The weakest consent position; not recommended.
  - Trade-off of (A): crash coverage is only the opted-in share (unknown; often well under half). At 0–300 DAU, a handful of opted-in devices still shows the top crashes.
- **F2. Platforms.** **Android only in this plan.**
  - **Web:** Crashlytics has no Flutter web support. Web Analytics sets cookies (`_ga`), which ends the policy's "no advertising or analytics cookies" sentence, and it needs a cookie banner. It would also need these CSP hosts in `firebase.json`:
    - `script-src https://www.googletagmanager.com`
    - `connect-src https://*.google-analytics.com https://*.analytics.google.com https://*.googletagmanager.com`

    `deploy-dev.yml` and `promote-prod.yml` (gate files) apply the Hosting config. Web keeps what it has today: console only on the client, and server errors in Cloud Error Reporting. The Stage 2 version, with its trigger, is under Out of scope.
  - **iPhone:** TEL-3 adds the off-switch keys to `Info.plist` now, so an iOS build can never collect by accident. Turning it on waits for the Apple launch (TEL-16, conditional): dSYM upload, Podfile, the App Store privacy label and policy maintainer note 16.
- **F3. Linking to accounts.** **None.** No `setUserId` or `setUserIdentifier`, no user properties, and no uid, handle, email, post, message or search text in any event, parameter, custom key, log or breadcrumb. Data stays device-level, so ADR-0011 Q10 (f) ("Crashlytics and Analytics data keyed to the device, not the uid", founder-accepted 2026-10-07) holds and right-to-delete needs no new eraser step. Linking would cost all of this:
  - an eraser step calling the Google Analytics User Deletion API (a new API, credentials and IAM);
  - Crashlytics data that we know no per-user deletion API for (TEL-1 verifies), so it would stay until its retention ends;
  - an export section, a Q10 amendment, a new residue entry and new policy text;
  - "Linked to you" on the store forms.
- **F4. Which analytics events.** **Three custom events plus screen views, each tied to a product question:**
  - `post_created` {`kind`: post | reply | quote; `media`: none | photo | gif; `poll`: bool; `scheduled`: bool}: are people posting, and which composer extras do they use?
  - `follow` {`source`: profile | suggestions | search | list | other}: which surface grows the graph?
  - `search_used` {`type`: people | hashtag}: is search used? This is deliberately **not** GA's recommended `search` event, which carries a `search_term`.
  - `screen_view` with `screen_name` from a fixed map of route **templates** (`/post/:id` → `post_detail`, `/u/:handle` → `profile`, anything unmapped → `other`). Never the location, query string, handle or id.

  Parameters are enums or booleans only, never free text. "Sign-up completed" is left out: consent comes after onboarding, so the event would never fire, and the server already counts accounts. Google also collects its automatic events (first open, session start, engagement time, app update, OS update, app removed and, with FCM present, notification received or opened; TEL-1 lists them exactly). A new event or parameter is a policy change in the same PR.
- **F5. Google Analytics property settings (console, dev and prod).** These are console settings, not code:
  - **event data retention: 2 months (the minimum), with "reset on new activity" off;**
  - **Google signals off;**
  - **ads personalisation off in every region;**
  - **granular location and device data off;**
  - **user-provided data collection off;**
  - **every account data-sharing setting off;**
  - **no Google Ads, BigQuery or Search Console link.**

  The app side: advertising ID collection off, the `AD_ID` permission removed from the merged manifest, ad storage, ad user data and ad personalisation consent always denied, and SSAID off. Google says GA4 does not log or store IP addresses; TEL-1 verifies that and records what Crashlytics does with the IP.
- **F6. What a crash report may carry.** **The error type and the stack trace. Never the exception message**, unless the type is on a short allowlist of code-generated messages (`TypeError`, `StateError` with our fixed strings, `AssertionError`, `FlutterError` overflow and layout errors), and then only after the scrubber. The scrubber replaces digit runs of 6 or more, 28-character uid-like tokens, emails, @handles and URLs, and cuts the message at 200 characters.
  - A `ConnectException` sends only its code and `ErrorReason`.
  - A `FlutterErrorDetails` sends neither `context` nor `informationCollector`, because a build error can render `Text("<user text>")` there.
  - Custom keys: build number, `FIREBASE_ENV` and platform only. **No list of enabled flags:** with an allowlist of a few uids, a flag list would identify the person.
  - Breadcrumbs: compile-time constant strings only.
  - Alternative: a scrubbed message for every type. Easier debugging, but more leak risk.
- **F7. Flags, ceilings, ramp.** **Two client-only flags.** Dev ceiling: allowlist, at most 6 (as the other dev flags), percent 0. `flag-ceiling.json` has no prod block for any flag, so the **proposed prod ceiling `on`** is recorded in the ADR (TEL-1) and the runbook. Prod ramp: allowlist (you and testers), then `on`. A percent step buys little, because consent already limits who sends.
- **F8. Rule 10 ("PII limited to Firebase Auth + `users/{uid}/private`").** **The default reading is that it fits.** Rule 10 governs what we store about accounts. This data is not stored in our systems, is not keyed to accounts, and is covered by Q10 (f). It is still personal data under DPDP, which is why F1 asks for consent. If you read rule 10 as covering any personal data a client sends to a third party, this plan bends it, and the bend needs your explicit sign-off in TEL-1.
- **F9. "Policy live" for the dev allowlist.** On Android the in-app policy link always opens `https://dzeroth.com/privacy.html`, on **prod** Hosting (`app/lib/core/widgets/privacy_policy_link.dart`). Prod Hosting changes only when a `v*` tag is promoted. **Default:**
  - the dev allowlist may start once the new text is on dev Hosting (deploy-dev after the TEL-12 merge), **for the team's test accounts only**;
  - no account outside the team, in dev or prod, is allowlisted until prod Hosting serves the new text, through a promoted `v*` release that contains TEL-12.

  Stricter alternative: wait for prod Hosting before the dev allowlist too.
- **F10. Legal review.** The policy is still a Draft; maintainer note 1 says legal review has not been done. **Default: same as every other feature.** You approve the text by merging TEL-12, and legal review stays note 1's open item. The Analytics terms check (A2) **is** a gate.
- **F11. A second account on the same device.** **Default: reset the device's analytics ID whenever a different account signs in on the device than the last one, and on in-app account deletion.** Each account's choice is stored separately (per uid). Cost of the reset: one person with two accounts counts as two users.

**Decided 2026-11-02, after the TEL-10 review** (founder, 2026-11-02, as relayed by the lead; the founder confirms them by merging the PR that adds them):
- **F12. L-2: the analytics ID at a first sign-in. Decided: reset.** Reset the Google Analytics app-instance ID whenever the last uid recorded on the device differs from the uid signing in, **including when none is recorded** (`last == null`). Also reset when the record cannot be read (fail closed). This extends F11.
  - It replaces TEL-8's rule "no stored uid (first sign-in on the device): no reset". TEL-8 stays as built. TEL-18 changes the code and the tests, including "first sign-in on a device (no record) resets nothing".
  - Cost: one local `resetAnalyticsData()` per device at its first recorded sign-in, and again after an in-app deletion. It adds no GA user: the ID that exists before the first recorded sign-in has never sent an event (TEL-10 section 3.2).
  - C-6 is met by fixing L-1 and L-2 (TEL-18). No ADR-0032 amendment is needed.
- **F13. Q-1: DPDP Act 2023 s. 6(10), proof of consent. Decided: legal review later.** Keep the device-only consent record (F3).
  - Before any **non-team** account is allowlisted for either flag (any TEL-15 step beyond the team's test accounts, any prod raise, TEL-16), legal review decides whether the device-only record is enough.
  - The alternative, a server-side consent log keyed to the account, would undo F3 and ADR-0011 Q10 (f), and needs its own ADR.
  - Tracked as a blocker in "Before release" and in `docs/plans/roadmap.md` section 9, item 3.26. This is not legal advice.

## What exists already (verified on this branch, 2026-11-01)
| Piece | State | Delta |
|---|---|---|
| Packages | `firebase_core`, `firebase_auth`, `firebase_app_check`, `firebase_messaging` (`app/pubspec.yaml`); **no `firebase_crashlytics`, no `firebase_analytics`** | add both (TEL-3) |
| Error hook | `reportUnexpectedError` in `app/lib/app/session_wiring.dart` calls `FlutterError.reportError`. It is wired into about 20 repositories and cubits from `bootstrap.dart` and `app_widget.dart`. Its doc comment says "the Crashlytics handler hooks it", but **no `FlutterError.onError`, `PlatformDispatcher.instance.onError` or `runZonedGuarded` exists**, so today every report goes to the console only | route it to `CrashReporter` (TEL-4); callers unchanged |
| Web | no remote client error reporting at all; server errors reach Cloud Error Reporting through the API's `severity=ERROR` logs | none in this plan (F2) |
| Firebase options | `firebase_options.dart` and `firebase_options_prod.dart` web configs both carry a `measurementId` (`G-FH6BVXB47G`, `G-TRYTXZ3EPG`). That usually means a Google Analytics property and web stream already exist for the project. **Not verified in the console** (TEL-13 checks); the founder said on 2026-11-01 that neither Google Analytics nor Crashlytics is on for dzeroth-prod (privacy maintainer note 21). Nothing is collected today only because the app has no Analytics SDK | TEL-13 |
| Android native config | `app/android/app/google-services.json` is **dzeroth-dev's**, and the google-services Gradle plugin is applied. `release-prod.yml` says native SDK init "(Google Sign-In, Crashlytics) still reads the dev google-services.json". Native Crashlytics and Analytics bind to that config whatever the Dart options say | **TEL-14 must land before either flag leaves off in prod**; until then a prod Android build would report to dzeroth-dev |
| Android manifest | `allowBackup="false"`, FCM channel meta-data; no Firebase data-collection keys | off-switch keys, `AD_ID` removal (TEL-3) |
| iOS | `Info.plist` has no Firebase keys; no `Podfile` and no `GoogleService-Info.plist` in the repo (no Mac, Apple launch paused) | off-switch keys only (TEL-3); the rest TEL-16 |
| Release builds | `flutter build appbundle --release` with no `--obfuscate` or `--split-debug-info`, so Dart stack traces are readable without a symbol upload | none |
| CSP (`firebase.json`, enforced) | `script-src` and `connect-src` have **no** `googletagmanager.com` or `google-analytics.com`, so web Analytics would be blocked even if it started by accident. `firebase.json` is **not** in `.github/CODEOWNERS`, but the CSP is a security control | unchanged; TEL-9 asserts it |
| Policy | "We don't use analytics or a crash-reporting service ... If we add analytics or crash reporting, we will describe it here before we switch it on"; "We do not use advertising or analytics cookies"; retained list "Device-level diagnostics ... tied to your device rather than to your account". Maintainer notes run 1–21. Note 21 (#589) says the app ships neither SDK, records the founder's 2026-11-01 answer that neither product is on for dzeroth-prod in the Firebase console, and says to keep both off there while the text says we use neither | TEL-12 (replaces note 21) |
| Residue rule | ADR-0011 Q10 (f), founder-accepted 2026-10-07: Crashlytics and Analytics data keyed to the device, not the uid; "T20 verifies that the app never sets a user identifier" | becomes a CI guard (TEL-9); no new entry |
| Flags | client-only pattern: `flags.LoadSpec("SHELLS", "shells", flags.Off)` in `config.go`, ceilings dev allowlist 6, no prod block | two more (TEL-2) |
| Opt-in card pattern | `PushOptInCard` / `PushOptInCubit` / `DatabasePushOptInStore` (`AppSettingEntries` key per uid, kept on sign-out, `forget(uid)` on account deletion, Android only through `PushOptIn.supportedOn`) | copied for consent (TEL-7) |
| Readiness | `production-readiness` "Clients: Crashlytics on"; v0.4.0 readiness F14: "no Crashlytics", AAB and IPA not distributed | the line stays valid; see Before release |

## Goal & user value
- **For users:** crashes get found and fixed even when nobody reports them. Today a crash on someone's phone is invisible to us.
- **For the founder:** a few honest numbers answer product questions: are people posting, which composer extras they use, where follows come from, whether search is used, which screens are visited.
- Both are off unless the person says yes. Both are tied to the device, never to the account. The policy says so before anything is collected.

## Scope / Out of scope
**In scope (Stage 0):** both SDKs on Android with collection off at the native level; a single `core/telemetry` seam; crash-payload rules and the scrubber; three events and template screen names; the consent card and Settings switches; account-deletion and account-switch handling on the device; two client-only flags; the policy update; the store and console settings; the Android prod Firebase config; tests, security review, cost note and dev rollout.

**Out of scope (Stage 2/3 version and trigger; TEL-1 proposes this `stage-ladder` row):**
| Concern | Stage 0 (this plan) | Seam to protect | Stage 2/3 target | Trigger (measured, 30 days) |
|---|---|---|---|---|
| Client errors and usage | Crashlytics and Analytics on Android, opt-in, device-level, fixed event list; web console only; server errors in Error Reporting | `CrashReporter` / `UsageAnalytics` in `app/lib/core/telemetry/`; `UnexpectedErrorReporter` stays the only hook callers use; `AnalyticsEvent` is a sealed list; no SDK import outside the adapter files | **Web:** a `ReportClientError` RPC that writes a scrubbed `severity=ERROR` line, so Error Reporting shows it (a new public write: quota, rate limit, security ticket), and/or web Analytics with a consent banner and CSP hosts. **Product analytics:** batch export to BigQuery (roadmap Phase 3; no streaming) | web above 50 % of DAU, or 3 or more user-reported web-only failures in a month that the server logs cannot explain; product questions the free GA reports cannot answer, at Stage 2 (20k DAU) |

Also out: Performance Monitoring; Remote Config (forbidden); A/B tests; ATT prompt (no tracking, no IDFA); Crashlytics NDK; BigQuery export of either product; any account linking (F3).

## Non-functional targets (Stage 0, 0–300 DAU; credit mode changes nothing)
- **Startup:** nothing is awaited before the first frame except one call per SDK that applies the collection state (TEL-4). TEL-11 measures cold start on a low-end Android: target added p50 under 100 ms.
- **Latency of other paths:** unchanged; event logging is fire-and-forget.
- **0 RPCs.** Consent is stored on the device; flags ride on `GetMe`, which the app already calls.
- **Staleness:**
  | Read | Bound |
  |---|---|
  | Flags `crash_reporting`, `analytics` | as of the last `GetMe` (about 4 per DAU per day). A server change reaches a running app on its next `GetMe`. On a cold start the last decision for the restored account applies until then (TEL-4) |
  | Consent | immediate on this device |
  | Reports in the Firebase and GA consoles | Google's processing delay (hours); not our cache |
- **Accessibility (card and Settings rows):** each switch has a label and a state read once, 48 dp targets, nothing by colour alone, no overflow at text scale 2.0; widget tests at 360 / 600 / 1200, light and dark, 1.0 / 1.3 / 2.0.

## Cost (required)
Method: `free-tier-budget` §2, and the margin method of `docs/reviews/cost-model.md` §5 and §11 for the web bundle (as W8). **No RPC is added, so there is no budget row.**
| Item | Delta | Why |
|---|---|---|
| Firestore reads / writes / deletes | **0 / 0 / 0** per DAU per day | consent lives in `AppSettingEntries` on the device |
| Cloud Run requests, vCPU-s | **0** | no RPC; `GetMe` is not called more often |
| `GetMe` response | up to +35 bytes (`crash_reporting`, `analytics`) for callers the flags are on for | the registry reports enabled names only |
| Crashlytics, Google Analytics for Firebase | **INR 0** | no-cost Firebase products (TEL-11 re-checks the Firebase pricing page). No BigQuery link: BigQuery streaming is on the "not used at Stage 0" list, and GA4 and Crashlytics BigQuery exports stay off. No Performance Monitoring, no paid GA tier |
| Egress, Logging, Vision, Pub/Sub, Scheduler, Secret Manager | **0** on our bill | the device uploads straight to Google; no new server log line |
| New GCP resource, `cost-guard` | **none** (no Terraform resource; only flag env vars). Google Analytics is a new Google service, hence the ADR (TEL-1) | |
| Android download size | **+1 to 2 MB** per device (estimate; TEL-11 measures with `bundletool get-size`) | store-hosted, INR 0 |
| Web `main.dart.js` | **+10 to 40 KB gzip** (estimate): the plugins' Dart code is compiled into the one dart2js bundle even though web never calls it | at the margin (`cost-model.md` §1 web share 30 %, about 4.3 prod web releases a month, Hosting free transfer used up at about 2,731 DAU per §4, $0.15/GB past it): INR 0 at 300 and 1,000 DAU; at 3,000 DAU, 900 × 40 KB × 4.3 ≈ 0.15 GB ≈ **INR 2** a month (upper bound) |

**Total: Crashlytics and Analytics INR 0 / 0 / 0; all in, about INR 0 / 0 / 2 a month at 300 / 1,000 / 3,000 DAU** (the web bundle line, upper estimate). No quota crossover moves. Nothing depends on credit mode (ADR-0022). If A4 shows that the web build also fetches `firebase-analytics.js` from `www.gstatic.com` at startup, that is Google's CDN and not our Hosting bill, but it extends the policy's "when you load the web app" bullet (TEL-3 prevents it).

**TEL-17 to TEL-20 (TEL-10 follow-ups, 2026-11-02): INR 0.** A manifest change, client code, tests and docs. 0 RPCs, 0 Firestore operations, no new resource. TEL-18's extra `resetAnalyticsData()` is a local SDK call.

## Flags
| Flag (wire name) | Gates (client only; no RPC) | Kill switch |
|---|---|---|
| `FEATURE_CRASH_REPORTING` (`crash_reporting`) | the crash switch on the consent card and in Settings, and Crashlytics collection. Collection = flag on for the signed-in account **and** that account opted in on this device **and** a supported platform (Android) | `off`: on the next `GetMe`, collection is disabled, unsent reports are deleted and the switch is hidden. The stored choice is kept |
| `FEATURE_ANALYTICS` (`analytics`) | the same for Analytics | `off`: the same for Analytics |

- Registration copies `FEATURE_SHELLS`: `flags.LoadSpec(..., flags.Off)` on one line in `config.go`, `flags.NewRegistry` in `apiserver.go`, tests, Terraform `feature_crash_reporting*` and `feature_analytics*` in `envs/{dev,prod}`, default `off`, not applied.
- **Ceilings** (`scripts/promotion/flag-ceiling.json`, **founder-gated, CODEOWNERS**): both names in `flags`; dev `{"mode": "allowlist", "max_allowlist": 6, "max_percent": 0}`; prod ceiling `on` proposed in TEL-1 and recorded in the runbook (the file has no prod block).
- **Ramp:** dev allowlist (team test accounts, F9) → prod allowlist → prod `on`. Each step is a Terraform change plus the release flow (ADR-0019). Neither flag leaves `off` anywhere before its "Before release" items are done.
- **Retire:** never while the SDKs ship. The flags are the server-side kill switch for a client data flow.

## Abuse & security surface
- **New public reads or writes on our API:** none. No endpoint, nothing to scrape or enumerate.
- **New outbound flow:** device → Google (Crashlytics and Analytics endpoints), after consent only. TEL-9 proves "nothing before consent" with a network trace of a release-mode Android build.
- **Personal data in crash reports:** F6 rules, plus canary tests for each leaky type (TEL-5): `NoSuchMethodError` prints `Receiver: <value>`; `ArgumentError.value` and `RangeError` print the value; `FormatException` from `jsonDecode` includes the source text; `PlatformException` can carry file paths; `FlutterErrorDetails.context` can render `Text("<data>")`; `ConnectException` messages come from the server. These rules cover Dart errors only. An uncaught Java or Kotlin exception in Android's own code carries its own message to Crashlytics, not scrubbed, which can include a file name (ADR-0032 note 2026-11-02, TEL-10 L-3, TEL-19).
- **Linkability to accounts:**
  - no user id, no user properties, no flag list in custom keys (F3, F6);
  - the server stores an FCM token per uid (`deviceTokens`), and FCM tokens are issued per Firebase installation, so TEL-10 confirms that no Crashlytics or Analytics identifier can be joined to them;
  - two accounts on one device share one app-instance ID unless it is reset (F11);
  - during an allowlist ramp, reports come only from a few known people: pseudonymous but recognisable to us. That is acceptable for team testers; the runbook says not to try to match them.
- **Consent bypass:**
  - native auto-init: the off keys in the manifest and plist;
  - the enabled state is persisted by the SDKs across launches (A6): TEL-4 re-applies the decision at bootstrap;
  - reports cached while collection was off: deleted whenever the decision is "off";
  - the advertising ID: `AD_ID` removed from the **merged** manifest.
- **Web:** no Analytics, no Crashlytics; CSP unchanged as a second fence (TEL-9).
- **Fake data:** the measurement ID and API keys are public, so anyone can send fake events or crashes to our projects. That costs us nothing; the numbers are never used for security, billing or moderation decisions.
- **Supply chain:** official FlutterFire packages only; `osv-scanner` on `pubspec.lock`.

## Dependencies & open questions
**Dependencies:**
- **TEL-14 before any prod raise** (prod Android config).
- **TEL-12 live before any non-team account is allowlisted** (F9).
- **The Apple launch** before TEL-16.
- **Legal review of Q-1 (F13)** before any non-team account (roadmap 3.26).
- **Shared files:**
  - `config.go`, `apiserver.go`, `flag-ceiling.json` and the Terraform `feature_*` files serialise with every flag ticket;
  - `settings_screen.dart` and the Home card slot serialise with any wave adding a Settings row or a Home card;
  - `release-prod.yml` is a gate file (TEL-14 needs your review).

**Questions for @architect (TEL-1 answers them in the ADR):**
- **A1. ADR needed?** Yes: a new data flow to Google, Google Analytics terms, a consent model, the rule 10 reading (F8) and the Q10 (f) confirmation. The next free number (0032 at the time of writing).
- **A2. Terms.** Which terms cover each product? Is Crashlytics under the Firebase Data Processing and Security Terms? Is Analytics under the Google Analytics Terms with data processing terms accepted in GA admin? Is Google a processor for both, given F5's sharing settings? This is a gate for TEL-12.
- **A3. Retention and IP.** Crashlytics retention (believed 90 days), the GA minimum event retention (believed 2 months), GA4 IP handling and Crashlytics IP handling, from Google's docs at the time of writing.
- **A4. Web.** With `firebase_analytics` in pubspec, does `firebase_core_web` load `firebase-analytics.js` or start Analytics at `Firebase.initializeApp`? If yes, TEL-3 uses `window.flutterfire_ignore_scripts = ['analytics']`. That is an inline script, so it needs a new CSP `sha256` in `firebase.json`.
- **A5. Off-switch keys.** Use `firebase_analytics_collection_enabled=false` (iOS `FIREBASE_ANALYTICS_COLLECTION_ENABLED` NO), **not** `firebase_analytics_collection_deactivated`. The latter is believed to be permanent and could never be turned on at runtime, which would break the flag and consent path. Confirm. Also confirm `firebase_crashlytics_collection_enabled=false` (iOS `FirebaseCrashlyticsCollectionEnabled` NO), and that the Firebase Sessions SDK sends nothing while Crashlytics collection is off.
- **A6. Persistence and cache.** Do `setCrashlyticsCollectionEnabled` and `setAnalyticsCollectionEnabled` persist across launches (believed yes)? Does turning Crashlytics on upload reports recorded while it was off (believed yes, hence `deleteUnsentReports`)? With app consent mode, does denied `analytics_storage` send anything?
- **A7. Automatic events.** The exact automatic events and user properties on Android, including the FCM notification events and the Crashlytics `app_exception` and breadcrumb integration with Analytics.
- **A8. Proposed lines for gate files.** A `CLAUDE.md` reference-architecture line for Analytics, and the `stage-ladder` row above. Both files are CODEOWNERS gates; TEL-1 proposes them, you review.

## TEL-10 follow-ups (added 2026-11-02)
Source: `docs/reviews/security/security-client-telemetry.md` (CLEAR WITH CONDITIONS, #638). Every finding has a home below. The report's proposed tickets are TEL-17 to TEL-20. Its device and console checks stay in TEL-9 Part B.

| Finding | Severity | Goes to | Gate |
|---|---|---|---|
| M-1: the AdServices advertising-ID and attribution permissions stay in the merged manifest | Medium | TEL-17 | C-2: before the dev allowlist, and before TEL-13 answers the Play Data safety and Advertising ID questions |
| M-2: the Firebase installation ID (FID) may be joinable with the FCM token we store per uid | Medium | TEL-9 Part B item (below); a fix only if joinable | C-3: the check before the dev allowlist; any fix before any non-team account |
| L-1: no delete of unsent reports before crash collection turns on | Low | TEL-18 | C-6: before any prod raise |
| L-2: gaps in the first-sign-in reset | Low | TEL-18, per F12 | C-6: before any prod raise |
| L-3: native (Java or Kotlin) crash messages are not scrubbed | Low | TEL-19 (ADR note, done #645: ADR-0032 note 2026-11-02); TEL-9 Part B trace (b) records a native crash | C-5: TEL-12 item 6 carries the sentence |
| L-4: forged reports can trip the rollback trigger | Low | TEL-20 (runbook triage and BoM re-check, done #646); TEL-13 (no Measurement Protocol `api_secret`; the runbook says never create one) | before any prod raise |
| I-1: `breadcrumb()` is public and not gated | Info | TEL-18 (deleted until it has a caller) | none |
| Q-1: DPDP s. 6(10) proof of consent | question | F13, legal review | before any non-team account |

**Conditions (report section 5):**
- **C-1** TEL-9 device evidence: TEL-9 Part B. Before the dev allowlist.
- **C-2** M-1: TEL-17, then the merged-manifest permission line of TEL-9 Part B on its build. Before the dev allowlist.
- **C-3** M-2: the TEL-9 Part B item below. The check before the dev allowlist; any fix before any non-team account.
- **C-4** notification events in DebugView: TEL-9 Part B (test report §6b) or the TEL-15 smoke. Before any non-team account.
- **C-5** TEL-12 wording (M-1, L-3, ADR C1 and C2, the C-3 result): TEL-12, with TEL-17, TEL-19 and the C-3 result as inputs. At the TEL-12 merge. TEL-19's input is done (#645): the sentence is in ADR-0032's note of 2026-11-02. C-5 stays open until TEL-12 carries it.
- **C-6** L-1 and L-2: TEL-18. Before any prod raise.

**No ticket (one line each):**
- **I-2:** the CSP's `img-src https:` would pass an image beacon only if a GA script ran; the ignored script and the missing gtag host in `script-src` already stop that, and TEL-9 guards both. (This plan's "`firebase/firebase.json`" means the root `firebase.json`.)
- **I-3:** the Sessions settings host `firebase-settings.crashlytics.com` is already in the TEL-9 Part B fence for states 1 and 2 (test report §6b, C-1).
- **I-4:** the dev ceilings match F7; prod is gated by this plan's review and ADR-0019, as for every flag.
- **I-5:** wording only: the `AppSettingEntries` doc comment "holds no personal data" is out of date. No behaviour changes, and `app_database.dart` is shared, so fix it the next time a ticket edits that file.
- **I-6:** verified. Whether the FCM `data` keys reach GA is C-4's check.
- **I-7:** accepted. Consent still holds, and the runbook's next-launch wording covers it.

**TEL-9 Part B: what the device session covers.** The procedure is `docs/reviews/tests/test-report-client-telemetry.md` sections 6 and 6b; nothing here changes it.
- Run it once, on a dev build from `main` with TEL-17 and TEL-18 merged. Then C-2 passes on the same build, and trace (a) shows L-1's fix. TEL-18 is not a dev gate: if it lags, run Part B without it and repeat only trace (a) later.

| Item | Test report | Needs the founder's phone | Needs the founder's dzeroth-dev console |
|---|---|---|---|
| Merged-manifest permissions (C-2) | §6 step 1, §6b C-2 | no: a local release APK and `aapt2 dump permissions` (TEL-17 does it first) | no |
| Network traces, states 1 to 4, incl. `firebase-settings.crashlytics.com` (C-1) | §6 step 2, §6b C-1 | yes | no |
| Web trace (C-1) | §6b C-1 | no: a desktop browser | no |
| **M-2 (C-3), part 1:** FCM token prefix versus the FID, from logcat with the debug log tags; record only "equal" or "not equal", never the values; no `getId` call in app code | §6b C-3 / M-2 | yes | no |
| **M-2 (C-3), part 2:** every field of a test crash (device info, keys, logs) checked for the FID | §6b C-3 / M-2 | yes, to raise the crash | yes, read only |
| Notification events carry no ids, title or body (C-4) | §6b C-4 | yes, to receive the pushes | yes (DebugView) |
| Native crash: trace (b) (C1 residual, L-3) and trace (a) (L-1) | §6 step 3, §6b L-3; ADR-0032 Handoff | yes | yes |

- **C-3 does not wait for a forced fatal.** Part 2 needs only some test crash in dzeroth-dev. A non-fatal through a real `reportUnexpectedError` path, flushed by force-stop and relaunch (§6 step 3, option (b)), is enough. Only the native traces (a) and (b) need an answer to §6 step 3's open question.
- **Open question: how to force a native crash in a release build** (§6 step 3; owner frontend-developer or architect). **Proposed default:** a throwaway scratch build, never merged (as TEL-10 proposes for the M-2 logcat), that throws a Kotlin exception. No production seam.
- **Open question: Part B needs the flags on, and TEL-15 waits for Part B.** Part B's prerequisites (test report §6) put one dev test account on both allowlists. **Proposed default:** that targeted, plan-then-OK allowlist of one test account is an evidence step, not "the dev allowlist" of "Before release". TEL-15 widens it to the team's test accounts.
- **M-2 outcome.**
  - If the token prefix equals the FID **and** a dzeroth-dev Crashlytics view shows the FID: open the next free TEL ticket then. It covers the architect's ADR-0032 D9 note, the TEL-12 wording ("Google can link these to the push registration; we do not") and the runbook rule "never compare `devices.token` with console data". It gates any non-team account.
  - If either is false: the security-auditor records the evidence in the M-2 row and issues the unqualified line of the report's section 4.
  - Either way, the result is recorded in the security report (C-3) before TEL-12 merges, because TEL-12's "not linked to your account" depends on it (C-5).

## Milestones
1. **M1 Contract:** TEL-1 (ADR) ‖ TEL-2 (flags) ‖ TEL-14 (prod Android config).
2. **M2 Client, collection off:** TEL-3 → TEL-4 → TEL-5 ‖ TEL-6 ‖ TEL-7 → TEL-8.
3. **M3 Verify:** TEL-9 ‖ TEL-10 ‖ TEL-11.
4. **M4 Policy and stores:** TEL-12 (drafted in parallel with M2; merged after TEL-1 is Accepted and F1–F6, F8 and F11 are answered) → TEL-13.
5. **M5 Roll:** TEL-15 (dev; prod prepared). TEL-16 only at the Apple launch.
6. **M6 TEL-10 follow-ups (added 2026-11-02):** TEL-17 ‖ TEL-18 ‖ TEL-19 ‖ TEL-20, all startable now, with no shared file except TEL-20 and TEL-13 (the runbook). TEL-17 and the TEL-9 Part B session gate TEL-15. TEL-18 and TEL-20 gate the prod raise. TEL-19 and the M-2 result feed TEL-12.

| ID | Ticket | Owner | Size | Depends | Parallel | Status |
| --- | --- | --- | --- | --- | --- | --- |
| TEL-1 | ADR: client crash reporting and usage analytics (data inventory, terms, consent, rule 10, Q10 (f), A1–A8, proposed `CLAUDE.md` and `stage-ladder` lines, prod ceiling) | architect | M | — | **yes, start now** | Done (#595) |
| TEL-2 | `FEATURE_CRASH_REPORTING` + `FEATURE_ANALYTICS` registration, ceilings (gate), Terraform vars, runbook `client-telemetry.md` | backend-developer | S | — | **yes, start now**; shared flag files: one PR at a time | Done (#597) |
| TEL-3 | Packages and native off-switches (pubspec, AndroidManifest incl. `AD_ID` removal, `Info.plist`, web scripts) | frontend-developer | S | TEL-1 drafted (A4, A5) | yes | Done (#598) |
| TEL-4 | `core/telemetry` seam: `CrashReporter`, `UsageAnalytics`, `TelemetryController` (flag × consent × platform × auth), error hooks | frontend-developer | M | TEL-3 | yes | Done (#608) |
| TEL-5 | Crash payload rules and `CrashScrubber`, with canary tests | frontend-developer | S | TEL-4 | yes | Done (#609) |
| TEL-6 | Analytics events (sealed list) and template screen names | frontend-developer | S | TEL-4 | yes | Done (#611) |
| TEL-7 | Consent card, Settings switches, `TelemetryConsentStore` | frontend-developer | M | TEL-4; F1 | Settings and Home card files: one PR at a time | Done (#612) |
| TEL-8 | Account deletion and account switch on the device: forget consent, delete unsent reports, reset the analytics ID; runbook lines | frontend-developer | XS | TEL-7 | yes | Done (#635) |
| TEL-9 | Tests: guards (imports, no user id, manifest and plist values, CSP hosts), decision matrix, canaries end to end, release-build network trace | tester | M | TEL-5 to TEL-8 | yes | Code part merged (#640); device evidence (Part B) pending |
| TEL-10 | Security review: payloads, linkability, consent bypass, web, terms | security-auditor | S | TEL-5 to TEL-8 (TEL-9 evidence) | yes | CLEAR WITH CONDITIONS (#638); follow-ups ticketed as TEL-17 to TEL-20, conditions C-1 to C-6 open |
| TEL-11 | Cost and performance note: INR 0 line, AAB and web bundle deltas, cold start on a low-end Android; `cost-model.md` section | sre-performance | XS | TEL-3, TEL-4 | yes | Open |
| TEL-12 | Privacy Policy update (sentence list in the ticket) | architect (draft) + founder (approval) | S | TEL-1 Accepted; F1–F6, F8, F11; C-5: TEL-17, TEL-19 and the M-2 result (C-3) | yes (`privacy.html`: one PR at a time) | Open |
| TEL-13 | Store forms and console settings: Play Data safety, App Store label text (prepared for the Apple launch), GA property settings (F5) in dev and prod, the `measurementId` check | production-deployer (prepares) + founder (consoles) | XS | TEL-12 text | yes | Open |
| TEL-14 | Prod Android builds use dzeroth-prod's `google-services.json` (`release-prod.yml`, gate file) | production-deployer | S | — | **yes, start now** | Done (#593; device check 2026-11-01) |
| TEL-15 | Dev rollout (targeted Terraform plan, allowlist, dev Android build, smoke with network trace); prod change prepared, not applied | production-deployer | S | TEL-9 incl. Part B (C-1) and its M-2 check (C-3), TEL-10, TEL-11; TEL-12 on dev Hosting; TEL-13 dev settings; TEL-17 (C-2, M-1) | serialise dev applies | Open |
| TEL-16 | *(conditional: Apple launch)* iOS: Podfile without AdId support, dSYM upload, privacy manifest, `TelemetryPlatforms` adds iOS, App Store label, policy note 16 | frontend-developer + founder | S | Apple launch, TEL-15 | — | Open (conditional) |
| TEL-17 | *(TEL-10 M-1, C-2)* Remove the two AdServices permissions from the merged manifest; extend the TEL-9 manifest guard; dump a local release APK's permissions | frontend-developer | S | — | yes (Android manifest and `app/test/guards/` only) | Open |
| TEL-18 | *(TEL-10 L-1, L-2, I-1; C-6)* Delete unsent reports before crash "on"; reset the analytics ID with no record or an unreadable record (F12); delete the ungated `breadcrumb()` | frontend-developer | S | — | yes (`core/telemetry` and its tests; no file shared with TEL-17) | Done (#643) |
| TEL-19 | *(TEL-10 L-3, C-5)* ADR-0032 dated note: native crash messages are not scrubbed; the sentence for TEL-12 item 6 | architect | XS | — | yes (ADR-0032 only) | Done (#645) |
| TEL-20 | *(TEL-10 L-4)* Runbook triage before a reported leak counts as one; re-check the merged permissions at every Firebase BoM bump | sre-performance | XS | — | `client-telemetry.md`: one PR at a time with TEL-13 | Done (#646) |

**Definition of done per ticket:** `make ci` green; widget tests for every new widget at 360 / 600 / 1200, light and dark, text scale 1.0 / 1.3 / 2.0 via `test/support/theme_harness.dart`; `docs/ui-catalog.md` and `docs/code-map.md` updated for shared items; this table's Status updated in the PR.

## Tickets

### TEL-1 — ADR: client crash reporting and usage analytics  [owner: architect] [size: M] [depends: —]  Status: Done (#595)
- **Description.** A Proposed ADR, the next free number. It contains:
  - a data inventory per SDK: what is sent, which identifiers (Crashlytics installation UUID, Firebase installation ID, GA app-instance ID), to which hosts, and retention;
  - answers to A1–A8 from Google's documentation, cited with dates;
  - the consent model (F1), the platforms (F2), no linking (F3), the event list (F4), the console settings (F5), the payload rules (F6) and the rule 10 reading (F8; a bend if you say so);
  - a dated confirmation that Q10 (f) covers the residue, so no new entry is needed, and that its "T20 verifies" condition becomes the TEL-9 guard;
  - the proposed prod ceiling `on`;
  - the cost section (this plan: INR 0 / 0 / 2);
  - the proposed `stage-ladder` row and `CLAUDE.md` reference-architecture line, as text for you to apply (both files are CODEOWNERS gates).
- **Acceptance criteria.**
  - Given the ADR, then every A-question has an answer with a source, or is marked UNVERIFIED with the test that will settle it (TEL-9 network trace).
  - Given A2, then the ADR names the terms for each product and whether Google is a processor.
  - Given the ADR merged by you, then it is Accepted and TEL-12 may merge.
- **Test notes.** None (docs). `code-reviewer` checks the seam and trigger lines.
- **Observability.** —
- **Budget.** 0.
- **Flag.** Names both flags and the ceiling proposal.
- **Seam.** Defines the seam TEL-4 builds and the Stage 2/3 row.

### TEL-2 — Flag registration  [owner: backend-developer] [size: S] [depends: —]  Status: Done (#597)
- **Description.** Follow `FEATURE_SHELLS` (W8-1) line for line:
  - `config.go`: `FeatureCrashReporting` and `FeatureAnalytics` with doc comments ("client-only ... no RPC is gated"); `LoadSpec` on one line each;
  - copies of `shells_test.go`; the env names in the test env list; both in `flags.NewRegistry`;
  - `flag-ceiling.json`: both names, dev allowlist 6, percent 0 (gate, your review);
  - Terraform `feature_crash_reporting*` and `feature_analytics*` variables with validations, in `envs/dev` and `envs/prod`, default `off`, not applied;
  - `docs/runbooks/client-telemetry.md`: gates, consent, cost 0, ramp, kill switch. Failure modes:
    - personal data seen in a crash or event: flag off; fix the scrubber; delete the data with GA's data deletion request and the Crashlytics console, as TEL-1 confirms is possible;
    - traffic before consent;
    - a crash spike after an SDK update;
    - prod reports landing in dzeroth-dev (TEL-14).
- **Acceptance criteria.**
  - Given both flags unset, then the startup `feature_flags` line lists them off and `GetMe` never reports them.
  - Given `allowlist` with one uid, then only that uid gets the name.
  - Given an invalid value, then startup fails.
  - Given `scripts/promotion` checks, then `check-flag-registry.sh` passes.
- **Test notes.** The registry tests for the four modes; `terraform fmt -check` and `validate`.
- **Observability.** The startup `feature_flags` line.
- **Budget.** 0 reads, 0 writes (env vars, ADR-0008 D6).
- **Flag.** Adds both.
- **Seam.** The flags are client gates only; the server stays authoritative through `GetMe`.

### TEL-3 — Packages and native off-switches  [owner: frontend-developer] [size: S] [depends: TEL-1 drafted]  Status: Done (#598)
- **Description.**
  - `firebase_crashlytics` and `firebase_analytics` in `app/pubspec.yaml`, at versions matching the current FlutterFire BoM.
  - `AndroidManifest.xml` `<application>` meta-data:
    - `firebase_crashlytics_collection_enabled` false;
    - `firebase_analytics_collection_enabled` false (**not** `_deactivated`, A5);
    - `google_analytics_adid_collection_enabled` false;
    - `google_analytics_ssaid_collection_enabled` false;
    - `google_analytics_default_allow_analytics_storage`, `_ad_storage`, `_ad_user_data` and `_ad_personalization_signals` false;
    - `google_analytics_automatic_screen_reporting_enabled` false.
  - Plus `<uses-permission android:name="com.google.android.gms.permission.AD_ID" tools:node="remove"/>`.
  - `Info.plist`: `FirebaseCrashlyticsCollectionEnabled` NO, `FIREBASE_ANALYTICS_COLLECTION_ENABLED` NO, the `GOOGLE_ANALYTICS_DEFAULT_ALLOW_*` keys NO, `FirebaseAutomaticScreenReportingEnabled` NO, and `GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED` NO if TEL-1 confirms the key.
  - **Web:** if A4 says the Analytics script loads or starts at init, add `flutterfire_ignore_scripts` and update the CSP hash. Otherwise no web change.
  - No call to either SDK outside TEL-4's adapter files.
- **Acceptance criteria.**
  - Given a release Android build, when its **merged** manifest is inspected, then every key above has the off value and there is no `AD_ID` permission.
  - Given a fresh install with no flag and no consent, then a network trace shows no request to the Crashlytics, Firebase Sessions or Analytics hosts listed in TEL-1 (FCM and Firebase Installations traffic already exists and is excluded).
  - Given the web build, then no request goes to `googletagmanager.com` or `google-analytics.com` and the browser reports no CSP violation.
- **Test notes.** Merged-manifest check scripted (`apkanalyzer` or `aapt2 dump xmltree`); the bundle sizes before and after go to TEL-11.
- **Observability.** —
- **Budget.** 0.
- **Flag.** None yet; collection is off by construction.
- **Seam.** The SDKs exist only behind TEL-4's adapters.

### TEL-4 — `core/telemetry` seam and decision  [owner: frontend-developer] [size: M] [depends: TEL-3]  Status: Done (#608)
- **Description.** `app/lib/core/telemetry/`, the `analytics/` slot of the `flutter-feature` blueprint, named for both concerns:
  - **Interfaces:** `CrashReporter` (`record(error, stack, {fatal})`, `setCollecting(bool)`) and `UsageAnalytics` (`log(AnalyticsEvent)`, `screen(String name)`, `setCollecting(bool)`, `resetDevice()`).
  - **Implementations:** Firebase implementations in `firebase_crash_reporter.dart` and `firebase_usage_analytics.dart`, the **only** files importing the SDKs; `Noop` implementations for web, iOS (until TEL-16) and tests; `TelemetryPlatforms.supportedOn = {android}`.
  - **`TelemetryController`:** collecting = platform supported **and** a signed-in uid **and** the flag in `enabled_features` **and** consent stored for that uid. It is applied:
    - at bootstrap, right after `Firebase.initializeApp`, from the last decision stored for the restored uid (because A6 persistence means the native state can be stale);
    - again after each `GetMe`, each auth change and each consent change.
  - Every "off" decision also calls `deleteUnsentReports()`. Sign-out means off.
  - **Error hooks (no loop):**
    - `FlutterError.onError` is the single sink. It calls `FlutterError.presentError` in debug builds, then `CrashReporter.record` through TEL-5's rules.
    - `reportUnexpectedError` is unchanged: it still calls `FlutterError.reportError`, which reaches that sink. `UnexpectedErrorReporter` and its call sites do not change.
    - `PlatformDispatcher.instance.onError` calls `CrashReporter.record` directly.
    - Fix the stale comment "the Crashlytics handler hooks it".
- **Acceptance criteria.**
  - Given a report through `reportUnexpectedError`, then the fake adapter receives it exactly once and `FlutterError.onError` is not re-entered.
  - Given the 2 × 2 × 2 × 2 matrix (flag, consent, platform, signed in), then collection is on in exactly one cell, verified on fake adapters.
  - Given the flag turning off in a `GetMe`, then `setCollecting(false)` and `deleteUnsentReports` are called before the next `record`.
  - Given a direct switch from account A (opted in) to account B (not), then collection is off before any report attributed to B's session.
  - Given web, then `Noop` is used and no SDK method is called.
- **Test notes.** Unit tests with fake adapters and a fake clock; the bootstrap order test.
- **Observability.** A debug-only log of the decision changes (never in release).
- **Budget.** 0 RPCs.
- **Flag.** `crash_reporting`, `analytics`.
- **Seam.** `CrashReporter` / `UsageAnalytics`. A web `ReportClientError` implementation or another vendor replaces an adapter with no caller change.

### TEL-5 — Crash payload rules and scrubber  [owner: frontend-developer] [size: S] [depends: TEL-4]  Status: Done (#609)
- **Description.** `CrashScrubber` and the F6 rules inside `FirebaseCrashReporter`:
  - type and stack always;
  - the message only for allowlisted types, scrubbed and cut to 200 characters;
  - `ConnectException` → code and `ErrorReason` only;
  - `FlutterErrorDetails` → exception and stack only, without `context` or `informationCollector` (use `recordError`, not `recordFlutterError`);
  - custom keys: build number, `FIREBASE_ENV`, platform;
  - breadcrumbs: constants from one file.
- **Acceptance criteria.** Given a canary string `ZZCANARY123456789` placed in each of the following, then no argument passed to the fake Crashlytics adapter contains the canary or a 6-digit run:
  - a `Text` that throws in build;
  - `jsonDecode` input;
  - a `NoSuchMethodError` receiver;
  - an `ArgumentError.value`;
  - a `RangeError`;
  - a `PlatformException` message and details;
  - a `ConnectException` message;
  - a GoRouter "no route" location;
  - an email and an @handle.
- **Test notes.** One test per row; a property test of the scrubber over random strings with embedded ids and emails.
- **Observability.** —
- **Budget.** 0.
- **Flag.** `crash_reporting`.
- **Seam.** The scrubber is one function, shared by any future web reporter.

### TEL-6 — Analytics events and screen names  [owner: frontend-developer] [size: S] [depends: TEL-4]  Status: Done (#611)
- **Description.**
  - `sealed class AnalyticsEvent` with `PostCreated`, `FollowMade` and `SearchUsed` (F4). The parameters are Dart enums and bools, so free text cannot compile.
  - `screenNameFor(GoRouterState)` maps `state.fullPath` (the template) through a fixed table; unmapped → `other`; never `uri` or `matchedLocation`. A router listener calls `UsageAnalytics.screen`.
  - Call sites, success paths only: composer success (post, reply, quote; media, poll, scheduled); `FollowButton` success with its source; a search submit or result tap.
- **Acceptance criteria.**
  - Given `/post/123`, `/u/alice`, `/messages/<id>` and a search URL with a query, then the screen names are `post_detail`, `profile`, `message_thread` and `search`, and no id, handle or query reaches the adapter.
  - Given a failed post, then no `post_created`.
  - Given every route constant in `AppRouter`, then each maps to a name or to `other` (table test).
- **Test notes.** Fake adapter; a route table test.
- **Observability.** —
- **Budget.** 0.
- **Flag.** `analytics`.
- **Seam.** `AnalyticsEvent` is the only event vocabulary; a new event changes the policy in the same PR (runbook rule).

### TEL-7 — Consent card and Settings switches  [owner: frontend-developer] [size: M] [depends: TEL-4; F1]  Status: Done (#612)
- **Description.**
  - `TelemetryConsentStore`, a copy of `DatabasePushOptInStore`: `AppSettingEntries` keys `telemetry_consent:crash:<uid>` and `telemetry_consent:usage:<uid>` (on, off or unasked), kept on sign-out, `forget(uid)` on deletion.
  - `TelemetryConsentCard` at the top of Home (the `PushOptInCard` slot rules; one card at a time, push first). It is shown on Android when either flag is on for the account and that kind is unasked, with two switches (off), "Save" and "Not now", one sentence each on what is sent, "not linked to your account", and the Privacy Policy link.
  - Settings › Privacy & safety: the rows "Send crash reports" and "Share usage statistics", with switches, shown only while the matching flag is on, with the subtitle "This device only. Not linked to your account."
  - The final copy is approved by you in this PR, together with TEL-12.
  - If F1 is (B), the crash row starts on and the card becomes a notice.
- **Acceptance criteria.**
  - Given the flag on and nothing asked, then the card shows once; "Not now" stores off for both and it never shows again.
  - Given a switch turned off in Settings, then collection stops immediately (TEL-4).
  - Given both flags off, then no card and no rows.
  - Given web, then no card and no rows.
  - Given a screen reader, then each switch reads its label and state once.
  - Given text scale 2.0 at 360 dp, then no overflow.
- **Test notes.** Widget tests over the matrix; store tests with two uids on one device.
- **Observability.** —
- **Budget.** 0 RPCs.
- **Flag.** Both.
- **Seam.** The store and card are per kind, so a third kind (a web banner later) adds a key, not a new mechanism.

### TEL-8 — Deletion and account switch on the device  [owner: frontend-developer] [size: XS] [depends: TEL-7]  Status: Done (#635)
- **Description.**
  - In-app Delete account (before `/account-deleted`): `TelemetryConsentStore.forget(uid)`, `deleteUnsentReports()` and `UsageAnalytics.resetDevice()` (the SDK's `resetAnalyticsData()`), through `TelemetryController.forgetDevice(uid)` so they keep the controller's order.
  - On sign-in of a different uid than the last one on this device (stored in `AppSettingEntries` as `telemetry_last_uid`): `UsageAnalytics.resetDevice()` (F11), queued by the controller before that uid's first event. Same uid again, or no stored uid (first sign-in on the device): no reset. *(Superseded by F12, 2026-11-02: a missing or unreadable record also resets; TEL-18 changes the code.)*
  - Runbook lines:
    - `account-deletion.md` §7, the email answer: crash reports and usage statistics are device-level and cannot be found by account (Q10 (f)). To clear them, the user deletes in the app or clears the app's data.
    - §3b: no manual step.
- **Acceptance criteria.**
  - Given an in-app deletion, then the consent keys for that uid are gone and both reset calls ran (fake adapters).
  - Given account B after A on one device, then the reset ran before B's first event.
- **Test notes.** Unit and widget tests on the delete flow.
- **Observability.** —
- **Budget.** 0.
- **Flag.** Both.
- **Seam.** No server eraser step; Q10 (f) unchanged.

### TEL-9 — Tests and evidence  [owner: tester] [size: M] [depends: TEL-5 to TEL-8]  Status: Code part merged (#640); device evidence (Part B) pending
- **Description.**
  - Guard tests:
    - only the two adapter files import `firebase_crashlytics` or `firebase_analytics`;
    - no `setUserIdentifier`, `setUserId`, `setUserProperty` or `setDefaultEventParameters` anywhere;
    - `setCustomKey` only with the three allowed keys;
    - the manifest and plist keys exist with the off values;
    - the `firebase.json` CSP has no `googletagmanager.com` or `google-analytics.com`.
  - The TEL-4 matrix end to end; the TEL-5 canaries through `reportUnexpectedError`.
  - **Evidence:** a release-mode dev Android build with network traces in three states (no consent; consent with flag off; consent with flag on). The first two show no Crashlytics, Sessions or Analytics traffic. The third shows a forced test crash in the dzeroth-dev Crashlytics console and DebugView events with no id, handle or text.
  - Report in `docs/reviews/tests/test-report-client-telemetry.md`.
- **Acceptance criteria.** VERDICT PASS with the three traces attached; every guard fails when its rule is broken (mutation check).
- **Test notes.** Includes the Q10 (f) check ("the app never sets a user identifier").
- **Observability.** —
- **Budget.** 0.
- **Flag.** Both.
- **Seam.** The guards pin the seam.

### TEL-10 — Security review  [owner: security-auditor] [size: S] [depends: TEL-5 to TEL-8]  Status: CLEAR WITH CONDITIONS (#638); follow-ups ticketed as TEL-17 to TEL-20, conditions C-1 to C-6 open
- **Description.** Against `security-checklist`:
  - the F6 rules and canaries;
  - linkability (custom keys, flag lists, `deviceTokens` versus SDK identifiers, the app-instance ID across accounts);
  - consent bypass (persistence, cached reports, `AD_ID` in the merged manifest);
  - web (no SDK traffic, CSP);
  - the terms (A2);
  - fake-data abuse.

  Report in `docs/reviews/security/security-client-telemetry.md`.
- **Acceptance criteria.** SECURITY CLEAR, with 0 Critical or High open and an explicit line: "no identifier sent to Google is keyed to or joinable with a uid".
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Confirms the ceilings match F7.
- **Seam.** Confirms that no SDK call bypasses `core/telemetry`.

### TEL-11 — Cost and performance note  [owner: sre-performance] [size: XS] [depends: TEL-3, TEL-4]  Status: Open
- **Description.**
  - Re-check the Firebase pricing page for both products (no cost; no BigQuery link).
  - Measure the `main.dart.js` delta with the `cost-model.md` §11 build and the AAB download size with `bundletool get-size total`.
  - Measure cold start on a low-end Android, before and after.
  - Add a `cost-model.md` section ("client telemetry: 0 reads, 0 writes, 0 requests").
- **Acceptance criteria.** BUDGET: HOLDS; measured deltas recorded in this plan's Cost section; cold start p50 delta under 100 ms or a finding.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** —
- **Seam.** —

### TEL-12 — Privacy Policy update  [owner: architect (draft) + founder (approval)] [size: S] [depends: TEL-1 Accepted; F1–F6, F8, F11; C-5: TEL-17, TEL-19 and the M-2 result (C-3)]  Status: Open
- **Description.** Changes to `app/web/privacy.html`, in plain language like the rest of the page:
  0. **Re-check first.** This list was drafted against the #584 text and checked against #589 (maintainer notes 1–21). If a later refresh is on `main` when this ticket starts, re-read the page and add any new sentence about analytics, crash reporting, cookies or diagnostics to this list.
  1. **Header comment and maintainer notes.** Add TEL-12 and the ADR to the "Draft — last updated" line. Replace note 21 (#589: "we ship neither ... keep both off there while the text says we use neither"), which this change makes untrue, with: "Crash reports and usage statistics are Android only. Before either is switched on for iPhone (TEL-16) or the web, update 'Crash reports and usage statistics', 'Who we share it with', 'On your device' (web Analytics sets cookies) and the store forms. The events are the list in `app/lib/core/telemetry/analytics_events.dart`; a new event or parameter changes this page in the same PR." Extend note 16 with "and crash reports and usage statistics on iPhone".
  2. **"Last updated".** The merge date.
  3. **Data we collect, "On your device".** Keep "We do not use advertising or analytics cookies" (still true: no web Analytics, F2). Add: "On Android, if you allow crash reports or usage statistics, Google's software keeps a random ID on the device to send them."
  4. **Data we collect, new bullet.** "**Crash reports and usage statistics.** Only in the Android app and only if you allow them. See 'Crash reports and usage statistics' below."
  5. **Why we collect it.** "To debug problems and keep the app reliable" gains ", including, if you allow it, from crash reports sent by the Android app". New bullet: "If you allow it, to learn which features of the Android app are used, from usage statistics that are not linked to your account."
  6. **New section "Crash reports and usage statistics"** (before "Who we share it with"). Bullets:
     - **Off unless you allow it**, asked in the app, changeable any time in Settings › Privacy & safety, per account on each device.
     - **What a crash report contains:** the error type and where in the app's code it happened, the app version, the device model, Android version, free memory and storage, and the time. Never the text you wrote or saw.
     - **What usage statistics contain:** the fixed list from F4 (posting, with what kind of content but not the content; following and from which screen; using search, but not what you searched for; which screens you open, by type) and Google's automatic app events (first open, sessions and time in the app, app and Android updates, removal, and push notifications received or opened, as TEL-1 lists them), with the app version, device model, Android version, language and country.
     - **Never included:** your account ID, handle, email, posts, messages or searches; no advertising ID.
     - **Not linked to your account:** tied to a random ID on the device, which is reset when a different account signs in there or when you delete your account in the app.
     - **Not on the web or iPhone yet.**
     - **How long and where:** as in A3.
  7. **Who we share it with.** In the Google bullet's processor list, add "Firebase Crashlytics (crash reports from the Android app, if you allow them)". Add Google Analytics for Firebase with the terms A2 names. The A2 answer decides whether "We use Google as a processor" covers both.
  8. **The paragraph "We don't use analytics or a crash-reporting service, and the app shows no advertising. If we add analytics or crash reporting, we will describe it here before we switch it on."** Replace it with "The app shows no advertising. Crash reports and usage statistics are described above: they are off unless you allow them, and only in the Android app." The reCAPTCHA sentences stay.
  9. **Where your data is stored.** Add "Crash reports and usage statistics are processed by Google, which does not let us choose a region, so they may be processed in other countries, including the United States."
  10. **How long we keep it.** Add "Crash reports: up to 90 days, then deleted by Google" and "Usage statistics: individual events up to 2 months; reports built from them contain only totals". Use the values from A3.
  11. **Your rights.** "Withdraw consent" gains "(for crash reports and usage statistics, the switches in Settings)". Export gains "Crash reports and usage statistics are not in the export, because they are tied to your device, not your account."
  12. **When your account is deleted.** Add "Deleting your account in the app also deletes crash reports not yet sent from that device and resets the usage-statistics ID on it."
  13. **What can remain after deletion, "Device-level diagnostics".** Replace it with "**Crash reports and usage statistics, up to 90 days and 2 months.** If you allowed them in the Android app, Google keeps what was already sent for up to 90 days (crash reports) and 2 months (individual usage events). They are tied to a random ID on your device, not to your account, so we can't find or delete them by account." This is still Q10 (f), so it is not a new residue entry.
  14. **No change:** "Technical data", "Changes to this policy" (the consent card is the in-app notice), "Security".
- **Acceptance criteria.**
  - Given the page, then every sentence above matches the shipped behaviour (the TEL-9 report) and the A2 and A3 answers.
  - Given the founder's merge, then the text is approved.
  - Given deploy-dev, then dev Hosting serves it; prod Hosting serves it only after a promoted `v*` tag (F9).
- **Test notes.** The existing `privacy_policy_link_test.dart` is unaffected; a reviewer reads the page against TEL-9's traces.
- **Observability.** —
- **Budget.** 0.
- **Flag.** Gates both flags leaving `off` (Before release).
- **Seam.** Note 21 ties the event list to the page.

### TEL-13 — Store forms and console settings  [owner: production-deployer (prepares) + founder (consoles)] [size: XS] [depends: TEL-12 text]  Status: Open
- **Description.** Prepare a checklist in the runbook; the founder enters it:
  - **Play Data safety:** App info and performance (crash logs, diagnostics), App activity (app interactions) and Device or other IDs; collected, optional, not shared (service provider), encrypted in transit, purposes "Analytics" and "App functionality"; no advertising ID.
  - **App Store label (text only, for TEL-16):** Diagnostics (crash data, performance data, other diagnostic data), Usage data (product interaction) and Identifiers (device ID); not linked to you, not used for tracking.
  - **GA property settings (F5)** in dzeroth-dev and dzeroth-prod: confirm whether Google Analytics is already linked (the `measurementId` values exist), and link it if not.
  - **No Measurement Protocol `api_secret`** in either GA property (TEL-10 L-4). Confirm that none exists (Admin › Data streams › the Android stream › Measurement Protocol API secrets) and never create one, so events reach our properties only through the SDK, never from a script.
  - **No BigQuery links.** Screenshots go in the PR.
- **Acceptance criteria.**
  - The checklist exists.
  - The dev settings are done before TEL-15.
  - The Play form is updated before the first Play build containing the SDKs leaves internal testing; flags can turn on without a new build, so the form cannot wait for the flag.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** —
- **Seam.** —

### TEL-14 — Prod Android Firebase config  [owner: production-deployer] [size: S] [depends: —]  Status: Done (#593; device check 2026-11-01)
**Device check, 2026-11-01: PASS.** A release APK built with `release-prod.yml`'s defines and the checked-in `google-services.prod.json` (aapt2: `project_id` dzeroth-prod) was re-signed with a throwaway key whose SHA-1 was registered on the dzeroth-prod Android app only. On a Redmi K20 Pro (Android 11), "Continue with Google" reached Create your profile, and logcat showed the Google flow completing and FirebaseAuth signing in on prod. The throwaway SHA was removed from prod and the key deleted the same evening; prod again has no SHAs. Two findings:
- **One key, one project.** dev and prod share `com.dzeroth.dzeroth`, and Google allows one Android OAuth client per package + SHA-1. This PC's debug SHA was already on dev, so adding it to prod stored the SHA but created no OAuth client, and sign-in failed with `28444: Developer console is not set up correctly`. The real upload and app-signing keys (roadmap 3.24) go on prod only; the debug key stays on dev.
- The prod json lists only the web OAuth client and sign-in still worked, so roadmap 3.24 step (d)'s json refresh is housekeeping, not a sign-in fix.

The AAB `project_id` check runs on the first staged tag; the re-check with the real key is roadmap 3.24.
- **Description.** Make prod Android builds use dzeroth-prod's `google-services.json`, either with a build-time swap in `release-prod.yml` from a checked-in prod copy (client config, known-public per `security-checklist`) or per-flavor `flutterfire configure`. The default is the swap: it is the smallest change. **The workflow is a gate file: your review.** Remove the "founder follow-up" note.
- **Acceptance criteria.**
  - Given the prod AAB, then its merged resources carry `project_id` dzeroth-prod.
  - Given a dev build, then dzeroth-dev.
  - Google Sign-In on a prod build still works, checked on a device.
- **Test notes.** `aapt2 dump resources` on both builds.
- **Observability.** —
- **Budget.** 0.
- **Flag.** **Blocks both flags leaving `off` in prod.**
- **Seam.** —

### TEL-15 — Dev rollout; prod prepared  [owner: production-deployer] [size: S] [depends: TEL-9 incl. Part B (C-1) and its M-2 check (C-3), TEL-10, TEL-11; TEL-12 on dev Hosting; TEL-13 dev settings; TEL-17 (C-2, M-1)]  Status: Open
- **Description.**
  - A targeted dev Terraform plan for `feature_crash_reporting*` and `feature_analytics*` (roadmap 3.10: name `-target=module.budget.google_pubsub_topic.billing_alerts` too), shown to you; apply on OK, with the team's test accounts in the allowlist.
  - Smoke on a dev Android build: the card appears; with consent off, no SDK traffic; with consent on, a test crash and events arrive in the dzeroth-dev consoles with no id or text; with the flag off, collection stops on the next `GetMe`.
  - Prepare the prod change (allowlist, then `on`), not applied.
- **Acceptance criteria.** The smoke passes and the dev state is recorded here; the prod change is prepared with its preconditions (Before release).
- **Test notes.** —
- **Observability.** The startup `feature_flags` line shows both in allowlist mode.
- **Budget.** 0 reads beyond the smoke's `GetMe`.
- **Flag.** Dev allowlist; prod `off`.
- **Seam.** —

### TEL-16 — iOS at the Apple launch (conditional)  [owner: frontend-developer + founder] [size: S] [depends: Apple launch, TEL-15]  Status: Open (conditional)
- **Description.** A Podfile with `$FirebaseAnalyticsWithoutAdIdSupport = true`, the Crashlytics dSYM upload build phase, the app privacy manifest, `TelemetryPlatforms` gains iOS, the App Store label from TEL-13, and policy note 16 and the "Not on iPhone yet" bullet updated in the same PR.
- **Acceptance criteria.** The TEL-9 traces repeated on an iPhone; the label entered.
- **Test notes.** —
- **Observability.** —
- **Budget.** 0.
- **Flag.** Both.
- **Seam.** One platform-set entry; no caller change.

### TEL-17 — M-1: AdServices permissions out of the merged manifest  [owner: frontend-developer] [size: S] [depends: —]  Status: Open
- **Description.** TEL-10 M-1 (condition C-2). BoM 34.19.0 resolves `firebase-analytics` 23.2.0. Its `play-services-measurement-api` and `-sdk-api` manifests declare `android.permission.ACCESS_ADSERVICES_AD_ID` and `android.permission.ACCESS_ADSERVICES_ATTRIBUTION`. The app removes only `AD_ID`, so both merge in (reasoned from the cached AARs; no merged manifest has been dumped yet).
  - `app/android/app/src/main/AndroidManifest.xml`, next to the `AD_ID` line:
    - `<uses-permission android:name="android.permission.ACCESS_ADSERVICES_AD_ID" tools:node="remove"/>`
    - `<uses-permission android:name="android.permission.ACCESS_ADSERVICES_ATTRIBUTION" tools:node="remove"/>`
  - **Source guard** (`app/test/guards/telemetry_scan.dart`, `telemetry_guard_test.dart`):
    - extend `removesAdId` so all three permissions must carry `tools:node="remove"` in the main manifest (comments stripped), and no `debug` or `profile` manifest may add any of them back;
    - add synthetic-input tests for the two new names: removed, commented out, declared without `remove`;
    - the guard's name says it reads the source manifests (today it says "merged manifest", which it does not read; test report O-6).
  - **Merged-manifest check, no phone.** Build a release APK on your PC with the dev defines of test report §6 (Prerequisites). Run `aapt2 dump permissions` (or `apkanalyzer manifest permissions`) on it. Paste the full permission list in the PR.
  - A Firebase BoM bump can add a permission silently. TEL-20 puts the re-check in the runbook.
  - No Dart code under `lib/` changes. Do not touch `core/telemetry` (TEL-18).
- **Acceptance criteria.**
  - Given the main manifest, then all three permissions carry `tools:node="remove"` and the guard passes.
  - Given either new line deleted, commented out or left without `tools:node="remove"`, then the guard fails. This is a mutation check: record it in the PR the way the TEL-9 report's section 4 does, then revert.
  - Given a local release APK, when its permissions are dumped, then `com.google.android.gms.permission.AD_ID`, `android.permission.ACCESS_ADSERVICES_AD_ID` and `android.permission.ACCESS_ADSERVICES_ATTRIBUTION` are all absent, and the full list is in the PR.
- **Test notes.**
  - Run `flutter test test/guards` and `flutter analyze`.
  - The APK dump needs the Android SDK build-tools on the PC, not a device. TEL-9 Part B repeats the dump on its own build (§6b C-2).
  - Flag modes do not apply: permissions are static.
- **Observability.** None at runtime. The PR keeps the permission list as evidence.
- **Budget.** 0 RPCs, 0 Firestore operations. INR 0.
- **Flag.** None (a static manifest). Gates both flags leaving `off` in dev (C-2), and TEL-13's Play Data safety and Advertising ID answers.
- **Seam.** The SDKs stay behind TEL-4's adapters; the guard pins the manifest.

### TEL-18 — L-1, L-2 and I-1 in `core/telemetry`  [owner: frontend-developer] [size: S] [depends: —]  Status: Done (#643)
- **Description.** TEL-10 L-1 and L-2 (condition C-6) and I-1. All three are in the controller, the crash adapter and their tests.
  - **L-1: delete before "on" (ADR-0032 D3 step 1).**
    - In `TelemetryController._decide`, when crash collection becomes true, enqueue `_crash.deleteUnsentReports` **before** `_crash.setCollecting(true)`.
    - It is a no-op once native collection is on, so it is safe in every state, including the bootstrap's forced apply.
  - **L-2: reset per F12.**
    - In `_noteSignIn`, reset when `last != uid`, **including `last == null`**.
    - When `_lastUid.read()` throws, reset anyway (fail closed), then try to write the uid.
    - A failing reset or write never breaks sign-in (as today).
    - This also closes the `forgetDevice` gap: a swallowed reset followed by a cleared record now resets at the next sign-in.
    - Update the doc comments that say a first sign-in resets nothing.
  - **I-1: delete the ungated breadcrumb path** until it has a caller. Delete:
    - `FirebaseCrashReporter.breadcrumb()`;
    - `CrashlyticsPort.log`, with its `FirebaseCrashlyticsPort` and `FakeCrashlyticsPort` (`app/test/support/fake_crashlytics_port.dart`) implementations;
    - `crash_breadcrumbs.dart` (`CrashBreadcrumb`). None of these has another user (grep, 2026-11-02);
    - the test "breadcrumbs are the enum constants" (`firebase_crash_reporter_test.dart`) and the `docs/ui-catalog.md` entry.

    A future breadcrumb comes back through `TelemetryController`, gated like `recordError`, with its policy line.
  - **Tests that change, because the rule changed** (line numbers approximate):
    - `telemetry_controller_test.dart`: "a consent change applies at once" (line 185) becomes `['crash.deleteUnsent', 'crash.setCollecting(true)']`. The bootstrap test (line 203) gains `usage.reset` (empty record) and `crash.deleteUnsent` before `crash.setCollecting(true)`.
    - `telemetry_account_switch_test.dart`:
      - "first sign-in on a device (no record) resets nothing" (line 83) becomes "resets once and records the uid";
      - "A, sign out, B, sign out, A" (line 69) counts 3 resets;
      - "after A is deleted, B signing in is a first sign-in: no second reset" (line 139) now resets.
    - `telemetry_decision_matrix_e2e_test.dart`: the tests at lines 213, 240, 263 and 322. Each launches on an empty store and counts resets.
    - Any other test that pins an exact call list gets the same treatment.
- **Acceptance criteria.**
  - Given crash consent turned on while the flag is on, then the adapter calls are exactly `deleteUnsentReports`, then `setCollecting(true)`.
  - Given a bootstrap whose restored uid has crash on, then `deleteUnsentReports` runs before `setCollecting(true)`.
  - Given no `telemetry_last_uid` record and a sign-in (or a restored uid at bootstrap), then the analytics ID is reset once, before that uid's first event, and the uid is recorded.
  - Given a record read that throws, then the reset still runs before the uid's first event, and sign-in completes.
  - Given account A deleted in the app with its reset failing, then B's sign-in resets.
  - Given A, sign-out, A again, with A recorded, then no reset (unchanged).
  - Given `app/lib` and `app/test`, then no `breadcrumb(`, `CrashBreadcrumb` or Crashlytics `log` call remains. The canaries' "no other call reached the SDK" test still passes.
  - Every changed test names the new rule. A test about something else seeds `telemetry_last_uid` instead of changing its counts. No exact call list is loosened to `contains`.
- **Test notes.**
  - Mutation checks, recorded in the PR and reverted (as the TEL-9 report's section 4):
    - drop the pre-enable delete: the L-1 tests fail;
    - restore `last != null &&`: the first-sign-in tests fail;
    - remove the fail-closed reset: the read-failure test fails.
  - Run `flutter test test/core/telemetry test/guards test/features/account` and `flutter analyze`.
  - Flag modes: the 2 × 2 × 2 × 2 matrix stays green.
  - On a device, TEL-9 Part B trace (a) shows L-1's fix.
- **Observability.** The existing debug-only decision log; nothing in release.
- **Budget.** 0 RPCs, 0 Firestore operations. INR 0. One more local `resetAnalyticsData()` per device, at its first recorded sign-in and after an in-app deletion.
- **Flag.** `crash_reporting`, `analytics`. Nothing changes while both are off. Gates any prod raise (C-6).
- **Seam.** `CrashReporter` and `UsageAnalytics` keep their methods. `TelemetryController` stays the only decision point, and every SDK call goes through its queue.

### TEL-19 — L-3: native crash messages in ADR-0032  [owner: architect] [size: XS] [depends: —]  Status: Done (#645)
- **Description.** TEL-10 L-3 (condition C-5). F6 and the scrubber cover Dart errors only. An uncaught Java or Kotlin exception in a plugin or the engine reaches Crashlytics through its `UncaughtExceptionHandler`, with its message: for example a file path or content URI from `image_picker`, or a SQLite message. No native scrubber at Stage 0.
  - A dated note in ADR-0032 (Data inventory, Crashlytics "What is sent", and D6). It says a crash in Android's own code carries Android's error message, which can include a file name or path. Post and message text are not expected there. The Accepted decision does not change.
  - The note gives the sentence TEL-12 item 6 must carry (C-5). For example: "A crash in Android's own code can include Android's error message, which may contain a file name." TEL-12 is edited when it is drafted, not in this ticket.
- **Acceptance criteria.**
  - Given ADR-0032, then the Data inventory and D6 no longer read as if every crash message passes the scrubber, and the note is dated and cites TEL-10 L-3.
  - Given the TEL-12 draft, then item 6 can use the note's sentence as written.
- **Test notes.** None (docs). TEL-9 Part B trace (b) records what a forced native crash shows. If it shows more than paths or URIs, revise the note.
- **Observability.** —
- **Budget.** 0.
- **Flag.** Feeds TEL-12, which gates both flags leaving `off`.
- **Seam.** —

### TEL-20 — L-4: triage before a reported leak counts as one  [owner: sre-performance] [size: XS] [depends: —]  Status: Done (#646)
- **Description.** TEL-10 L-4. The app's Firebase IDs and API key are public. Anyone can plant a crash or event that contains an id, handle, email or text. That trips the rollback trigger, or plants third-party personal data in our consoles.
  - **`docs/runbooks/client-telemetry.md`, Failure modes:** a triage step before "Personal data seen in a crash report or an event" counts as a leak. Check that:
    - the build number is in a shipped range;
    - the top frames are `package:dzeroth/` or our plugins;
    - the text sits where our code can put text (only allowlisted Dart types carry a message; native messages per L-3 and TEL-19).

    A report that fails these checks is forged: delete it (Firebase support, or a GA data-deletion request) and do not roll back. A report that passes is a leak: flag `off`, as today.
  - **Same file, Kill switch:** the first rollback trigger points to the triage step.
  - **Same file, BoM bumps (TEL-10 M-1):** at every Firebase BoM bump (Dependabot), rerun TEL-17's permission dump on a release APK and compare it with the baseline, the permission list recorded in TEL-17's PR. A permission not in the baseline blocks the release until it is removed with `tools:node="remove"` or declared in TEL-13's forms. Record the new list as the next baseline.
  - **Same file:** never create a Measurement Protocol `api_secret` (TEL-13 checks the consoles).
  - **This plan's Rollout plan:** the first rollback trigger gains "(after the runbook's triage step)".
- **Acceptance criteria.**
  - Given a report whose build number was never shipped, or whose top frames are not ours, when the runbook is followed, then the outcome is "forged: delete, no rollback".
  - Given a report from a shipped build, with our frames and text in an allowlisted message, then the outcome is "leak: flag off".
  - Given a BoM bump, then the runbook names the check and what to do with a new permission.
- **Test notes.** Walk both cases through the runbook with the tester or the founder; no code.
- **Observability.** The triage step names the console fields to read (build number, frames, where the text sits).
- **Budget.** 0.
- **Flag.** Changes when the kill switch is used, not the flags. Before any prod raise.
- **Seam.** —

## Before release (nothing leaves `off` anywhere until each item for that step is done)
- **Before any merge that ships the SDKs:** TEL-3's off keys and TEL-4's decision are in the same or an earlier PR, so a merged build collects nothing.
- **Before the dev allowlist (TEL-15):**
  - TEL-1 Accepted;
  - TEL-9 PASS with the three traces;
  - TEL-10 CLEAR;
  - TEL-11 HOLDS;
  - TEL-12 merged and on dev Hosting;
  - TEL-13 dev console settings done;
  - team test accounts only (F9);
  - TEL-17 merged, and the merged manifest of the Part B build has none of the three advertising permissions (C-2);
  - the M-2 item of TEL-9 Part B done and its result recorded in the security report (C-3).
- **Before any Play build with the SDKs leaves internal testing:** the TEL-13 Play Data safety form is updated, and TEL-17 is in that build (C-2), so the Advertising ID and Data safety answers describe it.
- **Before any prod raise or any non-team account:**
  - TEL-12 is served by prod Hosting (a promoted `v*` tag containing it; the Android in-app link opens prod Hosting);
  - TEL-14 is in the release;
  - the TEL-13 prod GA settings are done;
  - your OK on the Terraform plan and the release flow (ADR-0019);
  - TEL-18 is in the release (C-6: L-1 and L-2), and TEL-20 is merged (L-4);
  - C-4 is checked (TEL-9 Part B or the TEL-15 smoke);
  - if the M-2 check found a join, its follow-up ticket is done (C-3);
  - **legal review has decided Q-1 (F13, roadmap 3.26).** This also blocks any TEL-15 step beyond the team's test accounts, and TEL-16.
- **iPhone and web:** nothing in this plan turns them on (TEL-16; Out of scope).
- **Readiness checklist:** the `production-readiness` line "Crashlytics on" stays valid. For a release, the evidence is `crash_reporting` on in prod plus a dzeroth-prod Crashlytics console screenshot (Android); it is N/A for web. `CLAUDE.md` already lists Crashlytics; the Analytics line is TEL-1's proposal for you.

## Rollout plan
- **Dev:** allowlist with the team test accounts (TEL-15).
- **Prod:**
  1. allowlist (you and testers);
  2. `on`.

  Each step is a Terraform change plus a `v*` tag, a production-reviewer GO and `promote-prod`. Consent still applies to every user.
- **Rollback triggers:**
  - any crash report or event containing an id, handle, email or user text (after the runbook's triage step);
  - SDK traffic seen without consent;
  - a crash-rate or ANR rise attributable to the SDKs;
  - reports from a prod build landing in dzeroth-dev;
  - a store rejection over the data forms.
- **Kill switch:** set the flag to `off` and deploy. Collection stops and unsent reports are deleted on the next `GetMe`. No data migration. Already-sent data: GA data deletion request or the Crashlytics console (runbook). Last resort: drop the SDKs in the next store build.

## Risks
| Risk | Mitigation |
|---|---|
| User text or ids leak through exception messages or Flutter error context | F6: no message by default; no `context` or `informationCollector`; scrubber; canaries per leaky type (TEL-5, TEL-9); TEL-10. Dart errors only: a native (Java or Kotlin) crash's message is not scrubbed, so the policy discloses it, and TEL-9 Part B trace (b) checks what it carries (ADR-0032 note 2026-11-02, TEL-19) |
| Data becomes linkable to accounts (custom keys, flag lists, FCM tokens, a shared device) | F3, F6, F11; the TEL-9 guards; the TEL-10 join check |
| Something is collected before consent (native auto-init, persisted enable, cached reports) | the off keys, the bootstrap re-apply, `deleteUnsentReports` on every "off", network traces in TEL-3 and TEL-9 |
| `firebase_analytics_collection_deactivated` used by mistake makes Analytics impossible to turn on | A5; the TEL-3 key list; the TEL-9 manifest guard |
| Prod Android reports go to dzeroth-dev | TEL-14 blocks the prod raise |
| The policy is not live where the in-app link points (prod Hosting) | F9; Before release |
| Opt-in coverage is too low to be useful | at Stage 0 a few devices show the top crashes; revisit F1 (B) with legal advice if crash triage is blind for 30 days |
| A Google Analytics property already exists with permissive defaults | TEL-13 checks the `measurementId` properties and applies F5 before any collection |
| Web Analytics added later without the cookie, banner and CSP work | Out of scope with a trigger; the TEL-12 maintainer note (replacing note 21); the TEL-9 CSP guard |
| Fake events or crashes from scripts | numbers are never used for security, billing or moderation; console noise only |
| A Firebase BoM bump adds an advertising or other permission to the merged manifest without anyone noticing (TEL-10 M-1) | TEL-17 removes the known three and dumps a release APK's permissions; TEL-20's runbook line repeats the dump at every BoM bump |
| A forged report forces a kill switch (TEL-10 L-4) | TEL-20's triage step; no Measurement Protocol `api_secret` (TEL-13) |
