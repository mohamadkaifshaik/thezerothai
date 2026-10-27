# Runbook: W3 Part A dev rollout (ADR-0024, ticket W3-24)

Owner: the founder decides and runs every step that changes dev; `production-deployer` prepared this and ran nothing that writes.
Status (2026-10-27): **PLAN ONLY.** Nothing is applied, no flag is changed and the real backfill has NOT been run (only its dry run).
Every command below that writes is for the founder to run, after the OK. Prod: no change, and prod stays on hold (`docs/pending.md` 1.2).
Plan: `docs/plans/ui-w3-profile-graph-completion.md` (W3-24). Decisions: ADR-0024 and its Amendment 1.
Related: `docs/runbooks/posts.md` section 13 (backfill), `docs/runbooks/identity.md`, `docs/runbooks/graph.md` sections 5 and 6,
`docs/runbooks/engagement.md`, `docs/runbooks/bookmarks.md` ("Dev rollout", the W2-16 precedent), `docs/runbooks/rollback.md`,
`docs/reviews/cost-model.md` section 12.

## Decisions for the founder

Three decisions. The order of execution is **2, then 3, then 1**: decision 2 changes the tfvars lines the plan is made from, and
decision 3 is a precondition of `FEATURE_PROFILE_TABS` leaving `off`, which is part of decision 1.

| # | Decision | Recommended | What it costs / risks |
|---|---|---|---|
| 1 | **OK to apply the targeted dev plan** (section 3): the four W3 flags to `allowlist` for the same 3 tester uids as bookmarks, engagement and media, plus the W3 limits that were never applied to dev. 0 add, 1 change, 0 destroy, only the `api` service template. | Yes, after 3. | Creates a 0% revision; traffic moves only when you route it (step 4). Reversible: flags back to `off`, or traffic back to the previous revision in seconds. 3 users and a handful of reads. |
| 2 | **`SUGGESTED_USER_IDS` for dev** (the curated "who to follow" fallback; empty by default, so a user who follows fewer than 3 accounts sees an empty card). | Set it to the same 3 test uids (dev only; prod is untouched). Each tester then sees at most the other two. | A founder choice. Empty also works, but then the card appears only for a tester whose followees follow other dev accounts, so "get suggestions" in the smoke may show nothing. The list is not a secret (like the allowlists); at most 20 uids. |
| 3 | **OK to run the real `opsctl backfill-has-media` in dev** (step 1). | Yes, before 1. | 74 reads and 73 writes (from the dry run); a rerun 74 reads and 0 writes. Inside dev's free quota (50,000 reads, 20,000 writes a day). Field-level `Update` only, never `Set`; never touches a post that already has the key. |

If you want to apply before the backfill, leave the two `feature_profile_tabs` lines out of the tfvars (the other three flags are independent) and
apply the tabs flag later. `profile_tabs` never leaves `off` in a project before the indexes are READY (they are) and the backfill has run.

**Open architect item from W3-23 (does not block the dev allowlist).** "Who to follow" is modelled at 35.7 of 300.2 reads per DAU, 11.9% of
all reads, against its own 10% review line (`docs/reviews/cost-model.md` section 6; ADR-0024 risks). The levers are a 48 h client cache
(6.3%) or `SUGGESTIONS_EDGE_LIMIT` 20 (9.4%; a change of a cap in `envs/*/main.tf`, reviewed like logic, with its cost note). Choose before
`follow_suggestions` ramps past the dev allowlist. This plan keeps the shipped value (30).

## 1. Preconditions, with evidence (dev project `dzeroth-dev`, captured 2026-10-27, 14:37 to 14:46 UTC)

Raw output of every command below is in the session scratchpad
`C:/Users/skmk1/AppData/Local/Temp/claude/C--Users-skmk1-Documents-google-claude-project-project-thezerothai/82446087-214e-4b8c-b5e2-a0a0a55cc7f6/scratchpad/w3-24/`
(files `1a-*`, `1b-*`, `1c-*`). It is session scoped: **re-run these commands before you act**, because the serving state changes with every merge.

### 1.1 The W3-2 indexes and field overrides are deployed and READY: PASS
`gcloud firestore indexes composite list --project dzeroth-dev --format=json`, the `posts` rows (the last two are the W3-2 composites):
```
posts/CICAgOjXh4EJ  READY  hashtags:CONTAINS, createdAt:DESCENDING, __name__:DESCENDING
posts/CICAgOi3kJAJ  READY  authorId:ASCENDING, createdAt:DESCENDING, __name__:DESCENDING
posts/CICAgJj7z4EK  READY  conversationId:ASCENDING, createdAt:ASCENDING, __name__:ASCENDING
posts/CICAgJjF9oIK  READY  authorId:ASCENDING, isReply:ASCENDING, createdAt:DESCENDING, __name__:DESCENDING
posts/CICAgNjamYQK  READY  authorId:ASCENDING, kind:ASCENDING, createdAt:DESCENDING, __name__:DESCENDING       <- W3-2, Reposts tab
posts/CICAgJiH8YUK  READY  authorId:ASCENDING, hasMedia:ASCENDING, createdAt:DESCENDING, __name__:DESCENDING   <- W3-2, Media tab
```
- **`CICAgJiH8YUK`** is `posts (authorId, hasMedia, createdAt DESC)` and **`CICAgNjamYQK`** is `posts (authorId, kind, createdAt DESC)`; both
  `queryScope COLLECTION`, state `READY`, and both match `firebase/firestore.indexes.json`. The emulator enforces no index, so this is the first
  real proof; the first real tab call in the smoke (4.1 step 5) is the second. The index `ListSuggestedUsers` uses, `follows (followerId, createdAt DESC)`
  (`follows/CICAgJiH2JAK`), is READY too (no index change in W3).
- **Field overrides.** The five W3-2 overrides are `users.bannerUrl`, `users.bannerThumbUrl`, `users.location`, `users.website` and
  `users.pinnedPostId`, each `indexes: []`. A field override with no index entries has no READY state to show. What shows it is deployed is an
  explicit entry in `gcloud firestore indexes fields list --project dzeroth-dev` with an empty `INDEXES` table and no reverting flag
  (`gcloud firestore indexes fields describe website --collection-group=users --project dzeroth-dev`: `ANCESTOR_FIELD .../__default__/fields/*`,
  `INDEXES` empty; the same for the other four). A cross-check of the repo file against dev found **all 34** `indexes: []` overrides present in
  dev (the 35th, `notifications.actorIds`, carries one READY collection-group index), none reverting. `check-field-overrides.sh`:
  `ok: fieldOverrides unchanged: 35 override(s)`.

### 1.2 100% of dev traffic is on a revision that includes #335 (W3-6) and #354 (M-1): PASS
Captured after `deploy-dev` run 40522371796 had finished (an earlier capture taken mid-deploy was discarded), `gcloud run services describe api --region asia-south1 --project dzeroth-dev`:
```
latestCreatedRevisionName: api-00555-yeq    latestReadyRevisionName: api-00555-yeq
traffic: api-00552-por   tag last-good   (0%)
         api-00555-yeq   tag candidate   percent: 100
```
| Revision | Share | Image digest | Commit (the Artifact Registry image tag) | deploy-dev run |
|---|---|---|---|---|
| `api-00555-yeq` | 100%, serving | `sha256:3b5182e04a01de6118b0bba0af870470710994b7a9ed64e69b64e51216b25dfa` | `b89cbcbe` (main after #355, W3-20) | 40522371796, success, finished 14:41 UTC |
| `api-00552-por` | 0%, `last-good` | `sha256:cf5205475cbb4510918ec35a3e6b7fb3d16ce22350ba089824f4ac3db14d4b6b` | `941c8773` (#359) | 40520674543, success |

`git merge-base --is-ancestor` answers **yes** for #328, #330, #331, #332 (W3-7), **#335 (`9b7cfd90`)**, #336, #337, #338, #339, #343, #350, #351,
**#354 (`9b3f9fb4`)** and #355 against `b89cbcbe`, and for #332, #335 and #354 against `941c8773`. So the precondition holds on the serving revision
and also on the rollback target. The PRs' own deploys: #335 run 40442790004, #354 run 40512546531, both success.
- The `api` template carries **none** of the W3 env vars yet (105 env names; no `FEATURE_PROFILE_*`, `FEATURE_LIKES_LIST`, `FEATURE_FOLLOW_SUGGESTIONS`,
  `SUGGEST*`, `PROFILE_UPDATES_PER_DAY`), so all four flags are off by the code default. `validate-revision.sh` on it: `RESULT: all checks passed`, the four W3 flags `mode=off`.
- **Do not plan, apply or route while a `deploy-dev` run is in flight.** This PR itself triggers one when it merges (it touches `infra/`); wait for it to finish.

### 1.3 `opsctl backfill-has-media` dry run: PASS (nothing written)
`cd backend && go run ./cmd/opsctl backfill-has-media --project dzeroth-dev --dry-run`, exit 0:
```
call 1: scanned=0 missing=0 updated=0 checkpoint=- -> scanned=74 missing=73 updated=0 checkpoint=0108395972892241920 done=true
backfill-has-media: reads=74 writes=0 deletes=0
dry-run: scanned=74 missing=73 would_update=73 runs_needed=1 (nothing written)
```
- Dev has 74 posts and **73 lack the `hasMedia` key** (the one that has it was written by a create path since #332 serves), so the real run is **73 writes in 1 run**.
- The 5,000-write cap (`posts.BackfillMaxWrites`) and the `--after <checkpoint>` resume do not come into play: 73 is far below the cap and `runs_needed=1`.
  A larger project stops at the cap with exit 0 and prints the `--after` hint.
- If testers post before you run it the counts are a little higher. The clean rerun (`writes=0`) is the proof, not these numbers.

### 1.4 Other gates, all satisfied
- W3-20 (backend matrix, #355), W3-21 (client matrix, #359), W3-22 (security review #348; fixes #350, #351, #354; client #357) and W3-23 (cost report, #352) are merged.
- The W3-22 M-1 gate for `profile_extras` (website hidden under a global off, clears always allowed, `opsctl clear-profile-fields`) is #354, serving.
- ADR-0024 Amendment 1 A4 (deleting replaced banner and avatar objects, `PROFILE_MEDIA_RETIRE`) is **not built yet**: a replaced banner stays public by URL until
  account deletion (D10 "keep"). Accepted for a 3-uid dev cohort; it must be built before a wider ramp.
- No security finding blocks the dev allowlist (`docs/reviews/security-review-w3.md`, W3-24 criterion).

## 2. The targeted dev Terraform plan

No `.tf` change is needed: W3-4 (#330) already added the variables and the env wiring in `infra/terraform/envs/dev/main.tf` and `variables.tf`, all
default `off`. The rollout is **tfvars only**. The branch carries the nine lines as a commented example in `infra/terraform/envs/dev/terraform.tfvars.example`;
the real lines go in your gitignored `envs/dev/terraform.tfvars`. No uid appears in any committed file.

### 2.1 What the plan changes (made from this branch, `main` at `b89cbcbe`, with your real tfvars plus an overlay of the nine lines; nothing applied)
```
terraform plan -var-file=<main checkout>/infra/terraform/envs/dev/terraform.tfvars -var-file=<overlay: the nine lines> \
  -target=module.cloud_run_api.google_cloud_run_v2_service.api -target=module.budget.google_pubsub_topic.billing_alerts
...
Plan: 0 to add, 1 to change, 0 to destroy.
```
Exactly one resource changes, `module.cloud_run_api.google_cloud_run_v2_service.api` (update in place); the plan JSON lists 40 resources and 39 are `no-op`.
Inside it: `template.revision "api-00555-yeq" -> null` (the known line; it makes Cloud Run name a new revision) and **23 added `env` entries, 0 removed, 0 changed**.
No scaling, image, traffic, IAM or other attribute changes.

| Group | Env vars added | Why |
|---|---|---|
| The rollout (9) | `FEATURE_PROFILE_EXTRAS`, `FEATURE_PROFILE_TABS`, `FEATURE_LIKES_LIST`, `FEATURE_FOLLOW_SUGGESTIONS` = `allowlist`; `FEATURE_<each>_ALLOWLIST` = 3 uids; `SUGGESTED_USER_IDS` = 3 uids (decision 2) | The change you are approving |
| Percent (4) | `FEATURE_PROFILE_EXTRAS_PERCENT`, `FEATURE_PROFILE_TABS_PERCENT`, `FEATURE_LIKES_LIST_PERCENT`, `FEATURE_FOLLOW_SUGGESTIONS_PERCENT` = `0` | W3-4 wiring never applied to dev (ceiling: percent 0) |
| Limits wired by W3-4, never applied (9) | `RATE_LIMIT_SUGGESTIONS_PER_MIN=10`, `RATE_LIMIT_LIKES_LIST_PER_MIN=10`, `RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN=60`, `SUGGESTIONS_CALLS_PER_DAY=50`, `SUGGESTIONS_SAMPLE_FOLLOWEES=30`, `SUGGESTIONS_EDGE_LIMIT=30`, `SUGGESTIONS_HYDRATE_MAX=10`, `SUGGESTIONS_MAX_RESULTS=5`, `SUGGESTIONS_CACHE_TTL=1h` | The ListSuggestedUsers config (ADR-0024 D8, D10); equal to the code defaults, written out so they are reviewed as code |
| #351 (1) | `PROFILE_UPDATES_PER_DAY=100` | W3-22 L-4 daily cap of `UpdateProfile` (expected; the live revision runs the code default) |

9 + 4 + 9 + 1 = 23. The expectation was only `PROFILE_UPDATES_PER_DAY` from #351, but W3-4's limit and percent vars were never applied to dev either
(W2-16 applied only the nine bookmark vars). They equal the code defaults, so the only behaviour change is the four flags. Redacted plan text (uids
as `<uid-n>`): scratchpad `2-plan-w3-24-dev.redacted.txt`; the uid-free list to compare against: `2-plan-compare-summary.txt`.

**The known dev drift (`docs/pending.md` 3.10) is NOT in this plan; `-target` excludes it.** An untargeted plan from the same tree is `Plan: 1 to add, 2 to change,
0 to destroy`: it adds the unapplied #244 TTL field `module.firestore.google_firestore_field.ttl["scheduled_expire_at"]`, changes `module.apikeys.google_apikeys_key.android`
(strips the console-set package and SHA-1 restriction) and the `api` service. The two `-target` flags name the `api` service and the `billing_alerts` topic, so the
apply cannot touch the other two (the topic target is the 3.10 workaround for a state move; today a plan with the `api` target alone is identical, so it is harmless; keep
both as the 2026-10-27 apply did). **Never run a full `terraform apply` in `envs/dev`, and apply only the saved plan file you reviewed.**

Plans made and saved (scratchpad `tf/`): the one above (`w3-24-dev.tfplan`); the same without `SUGGESTED_USER_IDS` (`w3-24-dev-nosuggest.tfplan`, decision 2 = empty; still 0/1/0, `SUGGESTED_USER_IDS` added with an empty value); and a baseline with every W3 flag `off` (`baseline.tfplan`; 0/1/0 with the same 23 names, modes `off`). Saved plans are session scoped and
go stale when state changes: **re-plan from your checkout** (step 2).

### 2.2 Ceilings and validators (run on this branch, 2026-10-27)
- `scripts/promotion/flag-ceiling.json` (dev): `PROFILE_EXTRAS`, `PROFILE_TABS`, `LIKES_LIST`, `FOLLOW_SUGGESTIONS` are all `allowlist`, `max_allowlist 3`, `max_percent 0` (W3-4, #330). No ceiling
  change is needed or proposed. `validate-revision.sh` on a revision JSON built from the live revision with the planned env (128 entries = 105 + 23) passes: the four flags
  `mode=allowlist (ceiling allowlist) allowlist=3/3 percent=0/0`, every other flag unchanged, `scaling min=0 max=1`, `RESULT: all checks passed`. Run it again on the REAL new revision
  before routing (step 4). The same validator runs inside `deploy-dev` on every candidate.
- `check-flag-registry.sh`: `ok: 20 flags registered`. `check-until-dates.sh infra/terraform`: `ok: 11 until: marker(s) checked against 2026-10-27` (the example lines carry no
  `until:` marker). `check-field-overrides.sh`: `ok: fieldOverrides unchanged: 35 override(s)`. Fixture tests `scripts/promotion/test/run.sh` and `promote-test.sh`: @@PROMO_TESTS@@.
  Output: scratchpad `3-*.txt`.
- **The cohort.** The three uids are set-equal to `feature_bookmarks_allowlist`, `feature_engagement_allowlist` and `feature_media_allowlist` in your tfvars (checked without printing them; also
  equal to ui_shell, notifications, profile_snapshot, reports, replies, quotes, account_lifecycle and removed_ids). It matters: `likes_list` ramps with `bookmarks` and `engagement` on the
  same uids (the History drawer row needs `bookmarks`), the banner also needs `media`, and `follow_suggestions` needs `graph` (on in dev; ceiling `on`). Terraform does not check the subset rule.

## 3. Execution order: the exact commands (founder; each step after its OK)

Run everything from your **MAIN checkout** (the real `terraform.tfvars` is there), after `git pull --ff-only`, so it has this PR. Windows Git Bash, `export GOWORK=off`; `gcloud` and
`terraform` on the PATH (as in the W2-16 apply).

**Step 0: pre-flight.**
```bash
cd C:/Users/skmk1/Documents/google-claude-project/project/thezerothai && git pull --ff-only
gh run list --workflow deploy-dev.yml --limit 3 --json status,conclusion,headSha   # none in_progress; the newest is success (this PR's own deploy included)
```
Serialise with W4-24 and W5-19 (the other dev applies) and do not merge anything meanwhile.

**Step 1: backfill (decision 3).** From `backend/`, with ADC (`gcloud auth application-default login` once):
```bash
cd backend
go run ./cmd/opsctl backfill-has-media --project dzeroth-dev --dry-run   # expect: dry-run: scanned=74 missing=73 would_update=73 runs_needed=1 (nothing written)
go run ./cmd/opsctl backfill-has-media --project dzeroth-dev             # expect: reads=74 writes=73 deletes=0 ... complete: scanned=74 updated=73 checkpoint=<id>
go run ./cmd/opsctl backfill-has-media --project dzeroth-dev             # THE PROOF: reads=74 writes=0 deletes=0 ... complete: scanned=74 updated=0
```
Stop, and do not turn `profile_tabs` on, if the third run says anything but `writes=0`. Interrupted: rerun (committed pages stay written). `RESOURCE_EXHAUSTED`: the day's write
quota is spent, rerun tomorrow. Details: `docs/runbooks/posts.md` section 13.

**Step 2: the tfvars lines (decision 2) and the plan.** The lines copy the uids from the bookmarks cohort, so no uid is typed or pasted:
```bash
cd C:/Users/skmk1/Documents/google-claude-project/project/thezerothai/infra/terraform/envs/dev
UIDS=$(grep -E '^feature_bookmarks_allowlist[[:space:]]*=' terraform.tfvars | sed -E 's/^[^"]*"([^"]*)".*/\1/' | tr -d '\r')
[ "$(printf '%s' "$UIDS" | tr ',' '\n' | grep -c .)" = 3 ] && echo "3 uids" || echo "STOP: not 3 uids"
cat >> terraform.tfvars <<EOF

# W3 Part A rollout (ADR-0024, W3-24): the same 3 testers as bookmarks, engagement and media. Remove these lines to roll back.
feature_profile_extras               = "allowlist"
feature_profile_extras_allowlist     = "$UIDS"
feature_profile_tabs                 = "allowlist"
feature_profile_tabs_allowlist       = "$UIDS"
feature_likes_list                   = "allowlist"
feature_likes_list_allowlist         = "$UIDS"
feature_follow_suggestions           = "allowlist"
feature_follow_suggestions_allowlist = "$UIDS"
suggested_user_ids                   = "$UIDS"
EOF
# Decision 2 = empty: delete the last line. Applying before the backfill: delete the two feature_profile_tabs lines.
PLAN="$LOCALAPPDATA/Temp/w3-24-dev.tfplan"
terraform init -backend-config="bucket=dzeroth-tfstate" -lockfile=readonly      # only if .terraform is missing or stale
terraform plan -input=false -out="$PLAN" \
  -target=module.cloud_run_api.google_cloud_run_v2_service.api \
  -target=module.budget.google_pubsub_topic.billing_alerts
```
Compare the plan with section 2.1, the uids shown as counts:
```bash
terraform show -json "$PLAN" | jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | .address + "  " + (.change.actions | join(",")), ((.change.before.template[0].containers[0].env | map(.name)) as $had | .change.after.template[0].containers[0].env[] | select(.name as $n | ($had | index($n)) | not) | "  + env " + .name + "=" + (if (.name | test("ALLOWLIST|SUGGESTED_USER_IDS")) then ((.value | split(",") | map(select(. != "")) | length | tostring) + " uid(s)") else .value end))' | tr -d '\r'
```
Expected: the line `module.cloud_run_api.google_cloud_run_v2_service.api  update`, the 23 `+ env` lines of section 2.1, and `Plan: 0 to add, 1 to change, 0 to destroy.` in the plan itself.
**STOP and ask** (do not apply) on: any other resource; any destroy or replace; a removed or changed env entry; any attribute change other than `template.revision` and the added env
entries; a flag mode other than `allowlist`; an allowlist count other than 3; a `FEATURE_*_PERCENT` other than 0. (If another deploy ran meanwhile the `revision` line just shows that newer name.)

**Step 3: apply (decision 1, the saved plan only).**
```bash
terraform apply "$PLAN"        # expect: Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

**Step 4: route traffic.** The apply creates a **0% revision**: dev traffic is pinned to a named revision and Terraform ignores `traffic` and the image, so users see nothing until you route
(the same trap as `docs/runbooks/bookmarks.md`, "Dev rollout"). Do not route while a deploy-dev run is in flight.
```bash
P="--project=dzeroth-dev --region=asia-south1"
SERVING=$(gcloud run services describe api $P --format=json | jq -r '.status.traffic[] | select(.percent==100) | .revisionName' | tr -d '\r')   # note it: the instant fallback
NEW=$(gcloud run services describe api $P --format="value(status.latestCreatedRevisionName)" | tr -d '\r')
[ "$NEW" != "$SERVING" ] || echo "STOP: no new revision"
gcloud run revisions describe $NEW $P --format="value(spec.containers[0].image)"          # must equal the same command on $SERVING
gcloud run revisions describe $NEW $P --format=json > "$LOCALAPPDATA/Temp/w3-24-new-rev.json"
cd ../../../.. && bash scripts/promotion/validate-revision.sh "$LOCALAPPDATA/Temp/w3-24-new-rev.json" scripts/promotion/flag-ceiling.json dev   # all checks passed; the four flags allowlist 3/3
gcloud run services update-traffic api $P --to-revisions=$NEW=100 --quiet
# Alternative (b): gh workflow run deploy-dev.yml -f promote=true   (stages a candidate from the updated template with main's image, ceiling check, smokes, tags last-good, promotes; main at its head only).
# Fallback with either route: gcloud run services update-traffic api $P --to-revisions=$SERVING=100
```
Then confirm one revision serves 100% (`gcloud run services describe api $P --format=json | jq '.status.traffic'`), run the smoke (section 4) and watch for 15 minutes (section 6).

## 4. Dev smoke checklist (founder, after step 4)

Accounts: the **tester** is one of the 3 allowlisted accounts (credentials in this terminal session only: `TESTER_EMAIL`, `TESTER_PASSWORD`; never in an argument, a file or this repo). **Tester B** is another
of the three (`TESTER_B_EMAIL`, `TESTER_B_PASSWORD`). **Smoke A** is the dev smoke account (`docs/runbooks/smoke-accounts.md`), never allowlisted, for the negative leg. Output is only the RPC, the HTTP status,
the Connect code and counts; no token, body or uid is printed except the fields you ask for. The helpers were checked against a stubbed `curl` only: there is no credential here to run them against dev.

```bash
. scripts/promotion/lib.sh                                    # jqr, firebase_web_api_key
BASE=${BASE:-$(gcloud run services describe api --region asia-south1 --project dzeroth-dev --format="value(status.url)" | tr -d '\r')}
REF=https://dzeroth-dev.web.app/                              # an allowed referrer of the dev browser key (sign-in request only)
FIREBASE_API_KEY=${FIREBASE_API_KEY:-$(firebase_web_api_key app/lib/firebase_options.dart)}
signin() {   # env EMAIL, PASSWORD for this call only; prints the ID token
  jq -n '{email:$ENV.EMAIL,password:$ENV.PASSWORD,returnSecureToken:true}' | curl -s --max-time 15 -X POST \
    -H 'content-type: application/json' -H "Referer: $REF" --data-binary @- \
    "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$FIREBASE_API_KEY" | jqr '.idToken // empty'; }
call() {     # call <token> <package> <Method> <json>: prints "<Method> HTTP <status> <Connect code|ok> rows=<n>"; the body stays in $BODY
  local out; out=$(printf 'Authorization: Bearer %s\n' "$1" | curl -s --max-time 20 -w '\n%{http_code}' -X POST \
    -H 'content-type: application/json' -H @- --data-binary "$4" "$BASE/dzeroth.$2.v1.${2^}Service/$3")
  BODY=${out%$'\n'*}
  echo "$3 HTTP ${out##*$'\n'} $(printf '%s' "$BODY" | jqr '.code // "ok"') rows=$(printf '%s' "$BODY" | jqr '(.posts // .users // []) | length')"; }
field() { printf '%s' "$BODY" | jqr "$1"; }                   # print one field of the last body (your own values only; never a token)
N=$(date +%s)                                                 # idempotency keys: 16-64 chars of [A-Za-z0-9_-]
```

### 4.1 The tester (allowlisted)
```bash
T=$(EMAIL="$TESTER_EMAIL" PASSWORD="$TESTER_PASSWORD" signin); [ -n "$T" ] || echo "FAIL sign-in (tester)"
# 1. The four flags reach the client.
call "$T" identity GetMe '{}'
field '[.enabledFeatures[] | select(. == "profile_extras" or . == "profile_tabs" or . == "likes_list" or . == "follow_suggestions")] | sort | join(",")'   # follow_suggestions,likes_list,profile_extras,profile_tabs
MY_UID=$(field '.profile.userId')
# 2. Location and website.
call "$T" identity UpdateProfile "{\"idempotencyKey\":\"w3-$N-prof-0001\",\"location\":\"Mumbai\",\"website\":\"https://example.com\"}"
field '[.profile.location, .profile.website] | join(" ")'                                                                                              # Mumbai https://example.com
# 3. Banner: in the app, see the table. 4. Pin one of the tester's own posts.
call "$T" timeline GetUserTimeline "{\"userId\":\"$MY_UID\",\"pageSize\":20,\"tab\":\"USER_TIMELINE_TAB_POSTS\"}"
POST_ID=$(field '.posts[0].post.postId')
call "$T" identity UpdateProfile "{\"idempotencyKey\":\"w3-$N-pin-0001\",\"pinnedPostId\":\"$POST_ID\"}"
field '.profile.pinnedPostId != ""'                                                                                                                    # true
# 5. The four tabs (Media and Reposts need the two W3-2 indexes: a 500 here with "requires an index" in the logs means one is not READY: stop).
for t in POSTS REPLIES MEDIA REPOSTS; do call "$T" timeline GetUserTimeline "{\"userId\":\"$MY_UID\",\"pageSize\":20,\"tab\":\"USER_TIMELINE_TAB_$t\"}"; done
# 6. Likes (like a post in the app first).
call "$T" engagement ListLikedPosts '{"pageSize":20}'
# 7. "Follows you": tester B follows the tester, then the tester asks about B.
TB=$(EMAIL="$TESTER_B_EMAIL" PASSWORD="$TESTER_B_PASSWORD" signin); [ -n "$TB" ] || echo "FAIL sign-in (tester B)"
call "$TB" identity GetMe '{}'; B_UID=$(field '.profile.userId')
call "$TB" graph Follow "{\"idempotencyKey\":\"w3-$N-fol-0001\",\"userId\":\"$MY_UID\"}"                  # a real follow edge between two testers (undo: Unfollow); skip if B already follows
call "$T" graph GetProfileRelationship "{\"userId\":\"$B_UID\"}"
field '.followedBy // false'                                                                              # true
# 8. Suggestions.
call "$T" graph ListSuggestedUsers '{"maxResults":5}'
# 9. Clear everything again (the banner: Edit profile, Remove), so the account returns to its start.
call "$T" identity UpdateProfile "{\"idempotencyKey\":\"w3-$N-clr-0001\",\"location\":\"\",\"website\":\"\",\"pinnedPostId\":\"\"}"
```

| Step | In the app (web `https://dzeroth-dev.web.app` or the device) | Expect | Cold `fs_reads` / writes (cost-model section 2 W3 block, section 12) |
|---|---|---|---|
| 1 | Reload; the features appear | `HTTP 200 ok` and all four names | 1 (interceptor) / 0 |
| 2 | Edit profile shows the location and website fields; the profile header shows both | `HTTP 200 ok`, `Mumbai https://example.com` | 4 cold (3 service + interceptor) / 1 |
| 3 | Edit profile, banner: pick an image, Save (needs `media` and `profile_extras`) | The banner shows at once, no layout jump | CreateUpload 2 reads / 3 writes, FinalizeUpload 2 / 3, +2 interceptor, **2 Vision units**; UpdateProfile as step 2 |
| 4 | The "Pinned" row at the top of the Posts tab, the post not repeated below; the post menu says Unpin | `HTTP 200 ok`, `true` | UpdateProfile 4 cold (+1 for the pin check) / 1; the pinned row's `GetPost` 1 warm, 4 cold |
| 5 | Posts, Replies, Reposts, Media tabs on the profile, each its own list | `HTTP 200 ok` for each; Media shows posts with images, Reposts the reposts | MEDIA and REPOSTS **24 cold at page 20** (21 planning, 20 warm); `jsonPayload.tab` is `media` or `reposts` |
| 6 | History, Likes tab (`/bookmarks?tab=likes`); newest like first | `HTTP 200 ok`, rows >= 1 | **23 cold** at page 20 (24 asserted ceiling), 2 for an empty list |
| 7 | Open B's profile: the "Follows you" chip and "Follow back" | `HTTP 200 ok`, `true` | 4 cold, 1 after the header's GetProfile, 0 inside 60 s / 0 |
| 8 | The Home "Who to follow" card (and "You might like" in the desktop column with `ui_shell`) | `HTTP 200 ok`, up to 5 rows. With decision 2 = the 3 testers and a tester who follows fewer than 3 accounts it shows at most the other two; if the tester already follows both, it is **empty and the card hides: correct** | friends of friends **42 cold at most**, curated 12 at most (about 5 with a 3-uid list), warm 1 to 2 / 0 |
| 9 | The profile shows none of the four | `HTTP 200 ok` | 1 to 4 / 1 |

The whole of 4.1 is about 150 cold reads, 15 writes and 2 Vision units in dev. Compare the day with `make cost PROJECT_ID=dzeroth-dev` (last 24 h reads and writes, Vision month and
today). A cold call more than a few reads above the table is a regression (`budgettest` asserts these ceilings).

### 4.2 Smoke A (not allowlisted)
`A=$(EMAIL="$SMOKE_EMAIL" PASSWORD="$SMOKE_PASSWORD" signin)`, then (`MY_UID` from 4.1, or any valid uid):

| Check | Command | Expect | `fs_reads` |
|---|---|---|---|
| Media tab refused | `call "$A" timeline GetUserTimeline "{\"userId\":\"$MY_UID\",\"tab\":\"USER_TIMELINE_TAB_MEDIA\"}"` | `HTTP 400 failed_precondition` (`FEATURE_DISABLED`, `feature=profile_tabs`) | 1 |
| Likes refused | `call "$A" engagement ListLikedPosts '{"pageSize":20}'` | `HTTP 400 failed_precondition` | 1 |
| Suggestions refused | `call "$A" graph ListSuggestedUsers '{"maxResults":5}'` | `HTTP 400 failed_precondition` | 1 |
| A set is refused | `call "$A" identity UpdateProfile "{\"idempotencyKey\":\"w3-$N-na-0001\",\"location\":\"x\"}"` | `HTTP 400 failed_precondition` (`feature=profile_extras`), 0 writes | 1 |
| "Follows you" needs `graph` only | `call "$A" graph GetProfileRelationship "{\"userId\":\"$MY_UID\"}"` | `HTTP 200 ok` | 4 cold |
| Posts and Replies are never gated | `call "$A" timeline GetUserTimeline "{\"userId\":\"$MY_UID\",\"tab\":\"USER_TIMELINE_TAB_POSTS\"}"` | `HTTP 200 ok` | as before W3 |

### 4.3 Logs and cost
Request lines (these two `gcloud logging read` filters were syntax-checked read-only on dev on 2026-10-27; fields `rpc`, `tab`, `fs_reads`, `suggestions_cache_hit`, `source`):
```
resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND jsonPayload.rpc=~"(GetUserTimeline|ListLikedPosts|GetProfileRelationship|ListSuggestedUsers)" AND jsonPayload.fs_reads:*
resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND logName="projects/dzeroth-dev/logs/run.googleapis.com%2Frequests" AND httpRequest.requestUrl=~"(GetUserTimeline|ListLikedPosts|GetProfileRelationship|ListSuggestedUsers)" AND httpRequest.status>=500
```
The second (5xx on the new RPCs) had no line in the last 7 days and is expected to stay empty. The per-RPC and share queries are in `docs/reviews/cost-model.md` section 9 ("W3 Part A").

## 5. Flag-off check (a separate plan and OK, after section 4)

Its own targeted plan: every template change is one apply and one revision.
1. In the dev `terraform.tfvars` set the four modes to `off` and keep the allowlists (a mode `off` ignores them): `feature_profile_extras`, `feature_profile_tabs`, `feature_likes_list`,
   `feature_follow_suggestions` = `"off"`. Same targeted plan as step 2 (expect four `~ value "allowlist" -> "off"` lines and nothing else), apply with the OK, route as step 4. To prove each
   flag on its own, do them one at a time in this order: `profile_tabs`, `likes_list`, `follow_suggestions`, then `profile_extras` last (it is the kill switch for the pin and website).
2. Reload the app as the tester and confirm. Only mode `off` is a kill switch; an empty allowlist or percent 0 is a rollout.

| Flag set to `off` | The UI must (W3-13 to W3-19, and the W3-21 flag-off routing matrix) | The server must |
|---|---|---|
| `profile_tabs` | Profiles show Posts and Replies only; no Media or Reposts tab (a tab also hides itself if the server answers FEATURE_DISABLED) | GetUserTimeline with MEDIA or REPOSTS: `400 failed_precondition`, 1 read (the interceptor), none for the service; POSTS and REPLIES unchanged |
| `likes_list` | History (`/bookmarks`) shows Bookmarks only, no Likes tab; `/bookmarks?tab=likes` falls back to Bookmarks | ListLikedPosts: `400 failed_precondition` |
| `follow_suggestions` | No "Who to follow" card on Home, no "You might like" in the desktop column, and the client asks nothing | ListSuggestedUsers: `400 failed_precondition`. "Follows you" is not behind this flag (it needs `graph` only) |
| `profile_extras` (global off) | **The website and the pin disappear from every profile, the owner's own included** (Amendment 1 A1); the banner and location **still render**; Edit profile offers no setters but Remove for an existing banner and location; "Pin to your profile" is absent | A set (non-empty `location`, `website`, `banner_media_id`, `pinned_post_id`) and `CreateUpload` BANNER: `400 failed_precondition`; an exact `""` clear is still `200` (A2) |

Verify with the 4.2 commands (they now fail for the tester too) and in the app. Then restore: the four lines back to `allowlist`, plan, OK, apply, route.
Nothing else breaks while a flag is off: the strict dev smoke in `deploy-dev` covers bookmarks only (`bookmarks-smoke.sh`) and no W3 smoke exists in it. A strict dev-only W3 smoke (account A
refused on the four flags, like the bookmarks one) is a reasonable follow-up PR once the cohort is settled; it was not added here because `promote-dev.sh` and the workflow are gate files and
nothing here could run it without the smoke credentials.

## 6. Rollback and its trigger (the plan's "Rollout, kill switch, risks")

**Trigger.** Error rate on a new RPC above **2% for 15 minutes** (the 5xx query in 4.3 against that RPC's total), **or** Part A reads per DAU above **twice the W3-23 model**, that is the Part A RPCs
above about **103 reads per DAU** (model 51.5; `docs/reviews/cost-model.md` section 9, "Per-RPC reads against the model"). With three testers the per-DAU number is noise in the first days;
the practical check is a cold call repeatedly above its ceiling in the 4.1 table (24, 23, 4, 42, 4). Also any `requires an index` or `INTERNAL` on a tab call, or an unexpected
`FEATURE_DISABLED` for an allowlisted tester. Watch for 15 minutes after the route, then again after the first real day.

**Rollback = the flags back to `off`, through Terraform.** No data migration; data stays (banners and meta keep rendering; pins and websites stop rendering while `profile_extras` is globally off).
1. In the dev `terraform.tfvars` remove the nine lines you added (or set the four modes to `off`; the variable defaults are `off`). `suggested_user_ids` can stay or go.
2. The same targeted plan as step 2 (expect the env entries to revert: 0 add, 1 change, 0 destroy), apply the saved plan with the OK, then route the new revision as step 4.
3. **Faster, in seconds, no Terraform:** `gcloud run services update-traffic api --project=dzeroth-dev --region=asia-south1 --to-revisions=$SERVING=100`, where `$SERVING` is the revision noted
   in step 4. It has no W3 env, so every flag is off by the code default, and it still contains #335 and #354. `last-good` (`api-00552-por`) is also such a revision. Then make the Terraform
   change so state and live agree. **Do not run `deploy-dev` between the two**: it builds its candidate from the service template, which still carries the flags until Terraform is changed.
4. The backfill is not rolled back: `hasMedia` on posts is harmless with the flag off.

## 7. Not verified here (and why)
- The app side of every smoke row (no device or browser session was driven) and the helpers against dev (no tester or smoke credential here). The helper block ran only against a stubbed `curl`.
- A real banner upload through Vision (2 units) and a real Media or Reposts tab call: the first real `fs_reads` per tab come from the smoke above (the emulators measured them).
- The saved plans live in the session scratchpad and go stale on any state change. Re-plan at step 2.
- `SUGGESTED_USER_IDS` behaviour with a 3-uid list is read from `suggester.go` and `docs/runbooks/graph.md` section 6, not run against dev.
- Dev max instances: Terraform sets 1 (the revision shows `maxScale 1`), the ceiling file allows 3. The plan does not change it.
