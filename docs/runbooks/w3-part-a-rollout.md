# Runbook: W3 Part A dev rollout (ADR-0024, ticket W3-24)

Owner: the founder decides and runs every step that changes dev; `production-deployer` prepared this and, after the founder's GO of 2026-10-27, ran it (section 8).
Status (2026-10-27): **APPLIED IN DEV.** The founder gave the GO on all three decisions (real backfill; `SUGGESTED_USER_IDS` = the same 3 test uids; targeted apply, route, smoke).
Backfill: dry run `scanned=74 missing=73 would_update=73`; real run `reads=74 writes=73 deletes=0`; rerun `reads=74 writes=0 updated=0` (the proof). Plan `0 to add, 1 to change, 0 to destroy`
(24 env entries added, 0 removed, 0 changed); apply `0 added, 1 changed, 0 destroyed` at about 17:15 UTC. The new revision `api-00306-482` (same image digest as the one that served before,
`api-00564-vik`, main `b0bc56d7`) has served 100% since about 17:16 UTC. Fallback revision: `api-00564-vik` (no W3 env; `last-good` is `api-00561-meb`). Smoke: the server-side legs that need no
credential ran and passed; the authenticated legs (4.1, 4.2) are still owed to the testers (section 8). The text of sections 1 to 7 below is the plan as written before the apply; the revision names
in it (`api-00558-viz`, `api-00555-yeq`) are the ones that served then. Prod: no change, and prod stays on hold (`docs/pending.md` 1.2).
**Current dev revision (2026-10-27 17:56 UTC): `api-00307-fcs`**, not `api-00306-482`: the ADR-0024 A4 switch `PROFILE_MEDIA_RETIRE` went `off` to `banner` as its own targeted plan and apply
(one env value, same image digest, the four W3 flags still `allowlist` 3/3; `docs/runbooks/media.md`, "Results, dev, banner switch"). `api-00306-482` is now the previous revision and the
fast fallback for that change (same image, switch `off`, W3 flags unchanged); the W3-24 fallback above (`api-00564-vik`) is for rolling the W3 flags back. `last-good` is still `api-00561-meb`.
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

## 1. Preconditions, with evidence (dev project `dzeroth-dev`, captured 2026-10-27, 14:37 to 15:33 UTC)

The raw output of every command below was kept outside the repository (the preparing session's scratchpad, files `1a-*`, `1b-*`, `1c-*`; some raw files hold uids, so none is
committed). The summaries here are the evidence. **Re-run the commands before you act**, because the serving state changes with every merge.

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
Captured after `deploy-dev` run 40529672800 (main `8ff86217`, #360) had finished, at 15:26 UTC (an earlier capture taken mid-deploy, and the one before #360, were discarded), `gcloud run services describe api --region asia-south1 --project dzeroth-dev`:
```
latestCreatedRevisionName: api-00558-viz    latestReadyRevisionName: api-00558-viz
traffic: api-00555-yeq   tag last-good   (0%)
         api-00558-viz   tag candidate   percent: 100
```
| Revision | Share | Image digest | Commit (the Artifact Registry image tag) | deploy-dev run |
|---|---|---|---|---|
| `api-00558-viz` | 100%, serving | `sha256:e5d2a599ab887e3bc08e75c75f46d0b102bb0aa6fc8dcdca4d9842b02a3f8500` | `8ff86217` (main after #360, ADR-0024 A4) | 40529672800, success, finished 15:26 UTC |
| `api-00555-yeq` | 0%, `last-good` | `sha256:3b5182e04a01de6118b0bba0af870470710994b7a9ed64e69b64e51216b25dfa` | `b89cbcbe` (main after #355, W3-20) | 40522371796, success, finished 14:41 UTC |

`git merge-base --is-ancestor` answers **yes** for #328, #330, #331, #332 (W3-7), **#335 (`9b7cfd90`)**, #336, #337, #338, #339, #343, #350, #351,
**#354 (`9b3f9fb4`)**, #355 and #360 against `8ff86217`, and for #332, #335 and #354 against `b89cbcbe`. So the precondition holds on the serving revision
and also on the rollback target. The PRs' own deploys: #335 run 40442790004, #354 run 40512546531, both success.
- The `api` template carries **none** of the W3 env vars yet (105 env names; no `FEATURE_PROFILE_*`, `FEATURE_LIKES_LIST`, `FEATURE_FOLLOW_SUGGESTIONS`,
  `SUGGEST*`, `PROFILE_UPDATES_PER_DAY`, `PROFILE_MEDIA_RETIRE`), so all four flags are off by the code default. `validate-revision.sh` on it: `RESULT: all checks passed`, the four W3 flags `mode=off`.
- **Do not plan, apply or route while a `deploy-dev` run is in flight.** This PR itself triggers one when it merges (it touches `infra/`); wait for it to finish.

### 1.3 `opsctl backfill-has-media` dry run: PASS (nothing written)
`cd backend && go run ./cmd/opsctl backfill-has-media --project dzeroth-dev --dry-run`, exit 0 (captured at 14:41 and again at 15:38 UTC with identical numbers):
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
- ADR-0024 Amendment 1 A4 (deleting replaced banner and avatar objects) merged as #360 while this plan was being made, with `PROFILE_MEDIA_RETIRE` **off** by default (the 24th
  env var of the plan, value `off`: no behaviour change). Its free `days_since_custom_time = 1` lifecycle rule on the media bucket was applied to dev at 15:31 UTC by a separate change, not by this ticket
  (`gcloud storage buckets describe gs://dzeroth-dev-media --format="default(lifecycle_config)"` shows the `Delete` rule; the targeted plan of that module reads `No changes`). Raising
  `profile_media_retire` past `off` is A4's own switch order (`docs/runbooks/media.md`) and is not part of this rollout: until then a replaced banner stays public by URL until account deletion
  (D10 "keep"), accepted for a 3-uid dev cohort.
- No security finding blocks the dev allowlist (`docs/reviews/security-review-w3.md`, W3-24 criterion).

## 2. The targeted dev Terraform plan

No `.tf` change is needed: W3-4 (#330) already added the variables and the env wiring in `infra/terraform/envs/dev/main.tf` and `variables.tf`, all
default `off`. The rollout is **tfvars only**. The branch carries the nine lines as a commented example in `infra/terraform/envs/dev/terraform.tfvars.example`;
the real lines go in your gitignored `envs/dev/terraform.tfvars`. No uid appears in any committed file.

### 2.1 What the plan changes (made at 15:33 UTC from this branch merged with `main` `8ff86217`, with your real tfvars plus an overlay of the nine lines; nothing applied)
```
terraform plan -var-file=<main checkout>/infra/terraform/envs/dev/terraform.tfvars -var-file=<overlay: the nine lines> \
  -target=module.cloud_run_api.google_cloud_run_v2_service.api -target=module.budget.google_pubsub_topic.billing_alerts
...
Plan: 0 to add, 1 to change, 0 to destroy.
```
Exactly one resource changes, `module.cloud_run_api.google_cloud_run_v2_service.api` (update in place); the plan JSON lists 40 resources and 39 are `no-op`.
Inside it: `template.revision "api-00558-viz" -> null` (the known line; it makes Cloud Run name a new revision) and **24 added `env` entries, 0 removed, 0 changed**.
No scaling, image, traffic, IAM or other attribute changes.

| Group | Env vars added | Why |
|---|---|---|
| The rollout (9) | `FEATURE_PROFILE_EXTRAS`, `FEATURE_PROFILE_TABS`, `FEATURE_LIKES_LIST`, `FEATURE_FOLLOW_SUGGESTIONS` = `allowlist`; `FEATURE_<each>_ALLOWLIST` = 3 uids; `SUGGESTED_USER_IDS` = 3 uids (decision 2) | The change you are approving |
| Percent (4) | `FEATURE_PROFILE_EXTRAS_PERCENT`, `FEATURE_PROFILE_TABS_PERCENT`, `FEATURE_LIKES_LIST_PERCENT`, `FEATURE_FOLLOW_SUGGESTIONS_PERCENT` = `0` | W3-4 wiring never applied to dev (ceiling: percent 0) |
| Limits wired by W3-4, never applied (9) | `RATE_LIMIT_SUGGESTIONS_PER_MIN=10`, `RATE_LIMIT_LIKES_LIST_PER_MIN=10`, `RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN=60`, `SUGGESTIONS_CALLS_PER_DAY=50`, `SUGGESTIONS_SAMPLE_FOLLOWEES=30`, `SUGGESTIONS_EDGE_LIMIT=30`, `SUGGESTIONS_HYDRATE_MAX=10`, `SUGGESTIONS_MAX_RESULTS=5`, `SUGGESTIONS_CACHE_TTL=1h` | The ListSuggestedUsers config (ADR-0024 D8, D10); equal to the code defaults, written out so they are reviewed as code |
| #351 (1) | `PROFILE_UPDATES_PER_DAY=100` | W3-22 L-4 daily cap of `UpdateProfile` (expected; the live revision runs the code default) |
| #360 (1) | `PROFILE_MEDIA_RETIRE=off` | ADR-0024 A4 switch, default `off` (merged after this plan was started; `off` deletes nothing) |

9 + 4 + 9 + 1 + 1 = 24. The expectation was only `PROFILE_UPDATES_PER_DAY` from #351, but W3-4's limit and percent vars were never applied to dev either
(W2-16 applied only the nine bookmark vars). They equal the code defaults (and `PROFILE_MEDIA_RETIRE=off` is the default), so the only behaviour change is the four flags. Redacted plan text (uids
as `<uid-n>`) and the uid-free list to compare against were kept in the preparing session (not committed); the command that produces the list is in step 2.

**The known dev drift (`docs/pending.md` 3.10) is NOT in this plan; `-target` excludes it.** An untargeted plan from the same tree is `Plan: 1 to add, 2 to change,
0 to destroy`: it adds the unapplied #244 TTL field `module.firestore.google_firestore_field.ttl["scheduled_expire_at"]`, changes `module.apikeys.google_apikeys_key.android`
(strips the console-set package and SHA-1 restriction) and the `api` service. The two `-target` flags name the `api` service and the `billing_alerts` topic, so the
apply cannot touch the other two (the topic target is the 3.10 workaround for a state move; today a plan with the `api` target alone is identical, so it is harmless; keep
both as the 2026-10-27 apply did). **Never run a full `terraform apply` in `envs/dev`, and apply only the saved plan file you reviewed.**

**`-target` also pulls in the target's dependencies, and a pending change in one of them joins the plan.** It happened during this preparation: after #360 merged, the `api` service (which reads
`MEDIA_BUCKET`) planned together with `module.media_buckets.google_storage_bucket.media`, whose A4 lifecycle rule was not applied yet, so the plan read `0 to add, 2 to change` (the `api`
service and `+ lifecycle_rule { days_since_custom_time = 1, Delete }`). Terraform 1.16.6 has no `-exclude`. That rule was applied to dev at 15:31 UTC by a separate change that this ticket did not make (the same plan
then read `1 to change` again), which is also why the dev state moves under you: **re-plan right before you apply and stop if a second resource shows up** (step 2).

Variants checked in the preparing session (saved plans, not committed and never to be applied: they are session scoped and stale after any state change): the plan above; the same without `SUGGESTED_USER_IDS`
(decision 2 = empty; still 0/1/0, `SUGGESTED_USER_IDS` added with an empty value); and a baseline with every W3 flag `off` (0/1/0 with the same 24 names, modes `off`). **Re-plan from your checkout** (step 2).

### 2.2 Ceilings and validators (run on this branch, 2026-10-27)
- `scripts/promotion/flag-ceiling.json` (dev): `PROFILE_EXTRAS`, `PROFILE_TABS`, `LIKES_LIST`, `FOLLOW_SUGGESTIONS` are all `allowlist`, `max_allowlist 3`, `max_percent 0` (W3-4, #330). No ceiling
  change is needed or proposed. `validate-revision.sh` on a revision JSON built from the live revision with the planned env (129 entries = 105 + 24) passes: the four flags
  `mode=allowlist (ceiling allowlist) allowlist=3/3 percent=0/0`, every other flag unchanged, `scaling min=0 max=1`, `RESULT: all checks passed`. Run it again on the REAL new revision
  before routing (step 4). The same validator runs inside `deploy-dev` on every candidate.
- `check-flag-registry.sh`: `ok: 20 flags registered`. `check-until-dates.sh infra/terraform`: `ok: 11 until: marker(s) checked against 2026-10-27` (the example lines carry no
  `until:` marker). `check-field-overrides.sh`: `ok: fieldOverrides unchanged: 35 override(s)`. Fixture tests `scripts/promotion/test/run.sh` and `promote-test.sh`: `run.sh` 97 passed, 0 failed; `promote-test.sh` 154 passed, 0 failed.
- **The cohort.** The three uids are set-equal to `feature_bookmarks_allowlist`, `feature_engagement_allowlist` and `feature_media_allowlist` in your tfvars (checked without printing them; also
  equal to ui_shell, notifications, profile_snapshot, reports, replies, quotes, account_lifecycle and removed_ids). It matters: `likes_list` ramps with `bookmarks` and `engagement` on the
  same uids (the History drawer row needs `bookmarks`), the banner also needs `media`, and `follow_suggestions` needs `graph` (on in dev; ceiling `on`). Terraform does not check the subset rule.

## 3. Execution order: the exact commands (founder; each step after its OK)

Run everything from your **MAIN checkout** (the real `terraform.tfvars` is there), after `git pull --ff-only`, so it has this PR. Windows Git Bash, `export GOWORK=off`; `gcloud` and
`terraform` on the PATH (as in the W2-16 apply).

**Step 0: pre-flight.**
```bash
cd <the repo root of your MAIN checkout> && git pull --ff-only
gh run list --workflow deploy-dev.yml --limit 3 --json status,conclusion,headSha   # none in_progress; the newest is success (this PR's own deploy included)
```
Serialise with W4-24 and W5-19 (the other dev applies) and do not merge anything meanwhile.

**Step 1: backfill (decision 3).** With ADC (`gcloud auth application-default login` once):
```bash
# from the repo root of your MAIN checkout; each subshell below leaves the shell where it was
(cd backend && go run ./cmd/opsctl backfill-has-media --project dzeroth-dev --dry-run)   # expect: dry-run: scanned=74 missing=73 would_update=73 runs_needed=1 (nothing written)
(cd backend && go run ./cmd/opsctl backfill-has-media --project dzeroth-dev)             # expect: reads=74 writes=73 deletes=0 ... complete: scanned=74 updated=73 checkpoint=<id>
(cd backend && go run ./cmd/opsctl backfill-has-media --project dzeroth-dev)             # THE PROOF: reads=74 writes=0 deletes=0 ... complete: scanned=74 updated=0
```
Stop, and do not turn `profile_tabs` on, if the third run says anything but `writes=0`. Interrupted: rerun (committed pages stay written). `RESOURCE_EXHAUSTED`: the day's write
quota is spent, rerun tomorrow. Details: `docs/runbooks/posts.md` section 13.

**Step 2: the tfvars lines (decision 2) and the plan.** The lines copy the uids from the bookmarks cohort, so no uid is typed or pasted:
```bash
cd infra/terraform/envs/dev                         # from the repo root of your MAIN checkout
grep -q "^feature_profile_extras" terraform.tfvars && echo "STOP: the W3 lines are already in terraform.tfvars (a second append would redefine the keys)"
UIDS=$(grep -E '^feature_bookmarks_allowlist[[:space:]]*=' terraform.tfvars | sed -E 's/^[^"]*"([^"]*)".*/\1/' | tr -d '\r')
[ "$(printf '%s' "$UIDS" | tr ',' '\n' | grep -c .)" = 3 ] && echo "3 uids" || echo "STOP: not 3 uids"
```
Paste the next block only if the checks above printed `3 uids` and no `STOP` (a pasted block does not stop by itself):
```bash
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
terraform show -json "$PLAN" | jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | .address + "  " + (.change.actions | join(",")), (select(.address | endswith("service.api")) | (.change.before.template[0].containers[0].env | map(.name)) as $had | .change.after.template[0].containers[0].env[] | select(.name as $n | ($had | index($n)) | not) | "  + env " + .name + "=" + (if (.name | test("ALLOWLIST|SUGGESTED_USER_IDS")) then ((.value | split(",") | map(select(. != "")) | length | tostring) + " uid(s)") else .value end))' | tr -d '\r'
```
Expected: the line `module.cloud_run_api.google_cloud_run_v2_service.api  update`, the 24 `+ env` lines of section 2.1, and `Plan: 0 to add, 1 to change, 0 to destroy.` in the plan itself.
**STOP and ask** (do not apply) on, for this first apply: any other resource; any destroy or replace; a removed or changed env entry; any attribute change other than `template.revision` and the added env
entries; a second resource, which is a dependency pulled in by `-target` (section 2.1) that you did not review; a flag mode other than `allowlist`; an allowlist count other than 3; a `FEATURE_*_PERCENT` other than 0. (If another deploy ran meanwhile the `revision` line just shows that newer name.)

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
POST_ID=$(field '[.posts[] | select(.post.kind != "POST_KIND_REPOST")][0].post.postId // empty')   # a REPOST cannot be pinned
[ -n "$POST_ID" ] || echo "STOP: the tester has no pinnable post; post something first (an empty id would send a clear)"
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
| 1 | Reload; the features appear | `HTTP 200 ok` and all four names | 1 to 2 / 0 (GetMe row of section 2) |
| 2 | Edit profile shows the location and website fields; the profile header shows both | `HTTP 200 ok`, `Mumbai https://example.com` | 4 cold (3 service + interceptor) / 1 |
| 3 | Edit profile, banner: pick an image, Save (needs `media` and `profile_extras`) | The banner shows at once, no layout jump | CreateUpload 2 reads / 3 writes, FinalizeUpload 2 / 3, +2 interceptor, **2 Vision units**; UpdateProfile as step 2 |
| 4 | The "Pinned" row at the top of the Posts tab, the post not repeated below; the post menu says Unpin | `HTTP 200 ok`, `true` | UpdateProfile 4 cold (+1 for the pin check) / 1; the pinned row's `GetPost` 1 warm, 4 cold |
| 5 | Posts, Replies, Reposts, Media tabs on the profile, each its own list | `HTTP 200 ok` for each; Media shows posts with images, Reposts the reposts | MEDIA and REPOSTS **24 cold at page 20** (21 planning, 20 warm); `jsonPayload.tab` is `media` or `reposts` |
| 6 | History, Likes tab (`/bookmarks?tab=likes`); newest like first | `HTTP 200 ok`, rows >= 1 | **23 cold** at page 20 (24 asserted ceiling), 2 for an empty list |
| 7 | Open B's profile: the "Follows you" chip and "Follow back" | `HTTP 200 ok`, `true` | 4 cold, 1 after the header's GetProfile, 0 inside 60 s / 0 |
| 8 | The Home "Who to follow" card (and "You might like" in the desktop column with `ui_shell`) | `HTTP 200 ok`, up to 5 rows. With decision 2 = the 3 testers and a tester who follows fewer than 3 accounts it shows at most the other two; if the tester already follows both, it is **empty and the card hides: correct** | friends of friends **42 cold at most**, curated 12 at most (about 5 with a 3-uid list), warm 1 to 2 / 0 |
| 9 | The profile shows none of the four | `HTTP 200 ok` | 1 to 4 / 1 |

A tab with fewer rows than the page costs fewer reads: **24 is a full page of 20**; an empty Media or Reposts page is about 1 for the query plus the cold chain of 4 (the interceptor, the target, the caller's graph and `userLikes`), so a low `fs_reads` on a thin account is not an anomaly. A `200` on an empty Media or Reposts page still proves the index exists (a missing index answers 500). The whole of 4.1 is about 150 cold reads, 15 writes and 2 Vision units in dev. Compare the day with `make cost PROJECT_ID=dzeroth-dev` (last 24 h reads and writes, Vision month and
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
   `feature_follow_suggestions` = `"off"`. Same targeted plan as step 2: after the first apply `main.tf` always emits all 24 vars, so expect **exactly four `~ value "allowlist" -> "off"` changes** (the allowlists stay), 0 added, 0 removed, plus the known `template.revision` line. Apply with the OK, route as step 4. To prove each
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
2. The same targeted plan as step 2. `main.tf` always emits all 24 vars, so removing the nine lines resets values to their defaults and removes no entry: expect **nine `~ value` changes** (the four modes `"allowlist" -> "off"`, the four allowlists and `SUGGESTED_USER_IDS` to empty), 0 added, 0 removed, plus the known `template.revision` line, summarised as `Plan: 0 to add, 1 to change, 0 to destroy`. Apply the saved plan with the OK, then route the new revision as step 4.
3. **Faster, in seconds, no Terraform:** `gcloud run services update-traffic api --project=dzeroth-dev --region=asia-south1 --to-revisions=$SERVING=100`, where `$SERVING` is the revision noted
   in step 4. It has no W3 env, so every flag is off by the code default, and it still contains #335 and #354. `last-good` (`api-00555-yeq`) is also such a revision. Then make the Terraform
   change so state and live agree. **Do not run `deploy-dev` between the two**: it builds its candidate from the service template, which still carries the flags until Terraform is changed.
   **Update 2026-10-28.** `deploy-dev` has run since (#368, 18:30 UTC on 2026-10-27). Dev now serves `api-00571-xat`, and `last-good` is `api-00307-fcs`. Both carry the W3 env (the four flags on `allowlist`, `PROFILE_MEDIA_RETIRE=banner`), so routing to `last-good` does **not** turn the flags off. The revisions with no W3 env are `api-00564-vik` (`$SERVING` above) and `api-00561-meb`; both also have the retire switch `off` and lack only #368's job-log fix. Re-check with `gcloud run revisions describe` before routing.
4. The backfill is not rolled back: `hasMedia` on posts is harmless with the flag off.

## 7. Not verified here (and why)
- The app side of every smoke row (no device or browser session was driven) and the helpers against dev (no tester or smoke credential here). The helper block ran only against a stubbed `curl`.
- A real banner upload through Vision (2 units) and a real Media or Reposts tab call: the first real `fs_reads` per tab come from the smoke above (the emulators measured them).
- The saved plans live in the session scratchpad and go stale on any state change. Re-plan at step 2.
- `SUGGESTED_USER_IDS` behaviour with a 3-uid list is read from `suggester.go` and `docs/runbooks/graph.md` section 6, not run against dev.
- Dev max instances: Terraform sets 1 (the revision shows `maxScale 1`), the ceiling file allows 3. The plan does not change it.

## 8. Applied in dev, 2026-10-27 (what ran, with the numbers)

Run by `production-deployer` on the founder's GO for all three decisions, from the MAIN checkout (`infra/terraform/envs/dev`, the real gitignored `terraform.tfvars`) and the repo root. Times are UTC.
No uid appears here; raw outputs (some hold uids) stayed outside the repository.

| Step | Result |
|---|---|
| Preconditions re-run (about 17:09 to 17:13) | Every composite index READY (none in another state), the six `posts` and two `follows` rows included: `CICAgJiH8YUK` (hasMedia) and `CICAgNjamYQK` (kind) and the `follows` one `CICAgJiH2JAK`. 100% of traffic was on `api-00564-vik` (image `sha256:906eda13f44a9c8ed9de7feb99451e14d15bbcd2a7a68545e728a86f5708428c`, tagged with `b0bc56d7`, main after #362; deploy-dev run 40542454555, success); `last-good` `api-00561-meb` (`4877a196`). `git merge-base --is-ancestor` yes for #335 `9b7cfd90` and #354 `9b3f9fb4` against `b0bc56d7`. The service template had 105 env names and none of the 24 W3 ones; `validate-revision.sh` on it passed with the four W3 flags `mode=off`. `$SERVING` = `api-00564-vik`. |
| Backfill dry run | `scanned=74 missing=73 updated=0`, `reads=74 writes=0 deletes=0`, `dry-run: scanned=74 missing=73 would_update=73 runs_needed=1 (nothing written)` (the same numbers as the plan) |
| Backfill, real run | `call 1: ... -> scanned=74 missing=73 updated=73 checkpoint=0108395972892241920 done=true`, `reads=74 writes=73 deletes=0`, `complete: scanned=74 updated=73` |
| Backfill rerun (the proof) | `scanned=74 missing=0 updated=0`, `reads=74 writes=0 deletes=0`, `complete: scanned=74 updated=0` |
| tfvars | The nine lines were appended to the dev `terraform.tfvars` exactly as step 2 says (the four flags `allowlist`, each allowlist and `suggested_user_ids` copied from `feature_bookmarks_allowlist`, so 3 uids each; checked equal to the bookmarks, engagement and media cohorts without printing them). The duplicate-key guard printed nothing before and 9 keys after. |
| Guards | `check-flag-registry.sh` `ok: 20 flags registered`; `check-until-dates.sh infra/terraform` `ok: 11 until: marker(s) checked against 2026-10-27`; `check-field-overrides.sh` `ok: fieldOverrides unchanged: 35 override(s)`. |
| Plan (about 17:14; saved plan file, `-target` the `api` service and the `billing_alerts` topic) | `Plan: 0 to add, 1 to change, 0 to destroy.` Only `module.cloud_run_api.google_cloud_run_v2_service.api` changes (the plan JSON has 40 resources, 39 `no-op`). Env: before 105, after 129, **24 added, 0 removed, 0 changed**, exactly the 24 names of section 2.1, the four modes `allowlist`, each allowlist and `SUGGESTED_USER_IDS` 3 uids, every `_PERCENT` 0. No attribute other than `template.revision` and the env list differs. No second resource, no 3.10 drift. |
| Apply (about 17:15) | `Apply complete! Resources: 0 added, 1 changed, 0 destroyed.` Traffic did not move (still 100% on `api-00564-vik`). |
| New revision | `$NEW` = `api-00306-482` (its name carries the service configuration generation 306, label `serving.knative.dev/configurationGeneration`, so the number is lower than `00564`; it is the newest by creation time, 17:15:06). `Ready` True. Image `sha256:906eda13f44a9c8ed9de7feb99451e14d15bbcd2a7a68545e728a86f5708428c`, equal to `$SERVING`'s. 129 env names. `validate-revision.sh` on the real revision JSON: `RESULT: all checks passed`; the four flags `mode=allowlist (ceiling allowlist) allowlist=3/3 percent=0/0`, `scaling min=0 max=1`. |
| Route (about 17:16) | `gcloud run services update-traffic api ... --to-revisions=api-00306-482=100`: `100% api-00306-482`, `0% api-00561-meb (last-good)`, `0% api-00564-vik (candidate)`. The `candidate` tag now sits on the previous serving revision at 0%, which is harmless: `promote-dev.sh` (the `deploy-dev` script) deploys a new 0% `candidate` (the tag moves), tags the previously serving revision `last-good` and promotes, and its first check (`check-traffic.sh ... serving`: one named revision at 100%, tags in the dev allow-list `cand`, `p8-t1`, `candidate`, `last-good`) passes on today's shape (run on the live service JSON after the route: `RESULT: all checks passed`). Read from the scripts; no `deploy-dev` run has been done since. `GET /health` on the service URL: `HTTP 200 ok`. |
| After the apply | A fresh targeted plan from the same tfvars: `No changes. Your infrastructure matches the configuration.` (so later plans show no drift from this change). |

### 8.1 Smoke legs: what ran and what is owed
No `TESTER_*` or `SMOKE_*` credential exists on the deploying machine (the smoke accounts' secrets live only in the GitHub `dev` environment, and `scripts/mint-app-token.sh` mints a GitHub App token, not a Firebase ID token), so no authenticated call was made and no workaround was tried.

| Leg | Result |
|---|---|
| `/health` on the service URL | Ran: HTTP 200 `ok` |
| New revision starts with the 24 new env entries (flag parse) | Ran: `Ready` True, serving 100%, `/health` 200, no log line at severity ERROR or above on `api-00306-482` after the route |
| `validate-revision.sh` on the real new revision | Ran: all checks passed |
| The three new RPC paths are served by the new revision (extra to this runbook) | Ran: `ListSuggestedUsers`, `ListLikedPosts`, `GetUserTimeline` with no token each answer `HTTP 401 unauthenticated` (proves routing and the auth interceptor only, not the flag gates) |
| 4.3 filter 2, 5xx on the four RPCs | Ran right after the route and again after the 15-minute watch: no line right after the route and none after the 15-minute watch (it ended 17:32 UTC); also no 5xx on any RPC and no ERROR-or-above line on `api-00306-482`, `/health` 200, traffic still 100% on it. It says nothing yet about those paths: the watch saw no call of the four new RPCs, so the 2%-for-15-minutes trigger of section 6 can only be judged once the testers generate traffic |
| 4.3 filter 1, request lines of the four RPCs | Ran: no call of the new RPCs yet (the only lines are earlier `GetUserTimeline` `posts` calls from before the route) |
| 4.1 steps 1 to 9 (tester: `GetMe` flags, `UpdateProfile` location and website, pin, the four tabs, `ListLikedPosts`, "Follows you", `ListSuggestedUsers`, clear) | **Not run: needs tester credentials** (`TESTER_EMAIL`, `TESTER_B_EMAIL` and passwords in the terminal session) |
| 4.1 step 3 and the "In the app" column (banner upload with its 2 Vision units, History > Likes, "Who to follow" card, profile header, pinned row, tabs) | **Not run: needs tester credentials and an app build** (web `https://dzeroth-dev.web.app` or a device) |
| 4.2 Smoke A, the six checks (four refusals, "Follows you" and Posts tab unrefused) | **Not run: needs the smoke account A credential** |
| Section 5 flag-off check | Not run (it is the rollback check and not required now). Command: in the dev `terraform.tfvars` set the four modes to `"off"` (allowlists stay), the same targeted plan (expect exactly four `~ value "allowlist" -> "off"`, 0 added, 0 removed, plus the known `template.revision` line), apply the saved plan, route the new revision as step 4. Fast fallback with no Terraform: `gcloud run services update-traffic api --project=dzeroth-dev --region=asia-south1 --to-revisions=api-00564-vik=100` (no W3 env, so every W3 flag is off by the code default; it has #335 and #354), then make the Terraform change so state and live agree and do not run `deploy-dev` in between. |

The cohort and the Vision figures are unchanged by this run (Vision units this month 10 of the 10,000 cap, 0 today, read from `make cost PROJECT_ID=dzeroth-dev` after the route).
For the next reader: the dev `api` template now carries the 24 W3 entries, so the next `deploy-dev` run keeps the four flags on `allowlist`; a rollback by Terraform removes the nine tfvars lines as section 6 says.

### 8.2 Tester traffic since the apply, read from the logs (2026-10-28)
Read on 2026-10-28 at about 04:10 UTC with the 4.3 filters plus the request-log 5xx filter on every RPC, for the window from the route (17:16 UTC on 2026-10-27) to then. Counts only: no uid or uid hash is written here.
Three allowlisted accounts used the app in that window. An account is counted as allowlisted only if a `MEDIA` or `REPOSTS` tab call answered `ok` for it, because `profile_tabs` refuses anyone else.

| Leg | Evidence in the logs | Status |
|---|---|---|
| 1. Flags reach the client | `GetMe` `ok` for all three; the client then called the gated RPCs and got `ok` | Covered in effect (the log has no `enabledFeatures` list) |
| 2, 4, 9. Location, website, pin, clear | 4 `UpdateProfile` `ok` from two accounts | Not provable: the request line does not say which fields changed |
| 3. Banner set | 2 `CreateUpload` + `FinalizeUpload` pairs with purpose `BANNER`, each followed by `UpdateProfile` `ok`, from two accounts; 1 `AVATAR` pair | Covered. Dev Firestore holds exactly 2 `BANNER` media documents, one per account, both `READY`, so each was that account's first banner |
| 5. The four tabs | `GetUserTimeline` `ok`: 4 `replies`, 5 `reposts` and 9 `media` across the three accounts; 21 `posts`, 2 of them from a fourth account that is not allowlisted (the Posts tab is never gated) | Covered. A `media` or `reposts` answer of `ok` also proves both W3-2 indexes |
| 6. Likes | 2 `ListLikedPosts` `ok` (19 and 3 reads) | Covered; 19 is under the 23 cold ceiling |
| 7. "Follows you" | No `GetProfileRelationship` call at all | **Owed** |
| 8. Suggestions | 5 `ListSuggestedUsers` `ok` (1 to 9 reads) | Covered; all far under the 42 cap |
| 4.2 Smoke A, the six checks | No `failed_precondition` on any W3 RPC; the one `failed_precondition` in the window is an `AddBookmark` from another flag's smoke | **Owed** |
| Banner replace (`media.md`, "Owed to the testers") | No `account_job=profile_media_retired` line and no `profile_media_retire_enqueue_failed`. That is correct: both banner sets were first sets, which retire nothing | **Owed** |

**Rollback trigger (section 6).** Not met. The four new RPCs answered 49 calls: 46 `ok` and 3 `unauthenticated` (the deployer's no-token probes at 17:17). No 5xx on any RPC in the window, and no line at ERROR or above; the only WARNING lines are the expected 401 and 400 request lines. No cold call went above its 4.1 ceiling. This is thin evidence: 49 calls from three accounts over about 11 hours, most of them in the first two hours.

**What is still owed (testers or the founder, with the 4.1 helpers in a terminal that holds the credentials):**
1. Step 7: tester B follows the tester, then the tester opens B's profile (or runs `GetProfileRelationship`).
2. Steps 2, 4 and 9 as written, so the fields are checked, not only the status.
3. Section 4.2, all six checks, as smoke account A.
4. One banner **replace or remove** by either account that now has a banner, then the four checks in `media.md` "Owed to the testers".
