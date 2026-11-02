# Security review: client crash reporting and usage analytics (TEL-10)

**Reviewer:** security-auditor · **Date:** 2026-11-02 · **Reviewed:** branch `docs/tel-10-security-review` at `e01885e5` (= `origin/main`), read only. It contains TEL-1 #595, TEL-2 #597, TEL-3 #598, TEL-4 #608, TEL-5 #609, TEL-6 #611, TEL-7 #612, TEL-8 #635 and TEL-14 #593.

**Verdict: CLEAR WITH CONDITIONS.** There are no Critical or High findings: two Medium (M-1, M-2), four Low and seven Info. The plan's acceptance line, "no identifier sent to Google is keyed to or joinable with a uid", is issued **only in the scoped form of section 4**:
- what the app itself sends is verified;
- the Firebase installation ID cannot be joined with a uid from any surface we can read (M-2 closed 2026-11-02, C-3 met).

The TEL-9 Android device evidence ran on 2026-11-02 (test report section 6c); the web trace and C-4 are still open (C-1, C-4). Nothing here blocks code that serves traffic. Both flags are `off` in every project: in dzeroth-dev this was checked against Cloud Run and `GetMe` after the TEL-9 session (both flags were allowlisted for one test account only during it); prod rests on the plan (TEL-15 Open) and the Terraform defaults. So no telemetry flows today.

**Design:**
- ADR-0032 (Accepted 2026-11-01): F1 to F11, C1 to C10 and D1 to D15.
- Plan `docs/plans/client-crash-analytics.md`: F6, F7, "Abuse & security surface" and the TEL-10 ticket.
- Runbook `docs/runbooks/client-telemetry.md`.
- `app/web/privacy.html`, maintainer note 21 and the live text.

**Code read:**
- `app/lib/core/telemetry/*`: all 17 files.
- `app/lib/core/router/screen_names.dart`.
- `app/lib/app/bootstrap.dart`, the telemetry wiring.
- `app/lib/core/storage/app_database.dart`: `AppSettingEntries`, `clearAll` and `claimCacheFor`.
- `app/lib/features/account/presentation/delete_account_screen.dart`.
- The call sites of the events: `composer_cubit.dart`, `follow_button.dart` and `app_search_field.dart`.
- Android:
  - `app/android/app/src/{main,debug,profile}/AndroidManifest.xml`;
  - `app/android/app/build.gradle.kts` and `settings.gradle.kts`;
  - `res/xml/data_extraction_rules.xml`;
  - `MainActivity.kt`.
- iOS: `app/ios/Runner/Info.plist`.
- Web: `app/web/index.html` and `app/web/flutterfire_config.js`.
- `firebase.json` at the repo root. The Hosting CSP lives there; `firebase/` holds only the rules, indexes and ack.
- `backend/internal/notifications/fcm.go` (`buildMessage`).
- `backend/pkg/platform/config/config.go`, the flag specs.
- `scripts/promotion/flag-ceiling.json`.
- `infra/terraform/envs/{dev,prod}/variables.tf`, the `feature_crash_reporting*` and `feature_analytics*` variables.

**Third-party artifacts read, in the local caches, read only:**
- Pub cache: `firebase_analytics` 12.6.1 and `firebase_crashlytics` 5.4.1 (plugin manifests and Gradle files); `firebase_core_web` 3.12.0 (`_ignoredServiceScripts`); `firebase_analytics_web` 0.6.1+13 (the lazy instance); `firebase_core` 4.15.2 (`FirebaseSDKVersion=34.19.0`).
- Gradle cache:
  - the `firebase-bom` 34.19.0 POM, which maps `firebase-analytics` to 23.2.0 and `firebase-crashlytics` to 20.1.1;
  - the transformed AAR manifests of `play-services-measurement{,-api,-impl,-sdk,-sdk-api,-base}` 23.2.0, `play-services-ads-identifier` 18.0.0, `firebase-crashlytics` 20.1.1 and `firebase-sessions` 3.0.8;
  - strings in `firebase-sessions` 3.0.8 `classes.jar` and `firebase-messaging` 25.1.3 `GmsRpc.class`.

**Run:**
- `flutter test test/core/telemetry test/core/router/screen_names_test.dart` (Flutter 3.47.5): **69 tests passed**. They include the TEL-5 canaries, the 2×2×2×2 decision matrix and the TEL-8 account-switch tests.

**Not run or not available:**
- No Android device is connected, so there are no network traces, no merged manifest and no `apkanalyzer` output.
- No Firebase or GA console access and no `gcloud`. The role is read only.
- No Gradle build was run, so **no merged manifest exists on disk**. The merged-manifest statements below are reasoned from the cached AAR manifests that the locked BoM resolves to, and are marked as such.
- `osv-scanner` and `govulncheck` are not installed on this machine. The SDK packages are official FlutterFire releases, locked in `pubspec.lock`, and Dependabot is on (#624).

**Inputs from the tester:** none yet. TEL-9 is Open, `docs/reviews/tests/test-report-client-telemetry.md` does not exist, and the TEL-9 worktree is empty.

## Scope
The scope is a new **outbound data flow from the Android app to Google**: Crashlytics, Firebase Sessions and Google Analytics for Firebase. It is gated by:
- two client-only flags;
- per-account, per-device opt-in consent;
- a single Dart decision point, `TelemetryController`.

There is **no new RPC, Firestore path, Storage object, Pub/Sub topic, Scheduler job or endpoint**. So there is no new public read or write to scrape, enumerate or flood, and no per-user quota or rate limit to state.

## 1. Threat model (STRIDE)
Assets:
- the person's crash and usage data;
- the promise "not linked to your account" (ADR-0011 Q10 (f), ADR-0032 D4 and D9, and the consent copy);
- consent integrity;
- our consoles as a decision input.

| STRIDE | Threat | Control today | Residual / finding |
|---|---|---|---|
| **S**poofing | Anyone with the public `google_app_id`, API key and project number (they are in the APK and in `google-services*.json`) runs the SDK or a repackaged app, and sends forged crashes and events into dzeroth-dev or dzeroth-prod. App Check does not cover Crashlytics or GA endpoints | The numbers are never used for security, billing or moderation (ADR-0032 D13) | L-4: forged "leaks" can trip the rollback trigger. INR 0 |
| **T**ampering | A modified client turns collection on without consent | Only on the attacker's own device. Consent is device-local, and no RPC can change another person's consent or flags | none |
| **T**ampering | A server flag change makes others collect | A flag only gates. Collecting needs the flag **and** a stored "on" for that uid on that device **and** Android **and** a signed-in uid (`TelemetryController.crashCollecting` and `usageCollecting`; matrix test) | none |
| **R**epudiation | We cannot show that a given person consented: the consent record exists only on their device | By design: no account link (F3) | Founder question Q-1, the DPDP burden of proof (section 6) |
| **I**nformation disclosure | Personal data in crash payloads | F6 rules (`crash_payload.dart`, `crash_scrubber.dart`); `recordError` only, never `recordFlutterError`; empty `reason` and `information`; canaries pass | L-3: native Java or Kotlin exception messages bypass the scrubber |
| **I**nformation disclosure | Linkability to an account | No user id, property or default parameter; 3 fixed custom keys; enum and bool event parameters; template screen names; GA ID reset on an account switch | M-2: the Firebase installation ID versus the per-uid FCM token (open). L-2: hardening of the first-sign-in reset |
| **I**nformation disclosure | Advertising identifiers | `AD_ID` removed; `google_analytics_adid_collection_enabled=false`; ad consent denied | M-1: the AdServices AdId and Attribution permissions stay in the merged manifest |
| **I**nformation disclosure | Collection before consent | Native off keys; Dart gate; bootstrap re-apply with a forced SDK call; `deleteUnsentReports` on every "off" and at every off bootstrap | L-1 (D3 order); the C1 native residual (accepted in the ADR); TEL-9 traces (C-1) |
| **D**enial of service | The SDK crashes or ANRs the app; telemetry blocks startup | Every adapter call is queued and its errors are swallowed (`_enqueue`); flag `off` is the kill switch; TEL-11 measures cold start | Forged reports could force a kill-switch use (L-4) |
| **E**levation of privilege | none | The flags are client-only and gate no RPC (`config.go` `LoadSpec(..., flags.Off)`; registry only) | none |

### Effective limits and cost amplification
- **Effective limit: not applicable.** There is no endpoint, so the effective limit is 0 per instance × 3 max instances.
- **Cost-amplification scenario: none on our bill. INR 0 at any attack volume.**
  - A flood of forged crashes or events lands in Google's no-cost Crashlytics and GA products.
  - Neither product has a BigQuery export (on the Stage 0 "not used" list; ADR-0032 D1).
  - Nothing reaches Cloud Run, Firestore, Logging, Pub/Sub or Vision.
  - The only billed line ADR-0032 adds is the web bundle (+10 to 40 KB gzip, about INR 2/month at 3,000 DAU, TEL-11). An attacker cannot amplify it beyond ordinary page loads, which the Hosting quota already covers.

## 2. Findings
| ID | Severity | Where | Finding | Fix | Status |
|---|---|---|---|---|---|
| M-1 | Medium | `app/android/app/src/main/AndroidManifest.xml` (merged manifest); the `play-services-measurement-api` and `play-services-measurement-sdk-api` 23.2.0 manifests | **The merged manifest keeps two advertising-related permissions.** BoM 34.19.0 resolves `firebase-analytics` 23.2.0. Its `play-services-measurement-api` and `-sdk-api` AAR manifests declare `com.google.android.gms.permission.AD_ID`, `android.permission.ACCESS_ADSERVICES_AD_ID` and `android.permission.ACCESS_ADSERVICES_ATTRIBUTION`. The app removes only `AD_ID` (`tools:node="remove"`, which also covers the copies in `-impl` and `play-services-ads-identifier` 18.0.0). The two `ACCESS_ADSERVICES_*` permissions are not removed, so they merge in. They let the SDK call the platform AdServices advertising-ID API and Attribution Reporting API (Android 13+). **Reasoned from the cached AARs; no merged manifest exists on disk.** Whether GA calls those APIs with `google_analytics_adid_collection_enabled=false` and `ad_storage` / `ad_user_data` denied is **unverified**, and I do not claim it does. **Exploit scenario (disclosure accuracy):** F5's app-side control ("advertising ID collection off, `AD_ID` removed"), TEL-12's "no advertising ID", and the TEL-13 Play Data safety and Advertising ID declaration answers would all be stated for a build that still asks the OS for advertising-ID and attribution access. A store reviewer or a user inspecting the APK's permissions sees them. Cost: INR 0 | Add to the app manifest, next to the `AD_ID` line: `<uses-permission android:name="android.permission.ACCESS_ADSERVICES_AD_ID" tools:node="remove"/>` and `<uses-permission android:name="android.permission.ACCESS_ADSERVICES_ATTRIBUTION" tools:node="remove"/>`. TEL-9's manifest guard then asserts that **all three** are absent from the **merged** manifest of a release build (`apkanalyzer manifest permissions` or `aapt2 dump permissions`), not only from the source manifest. Re-check at every BoM bump, because a new transitive permission arrives silently | Fixed (C-2 met) |
| M-2 | Medium | `users/{uid}/devices/{deviceId}.token` (server); Crashlytics and Sessions requests (device) | **Possible join between an identifier Google receives and a uid.** ADR-0032 says the server "stores FCM tokens per uid, never the installation ID", so "we hold nothing that joins a Crashlytics report to an account". There are three signs that the stored token may carry the Firebase installation ID (FID): (1) the FCM SDK registers with `appid` taken from Firebase Installations (`GmsRpc` in `firebase-messaging` 25.1.3: `appid`, `FirebaseInstallationsApi`); (2) FCM tokens seen in the wild have a 22-character prefix before `:`, and an FID is 22 characters; (3) our own `fcm.go` notes that the Admin SDK now offers `Fid` as an addressing field. Crashlytics sends the FID with its reports (ADR Data inventory, [S1] and [S11b]). The Sessions settings fetch to `firebase-settings.crashlytics.com` uses it too (the `RemoteSettings` strings in `firebase-sessions` 3.0.8). If the prefix is the FID, **and** any Crashlytics surface we can read shows the FID, then an operator with Firestore and Crashlytics console access could tie a crash report to a uid. Google does not document the token format: **UNVERIFIED**. Exposure is insiders only, who already hold all account data. The harm is that the user-facing promise "Not linked to your account" and the basis of Q10 (f) would be inaccurate | Check on a debug device (C-3), **without** adding `FirebaseInstallations.getId` to app code; the TEL-9 guard stays. (1) Compare the FCM token prefix with the FID, using `adb logcat` with `FirebaseInstallations` / `FirebaseMessaging` debug logging, or a throwaway scratch build that is never merged. (2) Look at a test crash in the dzeroth-dev Crashlytics console (event view, Data and Keys tabs) for any field that shows the FID. **If both are true:** the architect amends ADR-0032 D9 and the TEL-12 wording ("Google can link these to the push registration; we do not"), and the runbook adds "never compare `devices.token` with console data". Optionally, restrict who has both Firestore and Crashlytics console access. **If either is false:** record the evidence here, and the unqualified line in section 4 can be issued | Closed 2026-11-02 (C-3 met). TEL-9 Part B (test report section 6c): (1) on a debug device, the FCM token prefix **equals** the FID (compared on the device, values never recorded); (2) in the dzeroth-dev Crashlytics console, the forced native test crash (trace (b)) shows **no** FID in the stack trace, the Keys (exactly `build_number`, `FIREBASE_ENV`, `platform`), the Logs (one `screen_view` breadcrumb, `home` / `MainActivity`) or the Data tab (device model, RAM, disk, OS, rooted, date, app version). Part 2 is false, so per the plan's M-2 outcome there is no ADR amendment and no new ticket; the section 4 line is issued. Firebase Sessions also sends the FID (L-5), but to no surface we can read. Standing rule (runbook): never enable a Crashlytics BigQuery or Cloud Logging export, and never compare `devices.token` with console data. |
| L-1 | Low | `telemetry_controller.dart` `_decide`; `firebase_crash_reporter.dart` `setCollecting`; test `telemetry_controller_test.dart:185` | **The crash "on" path skips ADR-0032 D3 step 1.** D3 (Accepted) says: on, first `deleteUnsentReports()` while native collection is still off, then `setCrashlyticsCollectionEnabled(true)`, so nothing recorded before consent is ever sent. The controller enqueues only `setCollecting(true)`, and the test pins `['crash.setCollecting(true)']`. The bootstrap "off" delete covers most cases. It does not cover these: a bootstrap delete that ran before Crashlytics finished picking up a previous run's report (for example an ANR from `ApplicationExitInfo`), or a delete whose error `_enqueue` swallowed. In those cases a pre-consent report (stack traces, device data) uploads the moment the person opts in. Cost: INR 0 | In `_decide`, when `crash` becomes true, enqueue `_crash.deleteUnsentReports` **before** `_crash.setCollecting(true)`. It is a no-op while native collection is on, so it is safe in every state. Update the test to `['crash.deleteUnsent', 'crash.setCollecting(true)']`. TEL-9 trace (a) shows the result | Fixed (C-6 met) |
| L-2 | Low | `telemetry_controller.dart` `_noteSignIn`, `forgetDevice` | **The first-sign-in rule leaves two small gaps in F11.** TEL-8 resets the GA app-instance ID only when a *different* uid was recorded, so `last == null` means no reset. (a) In `forgetDevice` the reset runs inside `_enqueue`, which swallows a failure, and then `_lastUid.forget(uid)` still clears the record. The next account to sign in is then treated as a first sign-in and inherits the deleted account's ID. (b) If `_lastUid.read()` throws, the whole enqueued block is dropped, so there is no reset and no record. Cost: INR 0 | See section 3.2: reset when `last != uid`, **including** `last == null`, and reset when the record cannot be read (fail closed). Update the test "first sign-in on a device (no record) resets nothing" | Fixed (C-6 met) |
| L-3 | Low | Crashlytics native handler; ADR-0032 Data inventory and D6; TEL-12 item 6; the consent card copy | **Native (Java or Kotlin) exception messages reach Crashlytics unscrubbed.** F6 and the scrubber apply to Dart errors. An uncaught exception in a plugin or the engine on the Android side is captured by the Crashlytics `UncaughtExceptionHandler`, with its message: for example a file path or content URI from `image_picker`, or a SQLite message. The ADR's inventory ("the message only for allowlisted types after the scrubber") and TEL-12's planned "never the text you wrote or saw" are written for Dart only. The realistic content is paths and URIs, not post or message text. Cost: INR 0 | Do not build a native scrubber at Stage 0. (1) The ADR inventory (an architect note) and TEL-12 item 6 say that a crash in Android's own code carries Android's error message, which can include a file name. (2) TEL-9 trace (b) records what a forced native crash report shows | Open (C-5) |
| L-4 | Low | `docs/runbooks/client-telemetry.md` rollback triggers | **Forged reports can trip the rollback trigger.** "Any crash report or event containing an id, handle, email or user text" is a rollback trigger. Anyone can plant such a report (see Spoofing), forcing a kill switch or planting third-party personal data in our consoles. Cost: INR 0 | Add a triage step before treating a report as a leak. Check that: the build number is in a shipped range; the top frames are `package:dzeroth/` or our plugins; and the text sits where our code can put text (only allowlisted Dart types carry a message; native messages per L-3). A report that fails these checks is treated as forged: delete it through Firebase support or a GA data-deletion request, and do not roll back. Also: never create a GA Measurement Protocol `api_secret` for either property (TEL-13), which keeps the scripted path to the SDK only | Open (ticket) |
| L-5 | Low | Firebase Sessions 3.0.8 via DataTransport; ADR-0032 C1 and Data inventory; runbook Kill switch; TEL-9 state 2 | **The run that first learns a flag `off` still starts with the previous native setting.** TEL-9 F-1: the app was force-stopped after the flags went off, then relaunched. Before Dart ran, the persisted "enabled" made Crashlytics fetch `firebase-settings.crashlytics.com` and made Sessions queue a `SESSION_START`. DataTransport sent it to `firebaselogging-pa.googleapis.com` about 1 min later, after both SDKs were disabled. The same pattern appears in trace (a) (about 35 s) and trace (b). By static read the event carries the FID, an FIS auth token, session ids, app, device and OS fields, and an envelope with build fingerprint, locale, country, MCC/MNC, network type and timezone; no account data. The next relaunch sends nothing (s2b PASS). Consent is not affected: a withdrawal on the device persists `false` before the next launch. The remembered-flag bootstrap is not the cause and stays (I-7). Cost: INR 0 | (1) Runbook Kill switch and ADR C1: "native capture and the SDKs' own traffic stop from the launch after the run whose `GetMe` returned `off`; that run still starts with the previous native setting (one Crashlytics settings fetch and one Firebase Sessions start event, which carries the installation ID)". (2) ADR inventory, Sessions column (architect note): identifiers FID and FIS token; host `firebaselogging-pa.googleapis.com`; the envelope fields; A5e VERIFIED (gated by Crashlytics data collection at cold start). (3) TEL-9 state 2 is defined as the second relaunch (or a relaunch after an in-run `GetMe`), and F-1 is closed as a procedure error. (4) Runbook: no Crashlytics BigQuery or Cloud Logging export. (5) Optional, architect: `firebase_sessions_enabled=false` after checking its cost to console metrics | Open (C-1, C-5) |

### Info (verified, no finding)
| ID | Where | Note |
|---|---|---|
| I-1 | `firebase_crash_reporter.dart` `breadcrumb()` | Public and **not gated** by the controller. It calls `CrashlyticsPort.log` directly, but it has no caller in `app/lib`. If it is wired later, route it through `TelemetryController` (as `recordError` is), or a breadcrumb could be logged while the decision is off. TEL-9's import guard does not catch this, because it is inside an adapter file |
| I-2 | `firebase.json` CSP | `script-src` and `connect-src` contain no `googletagmanager.com` or `google-analytics.com` (verified). `img-src https:` would let through an image-beacon fallback if a GA script ever ran. The real fences are the ignored script (C4) and the missing gtag host in `script-src`. The plan's "`firebase/firebase.json`" is the root `firebase.json` |
| I-3 | `firebase-sessions` 3.0.8 | The shipped jar gates session events on subscriber data collection ("Sessions SDK disabled through data collection. Events will not be sent."; `shouldLogSession`, `isDataCollectionEnabled`). Whether the remote-settings fetch (`firebase-settings.crashlytics.com`, which uses the FID) runs before that gate cannot be told statically. TEL-9 (d) must list that host among those asserted absent (C-1) TEL-9: Sessions is gated by Crashlytics data collection at cold start; it sends nothing while collection is off natively (states 1, 3 and 4 at cold start, s2b), and sends one `SESSION_START` per cold start while it is on (L-5). |
| I-4 | `scripts/promotion/flag-ceiling.json` | Dev `ANALYTICS` and `CRASH_REPORTING` are both `{"mode": "allowlist", "max_allowlist": 6, "max_percent": 0}`, which equals F7. `prod` has no block for any flag, so the proposed prod ceiling `on` lives only in ADR-0032 D11 and the runbook (line 31). Prod "Before release" gating is therefore enforced by the founder's plan review and ADR-0019, not by a validator. That is consistent with every other flag |
| I-5 | `AppSettingEntries` | `telemetry_consent:{crash,usage}:<uid>`, `telemetry_flags:<uid>` and `telemetry_last_uid` hold uids on the device: kept on sign-out, forgotten on in-app deletion, never passed to an SDK. `data_extraction_rules.xml` and `allowBackup="false"` keep them out of backup and device transfer, along with the SDKs' own IDs. The table's doc comment "holds no personal data" is out of date (the push opt-in keys already hold uids). Wording only |
| I-6 | `fcm.go` `buildMessage` | No `FCMOptions`, `AnalyticsLabel`, topic or message name (C9 verified). The title and body are fixed per type (`pushText`). The `Send` response (the message id that GA's `notification_*` events carry) is discarded (`if _, err := client.Send`) and never logged or stored, so it cannot be joined. But `data` carries `actorId` (a uid), `postId`, `notificationId` or `conversationId`. C-4 confirms that none reach GA |
| I-7 | Kill-switch latency | A cold start applies the stored flags of the restored uid until the first `GetMe` (documented staleness). If `GetMe` keeps failing (offline from our API, service paused), Dart-side collection continues under the last decision. Acceptable: consent still holds, and the runbook's next-launch wording already covers the native side |

## 3. Answers to the review items
### 3.1 F6 canaries: they fire, and they are safe
- `crashPayloadFor` hands the SDK a `CrashPayload` whose `toString()` is the type, or `type: scrubbed message` for an allowlisted type only. The allowlisted types are `TypeError`, `AssertionError`, `StateError`, and `FlutterError` with a first line matching the layout pattern.
  - `ConnectException` sends `code` plus the `ErrorReason` name.
  - `FlutterErrorDetails` sends the exception only; `recordFlutterError` forwards `details.exception` and `details.stack`.
  - `recordError` is called with `printDetails: false` and no `reason` or `information`.
- **What the canary tests put in payloads:** the canary string `ZZCANARY123456789` is planted in a `Text` build error (`context` and `informationCollector`), `jsonDecode` input, a `NoSuchMethodError` receiver, `ArgumentError.value`, `RangeError`, a `PlatformException` message and details, a `ConnectException` message, a GoRouter no-route location, and an email and @handle in allowlisted types. Every test asserts that no argument passed to the fake Crashlytics port contains the canary or a run of 6 or more digits. **All pass (run above).** The canaries are test-only constants and never ship.
- Every app-side `StateError` is built from a fixed string. This includes the freezed `'Unexpected subclass'`, and none interpolates runtime data (grep of `app/lib`).
- **Custom keys:** exactly `build_number`, `FIREBASE_ENV` and `platform` (`CrashKeys`), with no flag list.
- **Breadcrumbs:** the `CrashBreadcrumb` enum only, and nothing calls it today (I-1).
- **Scrubber limits (accepted by design):** bare handles without `@` and display names are not matched. Only code-generated messages reach the scrubber, so this matters only if a future allowlisted type interpolates user data.

### 3.2 Linkability
| Identifier sent to Google | By | Keyed to a uid? | Joinable by us? | Status |
|---|---|---|---|---|
| GA app-instance ID | Analytics | No: device-level; reset on a switch to a different account and on in-app deletion (F11) | No: the app never calls `getAppInstanceId`, and we store none | Verified (code, tests) |
| Crashlytics installation UUID | Crashlytics | No: device-level, shared by accounts on one device (ADR C2, accepted) | No: never read or stored by us | Verified (code) |
| Firebase installation ID | Crashlytics reports, the Sessions settings fetch and SESSION_START event (firebaselogging-pa, L-5), FCM registration (pre-existing) | No: the app never calls `getId` | No from any surface we can read: the FCM token prefix equals the FID, but no Crashlytics view shows the FID and Sessions events are aggregated (M-2 closed) | Verified (device and console, TEL-9 6c) |
| FCM message id | FCM to GA `notification_*` events (if the SDK logs them) | No | No: our backend discards it | Verified (code) |
| Custom keys, event parameters, screen names | Both | No: 3 fixed keys; Dart enums and bools; template table (`screenNameForTemplate(top.route.path)`, never `uri` or `matchedLocation`) | No | Verified (code, tests) |
| FCM `data` keys (`actorId`, `postId` and others) | FCM payload, on device | They are uids and ids | Only if the SDK copied them into GA events | C-4 |
| Allowlist (at most 6 team accounts) | Both, during the dev ramp | No | Recognisable by us (accepted; runbook "do not match") | Accepted |

**The no-reset-on-first-sign-in choice (TEL-8).** I recommend changing it: **reset also when no uid is recorded**.
- TEL-8's reason for not resetting is the GA user count. It does not apply to a first sign-in. Collection needs a signed-in, consenting uid, so the ID that exists before the first recorded sign-in has never sent an event, and resetting it adds no GA user. (One residual: an upgrade from a pre-TEL-8 build that had already collected. That never happened, because both flags have been `off` everywhere.)
- The benefit is closing L-2's paths: a failed reset in `forgetDevice` followed by a cleared record, an unreadable record, or any future path that loses `telemetry_last_uid` while the SDK keeps its ID.
- The cost is one local `resetAnalyticsData()` per device, at its first recorded sign-in and again after an in-app deletion.
- Also fail closed: when `_lastUid.read()` throws, reset.

### 3.3 Consent bypass
**Native off values, by reading:**
- Android `<application>` meta-data:
  - `firebase_crashlytics_collection_enabled`, `firebase_analytics_collection_enabled`, `google_analytics_adid_collection_enabled`, the four `google_analytics_default_allow_*` keys and `google_analytics_automatic_screen_reporting_enabled` are all `false`;
  - SSAID is `false` (not a control, C7);
  - `firebase_analytics_collection_deactivated` is absent, which is correct (A5).
- iOS `Info.plist`: `FirebaseCrashlyticsCollectionEnabled`, `FIREBASE_ANALYTICS_COLLECTION_ENABLED`, `FirebaseAutomaticScreenReportingEnabled`, `GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED` and the four `GOOGLE_ANALYTICS_DEFAULT_ALLOW_*` keys are all `false`, and iOS uses the `Noop` adapters anyway.
- The `debug` and `profile` manifests add only `INTERNET`. The plugin manifests (`firebase_analytics` 12.6.1, `firebase_crashlytics` 5.4.1) add no meta-data that overrides these.

**`AD_ID` in the merged manifest** (reasoned from the Gradle cache, because no merged manifest exists on disk):
- `AD_ID` is declared by `play-services-measurement-api`, `-impl` and `-sdk-api` 23.2.0 and by `play-services-ads-identifier` 18.0.0.
- The app's `tools:node="remove"` has the highest merge priority, so it removes `AD_ID` from all of them.
- `ACCESS_ADSERVICES_AD_ID` and `ACCESS_ADSERVICES_ATTRIBUTION` remain (M-1).
- `BIND_GET_INSTALL_REFERRER_SERVICE` remains too. GA reads the Play install referrer for `first_open` campaign data once it collects. No link of ours carries a referrer: there is no `play.google.com` or `utm_` link in `app/lib`.

**Dart path:**
- Only `firebase_crash_reporter.dart` and `firebase_usage_analytics.dart` import an SDK (grep of `app/lib`, `app/android`, `app/ios` and `app/web`).
- `MainActivity.kt` has no Firebase call.
- Adapters are built only when `TelemetryPlatforms.current` (Android, not web); otherwise they are `Noop`.
- Every record, event and screen goes through `TelemetryController`, which checks the synchronous decision first. A uid whose consent is not loaded reads as unasked, which is off.
- `onAuthChanged` drops the flags until that account's own `GetMe`.

**Persistence (A6):**
- `applyAtBootstrap` always calls both SDKs (`force: true`).
- Every "off" enqueues `deleteUnsentReports` (verified in tests).
- The missing pre-enable delete is L-1.

**Cookieless pings (C3):** collection is never enabled with `analytics_storage` denied. "On" grants consent and then enables; "off" disables and then denies (`firebase_usage_analytics.dart`).

**Native residual (C1):** accepted in the ADR; TEL-9 trace (b).

**Firebase Sessions:** see I-3.

**Account deletion:** `consent.forget(uid)` fires a change. The controller turns both kinds off before `forgetDevice` deletes unsent reports and resets the GA ID.

### 3.4 Web
- **No web Analytics or Crashlytics.**
  - The adapters are `Noop`.
  - `window.flutterfire_ignore_scripts = ['analytics']` sits in the same-origin `flutterfire_config.js`, loaded by a plain `<script src>` before `flutter_bootstrap.js`.
  - The locked `firebase_core_web` 3.12.0 honours it (`_ignoredServiceScripts`, consulted before `injectSrcScript` of `firebase-${service.name}.js`).
  - `firebase_analytics_web` creates its instance lazily, on the first method call, and the `Noop` adapter makes no call.
- **No CSP host for `googletagmanager.com` or `google-analytics.com`** in `script-src` or `connect-src` (I-2).
- Crashlytics has no web implementation.
- TEL-9's browser trace remains the evidence (C-1).

### 3.5 Terms and privacy (A2) against behaviour
**The live `privacy.html` (2026-11-01)** says we use neither analytics nor crash reporting and will describe them "before we switch it on". That is **true in effect today**:
- the SDKs ship;
- collection is off natively and in Dart;
- both flags are `off` everywhere;
- maintainer note 21 says exactly this.

It becomes untrue the moment either flag leaves `off`. TEL-12 is therefore already a gate (F9 and "Before release"), and so is C-5.

**A2 terms:**
- The ADR's reading is consistent with its cited sources: Crashlytics is under the Firebase DPST, with Google as processor in the European-law wording; Analytics is under the GA Terms plus the Google Ads Data Processing Terms, as a Processor Service only while data sharing is off. I did not re-read the terms pages; I relied on ADR-0032's sources, read 2026-11-01.
- The policy's Google bullet today names only the Firebase DPST and the Cloud DPA. TEL-12 must add the GA Terms and the Ads Data Processing Terms, and may call Google a processor for Analytics only once TEL-13's C6 screenshots exist (the Data Processing Amendment accepted, and sharing off, in both GA accounts).

**The in-app copy** (shipped behind the flags):
- "If the app crashes, it sends the error and what the app was doing, with your device model. Not linked to your account." Accurate for Dart. For native crashes "the error" includes Android's message (L-3). "What the app was doing" is the Analytics events attached as breadcrumbs when both are on (C8).
- "This device only. Not linked to your account." Accurate, subject to C-3.

**Wording TEL-12 must carry** (C-5):
- item 6, "no advertising ID": only after M-1 is fixed;
- item 6, "never the text you wrote or saw": add the native-message sentence (L-3);
- item 6, "reset when a different account signs in": usage statistics only (ADR C2);
- item 12: C1's next-launch wording;
- "not linked to your account": qualified if C-3 finds a join.

### 3.6 Fake-data abuse
An attacker can poison both consoles: see Spoofing and L-4. It matters only as:
- console noise;
- skewed answers to F4's product questions;
- misleading crash triage;
- a forced kill switch (L-4);
- third-party personal data planted in our consoles, removable through Firebase support or a GA deletion request.

It does not touch users, security decisions, moderation or billing. Cost to us is INR 0 (section 1).

### 3.7 Flag ceilings against F7
They match (I-4). Other checks:
- `config.go` loads both with `flags.Off`.
- Terraform `feature_crash_reporting*` and `feature_analytics*` default to `off` with validation, in both envs.
- The runbook records prod `on` as the proposal.

## 4. The linkability line (plan acceptance criterion), scoped
**Verified (code at `e01885e5`, tests green):**
- No identifier that the app itself sends to Google, in any crash payload, custom key, breadcrumb, event, event parameter or screen name, is keyed to a uid.
- The app never calls `setUserId`, `setUserIdentifier`, `setUserProperty`, `setDefaultEventParameters`, `FirebaseInstallations.getId` or `getAppInstanceId`.
- The GA app-instance ID is reset when a different account signs in and on in-app deletion.
- The FCM message id is never stored.

**Verified on a device and in the console (TEL-9 Part B, 2026-11-02):** the FCM token stored per uid has the Firebase installation ID as its prefix, but no Crashlytics surface we can read shows that ID, so it cannot be joined with a uid (M-2 closed).

**No identifier sent to Google is keyed to or joinable with a uid.**

## 5. Conditions
| ID | Condition | Owner | When |
|---|---|---|---|
| C-1 | **Partly met 2026-11-02 (test report 6c):** Android states 1a, 1b, 3 and 4, traces (a) and (b), and s2b passed; state 2 is redefined per L-5. **Open:** the web trace. **TEL-9 device evidence (pending: no phone connected).** On a release-mode dev Android build, network traces in the three plan states (no consent; consent with the flag off; consent with the flag on), plus ADR-0032 traces (a) to (e). The no-consent and flag-off traces must show no traffic to the Crashlytics, Firebase Sessions or Analytics hosts, **including `firebase-settings.crashlytics.com`** (I-3), and record the hosts actually seen. Also: the web trace (no `firebase-analytics.js`, `googletagmanager.com` or `google-analytics.com`; no CSP violation), and the guard tests with their mutation check | tester | Before the dev allowlist (TEL-15) |
| C-2 | **Met 2026-11-02:** M-1 fixed: both `ACCESS_ADSERVICES_*` permissions removed, and TEL-9's guard asserts that all three are absent from the merged manifest of a release build. TEL-17 manifest lines; release-APK `aapt2 dump permissions` shows all three absent (6c). | frontend-developer + tester | Before the dev allowlist, and before TEL-13 answers the Play Data safety and Advertising ID questions |
| C-3 | **Met 2026-11-02:** M-2 checked on a device and in the dzeroth-dev Crashlytics console; result recorded in this file. If joinable: the ADR-0032 D9 amendment, the TEL-12 wording and the runbook rule. Not joinable; evidence in M-2. No ADR amendment. | tester (device), founder (console, read only), architect (if joinable) | The check before the dev allowlist; any fix before any non-team account |
| C-4 | With analytics on in dev, receive one post-bearing push and one DM push. In DebugView, confirm that `notification_*` events (if logged at all) carry none of `actorId`, `postId`, `notificationId`, `conversationId`, the title or the body | tester | With TEL-9 or the TEL-15 smoke; before any non-team account |
| C-5 | TEL-12 carries section 3.5's wording (M-1, L-3, ADR C1 and C2, and C-3's result, plus L-5's wording (the run that learns `off` still starts with the previous native setting; Sessions sends the installation ID while crash reporting is on)). Google is called a processor for Analytics only with TEL-13's C6 screenshots on record | architect + founder | TEL-12 merge (already before any flag leaves `off`) |
| C-6 | **Met 2026-11-02:** L-1 and L-2 fixed with their tests, **or** the architect amends ADR-0032 D3 and F11 and the founder accepts the residual. TEL-18 #643: pre-enable `deleteUnsentReports` (L-1), reset on no record and on an unreadable record (L-2), with tests in `telemetry_controller_test.dart` and `telemetry_account_switch_test.dart`; trace (a) PASS. | frontend-developer (or architect + founder) | Before any prod raise |

## 6. Founder questions and proposed tickets
- **Q-1 (privacy obligation, for legal review; not legal advice).** DPDP Act 2023 s. 6(10) puts on the Data Fiduciary the burden of proving that notice was given and consent obtained when consent is the basis. Our consent record exists only on the person's device, by design (F3: no account link). Does legal review (maintainer note 1) accept that? The alternative is a server-side consent log keyed to the account, which would undo F3 and Q10 (f). This does not block the dev allowlist (team accounts only). It is for the founder before any non-team account.
- **Proposed tickets** (the planner assigns numbers):
  - (1) M-1 manifest lines and merged-manifest guard;
  - (2) L-1 pre-enable delete;
  - (3) L-2 reset on null and on read failure;
  - (4) L-3 ADR inventory note (architect) and TEL-9 trace (b) recording;
  - (5) L-4 runbook triage step and "no Measurement Protocol secret" in TEL-13;
  - (6) I-1 route `breadcrumb()` through the controller, or delete it until it has a caller.

## Not performed
- No device, so no network trace, merged manifest, `apkanalyzer`, logcat or FCM-token-versus-FID comparison.
- No Firebase or GA console access, and no `gcloud`.
- The AdServices behaviour of GA with the ad-ID key off is unverified.
- `osv-scanner` and `govulncheck` are not installed.
- No legal review (maintainer note 1).

## Sources
- Android `AdServicesPermissions` reference (`ACCESS_ADSERVICES_AD_ID`, `ACCESS_ADSERVICES_ATTRIBUTION`): https://developer.android.com/design-for-safety/privacy-sandbox/reference/adservices/common/AdServicesPermissions
- Privacy Sandbox on Android, setting up API access (removing AdServices permissions with `tools:node="remove"`): https://developers.google.cn/privacy-sandbox/private-advertising/setup/android/setup-api-access
- ADR-0032 Sources [S1] to [S28] (read 2026-11-01 by the architect), for the terms, retention, keys and Crashlytics identifiers.
- Local artifacts:
  - Gradle cache: `~/.gradle/caches/9.3.1/transforms/.../play-services-measurement-api-23.2.0/AndroidManifest.xml`, `play-services-measurement-sdk-api-23.2.0`, `-impl-23.2.0`, `play-services-ads-identifier-18.0.0`, `firebase-sessions-3.0.8/jars/classes.jar`, `firebase-messaging-25.1.3/jars/classes.jar`, `modules-2/.../firebase-bom/34.19.0`;
  - pub cache: `firebase_core_web-3.12.0/lib/src/firebase_core_web.dart`, `firebase_analytics_web-0.6.1+13`, `firebase_analytics-12.6.1`, `firebase_crashlytics-5.4.1`, `firebase_core-4.15.2/android/gradle.properties`.

SECURITY: CLEAR WITH CONDITIONS — C-1, C-4, C-5
