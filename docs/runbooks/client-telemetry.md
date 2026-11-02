# Runbook: client crash reporting and usage analytics (`crash_reporting`, `analytics`)

Plan: `docs/plans/client-crash-analytics.md`. Decision: ADR-0032 (the ADR wins where this file differs). Both flags are
**client-only**: no RPC is gated, and nothing on the server reads them except the registry that mirrors them to clients.

| Flag | Env / Terraform | Gates | Default |
| --- | --- | --- | --- |
| `crash_reporting` | `FEATURE_CRASH_REPORTING[_ALLOWLIST\|_PERCENT]` / `feature_crash_reporting*` | the "Send crash reports" switch (consent card and Settings) and Firebase Crashlytics collection in the Android app | off |
| `analytics` | `FEATURE_ANALYTICS[_ALLOWLIST\|_PERCENT]` / `feature_analytics*` | the "Share usage statistics" switch and Google Analytics for Firebase collection in the Android app | off |

## What the flags gate

- **Collection = flag on for the signed-in account AND that account opted in on this device AND a supported platform (Android).** All three. The flag alone collects nothing; a stored consent collects nothing while the flag is off.
- Web and iPhone never collect: web has no Crashlytics and Analytics is not started (ADR-0032 D10); the iOS keys stay off until the Apple launch (TEL-16).
- The server mirrors the flags through `GetMe.enabled_features` (0 Firestore reads, ADR-0008 D6). While a flag is `off`, `GetMe` never lists it and the startup `feature_flags` log line shows it `off`.
- **Consent** is per account and per device, opt-in, both switches off by default (ADR-0032 D2): shown once as a card on Home and always in Settings > Privacy & safety. The choice is stored on the device (`telemetry_consent:crash:<uid>`, `telemetry_consent:usage:<uid>`), kept on sign-out and forgotten on in-app account deletion.
- Both data flows are keyed to the device, never to the account (ADR-0011 Q10 (f), ADR-0032 D4 and D9). The app never sets a user id or user property.

## Cost

INR 0. Crashlytics and Google Analytics for Firebase are free. The server does 0 reads and 0 writes and has no new request path; Pub/Sub, Firestore quotas and `DEGRADED_MODE` are not involved.

## Ramp

1. **Dev allowlist**: team test accounts only (plan F9), at most 6 uids (the ceiling). Nobody else.
2. **Prod allowlist**: the founder and testers.
3. **Prod `on`.**

Each step is a Terraform change plus the ADR-0019 release flow (a `v*` tag, a `production-reviewer` GO, `promote-prod`). Consent still applies to every user at every step, so a percent step buys little.

- **Ceilings.** `scripts/promotion/flag-ceiling.json` (founder-gated) lists both names in `flags` and gives each a dev ceiling of `{"mode": "allowlist", "max_allowlist": 6, "max_percent": 0}` (founder approved 2026-11-01, "TEL plan defaults all ok", F7). The file has no prod block for any flag, so the **proposed prod ceiling is `on` for both** (ADR-0032 D11); it is recorded here until a prod block exists.
- **Terraform** variables `feature_crash_reporting`, `feature_crash_reporting_allowlist`, `feature_crash_reporting_percent` and the `feature_analytics*` set exist in `infra/terraform/envs/{dev,prod}`, default `off`, wired into the Cloud Run env. Allowlist uids are not secrets but are never written in the repo.
- **Nothing leaves `off` anywhere** until the plan's "Before release" list for that step is done, plus ADR-0032 C6: the Data Processing Amendment accepted and every data-sharing setting off, shown as two screenshots per GA account (dev, prod) from TEL-13.
  - Before the first dev allowlist: TEL-1 Accepted, TEL-9 PASS (three traces), TEL-10 CLEAR, TEL-11 HOLDS, TEL-12 on dev Hosting, TEL-13 dev console settings.
  - Before any prod raise or non-team account: TEL-12 served by prod Hosting, TEL-14 (#593, merged) in the release, TEL-13 prod GA settings, the founder's OK on the plan.
- **Allowlisted testers are few and known, so their reports are pseudonymous but recognisable. Do not try to match allowlisted testers to reports or events.**
- **Standing rule (TEL-10 M-2 and L-5): never enable a Crashlytics BigQuery export or a Crashlytics Cloud Logging export, and never compare `users/{uid}/devices/{deviceId}.token` (`devices.token`) with console data.** The FCM token prefix equals the Firebase installation ID, and Crashlytics and Sessions send that ID to Google. The ID cannot be joined with a uid only while no export puts per-device events where we can read them. BigQuery is also excluded by ADR-0032 D1.

## Kill switch

Set the flag to `off` and deploy (a Terraform change; no data migration). Effect, as ADR-0032 D11 words it:

- `crash_reporting` `off`: on the next `GetMe`, **Dart-side reports stop at once; native capture stops at the next launch, which also deletes unsent reports** (ADR-0032 C1). The switch is hidden; the stored choice is kept. Residual, accepted: a native (Java or Kotlin) fatal crash later in the same process run can still be uploaded.
- `analytics` `off`: on the next `GetMe`, collection is off (Google documents no next-launch delay for Analytics; TEL-9 checks).
- Staleness: as of the last `GetMe` (about 4 per DAU per day); on a cold start the stored decision for the restored uid applies until then. Native capture and the SDKs' own traffic stop from the launch after the run whose `GetMe` returned `off`; that run still starts with the previous native setting (one Crashlytics settings fetch and one Firebase Sessions start event, which carries the installation ID). A launch that is killed or offline before its `GetMe` returns leaves the next launch the same (ADR-0032 note of 2026-11-02; TEL-10 L-5; TEL-9 F-1). Only `off` is the kill switch; percent 0 or a shrunk allowlist is a rollout.
- Rollback triggers: any report or event containing an id, handle, email or user text **that passes the triage step under Failure modes** (a report that fails it is forged: delete it, do not roll back); SDK traffic seen without consent; a crash or ANR rise attributable to the SDKs; a prod report landing in dzeroth-dev.

## Deleting data (ADR-0032 C5)

Per-person deletion is impossible by construction (nothing is keyed to an account). To remove something that should not be there:

- **Crashlytics.** Turn the flag off and fix the cause (see the leak row under Failure modes: Dart error, the scrubber; native message, the crashing code). Then ask **Firebase support** to remove the affected reports, citing the Crashlytics issue id. Otherwise the reports age out after **90 days**. The API method `deleteCrashReports` needs a user id set through the SDK; we never set one, so there is nothing to target. No console delete is documented: do not promise one.
- **Analytics.** A Google Analytics data-deletion request (Editor role; data must be more than 12 days old; 7 to 63 days to process). Auto-collected parameters can only be deleted with **"Delete all parameters on all events"** for the date range. Retention is otherwise the property's setting (minimum 2 months).
- Deleting an account in the app stops crash reports from that device, deletes unsent reports at the next start and resets the usage-statistics id. It does not delete data already at Google.

## Failure modes (ADR-0032 D13)

| Failure | Effect | Response |
| --- | --- | --- |
| Google endpoints down or slow | SDKs queue on the device; the app and our API are unaffected | none |
| Crash or ANR rate rises after an SDK update | user-visible | flag `off`; compare the Crashlytics and Play Console rates with the previous build; last resort: drop the SDKs in the next store build |
| Personal data seen in a crash report or an event (id, handle, email, post text, a path) | **Run "Triage" below first.** Only a report that passes it is a leak | Forged: delete, no rollback (see Triage). Leak, by where the text sits: **Dart error** (an allowlisted type's message): flag `off` first; fix the scrubber (`CrashScrubber`) and add a canary test for the leaking type. **Native (Java or Kotlin) message** carrying anything the policy does not disclose: flag `off`; fix the crashing code, not the scrubber (it cannot see native messages). **Event:** flag `off`; fix the event vocabulary. Then delete per the section above and record the incident |
| Triage: a report or event looks like a leak (L-4) | The app's Firebase ids and API key are public, so anyone can plant a crash or event that holds an id, handle, email or text. Treating it as a leak forces a kill switch or leaves third-party personal data in our consoles | See "Triage" below |
| A Firebase BoM bump adds a permission (TEL-10 M-1) | The merged manifest can gain an advertising or other permission with no source change | See "BoM bumps" below |
| SDK traffic without consent (a trace or a report from a device that did not opt in) | consent breach | flag `off`; this is a rollback trigger; the TEL-9 traces are the regression test |
| Prod build reports to dzeroth-dev | wrong project | TEL-14 (#593, merged) makes `release-prod.yml` Android builds use dzeroth-prod's `google-services.json` and checks `project_id` in the build. To check: after the first prod allowlist session, open Crashlytics and Analytics (Realtime or DebugView) in **dzeroth-prod** and confirm the test device appears there and not in dzeroth-dev; confirm the staged candidate's AAB `project_id` is `dzeroth-prod`. Any sighting in dzeroth-dev from a prod build blocks every prod raise |
| Cold start regression | latency | TEL-11 target: added p50 under 100 ms; flag `off` stops collection but the SDK stays in the build |
| Firestore quota, Pub/Sub backlog or DLQ, `DEGRADED_MODE` | not involved (0 operations) | none; the flag is the switch |
| Scripted fake events or crashes (measurement id and API keys are public) | console noise; INR 0 to us | the numbers are never used for security, billing or moderation |

## Triage: forged report or leak (TEL-10 L-4)

Run all three checks, in order, before a report or event counts as a leak or trips a rollback trigger. Do not match a report to an allowlisted tester (Ramp section).

1. **Shipped build?**
   - Crashlytics: open the issue, then an event. Read the app version (version name and code) in the event header, and the custom key `build_number` (also `FIREBASE_ENV` and `platform`) under Keys.
   - GA: DebugView or Realtime does not show it reliably; use Reports > Tech > Tech details with the dimension App version, or an Explore with App version and Event name.
   - Compare with the builds we shipped (the `v*` release notes in `docs/releases/` and the Play uploads). A build number never shipped, `unknown`, a version code we never uploaded, a package name that is not ours, or `platform` other than `android` fails the check.
2. **Our frames?** (Crashlytics only.) Read the stack of the event. The top frames must be `package:dzeroth/...` or one of our plugins (`package:firebase_*`, `package:image_picker`, and so on, the packages in `app/pubspec.yaml`) or the Flutter engine. Frames from code we do not ship fail the check. A GA event has no frames: its check is that the event name and parameter names are in the fixed `AnalyticsEvent` list (ADR-0032); a name outside the list fails.
3. **Can our code put the text there?**
   - Dart error: only the allowlisted types carry a message (`TypeError`, `StateError` with our fixed strings, `AssertionError`, `FlutterError` overflow and layout errors), scrubbed and cut at 200 characters. Text in the message of any other Dart type, text over 200 characters, or text in a custom key other than `build_number`, `FIREBASE_ENV` and `platform`, fails the check.
   - Native (Java or Kotlin) crash: the message is not scrubbed. A file name, path or URI there is behaviour the policy and ADR-0032 Note 2026-11-02 (TEL-19) disclose, not a scrubber failure, and `CrashScrubber` cannot change it. Not a leak. A native message that carries anything the policy does not disclose (post or message text, a uid, a handle or an email) passes the check, and is a leak.
   - GA event: parameters outside the fixed vocabulary, or a user id or user property (we never set one), fail the check.

**Outcome.**
- **Any check fails: forged. Delete it and do not roll back.** Crashlytics: ask Firebase support to remove the issue (Section "Deleting data"). GA: a data-deletion request (same section). Note the report in the incident log with the check that failed. Keep the flag as it is.
- **All three pass: a leak.** Flag `off` as under Kill switch, then follow the leak row under Failure modes (Dart error: fix the scrubber; native message: fix the crashing code), then delete and record.
- Unsure on any check: treat it as a leak (flag `off`), then re-triage; turning the flag on again is a Terraform change and a release.
- Never create a Measurement Protocol `api_secret` for either GA property. With none, nobody can post events to the property by HTTP, which removes the easiest forgery route (TEL-13 checks the consoles). The measurement id and API keys stay public, so forged SDK traffic is still possible: that is what this triage is for.

## BoM bumps (TEL-10 M-1)

At every Firebase BoM bump (Dependabot PR for `app/android`, or any manual one), before the release that carries it:

1. Build a release APK with the dev defines of the TEL-9 test report (section 6), from `app/`:
   `flutter build apk --release --dart-define=FIREBASE_ENV=dev --dart-define=USE_EMULATORS=false --dart-define=API_BASE_URL=https://api-7sf5r44tbq-el.a.run.app --dart-define=BUILD_NUMBER=tel9`
   **Warning:** the API host `api-1053765609011...` is PROD. A first TEL-9 build pointed at it by mistake and sent 3 `GetMe` 401s to prod. Check `API_BASE_URL` before every build. When capturing with PCAPdroid: it asks ALLOW on every CaptureCtrl start, so expect the prompt each time; and Analytics uploads go through Google Play services, so a per-app capture cannot see Analytics hosts (use DebugView and logcat for Analytics).
2. Dump the merged permissions:
   `%LOCALAPPDATA%/Android/Sdk/build-tools/36.1.0/aapt2.exe dump permissions app/build/app/outputs/flutter-apk/app-release.apk`
   (In Git Bash: `"$LOCALAPPDATA/Android/Sdk/build-tools/36.1.0/aapt2.exe" dump permissions <apk>`.)
3. Compare with the baseline: the permission list recorded in TEL-17's PR #648.
4. A permission **not in the baseline blocks the release**. Remove it with `<uses-permission android:name="..." tools:node="remove"/>` next to the existing lines in the app manifest, or declare it in TEL-13's forms (Play Data safety, privacy policy) if we mean to keep it. Rebuild and dump again.
5. Record the new list as the next baseline (in the BoM PR body, and the TEL-9 report's permission line).
6. A permission that is in the baseline and gone is fine; note it.

## Before the first release

Both flags stay `off` in every environment until the "Before release" list in `docs/plans/client-crash-analytics.md` is done for that step and the ADR-0032 C6 screenshots are on record. A mode above the ceiling in `scripts/promotion/flag-ceiling.json` fails promotion (founder review to raise it).
