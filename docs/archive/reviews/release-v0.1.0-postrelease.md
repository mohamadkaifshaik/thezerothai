# Post-release record — v0.1.0 (2026-09-28)

**Released:** dZeroth v0.1.0, live at https://dzeroth.com. Readiness: `release-v0.1.0-readiness.md` (VERDICT: GO,
founder sign-off 2026-09-28).

| Item | Value |
|---|---|
| Tag | `v0.1.0` → `39557eb`. It was re-tagged from `b62039f` after the first run failed on the 2-character `rc` traffic tag (fixed in PR #18; no code change; P0.3 diff against `c19c112` empty) |
| release-prod | run 36373400065 **failed** at `gcloud run deploy --tag=rc` ("tag must be at least 3 characters"), with no traffic impact; run **36374448736** succeeded |
| Image | `asia-south1-docker.pkg.dev/dzeroth-prod/api/api@sha256:74fe11b1e1ccb673cc994580c90c7cafa2d19af8ce7005891c3a4bf567f66270` (= Artifact Registry tag `v0.1.0`) |
| Revisions | the new revision is `api-00003-tiw` (traffic tag `candidate`); the previous one is `api-00002-fnn` (the `hello` placeholder) |
| promote-prod stage 10 | run 36375778505: success, 90/10 split |
| promote-prod stage 100 | run 36376029394: success. `api-00003-tiw` at 100%, first Firebase Hosting release |

## Gates
- **P2** (all pass):
  - Traffic before promotion: placeholder 100%, `candidate` 0%.
  - Indexes: 7/7 READY, and the prod Firestore rules were released.
  - Smoke tests:
    - `/health` ok (0.16 s);
    - unauthenticated GetMe → 401;
    - prod test account: GetMe → PROFILE_REQUIRED (Firestore readable), CheckHandleAvailability ok, CreateProfile
      with an unverified email → EMAIL_NOT_VERIFIED (H1 in prod). The test account was deleted.
  - Logs for the candidate revision: 0 `severity>=ERROR`, 0 5xx. The only WARNINGs were Cloud Run request logs for the
    deliberate 4xx smoke calls.
- **P3** (stage 10): 10/10 `/health` returned 200, with 0 errors and 0 5xx at the 2-minute check. The founder chose
  to go to 100% early; with no web deploy yet, only probes reached the revision.
- **P5** (all pass):
  - `https://dzeroth.com` 200 and renders the sign-in screen (headless Chrome, no page errors);
  - `/privacy` 200, `/api/health` 200, `www` → 301 to the apex;
  - security headers present (`X-Frame-Options: DENY`, nosniff, Referrer-Policy, CSP report-only).
  - The founder verified email sign-up (verification from noreply@dzeroth.com, then handle/profile creation) and
    Google sign-in on dzeroth.com.
  - Prod logs for those requests: `via_hosting=true`, `xff_hops=2`, CreateProfile ok, **0 errors, 0 5xx**.

## Deviations
- The 2-character traffic-tag failure (above). Fixed and documented.
- The stage-10 watch was cut short at 2 minutes by the founder. Low risk: no real clients at that point.

## Week-1 watch (P6): check daily until 2026-10-05
- Logs Explorer: `resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND severity>=ERROR` → expect 0.
- Firestore usage (console → Firestore → Usage): expect < 2k reads/day and < 1k writes/day at launch.
  Rollback or read-only thresholds: > 10k reads/day or > 5k writes/day.
- Cloud Run: instances not pinned at 3, no 5xx. Budget emails (₹500/month). The uptime check stays green.
- Abuse signs (a surge of unverified sign-ups, `resource_exhausted`): `docs/runbooks/abuse-spike.md`.
- Watch `CheckHandleAvailability` rate-limit hits (R-N8): the founder's own test made 9 calls in one sign-up.
