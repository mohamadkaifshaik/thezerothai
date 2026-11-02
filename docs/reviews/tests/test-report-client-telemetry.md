# Test report: client crash reporting and usage analytics (TEL-9)

Plan: `docs/plans/client-crash-analytics.md` (TEL-9). Decision: ADR-0032 (Accepted). Code under test: TEL-1 to TEL-8, merged
(`app/lib/core/telemetry/`, the two SDK adapter files `firebase_crash_reporter.dart` and `firebase_usage_analytics.dart`,
the bootstrap wiring in `app/lib/app/bootstrap.dart`).

## TEL-9 (2026-11-02)

Tester: tester agent. Branch `test/tel-9-telemetry-guards` on `main@e01885e5`.

**VERDICT: PASS except state 2 first relaunch (finding F-1, procedure vs ADR-0032 C1 conflict + firebaselogging-pa after disable); C-4 and web trace not run.** The code part is unchanged: the guards, the decision matrix, the TEL-8 forget and reset, and the canaries all pass, and every guard and matrix rule fails when its rule is broken (20 mutations, section 4). No production file was changed. Part B (device evidence) was run on 2026-11-02 and its results are in section 6c. It settled A5e (no Sessions traffic on first launch) and learned the real hosts; M-2 part 2 is false. One finding is open: F-1. Not run: C-4 (notification events) and the C-1 web trace.

---

### 1. What was run

| Suite | Command (from `app/`) | Result |
|---|---|---|
| New guards | `flutter test test/guards/telemetry_guard_test.dart` | 15 pass |
| New decision matrix and TEL-8, end to end | `flutter test test/core/telemetry/telemetry_decision_matrix_e2e_test.dart` | 14 pass (one of them walks 64 cells) |
| New canaries, end to end | `flutter test test/core/telemetry/telemetry_canaries_e2e_test.dart` | 13 pass |
| Whole telemetry folder and guards | `flutter test test/core/telemetry test/guards` | all pass |
| Whole app suite | `flutter test` | see section 5 |
| `flutter analyze` | | see section 5 |
| Mutation checks | section 4 | 20 of 20 caught |

Flutter 3.47.5 (the installed 3.47.x). Nothing was run against dev, prod or any emulator: the app side of this feature has 0 RPCs.

### 2. What was added (all under `app/test/`, no production code)

| File | Purpose |
|---|---|
| `guards/telemetry_scan.dart` | pure scanners (text in, findings out): SDK imports, forbidden identifier calls, `setCustomKey` arguments, `<meta-data>` pairs and plist booleans with comments stripped, AD_ID removal, CSP header finder, SDK identifier reads, a tree reader that throws when a folder is missing |
| `guards/telemetry_guard_test.dart` | the guards (table in section 3) plus a synthetic-input test per scanner, so a guard cannot pass because its pattern stopped matching |
| `support/fake_crashlytics_port.dart` | the `CrashlyticsPort` fake that records every argument that would leave the device. **Moved** from a private class in `firebase_crash_reporter_test.dart` (that test now imports it; same assertions) |
| `support/telemetry_e2e_rig.dart` | one app launch with the real `startTelemetry`, controller, error hooks, `FirebaseCrashReporter`, `TelemetryConsentStore`, `DatabaseTelemetryFlagMemory`, `DatabaseTelemetryLastUidStore` and `TelemetryDeviceForget.of`, over an in-memory database. Only the SDK edges are fakes. A relaunch is a new rig over the same database |
| `core/telemetry/telemetry_decision_matrix_e2e_test.dart` | the TEL-4 matrix and TEL-8, end to end |
| `core/telemetry/telemetry_canaries_e2e_test.dart` | the TEL-5 canaries through `reportUnexpectedError` |

Reuse report: reused `FakeUsageAnalytics`, `CallLog`, `FakeConsent` patterns and the `AppDatabase.forTesting` pattern; extended nothing
in `lib/`; moved one private fake to `test/support/`; created the scanner and rig because no equivalent existed.

### 3. Guards

Paths: the tests run from `app/`. The CSP lives in the repo-root `firebase.json` (`../firebase.json`); the ticket text says
`firebase/firebase.json`, which does not exist, and `app/firebase.json` is a different one-line FlutterFire file.
Every guard fails (never skips) when the file or folder it reads is missing.

| Rule (plan TEL-9, ADR-0032) | Guard test | Scope |
|---|---|---|
| Only the 2 adapter files import `firebase_crashlytics` or `firebase_analytics` | `imports: only the two adapter files import the SDKs, each its own` | `import`/`export` of `package:firebase_(crashlytics\|analytics)*` in `lib/`, `test/`, `integration_test/` (absent today). The set must equal exactly the 2 adapters, each with its own SDK, so a stale list fails too |
| Native app code does not call the SDKs | `imports: native app code does not call the SDKs` | `android/app/src/**/*.kt\|java`, `ios/Runner/**/*.swift\|m\|h` |
| No `setUserIdentifier`, `setUserId`, `setUserProperty`, `setDefaultEventParameters` | `no user identifier: no setUserIdentifier ...` | Dart (`lib`, `test`) and native app code, case-insensitive (iOS spells `setUserID`), also `setUserProperty*` variants |
| App never reads the installation or app-instance ID (ADR-0032 data inventory: "TEL-9 guards the `getId` call") | `the app never reads the installation or app-instance ID` | `FirebaseInstallations`, `appInstanceId`, `getAppInstanceId` in Dart and native code |
| `setCustomKey` only with the 3 allowed keys | `setCustomKey is used only with the three allowed keys` | every call needs a string literal in `{build_number, FIREBASE_ENV, platform}`; the declaration `setCustomKey(String key, ...)` is not a call; the one variable-key call allowed is the SDK forwarder in the crash adapter. Runtime twin: `only the three custom keys exist, with no id in their values` (canaries file) |
| Android manifest holds the off values | `native off switches: every Android meta-data key has the off value` | the 9 keys of plan TEL-3 are present and `false`; comments are stripped first; the permanent switch-off keys (`*_collection_deactivated`) are absent (plan risk table, A5) |
| AD_ID removed | `the advertising-ID permission is removed from the merged manifest` | main manifest has `tools:node="remove"`; the debug and profile manifests do not add it back or turn a key on. This reads **source** manifests; the real merged-manifest check is Part B step 2 |
| iOS plist holds the off values | `every iOS plist key exists and is NO` | the 8 keys of plan TEL-3 exist as `<false/>`; no deactivated key |
| CSP has no analytics host | `web: the CSP exists and names no Google Analytics host` | parses `../firebase.json`, finds every `Content-Security-Policy` header at any depth, requires at least one with `script-src` and `connect-src`, none containing `googletagmanager` or `google-analytics` |
| Web shell loads no analytics | `the web shell loads no Analytics script` | `app/web/index.html` |

### 4. Mutation checks

Each mutation was applied to the real file with `sed`, the named test file was run, and the file was reverted with
`git checkout -- <file>` (`git status` was clean after every one and shows no change under `lib/`, `android/`, `ios/` or
`firebase.json`). Nothing is committed from these. Script: scratchpad `mutate.sh`.

| # | Mutation | Test file run | Result |
|---|---|---|---|
| G1 | third file imports `firebase_analytics` (`telemetry_controller.dart`) | guards | FAIL as wanted: `imports: only the two adapter files ...` |
| G2a | `c.setUserIdentifier("x")` added in `firebase_crash_reporter.dart` | guards | FAIL: `no user identifier ...` |
| G2b | `FirebaseCrashlytics...setUserId(u)` added in `MainActivity.kt` | guards | FAIL: `no user identifier ...` and `native app code does not call the SDKs` |
| G2c | `setDefaultEventParameters` added in `firebase_usage_analytics.dart` | guards | FAIL: `no user identifier ...` |
| G3 | `setCustomKey('platform'` changed to `'uid'` | guards | FAIL: `setCustomKey is used only with the three allowed keys` |
| G4a | manifest `firebase_crashlytics_collection_enabled` `false` to `true` | guards | FAIL: `every Android meta-data key has the off value` |
| G4b | manifest `firebase_analytics_collection_enabled` commented out | guards | FAIL: same (the comment-stripping works) |
| G4c | the same key renamed to `_deactivated` | guards | FAIL: same (key missing) |
| G4c2 | a `firebase_analytics_collection_deactivated` meta-data added next to it | guards | FAIL: same (deactivated key present) |
| G4d | the AD_ID `<uses-permission>` line deleted | guards | FAIL: `the advertising-ID permission is removed ...` |
| G4e | plist `FirebaseCrashlyticsCollectionEnabled` `<false/>` to `<true/>` | guards | FAIL: `every iOS plist key exists and is NO` |
| G5 | `https://www.googletagmanager.com` added to `connect-src` in `firebase.json` | guards | FAIL: `the CSP exists and names no Google Analytics host` |
| G6 | `FirebaseInstallations.instance.getId()` added to `telemetry_platforms.dart` | guards | FAIL: `the app never reads the installation or app-instance ID` |
| M1b | `crashCollecting` no longer checks consent | matrix | FAIL: 3 tests (64 cells, Settings switch, A to B) |
| M5 | `recordError` no longer checks the decision | matrix | FAIL: the 64 cells and the Settings-switch test |
| M2 | no `deleteUnsentReports` on "off" | matrix | FAIL: 5 tests (64 cells, flag off, switch off, relaunch, sign-out) |
| M3 | no reset on sign-in of a different uid | matrix | FAIL: 2 tests (A to B, "reset before first event") |
| M4 | `forgetDevice` skips the analytics reset | matrix | FAIL: 2 tests (both deletion tests) |
| C1 | `_allowlistedText` returns `error.toString()` for every type | canaries | FAIL: 5 tests (ArgumentError, NoSuchMethodError, PlatformException, fatal path, jsonDecode) |
| C2 | `CrashScrubber.scrub` returns its input | canaries | FAIL: 2 tests (email and handle, uid as message) |


Note on M1: my first edit (`M1`) deleted the consent check but broke the syntax, so the test file did not load; that run is not counted.
M1b is the valid one. Total valid mutations: 20 recorded above (13 guard, 5 matrix and TEL-8, 2 payload).

### 5. Whole-suite results

`flutter test` (all of `app/test`, run before the last guard test was added): **9259 tests, All tests passed**, 5 min 27 s. After adding the last guard (G6) the guard file was re-run: 15 pass. `flutter analyze`: **No issues found** (0 new warnings; the first run had an unused import and an unnecessary `dart:ui` import in my files, both removed). `dart format --set-exit-if-changed` on the new and changed test files: clean. Coverage: this ticket adds tests only and no `lib/` code; `core/telemetry` coverage was not measured separately.

### 6. Part B: device evidence (RUN 2026-11-02, results in section 6c; one open finding F-1)

Owner to run: the founder or `production-deployer` (TEL-15 repeats it on an iPhone later). Do this on the **dev** project
(`dzeroth-dev`) with a team test account that is on both dev allowlists. Do not use prod. Do not paste uids, emails or tokens
into the report; use the placeholders `<uid-A>` etc.

**Why not an HTTPS man-in-the-middle proxy.** A release build does not trust user-installed CAs, and Google SDKs may pin. So
"no traffic to host X" is proven from the **connection list** (DNS and SNI), not from decrypted bodies. The payload content
(no id, no handle, no text) is proven in the consoles in states 3 and 4.

**Host list.** ADR-0032's data inventory does not know the real hosts ("Hosts: not documented", status UNVERIFIED). Start the
fence from these candidates and extend it from state 4:
`crashlyticsreports-pa.googleapis.com`, `firebase-settings.crashlytics.com`, and for Analytics and Sessions anything under
`app-measurement.com`, `*.google-analytics.com`, `firebaselogging-pa.googleapis.com`, `play.googleapis.com` (batched logging),
plus `www.googletagmanager.com`. Excluded as existing traffic: `firebaseinstallations.googleapis.com`, FCM
(`fcm.googleapis.com`, `mtalk.google.com`), `securetoken.googleapis.com`, `identitytoolkit.googleapis.com`, the app's own API
host and GCS upload hosts. **A host that appears in state 4 and is not in the lists above is recorded and added to the fence for states 1 to 3.**

**Prerequisites**
- A dev release build: `flutter build apk --release --dart-define=FIREBASE_ENV=dev --dart-define=USE_EMULATORS=false --dart-define=API_BASE_URL=<dev api> --dart-define=BUILD_NUMBER=tel9` with the dev `google-services.json` (the committed one is dzeroth-dev's), installed with `adb install -r`.
- Both flags `allowlist` in dev for the test account (`FEATURE_CRASH_REPORTING` and `FEATURE_ANALYTICS`, Terraform plan-then-OK per ADR-0019, targeted to dev). A third trace needs the flag **off** for the same account, so keep a way to flip it (second test account that is not allowlisted, or flip the variable).
- A capture tool that records destination hosts without decrypting: PCAPdroid (on-device, shows SNI and DNS per app) or `emulator -tcpdump` on an emulator (less faithful). Export the connection list per state. Filter to this app's package.
- Clear state between runs: `adb shell pm clear <package>` (this also resets the SDK installation IDs).

**Step 1: merged-manifest check (the guard reads only source manifests).**
`apkanalyzer manifest print app-release.apk` (or `aapt2 dump xmltree --file AndroidManifest.xml app-release.apk`). Expect: each of the
9 keys of section 3 with value `false`; no `firebase_*_collection_deactivated`; no `com.google.android.gms.permission.AD_ID`
uses-permission. Record the output.

**Step 2: capture states.** For each, start the capture, cold-start the app, sign in with the test account, wait for Home, use
the app for 3 minutes (open a profile, search, compose a post), background the app for 1 minute, then stop and export the host list.

| State | Setup | Expect |
|---|---|---|
| 1. Consent off | flags on, consent card shown, tap "Not now" (both off) | **no** connection to any fence host. Also repeat once from a fresh install **before** signing in (nothing is collected without an account) |
| 2. Flags off, consent given earlier | give consent in state 3 or 4 first, then turn the flags off for the account (next `GetMe`), force-stop and relaunch | **First relaunch** (until its `GetMe` returns off): `firebase-settings.crashlytics.com` may be contacted before Dart runs, because the SDK persisted "enabled" and the device has not yet learned "off". Record it with its timestamp; it is not a failure. Record every other fence host too, and hand it to the security-auditor; do not pass or fail on it here. From logcat, record the Crashlytics and Analytics collection lines and any Analytics event logged between process start and the off decision. **Second relaunch** (after a run whose `GetMe` returned off): **no** fence host. That is the pass criterion (ADR-0032 note of 2026-11-02 on "the next launch"; runbook section on the kill switch) |
| 3. Crash only | flags on; consent card: crash on, usage off | fence hosts for Crashlytics appear **only after** the consent tap; none of the Analytics hosts |
| 4. Crash plus analytics | both on | both families appear after the consent tap; none before it. Record every host seen |

For states 3 and 4 also record, relative to the consent tap: first fence host timestamp (must be later than the tap).
For the first launch after install in state 1, record whether any Sessions traffic appears (settles ADR A5e: UNVERIFIED today).
If any fence host is seen in state 1, that is a failure of "nothing before consent": stop and file it with the host, the
timestamp and the build; do not tune the test. State 2 is not a consent case (consent was given). A fence host on its
second relaunch is a failure of the kill switch, filed the same way. Its first relaunch is judged only as its row says.

**Step 3: forced crash (state 3 or 4).**
There is no crash trigger in the app today (`grep` of `app/lib` finds none, and the plan adds none), and this ticket may not add
a production seam. **Open question for the owner (frontend-developer or architect): how is a fatal forced in a release build?**
Options: (a) a dev-only trigger behind a build flag, which needs an owner decision and a guard so it cannot ship to prod;
(b) provoke a real `reportUnexpectedError` path (a non-fatal), which needs no seam but only proves non-fatals; non-fatals are
sent "with the next fatal report or on app restart" (ADR A-table), so force-stop and relaunch to flush them. (`adb shell am crash`
is not a substitute: it is a different process death and may not produce a Crashlytics report.) Until (a) or (b) is chosen this
step is blocked. After the crash: relaunch the app (Crashlytics sends the report on the next
start), wait up to 5 minutes, open the **dzeroth-dev** Firebase console, Crashlytics, and check: the issue is listed, the
title is the error type only, custom keys are exactly `build_number`, `FIREBASE_ENV`, `platform`, there is **no user id**,
no email, no handle, no post text anywhere in the report, and the logs tab shows only breadcrumb constants (and, with
Analytics on, the screen/event breadcrumbs). Screenshot with identifiers masked.

**Step 4: DebugView (state 4).**
`adb shell setprop debug.firebase.analytics.app <package>` then relaunch. In the dzeroth-dev console, Analytics, DebugView:
perform one post, one follow, one search and a few screen changes. Expect only `post_created`, `follow`, `search_used`,
`screen_view` with template names (`home`, `profile`, `post_detail`, `search`, ...), automatic events (`session_start`,
`first_open`, `user_engagement`), parameters limited to the enums of `analytics_event.dart`, and **no** user ID, no user
properties, no handle, no id, no query text, no post text. Then switch the usage switch off in Settings and confirm events stop.
Afterwards `adb shell setprop debug.firebase.analytics.app .none.`.

**Step 5: bootstrap persistence (ADR A6a, "Android Analytics wording: TEL-9 bootstrap trace").**
In state 4, force-stop, turn the flag **off** server-side, relaunch, wait for Home (its `GetMe`), force-stop and relaunch again.
This is state 2 again, judged by its row. The first relaunch may contact `firebase-settings.crashlytics.com` before Dart runs.
From the second relaunch on there must be no fence host. This step checks that the bootstrap re-apply and the `GetMe`
decision persist "off" for the next launch. It cannot override the SDK's persisted "enabled" in the launch that is already
starting: the native SDK starts before Dart, and the device learns the flag only from that run's `GetMe` (ADR-0032 note of
2026-11-02).

**Attach to the report:** the merged-manifest output, four host lists with the consent-tap timestamp, the crash screenshot, the
DebugView screenshot, the list of hosts learned. The final verdict line then changes to `VERDICT: PASS` (or `FAIL`).

### 6b. Part B additions from the TEL-10 security review (`docs/reviews/security/security-client-telemetry.md`, CLEAR WITH CONDITIONS)

Results are in section 6c. These items are added to the procedure above; none changes production code.

- **C-1, hosts.** In states 1 and 2 assert no connection to `firebase-settings.crashlytics.com` (Sessions remote settings) as well as to the Crashlytics, Sessions and Analytics hosts of the fence. Record every host actually seen in each state, including the allowed existing ones.
- **C-1, web trace.** In a browser on the dev web build (DevTools Network, cache disabled, fresh profile, signed in, 3 minutes of use): no request to `firebase-analytics.js`, `googletagmanager.com` or `google-analytics.com`, and no CSP violation in the console or the Issues tab. Attach the HAR host list. (The source guard checks the CSP text and `web/index.html` only.)
- **C-2 / M-1, merged-manifest permissions.** On the release APK run `apkanalyzer manifest permissions app-release.apk` (or `aapt2 dump permissions`) and assert all three are absent: `com.google.android.gms.permission.AD_ID`, `android.permission.ACCESS_ADSERVICES_AD_ID`, `android.permission.ACCESS_ADSERVICES_ATTRIBUTION`. TEL-10 expects the last two to be present (they come from play-services-measurement 23.2.0) because the app removes only AD_ID. **Known gap M-1**: fixing it is a separate frontend ticket; this ticket's source-manifest guard asserts only what is true today (AD_ID removal), and no test was added that would fail on main.
- **C-3 / M-2, FID versus FCM token.** On a debug device, with `adb shell setprop log.tag.FirebaseInstallations DEBUG` and `log.tag.FirebaseMessaging DEBUG`, read logcat and compare the FCM token prefix (the part before the first `:`) with the Firebase installation ID. Record only whether they are equal, never the values. Do not add a `getId` call to the app (the guard in section 3 forbids it). Then open the forced test crash in the dzeroth-dev Crashlytics console and check every field (device info, keys, logs) for the FID.
- **C-4, notification events.** With analytics on in dev, receive one post push and one DM push. In DebugView confirm the `notification_*` events (`notification_receive`, `notification_open`, `notification_foreground`, `notification_dismiss`) carry no `actorId`, `postId`, `notificationId`, `conversationId`, title or body parameter.
- **L-3, native crash.** In step 3, also record what a forced **native (Kotlin)** crash report shows in the console (title, stack, keys, logs), since the Dart scrubber does not apply to it. This depends on the same open question about a crash trigger.

### 6c. Part B results (device session, 2026-11-02, run by the lead with the founder)

Procedure of sections 6 and 6b, run once; nothing was re-run for this write-up. Times are IST. No uids, emails, tokens, FID or FCM values appear here.

**Setup.** Redmi K20 Pro, Android 11, MIUI. Dev release APK from `main@4a29fffa`, `BUILD_NUMBER=tel9`. It was rebuilt once: the first build wrongly pointed `API_BASE_URL` at the PROD API; only 3 `GetMe` 401s reached prod, no writes. Every capture below is on the corrected build (API `https://api-7sf5r44tbq-el.a.run.app`). `FEATURE_CRASH_REPORTING` and `FEATURE_ANALYTICS` were `allowlist` for one test account (w7smoke1) through targeted dev applies and were set back to `off` at the end (revision `api-00496-mwj`). Capture: PCAPdroid `pcap_file` with `app_filter com.dzeroth.dzeroth`; hosts read from DNS and TLS SNI by a small parser (no tshark).

**Blocker found and fixed first.** The dev Android API key was restricted to a different SHA-1 and did not allow `fcmregistrations`, so Firebase Installations answered 403 `API_KEY_ANDROID_APP_BLOCKED`. Fixed by a targeted dev apply (PR #659).

| Item | Result | Evidence |
|---|---|---|
| C-2 merged-manifest permissions (`aapt2 dump permissions`, release APK) | **PASS** | `AD_ID`, `ACCESS_ADSERVICES_AD_ID`, `ACCESS_ADSERVICES_ATTRIBUTION` all absent; the 9 keys are `false`; no `*_collection_deactivated`. Observation: `BIND_GET_INSTALL_REFERRER_SERVICE` is present (from Play Install Referrer) |
| State 1a: fresh install, not signed in, about 1 min | **PASS** | Only `firebaseinstallations.googleapis.com`. No Sessions traffic on first launch: settles ADR A5e |
| State 1b: signed in, consent card shown, "Not now" tapped 17:07 | **PASS** | The tap is not in the capture, so it was re-captured with consent off, 3.5 min of use: `firebaseappcheck.googleapis.com`, the dev API, `storage.googleapis.com`. `firebaseappcheck` is not in the procedure's exclusion list; recorded as existing app traffic |
| State 3: crash only, through the Settings switch | **PASS** | Crashlytics "collection ENABLED by API" 17:20:56.830; first `firebase-settings.crashlytics.com` DNS 17:20:56.859 (+29 ms). No Analytics hosts. Extra host seen: `www.googleapis.com` |
| State 4: both, through the consent card on a fresh install | **PASS** | Consent 17:33:30.244; Crashlytics settings host +17 ms; Analytics measurement enabled 17:33:30.265. DebugView (founder): events present, no ids, handle or text in parameters; events stopped after usage was switched off at 17:36:04 (logcat "Event not sent since app measurement is disabled"). Limitation below |
| State 2 / step 5, first relaunch after the flags went off server-side | **FAIL (finding F-1)** | See F-1 |
| State 2, second relaunch | **PASS** | Only appcheck, the dev API, storage. Crashlytics DISABLED throughout; Sessions logged "SDK disabled through data collection". The Crashlytics SDK logged "userId set for session <id>": SDK-internal, not an app call; for the reviewer to confirm |
| M-2 / C-3 part 1 (debug build, SDK storage read with `run-as`, values never printed) | FCM token prefix **EQUALS** the FID | |
| Trace (a) / L-1 (TEL-18), scratch build | **PASS** | See below |
| Trace (b) / L-3 and C-3 part 2, scratch build | **PASS** | See below |
| C-4 notification events | **NOT RUN** | No pushes sent |
| C-1 web trace | **NOT RUN** | |

**Limitation (state 4).** Analytics events are handed to Google Play services ("Connected to remote service"), so no Analytics host appears in a per-app capture. "No Analytics host" in states 1 to 3 therefore cannot be proven from this capture alone; for Analytics the proof is DebugView and the logcat lines above.

**Procedure note.** The consent card is hidden while the push opt-in card is offered (`telemetry_consent_card.dart:69`). Not a defect.

**F-1 (state 2, first relaunch). Open; recorded as found, not tuned.** With the flags turned off server-side:
- `firebase-settings.crashlytics.com` was contacted at 17:46:15.205, before Dart ran: Crashlytics had persisted "enabled" natively.
- The SDK flip-flopped ENABLED, DISABLED, ENABLED, DISABLED, and Analytics went true to false, all within about 400 ms: the remembered flag was applied at bootstrap, then `GetMe` turned it off.
- `firebaselogging-pa.googleapis.com` was contacted at 17:47:13, about 1 min after both were disabled. This call is unexplained.

The procedure expected "no fence host after the relaunch", so this is a FAIL against the procedure. It conflicts with `docs/runbooks/client-telemetry.md:42-44` (ADR-0032 C1), which already says native capture stops at the next launch and the stored decision applies until the next `GetMe`. Owners: architect (procedure versus C1) and security-auditor (the `firebaselogging-pa` call after disable).

**Trace (a) / L-1 (TEL-18).** A throwaway, never-merged scratch build throws a Kotlin `IllegalStateException` 10 s after launch, on an intent extra. Crash A at 18:16:40 with collection disabled. Flags on, relaunch: "Waiting for send/deleteUnsentReports to be called" 18:20:04.560, collection ENABLED 18:20:06.889; two launches; no `crashlyticsreports-pa` traffic; the console later shows 1 crash from 1 user (only crash B).

**Trace (b) / L-3 and C-3 part 2.** Crash B at 18:25:08 with collection on: "report successfully enqueued to DataTransport"; `crashlyticsreports-pa.googleapis.com` at 18:25:23. Console (dzeroth-dev):
- Title: "Fatal Exception: java.lang.IllegalStateException: TEL9 scratch native test crash". The native message is not scrubbed, as the ADR-0032 L-3 note says.
- Keys: exactly `build_number=tel9-scratch`, `FIREBASE_ENV=dev`, `platform=android`.
- Logs: one `screen_view` breadcrumb, `firebase_screen=home`, class `MainActivity`.
- Data: device brand and model, RAM and disk free, Android 11, rooted no, crash date, app version 1.0.0 (1).
- The FID was NOT FOUND in the stack trace, keys or data.

**M-2 outcome.** Part 1 is true (prefix equals the FID); part 2 is false (the FID is not in the console view). Per the plan's M-2 outcome, no new TEL ticket is opened. The security-auditor records the evidence (C-3) before TEL-12.

**Hosts learned (extend the fence).** `firebase-settings.crashlytics.com` (states 3 and 4, and F-1), `crashlyticsreports-pa.googleapis.com` (crash B), `firebaselogging-pa.googleapis.com` (F-1 only), `www.googleapis.com` (state 3). Existing app traffic: `firebaseinstallations.googleapis.com`, `firebaseappcheck.googleapis.com`, the dev API, `storage.googleapis.com`.

**Remaining.** C-4 notification events (needs pushes); C-1 web trace; F-1 resolution (then repeat state 2, first relaunch).

### 7. Observations and gaps (for the owners; none is a defect)

- **O-1.** `bootstrap.dart` wires `onAuthChanged`, `onEnabledFeatures`, the consent load and `TelemetryDeviceForget.of` inline, where a test cannot call it. The rig copies the wiring order (documented in its class comment); a drift between the two would not be caught. A test of `bootstrap` itself needs a seam in production code; I did not add one (owner: frontend-developer, if wanted).
- **O-2.** `FirebaseUsageAnalytics` takes a `FirebaseAnalytics` and has no port like `CrashlyticsPort`, so what reaches the SDK for analytics (event name, parameters, the `setConsent` then `setAnalyticsCollectionEnabled` order of ADR C3) is tested only against the `UsageAnalytics` fake, plus the source guards. A port would make the order testable (owner: frontend-developer).
- **O-3.** The Text-throws-in-build canary cannot run through the installed hook while the widget builds: `testWidgets` keeps its own error handling and zone. The test captures the real `FlutterErrorDetails` (with the framework's context), then reports them through the installed hook and the real payload code. The framework text really contains the canary (asserted), so the check is not vacuous.
- **O-4.** No `integration_test/` folder exists; the guards scan it if it appears.
- **O-5.** The CRLF warnings printed by git on this checkout are line-ending normalisation only.
- **O-6.** The guards read source manifests. The merged manifest (plugins add their own meta-data and permissions) is only checked in Part B step 1.

VERDICT: PASS except state 2 first relaunch (finding F-1, procedure vs ADR-0032 C1 conflict + firebaselogging-pa after disable); C-4 and web trace not run
