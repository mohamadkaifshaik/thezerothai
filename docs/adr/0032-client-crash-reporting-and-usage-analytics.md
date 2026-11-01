# 0032. Client crash reporting and usage analytics (Crashlytics, Google Analytics for Firebase) at Stage 0
Status: Proposed
Date: 2026-11-01
Deciders: architect (proposal); the founder accepts by merging the PR. The plan's founder questions F1 to F11 were
answered by the founder on 2026-11-01 ("TEL plan defaults all ok, go ahead"), so every F below is **decided**, not a
default awaiting acceptance (table "Founder decisions"). The architect's own calls (sections "Changes against the plan"
and "Decision") can be overridden at acceptance. No decision here bends a `CLAUDE.md` non-negotiable rule (F8 reads
rule 10 as fitting), adds a fixed cost or changes a founder-gated file.

Plan: `docs/plans/client-crash-analytics.md`, ticket TEL-1 (this ADR). It gates TEL-12 (the policy may merge only once
this ADR is Accepted) and informs TEL-2 to TEL-16. The plan asked for "the next free number (0032 at the time of
writing)"; `docs/adr/` ends at 0031, so this is **0032**.

Related ADRs and rules:
- ADR-0001: free tier first; Firebase gives Crashlytics free. `CLAUDE.md` lists Crashlytics under "Crash reporting"
  and does not list Google Analytics.
- ADR-0008 D6: feature flags are env vars, mirrored to clients through `GetMe.enabled_features` (0 Firestore reads).
- ADR-0011 Q10 (f): "Firebase Crashlytics and Analytics data keyed to the device, not the uid (T20 verifies that the app
  never sets a user identifier)", founder-accepted 2026-10-07, and its note of 2026-11-01 (W6-55) that indexes the later
  residue entries.
- ADR-0019: prod moves only by a `v*` tag and the founder's approval. ADR-0022: credit mode. **Nothing here depends on a
  credit-mode item.**
- ADR-0026: client-only flags (`shells`, `ui_shell`), the pattern TEL-2 copies.
- `CLAUDE.md` rule 10 (privacy), rule 11 (cost caps are code).

## Context
Today a crash on someone's phone is invisible to us. `reportUnexpectedError` (`app/lib/app/session_wiring.dart`) is
wired into about 20 repositories and cubits and says "the Crashlytics handler hooks it", but no handler exists and the
app ships no Crashlytics or Analytics SDK, so every report stops at the device console. The founder asked on
2026-11-01 to "add crashlytics and google analytics and update the policy before it ships".

Constraints:
- **Stage 0, no fixed cost.** Both products are "No-cost" on the Firebase pricing page (read 2026-11-01). No BigQuery
  link (BigQuery streaming is on the "not used at Stage 0" list).
- **Client-only.** 0 RPCs, 0 Firestore reads, writes or deletes, no proto, no index, no Terraform resource beyond two
  flag env vars.
- **Privacy.** India's DPDP Act asks for notice and a clear affirmative consent that is as easy to withdraw as to give
  (the plan's F1; this is not legal advice). The Privacy Policy says today that we use neither product and will describe
  either "before we switch it on" (`app/web/privacy.html`, maintainer note 21).
- **Right to delete.** Q10 (f) already allows device-keyed Crashlytics and Analytics data to remain after an account is
  deleted, on the condition that the app never sets a user identifier.
- **Prod Android config.** Until TEL-14, prod Android builds read dzeroth-dev's `google-services.json`, so native SDKs
  would have reported to the dev project. TEL-14 merged as #593 on 2026-11-01 (`release-prod.yml` swaps in
  `app/android/google-services.prod.json`). Its AAB `project_id` check runs on the first staged tag, and the founder
  owes the on-device Google Sign-In check. Until both pass, D13's "TEL-14 blocks any prod raise" still applies.

## Founder decisions (2026-11-01)
The founder answered all eleven on 2026-11-01, verbatim: **"TEL plan defaults all ok, go ahead"**. Each is the plan's
bold default. INR are per month at 300 / 1,000 / 3,000 DAU (Cost impact).

| # | Question | Decision (founder, 2026-11-01) | INR 300 / 1,000 / 3,000 |
|---|---|---|---|
| F1 | Consent | **(A) Opt-in for both.** A card once per account on each Android device, at the top of Home (the push opt-in card slot; push first, one card at a time), with two switches, "Send crash reports" and "Share usage statistics", **both off**. "Save" keeps what was switched on; "Not now" keeps both off and is not asked again. Settings › Privacy & safety has the same two switches at any time. The choice is stored per uid on the device | 0 / 0 / 0 |
| F2 | Platforms | **Android only.** iOS: TEL-3 adds the off-switch keys to `Info.plist` now so an iOS build can never collect by accident; turning it on waits for the Apple launch (TEL-16). Web: neither (Crashlytics has no Flutter web support; web Analytics sets cookies, needs a banner and CSP hosts) | 0 |
| F3 | Linking to accounts | **None.** No `setUserId`, `setUserIdentifier`, user properties or default event parameters; no uid, handle, email, post, message or search text in any event, parameter, custom key, log or breadcrumb | 0 |
| F4 | Analytics events | **Three custom events plus template screen views:** `post_created` {`kind`: post, reply, quote; `media`: none, photo, gif; `poll`: bool; `scheduled`: bool}, `follow` {`source`: profile, suggestions, search, list, other}, `search_used` {`type`: people, hashtag}, and `screen_view` with `screen_name` from a fixed map of route templates (unmapped = `other`). Enums and booleans only. Plus Google's automatic events (A7). A new event or parameter changes the policy in the same PR | 0 |
| F5 | GA property settings (dev and prod) | Event data retention **2 months** with "reset on new activity" off; Google signals off; ads personalisation off in every region; granular location and device data off; user-provided data collection off; **every account data-sharing setting off**; no Google Ads, BigQuery or Search Console link. App side: advertising ID collection off, `AD_ID` removed from the merged manifest, ad storage, ad user data and ad personalisation consent always denied | 0 |
| F6 | Crash payload | **Error type and stack trace only.** The message only for an allowlist of code-generated types (`TypeError`, `StateError` with our fixed strings, `AssertionError`, `FlutterError` overflow and layout errors), after the scrubber (digit runs of 6 or more, 28-character uid-like tokens, emails, @handles and URLs replaced; cut at 200 characters). `ConnectException`: code and `ErrorReason` only. `FlutterErrorDetails`: no `context`, no `informationCollector`. Custom keys: build number, `FIREBASE_ENV`, platform; **no flag list**. Breadcrumbs: compile-time constants | 0 |
| F7 | Flags, ceilings, ramp | **Two client-only flags**, `FEATURE_CRASH_REPORTING` (`crash_reporting`) and `FEATURE_ANALYTICS` (`analytics`). Dev ceiling allowlist, at most 6, percent 0. **Proposed prod ceiling `on`** (D11). Prod ramp: allowlist (founder and testers), then `on` | 0 |
| F8 | Rule 10 | **Fits; not a bend** (D8) | 0 |
| F9 | "Policy live" for the dev allowlist | The dev allowlist may start, **for the team's test accounts only**, once dev Hosting serves the TEL-12 text. No account outside the team, in dev or prod, until **prod** Hosting serves it (a promoted `v*` release containing TEL-12), because the Android in-app link always opens prod Hosting (`privacyPolicyUrl`, `app/lib/core/widgets/privacy_policy_link.dart`) | 0 |
| F10 | Legal review | Same as every other feature: the founder approves the text by merging TEL-12; legal review stays maintainer note 1's open item. **The A2 terms check is a gate** (D7) | 0 |
| F11 | A second account on one device | Reset the device's **Google Analytics app-instance ID** whenever a different account signs in than the last one on the device, and on in-app account deletion; each account's choice stored per uid. Cost: one person with two accounts counts as two users. (C2: this resets the Analytics ID only, not the Crashlytics installation UUID) | 0 |

## Changes against the plan (where the plan and this ADR differ, the ADR wins)
Each item comes from a primary source read on 2026-11-01 (A1 to A8 below). Each one changes a ticket's acceptance
criteria or a TEL-12 sentence, listed per item.

- **C1. Turning Crashlytics off takes effect at the next launch, and `deleteUnsentReports` does nothing while
  collection is still on.**
  - Firebase says that passing `false` to `setCrashlyticsCollectionEnabled` "takes effect on the next launch and
    persists after that". Reports stored while collection is off "will be sent" once it is enabled. FlutterFire says
    `deleteUnsentReports` deletes queued reports only "if automatic data collection is disabled. Otherwise, this method
    is a no-op." (A6)
  - So an "off" decision needs four things (D3):
    - a **Dart-side gate**: `FirebaseCrashReporter.record` drops the report without calling the SDK the moment the
      decision is off;
    - `setCrashlyticsCollectionEnabled(false)`, which persists and stops the native handler from the next launch;
    - `deleteUnsentReports()` now (it may be a no-op);
    - `deleteUnsentReports()` again at **every bootstrap whose decision is off**, which is when it works.
  - An "on" decision calls `deleteUnsentReports()` **before** `setCrashlyticsCollectionEnabled(true)`. That way
    nothing recorded before consent, including another account's session on the same device, is ever sent.
  - **Residual, accepted:** after an opt-out, a flag `off` or a sign-out, a *native* (Java or Kotlin) fatal crash later
    in the same process run can still be uploaded. Dart errors cannot. The window is the rest of that run. TEL-9
    measures it.
  - What this rewrites in the plan:
    - Flags table, kill switch "on the next `GetMe`, collection is disabled, unsent reports are deleted" becomes:
      "on the next `GetMe`, Dart-side reports stop at once; native capture stops at the next launch, where unsent
      reports are deleted".
    - TEL-4 AC 3: unchanged for `record`. Add "and again at the next bootstrap".
    - TEL-7 AC 2 "collection stops immediately" becomes "no Dart-side report is passed to the SDK after the switch;
      native capture stops at the next launch".
    - TEL-8: delete is the off decision above.
    - TEL-12 item 12 must not promise a same-run deletion. Suggested wording: "Deleting your account in the app stops
      crash reports from that device. Reports not yet sent are deleted when the app next starts, and the
      usage-statistics ID is reset."
- **C2. F11 resets only the Google Analytics app-instance ID.**
  - `resetAnalyticsData` "clears all analytics data for this app from the device and resets the app instance id".
  - The Crashlytics installation UUID "is rotated when the Firebase installation ID changes" (Play data disclosure page),
    and F11 does not change that ID.
  - Rotating the Firebase installation ID on purpose would invalidate the FCM registration that push relies on, so this
    ADR does not do it.
  - Two accounts on one device therefore share a Crashlytics installation UUID. It is still device-keyed and carries no
    account identifier, so Q10 (f) holds (D9).
  - TEL-12 item 6 ("tied to a random ID on the device, which is reset when a different account signs in") is true of
    usage statistics only. For crash reports it should read "an ID that stays with the app on this device until the app
    is reinstalled or its storage is cleared" (TEL-9 checks the clear-storage case).
- **C3. Consent mode is not the gate; the collection switch is.**
  - Google: when `analytics_storage` is denied, "cookieless pings are sent" and, for apps, "events without device or
    user identifiers will be sent to Google Analytics".
  - The control that stops all Analytics traffic is collection disabled: `firebase_analytics_collection_enabled=false`
    in the manifest and `setAnalyticsCollectionEnabled(false)` at runtime. The consent defaults are a second fence.
  - Order (D3):
    - **on**: `setConsent(analytics_storage: granted)`, then `setAnalyticsCollectionEnabled(true)`;
    - **off**: `setAnalyticsCollectionEnabled(false)`, then `setConsent(analytics_storage: denied)`.
  - `ad_storage`, `ad_user_data` and `ad_personalization` are denied in the manifest and never granted.
- **C4. Web (A4): the CSP does not block the Analytics script.**
  - `firebase_core_web` injects `https://www.gstatic.com/firebasejs/<version>/firebase-analytics.js` at
    `Firebase.initializeApp` for every registered service. `firebase_analytics_web` registers `analytics`.
  - The current CSP allows `script-src https://www.gstatic.com` and `connect-src https://*.googleapis.com`. Only the
    gtag loader (`www.googletagmanager.com`) and the collection hosts (`*.google-analytics.com`) are fenced out.
  - The plan's "web Analytics would be blocked even if it started by accident" is true of collection only.
  - The Analytics instance is lazy: it is created on the first plugin method call. On web the `Noop` adapter makes no
    call, so nothing starts.
  - TEL-3 stops the script download with `window.flutterfire_ignore_scripts = ['analytics']`, placed in a **same-origin
    external file** `app/web/flutterfire_config.js`. That file is loaded by a plain (not `async`) `<script src>` before
    `flutter_bootstrap.js`.
  - `script-src 'self'` already covers that file, so **`firebase.json` does not change** and no new `sha256` is needed.
    The plan proposed an inline script plus a new hash.
- **C5. Crashlytics deletion.**
  - A per-user deletion method exists: `projects.apps.users.deleteCrashReports` (v1alpha, `firebasecrashlytics.googleapis.com`).
    It is keyed by "the user ID set using the Crashlytics SDK" [S28]. Firebase's Crashlytics page says that to delete
    records tied to a user ID, you contact Firebase support [S18].
  - The plan's F3 said "Crashlytics data that we know no per-user deletion API for (TEL-1 verifies)". That is
    corrected here: the method exists, but only for a user ID.
  - Under F3 no user ID is ever set, so there is nothing to target. F3's conclusion holds: linking would buy a deletion
    path at the price of everything F3 lists.
  - The TEL-2 runbook line "delete the data with ... the Crashlytics console" has **no source** (UNVERIFIED). The
    runbook says instead:
    - turn the flag off and fix the scrubber;
    - ask Firebase support to remove the affected reports, citing the issue id;
    - otherwise the reports age out at 90 days.
  - For Analytics, a GA4 data-deletion request (Editor role; data must be more than 12 days old; 7 to 63 days to
    process). **Auto-collected parameters can only be deleted with "Delete all parameters on all events"** for the date
    range.
- **C6. A2 adds a console gate before TEL-12 may call Google a processor for Analytics.**
  - Google Analytics for Firebase is a *Processor Service* under the **Google Ads Data Processing Terms**.
  - A property outside the EEA, UK and Switzerland must "proactively accept such terms" in GA Admin › Account settings
    › Account details › Data Processing Amendment. The same page says "Amendments for new accounts are automatically
    accepted", which is ambiguous for us.
  - **TEL-13 must screenshot that screen in both GA accounts (dev, prod)**, showing the amendment accepted, before TEL-12
    merges.
  - With "Google products & services" data sharing on, Google is "a controller of the data that is shared". F5's
    sharing-off is therefore required for the processor reading, not cosmetic.
- **C7. Keys.**
  - Every Android and iOS key in the plan is confirmed in Google's docs except `google_analytics_ssaid_collection_enabled`,
    which no Google page found mentions (UNVERIFIED).
  - TEL-3 may keep it (an unknown `meta-data` key is ignored), but it is **not a control**, and TEL-9 asserts nothing
    about it.
  - iOS: Google's page now says to leave out AdSupport by using `pod 'FirebaseAnalytics/Core'` or the SPM product
    `FirebaseAnalyticsCore`. The plan's Podfile variable `$FirebaseAnalyticsWithoutAdIdSupport` is not verified here.
    TEL-16 uses whichever mechanism the Firebase and FlutterFire docs name at the Apple launch.
- **C8. Crashlytics and Analytics see each other.**
  - When Analytics is present, Crashlytics attaches the session's Analytics events, including `screen_view` with
    `firebase_screen_class` and custom events "with their parameter data", to crash reports as breadcrumbs.
  - Analytics logs `app_exception` when Crashlytics is integrated. Both are harmless under F4, because parameters are
    enums. Whether `app_exception` is logged when Analytics is on but Crashlytics collection is off is UNVERIFIED (TEL-9).
- **C9. FCM notification events.**
  - With FCM present, Analytics logs `notification_receive`, `notification_open`, `notification_dismiss` and
    `notification_foreground`. Their parameters include `message_name`, `message_id`, `topic` and `label`.
  - The backend sets no FCM analytics label or message name today (no `AnalyticsLabel` or `FCMOptions` in `backend/`,
    checked 2026-11-01). TEL-10 confirms that nothing derived from user data can reach those fields, and TEL-9 adds a
    guard.
- **C10. Crashlytics and IP addresses.**
  - Google documents IP handling for Auth, Hosting, Performance Monitoring and others, but **not for Crashlytics**.
  - A network trace cannot settle server-side retention, so this stays UNVERIFIED and the policy makes no retention
    claim about it.
  - The policy's general sentence that Google sees the IP address of any request it serves stays true.

## A1 to A8: answers from Google's documentation (all read 2026-11-01)
Sources are listed at the end with URLs. **VERIFIED** = stated on a Google page (firebase.google.com,
support.google.com, business.safety.google, developers.google.com, pub.dev for the official FlutterFire packages,
github.com/firebase for SDK source). **UNVERIFIED** = no primary statement found; the test that settles it is named.

| # | Question | Answer | Status |
|---|---|---|---|
| A1 | ADR needed? | Yes: a new data flow to Google, separate Analytics terms, a consent model, the rule 10 reading and the Q10 (f) confirmation. This is 0032 | VERIFIED (repo) |
| A2a | Terms for Crashlytics | Firebase terms page: Crashlytics is under "Crashlytics & App Distribution Terms and Data Processing and Security Terms" [S2]. The Firebase DPST (last modified 2024-08-21) §5.1.1: "Google is a processor of that Customer Personal Data under European Data Protection Law"; §5.1.3: under other law each party complies with its own obligations [S3] | VERIFIED |
| A2b | Terms for Analytics | "Google Analytics is a separate service ... subject to separate terms" [S1]. Google Analytics Terms of Service, plus the **Google Ads Data Processing Terms** (v8.0, 2024-05-30; §5.1.1(b) "Google is a processor of Customer Personal Data") [S5]. "Google Analytics for Firebase" is listed as a **Processor Service**, not a controller service (service list updated 2025-10-23) [S6]. Accepted in GA Admin › Account details › Data Processing Amendment; outside EEA, UK and CH "need to proactively accept"; "amendments for new accounts are automatically accepted" [S4] | VERIFIED; acceptance on our accounts: **TEL-13 screenshot** (C6) |
| A2c | Is Google a processor for both, given F5? | Crashlytics: yes, under the DPST, worded for European law (A2a). Analytics: yes for the property's data, **provided** "Google products & services" data sharing is off; when on, "Google is ... a controller of the data that is shared" [S7]. F5 turns every sharing setting off. Whether these contracts give the role DPDP expects is legal review (maintainer note 1) | VERIFIED (terms text); legal reading open (F10) |
| A3a | Crashlytics retention | "keeps crash stack traces, extracted minidump data, and associated identifiers" for "90 days before starting the process of removing it from live and backup systems" [S1] | VERIFIED |
| A3b | GA retention | Standard properties: 2 or 14 months; the minimum is 2. It applies to user-level and event-level data and "only affects explorations and funnel reports"; standard aggregated reports are not affected. Age, gender and interest data always 2 months. "Reset on new activity" extends user-level expiry on each event [S8] | VERIFIED |
| A3c | GA IP | "In Google Analytics 4 ... IP addresses are not logged or stored" [S9]; the SDK "derives coarse location data from the masked IP addresses of the device" [S11]. EU, CH and UK traffic: IP used for coarse location then "immediately discarded" [S10] (not our users; no equivalent page read for India) | VERIFIED |
| A3d | Crashlytics IP | Not documented (C10) | **UNVERIFIED**; not settleable by a trace. The policy makes no claim |
| A3e | Where processed | Crashlytics is a global service that "could process data at any of the Google Cloud Platform locations" [S1]. Analytics: no location statement found | VERIFIED (Crashlytics); Analytics: no region choice, so "may be processed in other countries, including the United States" stays the honest wording |
| A4 | Web: does `firebase_core_web` load or start Analytics? | **Loads, does not start.** `_initializeCore` injects `firebase-${service.name}.js` from `www.gstatic.com` for every registered service, unless listed in `window.flutterfire_ignore_scripts` [S12]. `firebase_analytics_web` only calls `registerService('analytics')` with no `ensurePluginInitialized`, and creates the instance lazily ("Lazily initialize [_webAnalytics] on first method call") [S13]. Mechanism for TEL-3: `flutterfire_ignore_scripts` in a same-origin external file (C4) | VERIFIED from FlutterFire `main` source; TEL-3 re-checks against the locked `firebase_core_web` (3.12.0 today) and TEL-9's web trace confirms |
| A5a | Analytics Android key | `firebase_analytics_collection_enabled` `false` pauses collection, "To re-enable collection, such as after an end-user provides consent, call ... `setAnalyticsCollectionEnabled(true)`". `firebase_analytics_collection_deactivated` `true` is for "deactivate Analytics collection permanently in a version of your app" [S14]. iOS: `FIREBASE_ANALYTICS_COLLECTION_DEACTIVATED` `YES` "takes priority over" the enabled key and runtime calls; setting `NO` "has no effect" [S15]. **Use `_enabled=false`; never `_deactivated`** | VERIFIED |
| A5b | Analytics iOS key | `FIREBASE_ANALYTICS_COLLECTION_ENABLED` `NO` [S15] | VERIFIED |
| A5c | Other Analytics keys | Android `google_analytics_adid_collection_enabled` `false` [S14]; `google_analytics_default_allow_analytics_storage`, `_ad_storage`, `_ad_user_data`, `_ad_personalization_signals` (`true` or `false`) [S16]; `google_analytics_automatic_screen_reporting_enabled` `false` and iOS `FirebaseAutomaticScreenReportingEnabled` `NO` [S17]; iOS `GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED` `NO` and `GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS` `NO` [S15]. `google_analytics_ssaid_collection_enabled`: no Google page found (C7) | VERIFIED except SSAID: **UNVERIFIED**, not a control |
| A5d | Crashlytics keys | Android `firebase_crashlytics_collection_enabled` `false`; iOS `FirebaseCrashlyticsCollectionEnabled` `false` [S18] | VERIFIED |
| A5e | Firebase Sessions while Crashlytics is off | Not on the Crashlytics pages. Sessions (a transitive dependency) collects app and device metadata and foreground session starts [S11b]. SDK change "send session event based on data collection and setting config" (firebase-android-sdk #6852, merged 2025-04-09 to a feature branch) [S19] | **UNVERIFIED** as shipped behaviour; **TEL-9 trace** (no Sessions traffic in the no-consent and flag-off states) |
| A6a | Persistence | Crashlytics: "The override value persists across all subsequent launches of your app"; `false` "takes effect on the next launch" [S18]. Analytics: "The value set by the `setAnalyticsCollectionEnabled` method persists across app executions" [S15] (Android reference wording "persisted across app sessions", seen in an older copy only) | VERIFIED (Android Analytics wording: TEL-9 bootstrap trace) |
| A6b | Reports recorded while off | "Crashlytics will store crash information locally on the device"; once enabled, "any crash information stored on the device will be sent" [S18]. `deleteUnsentReports` is a no-op while collection is enabled [S20] (C1) | VERIFIED |
| A6c | Consent mode, `analytics_storage` denied | "cookieless pings are sent"; for apps "Events without device or user identifiers will be sent"; "No IDFA may be collected" [S21]. `appInstanceId` is "null if consent has been denied" [S22] (C3) | VERIFIED |
| A7a | Automatic events on Android | `first_open`, `session_start`, `user_engagement`, `screen_view` (automatic reporting off by key; we log it from TEL-6), `app_update`, `os_update`, `app_remove`, `app_clear_data`, `app_exception` (with Crashlytics), `notification_receive`, `notification_open`, `notification_dismiss`, `notification_foreground` (with FCM), `firebase_campaign` (only with campaign parameters), `error` (replaces an invalid event, not reported). Not applicable to us: `in_app_purchase` and `app_store_*` (no Play billing), `dynamic_link_*`, `fiam_*`, `ad_*` (no Mobile Ads SDK) [S23] | VERIFIED |
| A7b | Automatic user dimensions | App store, app version, device brand, category and model, language, operating system and version, platform, new or established, and city, region, country, continent and subcontinent (coarse, from the masked IP). Age, gender and interests need Google signals (off by F5) [S24]. F5's "granular location and device data off" stops city, device brand, model and name, minor OS versions and screen resolution [S10] | VERIFIED |
| A7c | Crashlytics and Analytics integration | Breadcrumbs: `screen_view` (with `firebase_screen_class`) and custom events with their parameters, attached to crash reports [S18]. `app_exception` "is sent when Firebase Crashlytics is integrated" [S23] (C8) | VERIFIED; the analytics-on, crash-off case: **TEL-9** |
| A8 | Gate-file lines | Proposed text in "Proposed gate-file text" below, **not applied in this PR** | n/a |

## Data inventory per SDK (Android)
| | Firebase Crashlytics | Firebase Sessions (comes with Crashlytics) | Google Analytics for Firebase |
|---|---|---|---|
| What is sent | Error type and stack trace (F6); the message only for allowlisted types after the scrubber; "point-in-time metadata about the device when an application crashes", including OS name and version and the time [S1, S11b]; custom keys (build number, `FIREBASE_ENV`, platform); breadcrumbs (our constants, plus Analytics events when Analytics is also on, C8); up to 8 non-fatals per fatal. Fatal reports are sent at once; non-fatals are written to disk and sent "with the next fatal report or on app restart" [S18] | Package name, OS information, SDK version, network connection type, device manufacturer and model, foreground session start [S11b] | Our 3 events and `screen_view` (F4); the automatic events (A7a); the automatic dimensions (A7b); consent state. No advertising ID (key + `AD_ID` removed), no user ID, no user properties |
| Identifiers | **Crashlytics installation UUID** (to count affected users; "rotated when the Firebase installation ID changes") and the **Firebase installation ID** [S1, S11b] | none of its own documented | **App-instance ID** ("by default ... not tied to a user identifier", reset by `resetAnalyticsData`) [S11c, S22]; masked IP for coarse location [S11c] |
| Hosts (device to Google) | Not documented by Google. Candidates from third-party lists: `crashlyticsreports-pa.googleapis.com`, `firebase-settings.crashlytics.com` | Not documented | Not documented |
| Host status | **UNVERIFIED: TEL-9 records the actual hosts** in the opted-in trace and asserts that none appear in the no-consent and flag-off traces. FCM and Firebase Installations (`firebaseinstallations.googleapis.com`) traffic already exists and is excluded | same | same |
| Retention | 90 days, then removal from live and backup systems starts [S1] | not documented | Event and user-level data **2 months** (F5); aggregated standard reports are not governed by this setting [S8] |
| Where | Global, any GCP location [S1] | not documented | not stated |
| Terms, Google's role | Crashlytics & App Distribution Terms + Firebase DPST; processor (European-law wording) [S2, S3] | Firebase terms | GA Terms + Google Ads Data Processing Terms; Processor Service while data sharing is off [S5, S6, S7] |
| Deletion by us | `deleteCrashReports` by SDK user ID only (none set, F3); otherwise Firebase support (C5) | n/a | Data-deletion request by date range and parameters; User Deletion API by `appInstanceId` [S25, S26] (we never hold the ID, so per-person deletion is not possible: Q10 (f)) |

The **Firebase installation ID** already exists on every Android device that runs the app (FCM). The server stores FCM
tokens per uid (`deviceTokens`), never the installation ID, and the app never calls `FirebaseInstallations.getId`. So we
hold nothing that joins a Crashlytics report to an account. TEL-9 guards the `getId` call and TEL-10 confirms the join.
Google can join its own identifiers internally; that is what "device-level" means in Q10 (f), and the policy says the
data is tied to the device.

## Options
### A. Crashlytics and Google Analytics for Firebase on Android, opt-in, device-level (chosen)
- Pros: no cost; the SDKs catch native and Dart crashes before any network call succeeds; standard retention and
  automatic reports; the products the founder named.
- Cons: a new third party (Analytics, separate terms); consent coverage is partial (F1); two SDKs and about 1 to 2 MB
  in the AAB.
- Cost: INR 0 idle, INR 0 / 0 / about 2 at 300 / 1,000 / 3,000 DAU (the web bundle line), about INR 20 at 10× the
  Hosting crossover (Cost impact).

### B. Crashlytics only; product questions from server logs
- Pros: no Analytics terms; the API already logs one line per RPC (`rpc`, `uid_hash`), so "are people posting" is a
  Logs Explorer query.
- Cons: no screen views, sessions or retention; the follow source and composer extras need new request fields; Cloud
  Logging keeps 30 days.
- Cost: INR 0. Rejected because the founder asked for Analytics, and screen and session questions have no server-side
  source.

### C. Our own `ReportClientError` RPC (and server-side event counts)
- Pros: everything stays in our project and in Error Reporting; works on web.
- Cons: a new public write (quota, rate limit, security ticket); it cannot report a native crash or a crash before the
  network is up; event counting would cost Firestore writes per event.
- Cost: Cloud Run requests and logs per report, Firestore writes per counted event; small but per use. Kept as the
  **Stage 2 web** rung (Stage ladder).

### D. A third-party service (Sentry, PostHog and the like)
- Rejected: `CLAUDE.md` fixes the stack to GCP and Firebase; a free tier with a step to a fixed fee is the cost shape
  the prime directive forbids.

## Decision
Ship Firebase Crashlytics and Google Analytics for Firebase in the Android app, **off until the account's flag is on and
the person opts in on that device**, device-level, with a fixed event vocabulary and scrubbed crash payloads, behind one
`core/telemetry` seam. The web and iPhone collect nothing. Cost is INR 0 for both products.

### D1. Scope
- Android: both SDKs. iOS: off-switch keys only (TEL-3), on at the Apple launch (TEL-16). Web: neither; the script is not
  even downloaded (C4).
- Out (unchanged from the plan): Performance Monitoring, Remote Config, A/B tests, an ATT prompt, Crashlytics NDK, any
  BigQuery export, any account linking.

### D2. Consent (F1, F11)
- `TelemetryConsentStore` (TEL-7) keeps `telemetry_consent:crash:<uid>` and `telemetry_consent:usage:<uid>` (on, off or
  unasked) in `AppSettingEntries` on the device, kept on sign-out, `forget(uid)` on in-app deletion.
- The card and the Settings rows appear only while the matching flag is on for the account, on Android.
- A different uid signing in than the last one on the device calls `resetAnalyticsData()` before that account's first
  event (F11). In-app deletion calls it too.

### D3. The collection decision and its order of calls (C1, C3)
`collecting(kind) = platform supported (Android) AND a signed-in uid AND the flag in enabled_features AND consent "on"
for that uid and kind`. `TelemetryController` (TEL-4) applies it:
- at bootstrap, right after `Firebase.initializeApp`, from the decision last stored for the restored uid (the native
  state persists, A6a, so it can be stale), with no network wait;
- after every `GetMe`, auth change and consent change.

| Kind | On | Off |
|---|---|---|
| Crash | 1. `deleteUnsentReports()` (collection is still off, so it works); 2. `setCrashlyticsCollectionEnabled(true)`; 3. open the Dart-side gate | 1. close the Dart-side gate (immediate); 2. `setCrashlyticsCollectionEnabled(false)` (next launch); 3. `deleteUnsentReports()` (may be a no-op); **and at every bootstrap whose decision is off: `deleteUnsentReports()`** |
| Usage | 1. `setConsent(analyticsStorage: granted)`; 2. `setAnalyticsCollectionEnabled(true)` | 1. `setAnalyticsCollectionEnabled(false)`; 2. `setConsent(analyticsStorage: denied)` |

`adStorage`, `adUserData` and `adPersonalization` are denied by manifest default and never passed as granted. Sign-out
is "off". Nothing is awaited before the first frame except one call per SDK that applies the stored decision (TEL-11
measures it).

### D4. No linking and no identifiers of ours (F3)
- Never called anywhere: `setUserIdentifier`, `setUserId`, `setUserProperty`, `setDefaultEventParameters`,
  `FirebaseInstallations.getId`.
- `setCustomKey` only with the three F6 keys.
- TEL-9 guards each of these by test.

### D5. Event vocabulary (F4)
- `sealed class AnalyticsEvent` in `app/lib/core/telemetry/analytics_events.dart` holds `PostCreated`, `FollowMade` and
  `SearchUsed`. Parameters are Dart enums and bools, so free text cannot compile.
- `screen_view` comes only from `screenNameFor(fullPath)`, a fixed table of route templates; unmapped = `other`; never
  `uri` or `matchedLocation`.
- Events fire on success paths only.
- A new event or parameter is a policy change in the same PR (runbook rule; TEL-12's maintainer note).

### D6. Crash payload (F6)
- As decided. `FlutterErrorDetails` go through `recordError(exception, stack)`, never `recordFlutterError`, so `context`
  and `informationCollector` never leave the device.
- `information` and `reason` are never filled from runtime strings.
- The scrubber is one function (`CrashScrubber`), shared by any later reporter.

### D7. Console settings and the terms gate (F5, A2, C6)
- F5 as decided, in dzeroth-dev and dzeroth-prod, done by the founder from TEL-13's checklist **before** that project
  receives any event.
- TEL-13 adds two screenshots per GA account:
  - the Data Processing Amendment accepted (Admin › Account settings › Account details);
  - every data-sharing setting off.
- TEL-12 may describe Google as a processor for Analytics only with those on record.
- TEL-13 also confirms whether the existing web `measurementId`s (`G-FH6BVXB47G`, `G-TRYTXZ3EPG`) mean a property is
  already linked, and applies F5 to it.

### D8. Rule 10 (F8): fits
- Rule 10 ("PII limited to Firebase Auth + `users/{uid}/private`") governs what **we store about accounts**.
- This data is not stored in our systems, is not keyed to accounts (D4), and is covered by Q10 (f).
- It is still personal data under DPDP, which is why F1 asks for consent and TEL-12 describes it.
- The founder accepted this reading on 2026-11-01. **No rule bends.**

### D9. Residue: Q10 (f) covers it (confirmation dated 2026-11-01)
On 2026-11-01 the architect confirms that ADR-0011 Q10 (f), "Firebase Crashlytics and Analytics data keyed to the device,
not the uid", covers everything this ADR sends:
- the Crashlytics installation UUID, the Firebase installation ID and the Analytics app-instance ID are device or
  installation identifiers (Data inventory);
- no uid or account attribute is attached (D4), and the account switch reset (F11) keeps Analytics from bridging two
  accounts by the app-instance ID;
- Google's retention bounds it (90 days, 2 months), and per-person deletion is impossible by construction (C5).

So: **no new residue entry, no ADR-0011 amendment, no new eraser step, no export section.** Q10's condition "T20
verifies that the app never sets a user identifier" becomes a **standing CI guard in TEL-9**:
- no `setUserIdentifier`, `setUserId`, `setUserProperty` or `setDefaultEventParameters` anywhere in `app/`;
- only the two adapter files import the SDKs.

The policy's "Device-level diagnostics" bullet is rewritten by TEL-12 item 13. It is the same entry, now with numbers.

### D10. Web (A4, C4)
- No Analytics, no Crashlytics.
- `flutterfire_ignore_scripts = ['analytics']` in `app/web/flutterfire_config.js`, loaded synchronously before
  `flutter_bootstrap.js`.
- `Noop` adapters; CSP unchanged.
- TEL-9's web guard: no request to `firebase-analytics.js`, `googletagmanager.com` or `google-analytics.com`, and no CSP
  violation report.

### D11. Flags and ceilings (F7)
| Flag (wire name) | Gates (client only; no RPC) | Kill switch |
|---|---|---|
| `FEATURE_CRASH_REPORTING` (`crash_reporting`) | the crash switch on the card and in Settings, and Crashlytics collection (D3) | `off`: on the next `GetMe`, Dart-side reports stop at once; native capture stops at the next launch, which also deletes unsent reports (C1); the switch is hidden; the stored choice is kept |
| `FEATURE_ANALYTICS` (`analytics`) | the same for Analytics | `off`: on the next `GetMe`, collection off (Google documents no next-launch delay for Analytics, unlike Crashlytics; TEL-9 checks) |

- Registered like `FEATURE_SHELLS` (TEL-2); Terraform default `off` in both envs; never retired while the SDKs ship.
- **Ceilings:**
  - dev `{"mode": "allowlist", "max_allowlist": 6, "max_percent": 0}` for both (`scripts/promotion/flag-ceiling.json`,
    founder-gated);
  - **proposed prod ceiling `on` for both.** The file has no prod block for any flag, so the value is recorded here and
    in `docs/runbooks/client-telemetry.md` (TEL-2). Consent limits who sends, so a percent step buys little.
- **Ramp:**
  - dev allowlist (team test accounts, F9);
  - prod allowlist;
  - prod `on`.

  Each step is a Terraform change and the ADR-0019 release flow. Neither flag leaves `off` anywhere before the plan's
  "Before release" items, plus C6's screenshots.

### D12. The seam TEL-4 builds (`app/lib/core/telemetry/`)
- **Interfaces:**
  - `CrashReporter`: `record(error, stack, {fatal})` and `setCollecting(bool)`. `setCollecting` owns D3's crash order,
    including the bootstrap delete.
  - `UsageAnalytics`: `log(AnalyticsEvent)`, `screen(String name)`, `setCollecting(bool)` and `resetDevice()`.
- **Implementations:**
  - `firebase_crash_reporter.dart` and `firebase_usage_analytics.dart` are **the only files that import
    `firebase_crashlytics` or `firebase_analytics`**.
  - `Noop` implementations serve web, iOS (until TEL-16) and tests.
  - `TelemetryPlatforms.supportedOn = {android}`.
- **`TelemetryController`:** D3's decision and nothing else.
- **`CrashScrubber`:** F6.
- **`AnalyticsEvent`:** sealed, D5.
- **Error hooks:**
  - `FlutterError.onError` is the single sink. It presents the error in debug, then calls `CrashReporter.record`.
  - `PlatformDispatcher.instance.onError` calls `record` directly.
  - `UnexpectedErrorReporter` and `reportUnexpectedError` keep their signature and call sites (it still calls
    `FlutterError.reportError`), so no caller changes.
- **Not a server event:** these client events never touch the API, Pub/Sub or the `Events` / `Emitter` seams. They are
  not cross-module side effects.
- **Swap story:**
  - a web `ReportClientError` adapter, another vendor, or iOS is one adapter or one platform-set entry, with no caller
    change;
  - Stage 2 BigQuery export is a console link plus its own ADR, with no client change.

### D13. Failure modes and degradation
| Failure | Effect | Response |
|---|---|---|
| Google endpoints down or slow | SDKs queue on the device; the app and our API are unaffected | none |
| SDK update raises crash or ANR rate | user-visible | flag `off` (D11); last resort: drop the SDKs in the next store build |
| Personal data seen in a report or event | privacy incident | flag `off`; fix the scrubber or vocabulary; deletion per C5; runbook `client-telemetry.md` (TEL-2) |
| SDK traffic without consent (trace or report) | consent breach | flag `off`; rollback trigger; TEL-9 traces are the regression test |
| Prod build reports to dzeroth-dev | wrong project | TEL-14 blocks any prod raise |
| Cold start regression | latency | TEL-11 target: added p50 under 100 ms |
| Firestore quota, Pub/Sub backlog or DLQ, `DEGRADED_MODE` | not involved (0 operations) | none; `DEGRADED_MODE` does not touch client telemetry; the flag is the switch |
| Abuse: scripted fake events or crashes (the measurement ID and API keys are public) | console noise; INR 0 to us | numbers are never used for security, billing or moderation |

### D14. Security and abuse surface
- **New public reads or writes on our API: none.** So there is no per-user quota, no per-instance rate limit and no
  effective limit to state (0 × 3 instances). Nothing new to scrape or enumerate.
- **New outbound flow:** device to Google, after consent only.
- **Threats for TEL-10:**
  - payload leaks (F6, the TEL-5 canaries);
  - linkability (D4, the installation-ID join, C2's shared Crashlytics UUID, an allowlist of a few known testers);
  - consent bypass (native auto-init keys, persisted enable, cached reports, C1's native residual, C3's cookieless
    events, the merged-manifest `AD_ID`);
  - web (C4);
  - the FCM `label` field (C9);
  - the terms (C6);
  - supply chain (official FlutterFire packages; `osv-scanner` on `pubspec.lock`).

### D15. Observability, caches and staleness
- **Server:** no new request path and no new log line.
- **Client:** the Crashlytics console is the new client error signal (the `observability` skill's "Client: Firebase
  Crashlytics"). The decision changes are logged in debug builds only.
- **Staleness:**
  - flags: as of the last `GetMe` (about 4 per DAU per day; on a cold start the stored decision for the restored uid
    applies until then);
  - consent: immediate on this device for Dart-side reports and Analytics; native crash capture at the next launch (C1);
  - consoles: Google's processing delay (hours).
- **Caches:** no cache of ours; no instance cache, no Memorystore question.

## Cost impact
- **Fixed monthly cost added: INR 0.** No GCP resource, no Terraform resource besides the flag env vars, no
  `cost-guard` line. Both products are "No-cost" [S27]. No BigQuery link, no Performance Monitoring, no paid GA tier.
  Nothing depends on ADR-0022; nothing bills after 2026-12-26.
- **Free-tier quota consumed:**
  - Firestore: **0 reads, 0 writes, 0 deletes** per DAU per day.
  - Cloud Run: **0 requests, 0 vCPU-s** (no RPC; `GetMe` is not called more often).
  - Pub/Sub, Scheduler, Logging, Vision, Secret Manager, GCS: 0.
  - Device uploads go to Google, not through our egress.
- **Per RPC:** none. `GetMe` grows by at most about 35 bytes (`crash_reporting`, `analytics`) for callers the flags
  are on for. At 4 calls per DAU per day and 3,000 DAU that is about 13 MB a month of egress to India, under INR 0.2.

| Line | 300 DAU | 1,000 DAU | 3,000 DAU |
|---|---|---|---|
| Crashlytics, Google Analytics for Firebase | 0 | 0 | 0 |
| Firestore, Cloud Run, Pub/Sub, Vision | 0 | 0 | 0 |
| `GetMe` +35 B (egress to India) | 0 | 0 | ≈ 0.1 |
| Web `main.dart.js` +10 to 40 KB gzip (the plugins' Dart code is in the one dart2js bundle) | 0 (inside the free 360 MB/day) | 0 | ≈ 2 (upper bound) |
| Android download +1 to 2 MB | 0 (store-hosted) | 0 | 0 |
| **Total** | **0** | **0** | **≈ 2** |

**Re-check of the plan's line, 2026-11-01.** The inputs are from `docs/reviews/cost-model.md`:
- web share 30 %, about 4.3 prod web releases a month;
- Hosting transfer free 360 MB/day used up at about 2,731 DAU (§4), $0.15/GB past it, INR 95 per USD;
- 40 KB per web DAU per release (the upper estimate).

At 3,000 DAU that is 900 × 40 KB × 4.3 ≈ 0.155 GB, which is $0.023, which is **INR 2.2**. It matches the plan.

**The quota that moves, and 2× / 10×.** Only one free quota is touched: Firebase Hosting transfer (360 MB/day).
- The product uses it up at about 2,731 DAU, which implies about 132 KB per DAU per day.
- This ADR adds at most 0.3 × 40 KB × 4.3 / 30 ≈ 1.7 KB per DAU per day (+1.3 %).
- That moves the crossover to about **2,696 DAU** (upper bound).

| | DAU | Web bundle increment, INR per month |
|---|---|---|
| Crossover | ≈ 2,696 (was ≈ 2,731) | 0 below it |
| 2× | ≈ 5,390 | ≈ 4 (1,617 web DAU × 40 KB × 4.3 ≈ 0.28 GB) |
| 10× | ≈ 26,960 | ≈ 20 (8,088 web DAU × 40 KB × 4.3 ≈ 1.39 GB) |

- No Firestore, Cloud Run, Vision or GCS crossover moves.
- If TEL-3's `flutterfire_ignore_scripts` were missing, the extra `firebase-analytics.js` download comes from Google's
  CDN (`www.gstatic.com`), not our Hosting bill. It would still extend the policy's "when you load the web app" bullet,
  which is why C4 stops it.
- **Abuse as cost:** 0 on our bill. Fake events or crashes land in no-cost products with no export.
- **Trigger that justifies it:** none needed (no fixed cost). The scale-up triggers are in the Stage ladder.
- **Budget rows for `sre-performance` (TEL-11, `cost-model.md`):**
  - "client telemetry: 0 reads, 0 writes, 0 deletes, 0 requests per DAU";
  - `GetMe` +≤ 35 B;
  - web bundle +10 to 40 KB gzip (measure);
  - AAB +1 to 2 MB (measure with `bundletool get-size total`);
  - cold start p50 delta (measure; target under 100 ms).

## Stage ladder
Proposed row for the `stage-ladder` skill (text below, **not applied in this PR**). The trigger is measured over 30
days, as in the plan, because client error volume is too sparse at Stage 0 for 7 days to mean anything.

| Concern | Stage 0 (this ADR) | Seam to protect now | Stage 2/3 target (ADR) | Trigger |
|---|---|---|---|---|
| Client errors and usage | Crashlytics and Google Analytics for Firebase on Android only, opt-in per account on each device, device-level (no user id), a fixed event list, 2-month GA retention, no BigQuery link; web and iPhone collect nothing (web errors stay console-only; server errors in Error Reporting) | `CrashReporter` / `UsageAnalytics` in `app/lib/core/telemetry/`, with the SDKs imported only by the two adapter files; `UnexpectedErrorReporter` stays the only hook callers use; `AnalyticsEvent` is a sealed list; `TelemetryPlatforms.supportedOn` | **Web:** a `ReportClientError` RPC writing a scrubbed `severity=ERROR` line into Error Reporting (a new public write: quota, rate limit, security review), and/or web Analytics with a consent banner, the CSP hosts and the cookie text in the policy. **iPhone:** TEL-16. **Product analytics:** GA4 batch export to BigQuery (no streaming), its own ADR | web above 50 % of DAU, or 3 or more user-reported web-only failures in a month that server logs cannot explain (web rung); product questions the free GA reports cannot answer, at Stage 2 (20k DAU) (export rung); the Apple launch (iPhone) |

## Proposed gate-file text (not applied in this PR)
Both files are founder-gated (`.github/CODEOWNERS`). This ADR proposes the text and does not apply it. The founder
applies it, or tells the architect directly to apply it in a follow-up commit.

**`CLAUDE.md`, "Reference architecture (Stage 0)" table.** Replace the "Crash reporting" row and add one row under it:

```
| Crash reporting             | Firebase Crashlytics: **Android only, opt-in per account on each device, device-level (no user id)**, behind `FEATURE_CRASH_REPORTING` (ADR-0032) | free |
| Usage analytics             | Google Analytics for Firebase: **Android only, opt-in, device-level, fixed event list**; 2-month retention, no Google signals, no data sharing, no BigQuery link; no web Analytics (ADR-0032) | free |
```

**`.claude/skills/stage-ladder/SKILL.md`, main table.** Append after the "DDoS and cost attacks" row:

```
| Client errors and usage | Crashlytics and Google Analytics for Firebase on Android only, opt-in per account on each device, device-level (no user id), fixed event list, 2-month GA retention, no BigQuery link; web and iPhone collect nothing (ADR-0032) | `CrashReporter` / `UsageAnalytics` in `app/lib/core/telemetry/`; SDKs imported only by the two adapter files; `UnexpectedErrorReporter` stays the only hook callers use; `AnalyticsEvent` is a sealed list | Web: a `ReportClientError` RPC into Error Reporting (new public write: quota, rate limit, security review) and/or web Analytics with a consent banner and CSP hosts; product analytics: GA4 batch export to BigQuery (no streaming); iPhone at the Apple launch | Web above 50 % of DAU, or 3+ user-reported web-only failures a month that server logs cannot explain; product questions free GA reports cannot answer, at Stage 2 (20k DAU); measured over 30 days |
```

Optional, same gating (not needed for acceptance):
- `.claude/skills/observability/SKILL.md` "Client:" line: "Firebase Crashlytics (Android, opt-in, ADR-0032); Performance
  Monitoring not used".
- `.claude/skills/free-tier-budget/SKILL.md` §1: add "Google Analytics for Firebase" to the "FCM, Crashlytics, App
  Check" no-cost row.

## Consequences
**Positive.**
- Crashes on Android get seen, from the people who allow it, at INR 0 and 0 Firestore operations.
- A handful of product numbers answer F4's questions.
- Nothing is collected before consent or on the web, and nothing is linked to an account. The residue stays Q10 (f), so
  no eraser step, export section or rule bend is added.
- Every later move (web reporter, iPhone, another vendor, BigQuery) is an adapter, a platform-set entry or a console
  link.

**Negative.**
- Coverage is the opted-in share only.
- After an opt-out or a flag `off`, native crash capture continues until the next launch (C1).
- Two accounts on one device share a Crashlytics installation UUID (C2).
- A second third party (Analytics, separate terms) needs a console gate (C6) and store-form upkeep (TEL-13).
- The hosts and the Firebase Sessions behaviour rest on TEL-9's traces, not on Google's docs.
- Crash data cannot be deleted by us, only aged out or removed through Firebase support (C5).

**Revisit when:**
- a Stage ladder trigger fires;
- crash triage is blind for 30 days because too few people opt in (revisit F1 (B) with legal advice);
- Google changes the terms, retention or keys (re-read the Sources each quarter with `free-tier-budget`);
- TEL-9 shows any traffic before consent;
- legal review (maintainer note 1) reads the consent or processor position differently.

## Handoff
- **founder:**
  - Accept by merging this PR. TEL-12 may merge only after that.
  - Apply the proposed gate-file text, or ask the architect directly to.
  - Enter the TEL-13 console settings, including C6's two screenshots per GA account.
- **backend-developer (TEL-2):**
  - `FeatureCrashReporting` and `FeatureAnalytics` exactly like `FEATURE_SHELLS`: `LoadSpec(..., flags.Off)` on one
    line each, the registry, tests, Terraform variables default `off` in `envs/dev` and `envs/prod`.
  - `flag-ceiling.json`: dev allowlist 6, percent 0 (gate).
  - `docs/runbooks/client-telemetry.md`, which must contain:
    - the proposed prod ceiling `on`;
    - D11's kill switch wording (Dart-side at once, native at the next launch);
    - C5's deletion paths (Firebase support for Crashlytics; a GA data-deletion request, "all parameters on all
      events" for auto-collected ones);
    - D13's failure table;
    - "do not try to match allowlisted testers to reports".
  - Budget: 0 reads, 0 writes.
- **frontend-developer (TEL-3 to TEL-8):**
  - **TEL-3:**
    - the plan's Android and iOS keys (A5), with `_enabled=false` and never `_deactivated`;
    - `AD_ID` `tools:node="remove"`;
    - the SSAID key optional (C7);
    - `app/web/flutterfire_config.js` plus a synchronous `<script src>` before `flutter_bootstrap.js` (C4), with no
      `firebase.json` change.
  - **TEL-4:**
    - D3's order of calls, including `deleteUnsentReports` before enabling and at every off bootstrap;
    - the Dart-side gate;
    - the C3 consent order;
    - the D12 seam.
  - **TEL-5:** D6. **TEL-6:** D5.
  - **TEL-7:** D2, with C1's wording for "turn off" (native capture stops at the next launch).
  - **TEL-8:**
    - deletion and account switch per D2 and C1;
    - `account-deletion.md` §7: crash reports and usage statistics are device-level, cannot be found by account (Q10
      (f)), and are cleared on the device by deleting in the app or clearing the app's storage.
- **tester (TEL-9):**
  - The plan's guards, plus:
    - no `FirebaseInstallations.getId` in `app/`;
    - no FCM analytics label or message name from user data in `backend/` (C9);
    - the web build fetches no `firebase-analytics.js` (C4);
    - no assertion on the SSAID key.
  - Traces in the three plan states, plus:
    - (a) opt in after a pre-consent native crash: nothing from before consent arrives;
    - (b) opt out, force a native crash in the same run, relaunch: record whether it arrived (C1 residual);
    - (c) Analytics on, Crashlytics off, force a crash: is `app_exception` logged (C8);
    - (d) no Firebase Sessions traffic in the no-consent and flag-off states (A5e);
    - (e) the Crashlytics installation UUID after "clear storage" (C2).
  - Record the actual hosts for the Data inventory.
- **security-auditor (TEL-10):**
  - D14's list, the installation-ID join ("no identifier sent to Google is keyed to or joinable with a uid"), C1's
    native residual, C3, C9, and the terms reading (A2, C6).
- **sre-performance (TEL-11):**
  - The budget rows in Cost impact; re-check the pricing page; measure the bundle, AAB and cold-start deltas.
  - Feed `cost-model.md`; do not edit this ADR.
- **architect (TEL-12):**
  - The policy draft on the A2 and A3 answers.
  - Crashlytics names the Firebase DPST. Analytics names the GA Terms and the Google Ads Data Processing Terms
    (processor only once C6's screenshots exist).
  - Crash reports: "Google starts deleting them after 90 days".
  - Usage events: 2 months; aggregated reports contain totals only.
  - C1's wording in item 12; C2's correction in item 6.
  - Maintainer note 8 extended to the Analytics terms.
  - Note 21 replaced as the plan says.
- **production-deployer (TEL-13, TEL-14, TEL-15):**
  - TEL-13:
    - F5 in both GA properties;
    - C6's screenshots;
    - the `measurementId` check;
    - Play Data safety (Crash logs, Diagnostics, App interactions, Device or other IDs; collected, optional, processed
      by a service provider, encrypted in transit) before a Play build with the SDKs leaves internal testing.
  - TEL-14: the prod `google-services.json` swap (gate file) before any prod raise.
  - TEL-15: a dev allowlist of team test accounts only, after the plan's "Before release" list and C6. Prod prepared,
    not applied.

## Sources (all read 2026-11-01)
- [S1] Firebase, Privacy and Security in Firebase (last modified 2026-09-24): https://firebase.google.com/support/privacy
- [S2] Firebase terms of service listing (last modified 2026-09-24): https://firebase.google.com/terms
- [S3] Firebase Data Processing and Security Terms (last modified 2024-08-21): https://firebase.google.com/terms/data-processing-terms
- [S4] Analytics Help, Data Processing Terms: https://support.google.com/analytics/answer/3379636
- [S5] Google Ads Data Processing Terms, v8.0 (2024-05-30): https://business.safety.google/adsprocessorterms/
- [S6] Google Ads Data Protection Terms: Service Information (last update 2025-10-23): https://business.safety.google/adsservices/
- [S7] Analytics Help, Data sharing settings: https://support.google.com/analytics/answer/1011397
- [S8] Analytics Help, Data retention: https://support.google.com/analytics/answer/7667196
- [S9] Analytics Help, IP masking (GA4 statement): https://support.google.com/analytics/answer/2763052
- [S10] Analytics Help, EU, Switzerland, or UK-focused data and privacy (granular location and device data): https://support.google.com/analytics/answer/12017362
- [S11] Firebase, Prepare for Google Play's data disclosure requirements (2026-10-28): https://firebase.google.com/docs/android/play-data-disclosure ([S11b] Crashlytics, Sessions, Installations entries)
- [S11c] Analytics Help, Prepare for Google Play's data disclosure requirements: https://support.google.com/analytics/answer/11582702
- [S12] FlutterFire `firebase_core_web` source, `main`: https://github.com/firebase/flutterfire/blob/main/packages/firebase_core/firebase_core_web/lib/src/firebase_core_web.dart
- [S13] FlutterFire `firebase_analytics_web` source, `main`: https://github.com/firebase/flutterfire/blob/main/packages/firebase_analytics/firebase_analytics_web/lib/firebase_analytics_web.dart
- [S14] Firebase, Configure Analytics data collection, Android (2026-10-28): https://firebase.google.com/docs/analytics/android/configure-data-collection
- [S15] Firebase, Configure Analytics data collection, Apple platforms (2026-10-28): https://firebase.google.com/docs/analytics/configure-data-collection?platform=ios
- [S16] Google tag platform, Consent mode for apps, Android (2026-07-30): https://developers.google.com/tag-platform/security/guides/app-consent?platform=android
- [S17] Firebase, Measure screenviews (2026-10-28): https://firebase.google.com/docs/analytics/screenviews
- [S18] Firebase, Customize Crashlytics crash reports, Flutter and Android (2026-10-28): https://firebase.google.com/docs/crashlytics/flutter/customize-crash-reports and https://firebase.google.com/docs/crashlytics/android/customize-crash-reports
- [S19] firebase-android-sdk PR #6852 (merged 2025-04-09): https://github.com/firebase/firebase-android-sdk/pull/6852
- [S20] pub.dev, `firebase_crashlytics` 6.0.1 `FirebaseCrashlytics` API: https://pub.dev/documentation/firebase_crashlytics/latest/firebase_crashlytics/FirebaseCrashlytics-class.html
- [S21] Analytics Help, Consent mode on websites and mobile apps: https://support.google.com/analytics/answer/9976101
- [S22] pub.dev, `firebase_analytics` 13.0.1 `FirebaseAnalytics` API: https://pub.dev/documentation/firebase_analytics/latest/firebase_analytics/FirebaseAnalytics-class.html
- [S23] Analytics Help, Automatically collected events: https://support.google.com/analytics/answer/9234069
- [S24] Analytics Help, [GA4] Predefined user dimensions: https://support.google.com/analytics/answer/9268042
- [S25] Analytics Help, Data-deletion requests: https://support.google.com/analytics/answer/9940393
- [S26] Google Analytics Admin API, User Deletion (`properties.submitUserDeletion`, 2026-04-14): https://developers.google.com/analytics/devguides/config/userdeletion/v3
- [S27] Firebase pricing (Crashlytics and Analytics "No-cost"): https://firebase.google.com/pricing
- [S28] Firebase Crashlytics API v1alpha, `projects.apps.users.deleteCrashReports` (method text read through Google's generated client reference): https://firebase.google.com/docs/reference/crashlytics/rest/v1alpha/projects.apps.users/deleteCrashReports and https://googleapis.github.io/google-api-python-client/docs/dyn/firebasecrashlytics_v1alpha.projects.apps.users.html
- Play Console Help, Advertising ID (SDKs such as Play services merge `AD_ID` by default): https://support.google.com/googleplay/android-developer/answer/6048248
