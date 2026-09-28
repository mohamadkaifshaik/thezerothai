# Runbook: abuse spike (mass sign-ups, scraping, request floods)

App Check is **monitor-only** at Stage 0 (ADR-0006 amendment 2026-09-27), so these are the controls we actually have.
All of them are free, and each can be reversed in a minute. Use the lightest one that works.

Git Bash on Windows:
```bash
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"; PROJ=dzeroth-prod     # or dzeroth-dev
TOKEN=$("$G" auth print-access-token)
H=(-H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJ" -H "Content-Type: application/json")
```
cmd.exe mangles `>`/`<` in `gcloud logging read` filters, so use **Logs Explorer** in the console for the queries below.

## 1. Detect and identify
- **Logs Explorer** (`resource.type="cloud_run_revision" AND resource.labels.service_name="api"`):
  - `jsonPayload.code="resource_exhausted"`: rate limits are firing. Group by `jsonPayload.rpc`.
  - `jsonPayload.rpc` counts: a flood on one RPC (e.g. `CheckHandleAvailability`, `CreateProfile`).
  - `jsonPayload.uid_hash`: one account hammering the API. `jsonPayload.via_hosting`: web or direct.
- **Sign-up surge:** the Firebase console → Authentication user list, sorted by creation date. Many new accounts with
  unverified emails is the tell. Profiles can't be created without verification (audit H1).
- **Cost signals:** Firestore writes/day on the dashboard, instances pinned at 3, budget emails
  (`docs/runbooks/cost-spike.md`).

## 2. Stop new sign-ups (the kill switch; drilled on dev 2026-09-28)
Existing users keep working; only `accounts:signUp` is refused (`ADMIN_ONLY_OPERATION`).
```bash
# ON
curl -s -X PATCH "${H[@]}" -d '{"client":{"permissions":{"disabledUserSignup":true}}}' \
  "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJ/config?updateMask=client.permissions.disabledUserSignup"
# OFF
curl -s -X PATCH "${H[@]}" -d '{"client":{"permissions":{"disabledUserSignup":false}}}' \
  "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJ/config?updateMask=client.permissions.disabledUserSignup"
```
The web app shows the sign-up error. Post a notice if it stays on for more than an hour.
(ADR-0006 once mentioned an `admin/config.signupsEnabled` flag. It was never built; this switch replaces it.)

## 3. Disable specific accounts
```bash
curl -s -X POST "${H[@]}" -d '{"localId":"<uid>","disableUser":true}' \
  "https://identitytoolkit.googleapis.com/v1/projects/$PROJ/accounts:update"      # "disableUser":false to undo
```
Find the uid from the email with `accounts:lookup` (see `docs/runbooks/account-deletion.md`). Logs only carry
`uid_hash`, so match on the time window and RPC if you start from logs.

## 4. Read-only mode (protects Firestore writes and cost)
`DEGRADED_MODE=readonly`, using the **pinned-traffic procedure** in `docs/runbooks/cost-spike.md`. A plain
`services update` alone does nothing in prod.

## 5. Tighten rate limits
The same pinned-traffic procedure, with `--update-env-vars` on any of:
`RATE_LIMIT_PRE_AUTH_IP_PER_MIN` (pre-auth per-IP, default 120), and the per-uid/per-IP/per-procedure limits in
`backend/pkg/platform/config` (`RATE_LIMIT_*`). Known gap: IP limits can be dodged by requests relayed through
Google-run fetchers (readiness report R-N2). Per-uid limits and email verification still apply.

## 6. Hard stop
`max_instance_count = 3` caps compute no matter the volume. For a severe incident (data exposure, runaway cost),
follow `docs/runbooks/rollback.md` / the readiness report §6: disable Hosting, then route API traffic away. Never
detach billing without the founder's explicit decision.

## 7. When to escalate to an ADR
Open an ADR for reCAPTCHA Enterprise (Fraud Defense, a flat $8/month above 10k assessments) and then App Check
enforcement, or Cloud Armor (fixed cost, Stage 2+), if **any** of these holds:
- the kill switch has been needed more than twice in a month;
- abusive sign-ups keep coming through with verified emails;
- abuse drives a budget alert.

## After
Turn the kill switch off, return to `DEGRADED_MODE=off`, re-enable wrongly disabled accounts, and write down the timeline
and what to change in `docs/reviews/`.
