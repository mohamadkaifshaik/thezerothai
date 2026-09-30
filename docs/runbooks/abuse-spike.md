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

## 5a. Follow spam and list scraping (graph, ADR-0008)
**Detect** (Logs Explorer, same base filter as section 1). The per-request `request` log line carries `rpc`, `code`,
`uid_hash`, `fs_reads`, `fs_writes` and, when a limiter rejected the call, `limit_name`. The quota *name* (`follows`)
is in the error metadata the client sees, not in the log line, so identify it by RPC plus code:
- Follow spam hitting the per-user daily quota (`QUOTA_EXCEEDED`, `quota=follows`):
  `jsonPayload.rpc:"GraphService/Follow" AND jsonPayload.code="resource_exhausted"`. A `uid_hash` that repeats is one
  account. Many different hashes each spending a few follows is a sign-up farm (then section 2).
- List scraping: `jsonPayload.limit_name="graph_list_daily"` (the per-uid daily cap on ListFollowers, ListFollowing,
  ListBlockedUsers and ListMutedUsers). Sort by `uid_hash`.
- Bulk mutation replays: `jsonPayload.limit_name="graph_mutation_daily"`.
- Read scraping / read-budget exhaustion (ADR-0010 D5, T3): `jsonPayload.limit_name="read_budget_daily"`. It is the
  per-uid daily Firestore read budget (`READ_BUDGET_PER_UID_PER_DAY`, default 2,000) and, on the profile-exempt
  procedures (CreateProfile, CheckHandleAvailability), the per-IP budget (`READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY`,
  default 500; IPv6 counts per /64). Count distinct accounts hitting it (Log Analytics):
  `SELECT json_payload.uid_hash, COUNT(*) AS rejections FROM <log view> WHERE json_payload.limit_name = "read_budget_daily" AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY) GROUP BY 1 ORDER BY 2 DESC`.
  Spend per account: max `jsonPayload.read_budget_spent` per `uid_hash` (present on every request the interceptor
  saw). One `uid_hash` at the cap is a scraper or a heavy legit user (a follower count over ~1,000 can hit it on a heavy
  day, ADR-0010 D5); many hashes each at the cap is a sign-up farm (section 2). `limit_name="check_handle_daily"` is the
  100 calls/uid/day cap on CheckHandleAvailability. Lever: raise or lower the env var with the pinned-traffic procedure
  below; the budget is per instance, so worst case is x3.
- Cost check: sum `jsonPayload.fs_reads` for the suspect `uid_hash` and compare with the daily 50k read quota.

**Levers, lightest first:**
1. **Lower the caps.** The env vars are `QUOTA_FOLLOWS_PER_DAY` (default 200; new accounts use
   `QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY`, default 50) and `LIST_CALLS_PER_DAY` (default 100). Optionally
   `RATE_LIMIT_GRAPH_FOLLOW_PER_MIN` (default 30) and `RATE_LIMIT_GRAPH_LIST_PER_MIN` (default 20). Use the
   **pinned-traffic procedure** in `docs/runbooks/cost-spike.md` (a new revision gets 0% traffic in prod until you
   shift it explicitly), with `--update-env-vars QUOTA_FOLLOWS_PER_DAY=50,LIST_CALLS_PER_DAY=20` instead of
   `DEGRADED_MODE`. The daily list cap is in memory per instance, so it resets on scale-to-zero and is approximate
   (worst case x3 with 3 instances). Per-user Firestore quotas are exact. Then reconcile Terraform so the next apply
   doesn't undo it.
2. **Kill switch.** `FEATURE_GRAPH=off` with the same pinned-traffic procedure. Every graph RPC then returns
   FAILED_PRECONDITION `FEATURE_DISABLED` with 0 Firestore reads, and the app hides the graph UI. Also `allowlist`
   (with `FEATURE_GRAPH_ALLOWLIST`) to keep only testers on. Existing follow data is untouched. Reverse it the same way.
3. **Disable the account** (section 3). Leave its data in place for evidence; review it before any purge.
4. Readonly mode (section 4) if writes are the problem across the board.

**After:** a follow-farm account that is deleted needs the graph purge in `docs/runbooks/account-deletion.md`. Other
graph failure modes are in `docs/runbooks/graph.md`.

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
