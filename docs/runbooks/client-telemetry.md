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

## Kill switch

Set the flag to `off` and deploy (a Terraform change; no data migration). Effect, as ADR-0032 D11 words it:

- `crash_reporting` `off`: on the next `GetMe`, **Dart-side reports stop at once; native capture stops at the next launch, which also deletes unsent reports** (ADR-0032 C1). The switch is hidden; the stored choice is kept. Residual, accepted: a native (Java or Kotlin) fatal crash later in the same process run can still be uploaded.
- `analytics` `off`: on the next `GetMe`, collection is off (Google documents no next-launch delay for Analytics; TEL-9 checks).
- Staleness: as of the last `GetMe` (about 4 per DAU per day); on a cold start the stored decision for the restored uid applies until then. Only `off` is the kill switch; percent 0 or a shrunk allowlist is a rollout.
- Rollback triggers: any report or event containing an id, handle, email or user text; SDK traffic seen without consent; a crash or ANR rise attributable to the SDKs; a prod report landing in dzeroth-dev.

## Deleting data (ADR-0032 C5)

Per-person deletion is impossible by construction (nothing is keyed to an account). To remove something that should not be there:

- **Crashlytics.** Turn the flag off and fix the scrubber. Then ask **Firebase support** to remove the affected reports, citing the Crashlytics issue id. Otherwise the reports age out after **90 days**. The API method `deleteCrashReports` needs a user id set through the SDK; we never set one, so there is nothing to target. No console delete is documented: do not promise one.
- **Analytics.** A Google Analytics data-deletion request (Editor role; data must be more than 12 days old; 7 to 63 days to process). Auto-collected parameters can only be deleted with **"Delete all parameters on all events"** for the date range. Retention is otherwise the property's setting (minimum 2 months).
- Deleting an account in the app stops crash reports from that device, deletes unsent reports at the next start and resets the usage-statistics id. It does not delete data already at Google.

## Failure modes (ADR-0032 D13)

| Failure | Effect | Response |
| --- | --- | --- |
| Google endpoints down or slow | SDKs queue on the device; the app and our API are unaffected | none |
| Crash or ANR rate rises after an SDK update | user-visible | flag `off`; compare the Crashlytics and Play Console rates with the previous build; last resort: drop the SDKs in the next store build |
| Personal data seen in a crash report or an event (id, handle, email, post text, a path) | privacy incident | flag `off` first; fix the scrubber (`CrashScrubber`) or the event vocabulary; delete per the section above; add a canary test for the leaking type; record the incident |
| SDK traffic without consent (a trace or a report from a device that did not opt in) | consent breach | flag `off`; this is a rollback trigger; the TEL-9 traces are the regression test |
| Prod build reports to dzeroth-dev | wrong project | TEL-14 (#593, merged) makes `release-prod.yml` Android builds use dzeroth-prod's `google-services.json` and checks `project_id` in the build. To check: after the first prod allowlist session, open Crashlytics and Analytics (Realtime or DebugView) in **dzeroth-prod** and confirm the test device appears there and not in dzeroth-dev; confirm the staged candidate's AAB `project_id` is `dzeroth-prod`. Any sighting in dzeroth-dev from a prod build blocks every prod raise |
| Cold start regression | latency | TEL-11 target: added p50 under 100 ms; flag `off` stops collection but the SDK stays in the build |
| Firestore quota, Pub/Sub backlog or DLQ, `DEGRADED_MODE` | not involved (0 operations) | none; the flag is the switch |
| Scripted fake events or crashes (measurement id and API keys are public) | console noise; INR 0 to us | the numbers are never used for security, billing or moderation |

## Before the first release

Both flags stay `off` in every environment until the "Before release" list in `docs/plans/client-crash-analytics.md` is done for that step and the ADR-0032 C6 screenshots are on record. A mode above the ceiling in `scripts/promotion/flag-ceiling.json` fails promotion (founder review to raise it).
