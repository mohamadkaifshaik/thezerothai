# Runbook: W3 Part B dev rollout (ADR-0025, ticket W3-38)

Owner: the founder decides and runs every step that changes dev; `production-deployer` prepared this and applies nothing.
Status (2026-10-29): **PREPARED, NOT APPLIED.** Nothing was applied, routed, deployed or written: the evidence below is read-only and the plan is saved, not applied.
**ON HOLD (founder, 2026-10-29): do not apply yet.** The `api` service env list in `infra/terraform/envs/dev/main.tf` also carries 15 W7 messaging and `SHELLS` entries that were never applied to dev (unconditional entries, e.g. `FEATURE_MESSAGING` at :247 and `FEATURE_SHELLS` at :299), so any targeted apply adds them too. The founder chose not to let them ride along. Wait for the W7 work to apply its own dev env lines, then re-plan: the plan must show only the 7 Part B entries (3 flag, 4 limits) before the founder is asked to OK it. Do not work around this with `gcloud run services update --update-env-vars` (click-ops, and Terraform state would drift).
Prod: no change (on hold, `docs/pending.md` 1.2). Plan: `docs/plans/ui-w3-profile-graph-completion.md` (W3-38). Decisions: ADR-0025 and the founder's answer B4 (the same 3 test uids as Part A).
Related: `docs/runbooks/w3-part-a-rollout.md` (the precedent: helpers, targeted-plan method), `docs/runbooks/private-accounts.md` (sections 1, 6, 8), `docs/runbooks/graph.md`,
`docs/runbooks/rollback.md` ("Private accounts: never roll back past enforcement"), `docs/reviews/security-review-w3b.md`, `docs/reviews/cost-model.md` (Part B).

## Decision for the founder

| # | Decision | Recommended | What it costs / risks |
|---|---|---|---|
| 1 | **OK to apply the saved targeted dev plan** (section 2): `private_accounts` to `allowlist` for the same 3 tester uids as Part A, `percent 0`. 0 add, 1 change, 0 destroy, only the `api` service template. | Yes, after reading the note on the 15 extra env entries in 2.1. | Creates a 0% revision; traffic moves only when you route it (step 4). Reversible in seconds (traffic back) or by Terraform (flag `off`). 3 users, a handful of reads and writes. |

Before approving, know the two facts the review of the plan found: (a) the plan adds **22** env entries, not 7: 15 belong to the W7 messaging and `SHELLS` wiring that was merged to `main.tf` but never applied to dev, all inert (modes `off`, limits equal to the code defaults); (b) a plan made from a stale tree or after another deploy shows a different `template.revision` line, which is harmless. Details in 2.1.

## 1. Preconditions, with evidence (dev project `dzeroth-dev`, captured 2026-10-29 about 05:30 UTC)

Raw outputs stayed in the preparing session's scratchpad (some hold uids, so none is committed). **Re-run every command before you act**: the serving state changes with every merge.

### 1.1 The `privacy.uids` fieldOverride is deployed in dev: PASS
`gcloud firestore indexes fields describe uids --collection-group=privacy --project=dzeroth-dev` answers an explicit entry (`FIELD uids`, `COLLECTION_GROUP privacy`, `ANCESTOR_FIELD .../__default__/fields/*`, an
empty `INDEXES` table). The repo has `{ "collectionGroup": "privacy", "fieldPath": "uids", "indexes": [] }` (`firebase/firestore.indexes.json` line 153). An override with `indexes: []` has no READY state to show
(the Part A method, `w3-part-a-rollout.md` 1.1): what shows it is deployed is the explicit entry in `gcloud firestore indexes fields list` (`.../collectionGroups/privacy/fields/uids`) with no indexes, and no reverting flag.
The set document itself does not exist yet: a read of `privacy/protectedAuthors` answered **404**, so nobody is protected in dev today (rollback.md step 1: the normal rollback steps apply until someone protects).

### 1.2 100% of dev traffic and `last-good` are at or after the enforcement floor `061395a0` (#395): PASS
`gcloud run services describe api --project=dzeroth-dev --region=asia-south1` (after `deploy-dev` run 40746368121 had finished, no run in flight):
```
traffic: api-00681-rih  tag candidate  percent 100
         api-00678-xeh  tag last-good  (0%)
latestReadyRevisionName: api-00681-rih
```
| Revision | Share | Image digest | Commit (the Artifact Registry image tags) | deploy-dev run | At or after 061395a0 |
|---|---|---|---|---|---|
| `api-00681-rih` | 100%, serving (created 2026-10-28 18:37 UTC) | `sha256:ed1f5b516ac92e5ab2f4952444927ef2011ff6d4ef8721a4a475784b2d8096a1` | `4d397779` (tags `4d39777961dbdf15970a24d5c0c8e888a6258c88`, `serving`) | 40746368121, success | **yes** |
| `api-00678-xeh` | 0%, `last-good` (created 2026-10-28 18:29 UTC) | `sha256:2d9508ae6b002e2dd201f1bef58cb42b66e23bf27ee760595d320914bcf33216` | `fca86e95` (tags `fca86e954820023f041647661b5498f863e1c539`, `last-good`; #415) | 40745129946, success | **yes** |

`git merge-base --is-ancestor 061395a0 <commit>` printed yes for both `fca86e95` and `4d397779`. The digest-to-commit link is the Artifact Registry tag list of the digest
(`gcloud artifacts docker tags list asia-south1-docker.pkg.dev/dzeroth-dev/api/api --project=dzeroth-dev --filter="version~<digest>"`).
Neither revision carries a `PRIVATE_ACCOUNTS` env entry yet, so the flag is `off` on both by the code default. **Record these two names and digests in the rollout record again at apply time**: a newer merge moves both.
This is W3-36 M-1(c) and the only precondition that gates the allowlist of 3.

### 1.3 Only M-1(c) gates this ticket: PASS (read from the plan)
- M-1(a), the runbook rule, is PR #404 (rollback.md section above). M-2 (W3-39) gates more uids, a percent or `on` (not the allowlist of 3). M-1(b) (W3-42) and M-1(d) gate any prod ramp. The Lows (W3-40a, W3-40b, W3-41a, W3-41b) gate nothing.
- **Owed before the smoke, by the testers on web:** W3-34b (the Follow requests entry points at 600 dp and up) is still in review; testers using the web build cannot reach the requests list on wide screens until it merges and `deploy-dev` serves it. Narrow screens (the drawer and the badge, W3-34) work now. This does not block the apply.

### 1.4 No other `deploy-dev` run is in flight: re-check at step 0.

## 2. The targeted dev Terraform plan

No `.tf` change is needed: the variables and wiring exist (`envs/dev/main.tf` lines 271 to 279, `variables.tf`), default `off`. The rollout is **three `-var` flags and no file edit**. The real, gitignored `envs/dev/terraform.tfvars`
holds no `feature_private_accounts*` line and is not touched. The 3 uids are copied from `feature_bookmarks_allowlist` in that file (checked set-equal to `feature_media_allowlist`, `feature_engagement_allowlist` and `feature_notifications_allowlist`, without printing them).

### 2.1 What the plan changes (made 2026-10-29 from the MAIN checkout at `origin/main` `4d397779`, real tfvars; nothing applied)
```
terraform plan -input=false -out=<scratchpad>/w3-38-dev.tfplan \
  -target=module.cloud_run_api.google_cloud_run_v2_service.api \
  -var 'feature_private_accounts=allowlist' -var "feature_private_accounts_allowlist=$UIDS" -var 'feature_private_accounts_percent=0'
...
Plan: 0 to add, 1 to change, 0 to destroy.
```
The plan JSON lists 33 resources: 1 `update` (`module.cloud_run_api.google_cloud_run_v2_service.api`), 32 `no-op`. Inside it: `template.revision "api-00681-rih" -> null` (the known line that makes Cloud Run name a new revision) and **22 added `env` entries (129 to 151), 0 removed, 0 changed**. No scaling, image, traffic, IAM or other attribute changes. No second resource was pulled in by `-target` and the 3.10 drift is not in it.

| Group | Env entries added | Why |
|---|---|---|
| The rollout (3) | `FEATURE_PRIVATE_ACCOUNTS=allowlist`, `FEATURE_PRIVATE_ACCOUNTS_ALLOWLIST` = 3 uids, `FEATURE_PRIVATE_ACCOUNTS_PERCENT=0` | The change you are approving |
| Part B limits (4) | `QUOTA_PRIVACY_TOGGLES_PER_DAY=4`, `PROTECTED_AUTHORS_MAX=20000`, `PROTECTED_SET_MAX_STALE=10m`, `RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN=60` | Wired in `main.tf` as literals (reviewed like logic), equal to the code defaults, never applied to dev |
| **Not Part B (15), inert** | `FEATURE_MESSAGING=off`, `FEATURE_MESSAGING_ALLOWLIST` (0 uids), `FEATURE_MESSAGING_PERCENT=0`, `FEATURE_SHELLS=off`, `FEATURE_SHELLS_ALLOWLIST` (0 uids), `FEATURE_SHELLS_PERCENT=0`, `CACHE_MESSAGING_CONVERSATION_ENTRIES=5000`, `MESSAGES_SENDS_PER_DAY=300`, `MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY=50`, `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR=20`, `MESSAGES_REQUEST_MAX_UNANSWERED=3`, `QUOTA_DM_NEW_CONVERSATIONS_PER_DAY=20`, `QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY=5`, `RATE_LIMIT_MESSAGES_READ_PER_MIN=30`, `RATE_LIMIT_MESSAGES_SEND_PER_MIN=20` | W7 wiring merged to `main.tf` and never applied to dev (the same thing Part A found for W3-4). Modes are `off`, so no behaviour changes; the limits are the code defaults. `-target` takes the whole service, so they ride along. Check them against the code defaults if you want; they are not part of what you are approving. |

3 + 4 + 15 = 22. The dev ceiling in `scripts/promotion/flag-ceiling.json` is `PRIVATE_ACCOUNTS` `allowlist`, `max_allowlist 3`, `max_percent 0` (W3-25b); the plan is exactly at it (mode `allowlist`, 3 uids, percent 0). `MESSAGING` and `SHELLS` stay `off`, below their `allowlist` 3 ceilings.
No ceiling change is needed or proposed.

**Never run a full `terraform apply` in `envs/dev`, and apply only the saved plan file you reviewed.** An untargeted plan also contains the known dev drift (`docs/pending.md` 3.10: the unapplied TTL field and the Android API key restriction).
Part A also named `-target=module.budget.google_pubsub_topic.billing_alerts` as a state-move workaround; this plan with the `api` target alone is a clean `1 to change`, so that second target is not used here. If your plan shows anything else, stop.

Redacted plan text (uids removed) was kept in the preparing session as `w3-38-dev-plan.txt`; it is not committed.

## 3. Execution order: the exact commands (founder; each step after its OK)

Run from the **MAIN checkout** (the real `terraform.tfvars` is there), after `git pull --ff-only`. Windows Git Bash, `export GOWORK=off`; `gcloud` and `terraform` on the PATH.

**Step 0: pre-flight.**
```bash
cd <the repo root of your MAIN checkout> && git pull --ff-only && git status -sb      # clean, at origin/main
gh run list --workflow deploy-dev.yml --limit 3 --json status,conclusion,headSha      # none in_progress; the newest is success
```
Serialise with the other dev applies (W4-24, W5-19) and do not merge anything meanwhile. Re-run the section 1.2 commands and note the two revisions.

**Step 1: the plan (no file edit).**
```bash
cd infra/terraform/envs/dev
UIDS=$(grep -E '^feature_bookmarks_allowlist[[:space:]]*=' terraform.tfvars | sed -E 's/^[^"]*"([^"]*)".*/\1/' | tr -d '\r')
[ "$(printf '%s' "$UIDS" | tr ',' '\n' | grep -c .)" = 3 ] && echo "3 uids" || echo "STOP: not 3 uids"
grep -q "^feature_private_accounts" terraform.tfvars && echo "STOP: a private_accounts line exists in tfvars (it would be overridden by -var; resolve first)"
PLAN="$LOCALAPPDATA/Temp/w3-38-dev.tfplan"
terraform init -backend-config="bucket=dzeroth-tfstate" -lockfile=readonly      # only if .terraform is missing or stale
terraform plan -input=false -out="$PLAN" \
  -target=module.cloud_run_api.google_cloud_run_v2_service.api \
  -var 'feature_private_accounts=allowlist' \
  -var "feature_private_accounts_allowlist=$UIDS" \
  -var 'feature_private_accounts_percent=0'
```
Compare with section 2.1, the uids shown as counts:
```bash
terraform show -json "$PLAN" | jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | .address + "  " + (.change.actions | join(",")), (select(.address | endswith("service.api")) | (.change.before.template[0].containers[0].env | map(.name)) as $had | .change.after.template[0].containers[0].env[] | select(.name as $n | ($had | index($n)) | not) | "  + env " + .name + "=" + (if (.name | test("ALLOWLIST")) then ((.value | split(",") | map(select(. != "")) | length | tostring) + " uid(s)") else .value end))' | tr -d '\r'
```
Expected: the line `module.cloud_run_api.google_cloud_run_v2_service.api  update`, the 22 `+ env` lines of section 2.1, and `Plan: 0 to add, 1 to change, 0 to destroy.`
**STOP and ask** (do not apply) on: any other resource; any destroy or replace; a removed or changed env entry; an attribute change other than `template.revision` and added env entries; `FEATURE_PRIVATE_ACCOUNTS` not `allowlist`; an allowlist count other than 3; `_PERCENT` not 0; `FEATURE_MESSAGING` or `FEATURE_SHELLS` not `off`.
(If another deploy ran meanwhile the `revision` line shows that newer name; the new revision then carries the new image, so redo 1.2.)

**Step 2: apply (the saved plan only; needs your OK).**
```bash
terraform apply "$PLAN"        # expect: Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

**Step 3: route traffic.** The apply creates a **0% revision** (dev traffic is pinned to a named revision; Terraform ignores `traffic` and the image). Do not route while a deploy-dev run is in flight.
```bash
P="--project=dzeroth-dev --region=asia-south1"
SERVING=$(gcloud run services describe api $P --format=json | jq -r '.status.traffic[] | select(.percent==100) | .revisionName' | tr -d '\r')   # note it: the instant fallback
NEW=$(gcloud run services describe api $P --format="value(status.latestCreatedRevisionName)" | tr -d '\r')
[ "$NEW" != "$SERVING" ] || echo "STOP: no new revision"
gcloud run revisions describe $NEW $P --format="value(spec.containers[0].image)"      # must equal the same command on $SERVING
gcloud run revisions describe $NEW $P --format=json > "$LOCALAPPDATA/Temp/w3-38-new-rev.json"
cd ../../../.. && bash scripts/promotion/validate-revision.sh "$LOCALAPPDATA/Temp/w3-38-new-rev.json" scripts/promotion/flag-ceiling.json dev   # all checks passed; PRIVATE_ACCOUNTS allowlist 3/3 percent 0/0
gcloud run services update-traffic api $P --to-revisions=$NEW=100 --quiet
# Fallback: gcloud run services update-traffic api $P --to-revisions=$SERVING=100   (read section 6 first once anyone is protected)
```
Confirm one revision serves 100% (`gcloud run services describe api $P --format=json | jq '.status.traffic'`), `GET /health` is 200, run the smoke (section 4) and watch 15 minutes (section 5).
**Do not run `deploy-dev` between the apply and the route**, and expect the next `deploy-dev` to keep the flag (it builds from the template, which now carries it).

## 4. Dev smoke (founder, after step 3)

Accounts: **A** (allowlisted, will protect), **B** (allowlisted, does not follow A at first), **C** the third allowlisted tester or, for the not-allowlisted legs, the dev smoke account (`docs/runbooks/smoke-accounts.md`).
B4 gives the same 3 uids as Part A, so there are only three allowlisted accounts: A, B and C are those three; leg 7 uses the smoke account. Credentials stay in the terminal session only
(`w3-part-a-rollout.md` section 4 has the `signin` / `call` / `field` helpers and the rules: no token, body or uid printed beyond the fields you ask for). The app side (web `https://dzeroth-dev.web.app`, or a device) is
the same flow; use web only after W3-34b serves for the wide-screen requests entry (1.3).

| # | Step | Expect | Cost (cost-model Part B) |
|---|---|---|---|
| 0 | `GetMe` as A, B, C and the smoke account | `enabledFeatures` has `private_accounts` for A, B, C and not for the smoke account | 1 to 2 reads each |
| 1 | **A protects**: `identity UpdateProfile {"idempotencyKey":"w3b-<N>-prot-0001","isPrivate":true}` | `HTTP 200 ok`; `GetMe.profile.isPrivate` true; log `privacy_toggle=on`; the set doc now has A's uid (1 uid) | protect 4 cold / 3 warm reads, 3 writes |
| 2 | **B, a non-follower**: `timeline GetUserTimeline {"userId":A}` | `HTTP 200`, `authorProtected` true, no posts, no tokens. `posts GetPost` of one of A's post ids: `404 not_found`. A QUOTE of A's post (a post by B or C quoting it, or one already existing) renders **stripped / withheld** to B (`PostView.withheld`), not the quoted text | 1 to 4 reads, 0 writes |
| 3 | **B follows A**: `graph Follow {"userId":A,...}` | `HTTP 200`, state `FOLLOW_STATE_REQUESTED`; no follow edge, no `follow` notification; a `follow_request` notification row for A. A: `GetMe` shows the pending count (badge), `graph ListFollowRequests {}` lists B. A: `graph RespondToFollowRequest` accept. B: `GetUserTimeline {"userId":A}` now returns A's posts, `authorProtected` false; `GetPost` works; B gets a `follow_accepted` row | Follow 3 writes; respond per the Part B cost table |
| 4 | **C requests, then withdraws**: C `graph Follow {A}` (REQUESTED), then C `graph Unfollow {A}` (withdraw) | `HTTP 200` each; after the withdraw A's list no longer has C and the badge count falls; C still sees nothing of A | 0 to 3 writes |
| 5 | **Unprotect with one request pending**: C requests again (REQUESTED), A sets `isPrivate:false` | `HTTP 200`, `privacy_toggle=off`; within a minute the `privacy_public` job accepts C (log `msg=privacy_public` `accepted=1` `outcome=done`; `account_job=privacy_public`), C now follows A, A's `followersCount` +1. Then A protects again (`privacy_toggle=on`; **mind the daily limit: 4 toggles per IST day**, this smoke uses protect, unprotect, protect = 3, so do not repeat it the same day) | job: 1 read + 2 per request; 3 writes + 1 delete per accept |
| 6 | **Flag off, A still protected**: see section 5 below ("Flag-off check", a separate plan and OK). With `private_accounts` `off`: A can still `UpdateProfile` (other fields), still respond to and list requests, and can **unprotect** (`isPrivate:false` is never refused); B still gets `authorProtected` for A (enforcement ignores the flag); a new `isPrivate:true` is `FEATURE_DISABLED` | as stated | 1 read for a refusal |
| 7 | **A non-allowlisted user's `isPrivate:true`**: as the smoke account, `identity UpdateProfile {"idempotencyKey":"w3b-<N>-na-0001","isPrivate":true}` | `HTTP 400 failed_precondition`, `FEATURE_DISABLED` with `feature=private_accounts`; 0 writes; the set is unchanged | 1 read |

Notes: a retry of any step with the same idempotency key replays; use a fresh `<N>` per run. After the smoke, A may stay protected (the tester accounts are 3 known people) or unprotect; if A stays protected, section 6's rule applies from then on.
Compare the day with `make cost PROJECT_ID=dzeroth-dev` (last 24 h reads and writes). A cold call more than a few reads above its ceiling is a regression (`budgettest` asserts them).

## 5. Flag-off check (a separate targeted plan and OK, after section 4)

Same plan as step 1 with `-var 'feature_private_accounts=off'` (the allowlist `-var` may stay: a mode `off` ignores it). Expect exactly **one `~ value "allowlist" -> "off"`**, 0 added, 0 removed, plus the `template.revision` line. Apply the saved plan with the OK, route as step 3, then run smoke leg 6 and
a second `FEATURE_DISABLED` check as A (`isPrivate:true` while already protected is an equal value and a no-op; use B for the refusal). Only mode `off` is a flag kill switch, and **it does not unprotect anyone**: enforcement is code (private-accounts.md header).
Restore afterwards (the allowlist plan again) only if you want to keep testing.

## 6. What to watch (15 minutes after the route, then after the first real day)

Logs Explorer, `resource.type="cloud_run_revision" AND resource.labels.service_name="api"`:
- `jsonPayload.privacy_toggle` (`on|off|noop|quota|cap`) and `jsonPayload.privacy_toggle_attempts` (above 1 on many requests is the hot-doc signal);
- `jsonPayload.msg="privacy_public"` (`page`, `accepted`, `skipped_inactive`, `skipped_cap`, `drift`, `outcome`), `account_job=privacy_public` with `fs_reads`/`fs_writes`;
- `jsonPayload.protected_set_reads`, `protected_set_stale`, `protected_set_unavailable` (the set loader; `unavailable` fails closed, private-accounts.md section 2);
- follow request lines: Follow `txn_attempts`, `follow_requests_count_cache_hit`, WARN `pending_count_failed`, `pin_omitted`;
- 5xx on the Part B RPCs: `logName="projects/dzeroth-dev/logs/run.googleapis.com%2Frequests" AND httpRequest.requestUrl=~"(UpdateProfile|Follow|Unfollow|ListFollowRequests|RespondToFollowRequest|GetUserTimeline|GetPost)" AND httpRequest.status>=500` (expected empty).
Error Reporting must stay quiet for the new revision. In particular `privacy_public_enqueue_failed` (the toggle worked, pending requests stay pending until the job is republished, private-accounts.md section 6).
Also run the set check (private-accounts.md section 4): `privacy/protectedAuthors.uids` length equals the count of `users` with `isPrivate == true`.

## 7. Rollback, the kill switch, and the M-1 rule

**Trigger.** Error rate above **2% for 15 minutes** on a Part B RPC, an unexpected `FEATURE_DISABLED` for an allowlisted tester, `INTERNAL` or `UNAVAILABLE` from the set on a read path, `privacy_toggle_attempts` repeatedly above 1,
a pending request that is not accepted after an unprotect (the job stuck), or a cold call repeatedly above its ceiling.

**The M-1 rule (rollback.md, "Private accounts: never roll back past enforcement").** A revision older than `main` `061395a0` shows protected posts to everyone. Before **any** traffic move (this section, a deploy-dev automatic rollback, a promotion):
1. Read `privacy/protectedAuthors` (1 read; a 404 or an empty `uids` means nobody is protected, the normal steps apply).
2. If `uids` is non-empty, the target revision's image digest must be at or after the floor (the digest-to-commit link of 1.2, `git merge-base --is-ancestor 061395a0 <commit>`). If it is older, **do not route to it**: route to another post-floor revision or roll forward with a fix.
Both revisions of 1.2 (`api-00681-rih` and `api-00678-xeh`) pass. At the time of writing the set is absent, so the rule is not yet binding.

**Kill switch = the flag, through Terraform** (section 5): `feature_private_accounts=off` stops new protections. Data stays; protected accounts stay protected (enforcement ignores the flag), and their owners can still unprotect and accept or decline requests.
No data migration.

**Fast fallback, seconds, no Terraform:** `gcloud run services update-traffic api --project=dzeroth-dev --region=asia-south1 --to-revisions=<SERVING from step 3>=100`. That revision (`api-00681-rih`, the post-floor image without the flag env) has `private_accounts` off by the code default **and** the enforcement code,
so it is a safe target even when someone is protected. Then make the Terraform change so state and live agree, and **do not run `deploy-dev` in between** (it builds from the template, which still carries the flag until Terraform changes).
`last-good` is `api-00678-xeh` today: also post-floor, but it moves with every deploy-dev, so re-check it with the M-1 rule each time.

## 8. Not verified here (and why)
- Every smoke leg of section 4 and the authenticated helpers: no tester or smoke credential exists on the preparing machine (the smoke secrets live in the GitHub `dev` environment). The RPC and field names are read from `proto/` and the runbooks, not run against dev.
- The wide-screen requests entry (W3-34b, in review) and the app side of every row.
- The 15 inert messaging and `SHELLS` entries: read from the plan, not checked line by line against the code defaults.
- The plan is session-scoped and stale after any state change. Re-plan at step 1.
