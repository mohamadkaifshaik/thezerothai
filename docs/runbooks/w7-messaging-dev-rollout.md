# Runbook: W7 messaging dev rollout (ADR-0027, ticket W7-24)

Owner: the founder decides and runs every step that changes dev; `production-deployer` prepared this and applied nothing.
Status (2026-10-29): **PREPARED, NOT APPLIED.** Nothing was applied, routed or deployed. The evidence below is read-only (`gcloud run services describe`, `gcloud firestore indexes fields list`, and one read-only Firestore `runQuery` with a non-existent parent), all against `dzeroth-dev`.
Prod: no change (on hold, `docs/pending.md` 1.2). `feature_messaging` stays `off` there. Plan: `docs/plans/ui-w7-messaging.md` (W7-24). Decisions: ADR-0027. Security condition: `docs/reviews/security-w7-messaging.md` (the dev allowlist is GO only with the 3 team test uids and no real-user data; `max_allowlist: 3` in `scripts/promotion/flag-ceiling.json`).
Related: `docs/runbooks/w3-part-b-rollout.md` (the precedent this copies: targeted plan, route, smoke, results), `docs/runbooks/messaging.md` (kill switch, push test, takedown), `docs/runbooks/account-deletion.md` section 6, `docs/runbooks/notifications.md`, `docs/reviews/cost-model.md` section 14.

## Decisions for the founder

| # | Decision | Recommended | What it costs / risks |
|---|---|---|---|
| 1 | **OK to apply the saved targeted dev plan** (section 4): `feature_messaging` to `allowlist` for the same 3 tester uids as every other dev flag, plus two new cap env entries. 0 add, 1 change, 0 destroy, only the `api` service template. | Yes, after the preconditions of section 1 hold (W7-27 above all) and this PR is merged. | Creates a 0% revision; traffic moves only when you route it (section 5). Reversible in seconds (traffic back) or by Terraform (flag `off`). 3 users, a few hundred reads. |
| 2 | **The account-deletion (tombstone) leg needs a throwaway user who has sent messages**, and sending needs `messaging` on for both people while in-app deletion needs `account_lifecycle`. Both allowlists are at the 3-uid ceiling and the security GO names "the 3 team test uids". | **DECIDED 2026-10-29 (founder): leg 7 is OWED, skipped in this dev smoke.** The W7-20 emulator tests cover the eraser end to end (`internal/messaging/eraser_test.go`, `lifecycle_integration_test.go`). Run the tombstone smoke later, with a throwaway user, **before prod** (`docs/pending.md` 3.16). No allowlist swap and no second plan in this rollout. | None now. Later, the way to run it stays in section 6.10 (a separate targeted plan that swaps C for a throwaway D in both allowlists, each staying at 3, then swaps back; or deleting C itself, which leaves a dead uid in the allowlists until the next swap). |
| 3 | **An Android device with `notifications` on** for the push leg (one handset signed in as B, device registered). | **DECIDED 2026-10-29 (founder): the founder has an Android phone with the dev app. Leg 5 stays in the smoke.** | Without the handset the push and deep-link leg would stay owed; every other leg runs on web. |

## 1. Preconditions, with evidence (dev project `dzeroth-dev`, captured 2026-10-29 about 12:45 UTC)

Re-run every command before you act: the serving state changes with every merge.

### 1.1 W7-27 is merged and deployed to dev: **NOT MET (blocks the apply, not this PR)**
The plan requires W7-27 (`ListMessages` first page returns `unread_count`) before W7-24 (plan table, "must land before W7-24"). At capture time it is not in `origin/main` and the plan row is still Open. Check: `git log origin/main --oneline --grep=W7-27`, then that the newest `deploy-dev` run built a commit at or after it (1.2). W7-30 and W7-33 follow it and also change the messaging read path; they do not gate this ticket.

### 1.2 The latest deploy-dev succeeded and serves what you expect
```bash
gh run list --workflow deploy-dev.yml --limit 3 --json status,conclusion,headSha      # none in_progress; the newest is success
P="--project=dzeroth-dev --region=asia-south1"
gcloud run services describe api $P --format=json > "$LOCALAPPDATA/Temp/w7-24-before.json"
jq -r '.status.traffic[] | "\(.revisionName) tag=\(.tag // "-") percent=\(.percent)"' "$LOCALAPPDATA/Temp/w7-24-before.json"
jq -r '.spec.template.spec.containers[0].image' "$LOCALAPPDATA/Temp/w7-24-before.json"
```
At capture: `api-00758-taj` serves 100% (tag `candidate`), `api-00755-for` carries `last-good`; image `...api/api:ba1afb291ea576847d76178641431d7ccba65dcd@sha256:f4918d48f567aa5cd4848edf6b3a46d9fcf0f406127c59be5899b8a4bc663ac2` (commit `ba1afb29`, #456). That commit predates W7-27, so the image the apply will carry forward is **not** yet the one the plan requires. **Record the serving revision and its image again just before step 0 of section 5; it is your instant fallback.**

### 1.3 The W7-3 fieldOverrides are deployed in dev: PASS
```bash
gcloud firestore indexes fields list --project=dzeroth-dev --format=json \
| jq -r '.[] | select(.name | test("collectionGroups/(messages|dmInbox|dmRequests)/")) | (.name | split("/collectionGroups/")[1]) + "  indexes=" + ((.indexConfig.indexes // []) | length | tostring)'
```
Expect exactly these six lines, each `indexes=0` (an explicit override with no indexes), matching the six `fieldOverrides` for `messages` and `dmInbox` / `dmRequests` in `firebase/firestore.indexes.json`:
```
dmInbox/fields/last  indexes=0
dmInbox/fields/peer  indexes=0
dmRequests/fields/last  indexes=0
dmRequests/fields/peer  indexes=0
messages/fields/requestHash  indexes=0
messages/fields/text  indexes=0
```
At capture all six were present (49 field entries in all). **If any is missing**, the overrides are not deployed: do not touch the flag. They deploy with the dev deploy workflow (`firebase deploy --only firestore:indexes` in `deploy-dev.yml`) when a merge to `main` changes `firebase/firestore.indexes.json`; if the workflow did not run for the W7-3 merge, dispatch `deploy-dev.yml` on `main` (it deploys indexes and rules before the code) and re-run this check. Never run `firebase deploy` by hand against dev without telling the founder.

### 1.4 The 3 test uids, and the flags that must already cover them: PASS
Accounts (W3-38 smoke accounts): **A = @disha, B = @hello1, C = @fan_of_ur_s.** Do not write the uids in the repo, a PR or a chat. They are the set already in your local `infra/terraform/envs/dev/terraform.tfvars`. Messaging needs the **same three** on `notifications` (push), `ui_shell` (the Messages bar item), `reports` (report a message) and `account_lifecycle` (deletion). At capture, `FEATURE_NOTIFICATIONS`, `FEATURE_UI_SHELL`, `FEATURE_REPORTS`, `FEATURE_ACCOUNT_LIFECYCLE` (and bookmarks, private accounts) were all `allowlist` with the **same set** (the six sorted sets hashed to one value), `FEATURE_GRAPH` is `on`. So **no `notifications` edit is needed**; only the two `feature_messaging*` lines change. Re-check without printing uids:
```bash
for f in NOTIFICATIONS UI_SHELL REPORTS ACCOUNT_LIFECYCLE; do printf '%s ' $f; jq -r --arg n "FEATURE_${f}_ALLOWLIST" '.spec.template.spec.containers[0].env[] | select(.name==$n) | .value' "$LOCALAPPDATA/Temp/w7-24-before.json" | tr -d '\r' | tr ',' '\n' | grep . | sort | md5sum | cut -c1-8; done
```
All four hashes must be equal, and equal to the one printed by step 1 of section 4 for the messaging list.

### 1.5 An Android device with notifications on (decision 3)
One handset or emulator signed in as B with a registered device (`RegisterDevice`; web and iOS get no push, ADR-0017 D11), installed from the dev build as in `docs/runbooks/notifications.md`. Check the notifications fan-out subscription is healthy (same runbook). Web: `https://dzeroth-dev.web.app`. The client reads enabled features at **sign-in**: after the route (section 5) every tester hard-refreshes and signs in again before the Messages item appears (the W3 Part B rollout hit this).

### 1.6 Serialise
No `deploy-dev` run in flight, nothing merged between the plan and the route, and no other dev rollout (W4-24, W5-19) applying. `docs/pending.md` 3.10 stays true: **never run a full `terraform apply` in `envs/dev`** (it strips the Android API key restriction and holds the unapplied TTL field). Use the saved targeted plan below only.

## 2. What changes: the env vars, read from the live service

The live dev `api` service has **151** env entries (145 declared in `envs/dev/main.tf` plus 6 the module sets: `APP_CHECK_MODE`, `DEGRADED_MODE`, `ENV`, `FIREBASE_PROJECT_ID`, `INTERNAL_OIDC_ALLOWED_EMAILS`, `INTERNAL_OIDC_AUDIENCE`). Every name in `main.tf` is already live, so before this PR there is no pending env drift. The messaging-related entries live today (the W3-38 apply carried the inert W7 wiring to dev):

| Env var (live, dev, 2026-10-29) | Value now | After this rollout |
|---|---|---|
| `FEATURE_MESSAGING` | `off` | **`allowlist`** |
| `FEATURE_MESSAGING_ALLOWLIST` | empty (0 uids) | **3 uids** (the same set as `FEATURE_NOTIFICATIONS_ALLOWLIST`) |
| `FEATURE_MESSAGING_PERCENT` | `0` | `0` (unchanged) |
| `RATE_LIMIT_MESSAGES_SEND_PER_MIN` / `_READ_PER_MIN` | `20` / `30` | unchanged |
| `MESSAGES_SENDS_PER_DAY` / `MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY` | `300` / `50` | unchanged |
| `QUOTA_DM_NEW_CONVERSATIONS_PER_DAY` / `QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY` | `20` / `5` | unchanged |
| `MESSAGES_REQUEST_MAX_UNANSWERED` | `3` | unchanged |
| `MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR` | `20` | unchanged |
| `CACHE_MESSAGING_CONVERSATION_ENTRIES` | `5000` | unchanged |
| `MESSAGES_MARK_READ_PER_DAY` | **not set** (code default 500) | **`500`, added** (this PR; W7-29 cap, rule 11) |
| `MESSAGES_MUTATIONS_PER_DAY` | **not set** (code default 500) | **`500`, added** (this PR; W7-29 cap, rule 11) |
| `FEATURE_NOTIFICATIONS` / `_ALLOWLIST`, `FEATURE_UI_SHELL`, `FEATURE_REPORTS`, `FEATURE_ACCOUNT_LIFECYCLE` | `allowlist`, same 3 uids | unchanged |
| `FEATURE_SHELLS` | `off`, 0 uids | unchanged (not part of messaging) |
| `DEGRADED_MODE` | `off` | unchanged |

The two added caps equal the code defaults (`backend/pkg/platform/config/config.go`: `MESSAGES_MARK_READ_PER_DAY` 500, `MESSAGES_MUTATIONS_PER_DAY` 500, both must be > 0), so the entries change no behaviour; they make the cap visible config. After the apply the service has **153** env entries.

## 3. The `changedAt` inbox index check (owed before W7-24; read-only; run it before the apply)

The inbox `since` refresh orders by `changedAt DESC, __name__ DESC` and uses `EndBefore` (`internal/messaging/repo_firestore.go`, `ListEntries`). The emulator does not enforce indexes, so this has never run against real Firestore. It uses the automatic single-field index on `changedAt` (`changedAt` is not exempted in `firebase/firestore.indexes.json`; only `peer` and `last` are). The query reads at most 1 document per folder.

**Pre-evidence (preparing session, 2026-10-29, read-only, a non-existent parent so no user data was read):** the `dmInbox` and `dmRequests` queries ordered by `changedAt` returned `readTime` and no error (HTTP 200, no document). The **control**, the same query ordered by the exempt field `peer`, returned `FAILED_PRECONDITION` ("The query requires a COLLECTION_DESC index for collection dmInbox and field peer"), which proves dev enforces indexes and this check can fail. Re-run it as yourself with a real tester uid:

```bash
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"; P=dzeroth-dev
TOKEN=$("$G" auth print-access-token)
H=(-H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $P" -H "Content-Type: application/json")
# the tester's uid stays in the shell: the first uid of the allowlist in your local tfvars (never echoed)
UID_A=$(grep -E '^feature_notifications_allowlist[[:space:]]*=' C:/Users/skmk1/Documents/google-claude-project/project/thezerothai/infra/terraform/envs/dev/terraform.tfvars | sed -E 's/^[^"]*"([^"]*)".*/\1/' | tr -d '\r' | cut -d, -f1)
BASE="projects/$P/databases/(default)/documents"
rq() {   # rq <collection> <orderField>: one read-only runQuery, EndBefore a cursor, limit 1; prints only the status and a document count
  BODY=$(jq -n --arg c "$1" --arg f "$2" --arg ref "$BASE/users/$UID_A/$1/00000000000000000000000000000000" \
    '{structuredQuery:{from:[{collectionId:$c}],orderBy:[{field:{fieldPath:$f},direction:"DESCENDING"},{field:{fieldPath:"__name__"},direction:"DESCENDING"}],endAt:{values:[{timestampValue:"2020-01-01T00:00:00Z"},{referenceValue:$ref}],before:true},limit:1}}')
  curl -s -X POST "${H[@]}" -d "$BODY" "https://firestore.googleapis.com/v1/$BASE/users/$UID_A:runQuery" \
  | jq -c --arg q "$1 by $2" '{query: $q, error: ([.[]? | .error.status] | map(select(. != null)) | first // null), docs: ([.[]? | select(.document != null)] | length)}'
}
rq dmInbox changedAt          # PASS: "error":null  (docs 0 or 1 both pass)
rq dmRequests changedAt       # PASS: "error":null
rq dmInbox peer               # CONTROL, expected to FAIL: "error":"FAILED_PRECONDITION"
```
`endAt` with `before:true` is what the Go `EndBefore` sends. **Expected:** the first two print `"error":null`; the control prints `FAILED_PRECONDITION`. The jq prints only the error status and a count, never `.document` (an inbox entry holds the peer's handle and uid). **Any `FAILED_PRECONDITION` or index error on the first two is a stop**: the since refresh would fail in dev; tell the backend owner (the fix is an index entry in `firebase/firestore.indexes.json`, a gate file). Cost: 3 reads.

## 4. The founder's local `terraform.tfvars` edits and the targeted plan

This PR adds the two cap lines to `envs/dev/main.tf` (and prod). **Merge it first** (with W7-27), then plan from the **MAIN checkout** (the real, gitignored `terraform.tfvars` is there): `git pull --ff-only` and a clean `git status -sb`. Windows Git Bash; `terraform` and `gcloud` on the PATH.

**Edit `C:/Users/skmk1/Documents/google-claude-project/project/thezerothai/infra/terraform/envs/dev/terraform.tfvars`** (append; back the file up first). No `notifications` edit is needed (1.4).
```hcl
feature_messaging           = "allowlist"
feature_messaging_allowlist = "<uidA>,<uidB>,<uidC>"   # the same three uids as feature_notifications_allowlist; no spaces
# feature_messaging_percent stays at its default 0
```
Step 1, the allowlist and the sanity checks (uids never printed):
```bash
cd C:/Users/skmk1/Documents/google-claude-project/project/thezerothai/infra/terraform/envs/dev
grep -c '^feature_messaging' terraform.tfvars                      # 2 after your edit (mode and allowlist); a third line = percent, must be 0
M=$(grep -E '^feature_messaging_allowlist[[:space:]]*=' terraform.tfvars | sed -E 's/^[^"]*"([^"]*)".*/\1/' | tr -d '\r')
printf '%s' "$M" | tr ',' '\n' | grep -c .                         # must print 3
printf '%s' "$M" | tr ',' '\n' | grep . | sort | md5sum | cut -c1-8   # must equal the four hashes of 1.4
```
Step 2, the plan (saved; read-only on GCP):
```bash
export GOWORK=off
PLAN="$LOCALAPPDATA/Temp/w7-24-dev.tfplan"
terraform init -backend-config="bucket=dzeroth-tfstate" -lockfile=readonly      # only if .terraform is missing or stale
terraform plan -input=false -out="$PLAN" \
  -target=module.cloud_run_api.google_cloud_run_v2_service.api
```
The target is the one `google_cloud_run_v2_service` resource. The module ignores `image` and `traffic` (`modules/cloud-run-api/main.tf`, `lifecycle.ignore_changes`), so **the plan cannot revert the CI-deployed image or the traffic split**; it deliberately does not ignore `template[0].revision`, so it always shows `revision -> null` (Cloud Run names the new revision). Earlier rollouts (W3 Part A, W3 Part B) used exactly this single target; if Terraform instead refuses with "Moved resource instances excluded by targeting", add `-target=module.budget.google_pubsub_topic.billing_alerts` (`docs/pending.md` 3.10) and nothing else.

**Expected plan shape:** `Plan: 0 to add, 1 to change, 0 to destroy.` One resource, `module.cloud_run_api.google_cloud_run_v2_service.api`, action `update`. Inside it: `template.revision "api-00758-taj" -> null` (or the newer serving name) and exactly these env differences, 151 to 153 entries:
```
~ FEATURE_MESSAGING            off -> allowlist
~ FEATURE_MESSAGING_ALLOWLIST  0 uid(s) -> 3 uid(s)
+ MESSAGES_MARK_READ_PER_DAY   500
+ MESSAGES_MUTATIONS_PER_DAY   500
```
`env` is an ordered list, so the plan text can show positional churn around the two inserted entries (lines that look removed and re-added, or an index shift). **Do not judge by the plan text: the name-keyed check below is the real one** (it compares before and after by env name and prints only what differs; the same filter was tested on a synthetic plan):
```bash
terraform show -json "$PLAN" | jq -r '
  .resource_changes[] | select(.change.actions != ["no-op"])
  | .address + "  " + (.change.actions | join(",")),
    (select(.address | endswith("service.api"))
     | (.change.before.template[0].containers[0].env | map({(.name): .value}) | add) as $b
     | (.change.after.template[0].containers[0].env | map({(.name): .value}) | add) as $a
     | (($a | keys) + ($b | keys) | unique[]) as $n
     | select($a[$n] != $b[$n])
     | "  " + (if ($b | has($n) | not) then "+" elif ($a | has($n) | not) then "-" else "~" end) + " env " + $n + ": "
       + (if ($n | test("ALLOWLIST"))
          then (([$b[$n] // "" | split(",")[] | select(. != "")] | length | tostring) + " uid(s) -> " + ([$a[$n] // "" | split(",")[] | select(. != "")] | length | tostring) + " uid(s)")
          else (($b[$n] // "(none)") + " -> " + ($a[$n] // "(none)")) end))' | tr -d '\r'
terraform show -json "$PLAN" | jq '[.resource_changes[] | select(.change.actions != ["no-op"])] | length'     # 1
```
Expected output: the line `module.cloud_run_api.google_cloud_run_v2_service.api  update`, then exactly the four `env` lines above, and `1`.

**STOP and show me (do not apply) on any of:**
- a second resource in the plan, or a `delete` / `create` / replace action;
- a `-` (removed) env line, or a `~` on any env name other than `FEATURE_MESSAGING` and `FEATURE_MESSAGING_ALLOWLIST`;
- a `+` on any name other than the two caps;
- `FEATURE_MESSAGING` not `allowlist`, an allowlist count other than 3, or `FEATURE_MESSAGING_PERCENT` not 0;
- **a diff on `image`, `traffic`, scaling (`max_instance_count`, `min_instance_count`, concurrency), memory, IAM or any attribute other than `template.revision` and `env`.** The image is ignored by the module, so a shown image diff means the module changed or the state is stale: re-run `git pull`, `terraform init`, and re-plan; if it persists, stop. If another deploy ran meanwhile, the `revision` line shows the newer name and the new revision carries the newer image: redo 1.2.
The ceiling check for the result is in section 5 (`validate-revision.sh`, `MESSAGING mode=allowlist allowlist=3/3 percent=0/0`). No ceiling change is needed or proposed.

## 5. Execution order (founder; each step after its OK)

**Step 0, pre-flight.** Re-run 1.1 to 1.4; note the serving revision and `last-good` and the image digest (the fallback). Run section 3. Take the plan of section 4.
**Step 1, apply (the saved plan only; needs your OK).**
```bash
cd C:/Users/skmk1/Documents/google-claude-project/project/thezerothai/infra/terraform/envs/dev
terraform apply "$LOCALAPPDATA/Temp/w7-24-dev.tfplan"       # expect: Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```
**Step 2, route traffic.** The apply creates a **0% revision**; dev traffic is pinned to a named revision and Terraform ignores `traffic`, so **without routing nothing changes for users**. Do not route while a `deploy-dev` run is in flight.
```bash
P="--project=dzeroth-dev --region=asia-south1"
SERVING=$(gcloud run services describe api $P --format=json | jq -r '.status.traffic[] | select(.percent==100) | .revisionName' | tr -d '\r')   # the instant fallback
NEW=$(gcloud run services describe api $P --format="value(status.latestCreatedRevisionName)" | tr -d '\r')
[ "$NEW" != "$SERVING" ] || echo "STOP: no new revision"
gcloud run revisions describe $NEW $P --format="value(spec.containers[0].image)"      # must equal the same command on $SERVING
gcloud run revisions describe $NEW $P --format=json > "$LOCALAPPDATA/Temp/w7-24-new-rev.json"
cd C:/Users/skmk1/Documents/google-claude-project/project/thezerothai
bash scripts/promotion/validate-revision.sh "$LOCALAPPDATA/Temp/w7-24-new-rev.json" scripts/promotion/flag-ceiling.json dev   # RESULT: all checks passed; MESSAGING mode=allowlist allowlist=3/3 percent=0/0
gcloud run services update-traffic api $P --to-revisions=$NEW=100 --quiet
# Fallback in seconds: gcloud run services update-traffic api $P --to-revisions=$SERVING=100   (that revision has MESSAGING off)
```
Confirm one revision serves 100% (`gcloud run services describe api $P --format=json | jq '.status.traffic'`), `GET /health` is 200, then run the smoke (section 6) and watch 15 minutes (section 8). **Do not run `deploy-dev` between the apply and the route**; the next `deploy-dev` builds from the template, which now carries the flag. Add the same two lines to your tfvars backup record so a later plan says `No changes`.

## 6. Dev smoke (founder, after the route)

Accounts: **A** = @disha, **B** = @hello1, **C** = @fan_of_ur_s. Three browser profiles or windows on `https://dzeroth-dev.web.app`, plus the Android handset signed in as B (decision 3). Each signs in fresh (1.5). Credentials stay in your sessions. Use fresh test text; the logs never hold message text, so write down what you sent.

**Logs Explorer.** Project `dzeroth-dev`, base filter `B`:
```
B:  resource.type="cloud_run_revision" AND resource.labels.service_name="api"
```
Request lines are `jsonPayload.message="request"` with `rpc`, `kind`, `state`, `refused_reason`, `limit_name`, `results`, `conversation_hash`, `uid_hash`, `fs_reads`, `fs_writes`. `uid_hash` and `conversation_hash` are the first 16 hex characters of sha256 of the uid / the conversation id, so you can find your own testers without any uid in the log:
```bash
h16() { printf '%s' "$1" | sha256sum | cut -c1-16; }     # h16 "<uid>" ; the conversation id is the 32-hex tail of the /messages/<id> URL
lg() { gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"api\" AND $1" --project=dzeroth-dev --freshness="${2:-30m}" --limit=60 --format=json \
  | jq -c '.[] | {t: .timestamp[11:23], rpc: ((.jsonPayload.rpc // .jsonPayload.message // "") | split("/")[-1]), kind: .jsonPayload.kind, state: .jsonPayload.state, refused: .jsonPayload.refused_reason, limit: .jsonPayload.limit_name, results: .jsonPayload.results, reads: .jsonPayload.fs_reads, writes: .jsonPayload.fs_writes, status: .httpRequest.status}' | tr -d '\r'; }
# e.g. lg 'jsonPayload.kind="send"'
```
Costs are from the plan and `docs/runbooks/messaging.md` section 4: SendMessage at most 5 reads cold and 3 / 4 / 5 writes (accepted / request / new conversation); Accept 3 reads, 2 writes, 1 delete; Delete 3 reads, 1 write, 1 delete; ListMessages poll about 1.4 reads; MarkConversationRead 2 reads, 1 write.

| # | Step (in the app) | Success looks like | Verify in Logs Explorer |
|---|---|---|---|
| 0 | A, B, C, and the dev smoke account (not allowlisted, `docs/runbooks/smoke-accounts.md`) sign in fresh | A, B, C show a **Messages** item (the 5th bar item, rail on wide screens) and the profile **Message** button; the smoke account shows neither | none (`GetMe` carries `messaging` in enabled features). A not-allowlisted `SendMessage` is `FEATURE_DISABLED`, see leg 3 negative |
| 1 | **A mutual pair sends both ways.** Make A and B follow each other (profile Follow; the earlier W3 smoke may have left B following A, so only the missing direction is needed). A: Messages, **New message**, pick B (your Following list), send "w7 a1". B: open Messages | B's **Conversations** list (not Message requests) shows A's row with 1 unread and the badge on Messages; opening it shows "w7 a1". B replies "w7 b1"; A sees it within about 15 s with the thread open (web hot poll) | `B AND jsonPayload.kind="send"`: the first send `state="new"` (5 writes: conversation, message, two entries, count), the reply `state="accepted"` (3 writes); each `fs_reads` <= 5, no `refused_reason`. Then `B AND jsonPayload.kind="poll"`: the open thread's polls, `results` 0 then 1 when the message lands, about 1 to 3 reads each |
| 2 | **A non-mutual request, accept, delete.** What makes this a request is that the pair is **not mutual**: A must not follow C (C may already follow A from the W3 smoke; that is fine). C: New message, pick or open A's profile Message button, send three messages "w7 c1", "w7 c2", "w7 c3" and then a fourth "w7 c4". A: Messages | A's **Message requests (1)** row (not Conversations); opening it shows C's messages and the request banner (**Accept**, **Delete**, **Block**). C's thread shows "Waiting for them to accept. You can send up to 3 messages." (it can disappear on reopen, plan W7-25). The **fourth** send is refused with a "too many requests" style error. A taps **Accept**: the conversation moves to A's Conversations. A then opens the thread menu, **Delete conversation**, and confirms: it leaves A's list; C still has its copy | sends 1 to 3: `state="request"` (4 writes); send 4: `limit_name="request_unanswered"` (RESOURCE_EXHAUSTED, 0 writes). Accept: `jsonPayload.kind="accept"`, 3 reads 2 writes 1 delete. Delete: `jsonPayload.kind="delete"`, 3 reads 1 write 1 delete. No push for the request (leg 5 negative) |
| 3 | **Block refusal.** B blocks C (C's profile, Block; B and C have no other relation, so the mutual A-B pair is untouched). C tries to send "w7 blocked" to B. Then B unblocks C | C's send fails with the generic "can't message" answer (the same bytes as every other refusal; it must not say blocked). Nothing reaches B. After the unblock C can send again (as a request, since B and C are not mutual) | `B AND jsonPayload.kind="send" AND jsonPayload.refused_reason:*`: `refused_reason="blocked"` (request line only; the wire answer is one CANNOT_MESSAGE). `B AND jsonPayload.limit_name=~"^(messages_\|request_unanswered\|dm_new_daily)"` lists any cap refusal (none expected here) |
| 4 | **Web polling.** B keeps the thread with A open on web, tab visible. A (any client) sends 3 messages at random gaps | Each message shows in B's thread by itself, no refresh, within about 15 s (up to about 45 s once the thread has been quiet); hidden tab or 5 minutes idle stops the polls | `B AND jsonPayload.kind="poll"` for B's `uid_hash`: a line about every 15 s while hot with `poll=true`, `results` 1 when a message lands; `since_retired` absent; reads about 1.4 per poll. A hidden tab shows the lines stop. Keep the data: this is also the input of section 7 |
| 5 | **Android push and deep link.** B signed in on the handset (notifications on), app in the background. A sends "w7 push" in the mutual A-B conversation. **Negative:** C (not mutual with B) sends B "w7 req" | The handset shows the generic **New message** push (no sender, no text). Tapping it opens `/messages/<conversationId>` over Home with the thread loaded and the message shown; the Messages badge clears after reading. C's request pushes nothing (it shows under Message requests); a muted sender pushes nothing; 21 messages in an hour show `push_throttled` (optional) | `jsonPayload.message="notification_delivery" AND jsonPayload.type="message"`: `outcome="ok"` `pushed=1` for the mutual message; none for C's request; `suppressed` / `push_throttled` counters otherwise. After the tap the thread shows `kind="list_messages"` then `kind="mark_read"` (2 reads, 1 write) |
| 6 | **Report a message.** First B sends a **fresh** message "w7 report me" in the mutual A-B thread, and it must stay the **last** message of that thread (nobody sends after it: the takedown only rewrites an inbox preview that shows the removed message, leg 8). On web, A long-presses (secondary click) that bubble in the A-B thread, picks **Report message**, chooses a reason and submits. Then A repeats the same report | A confirmation; the repeat answers "already reported". B is not told | `jsonPayload.report_target="MESSAGE"` with `outcome` (created, then the repeat's outcome): 6 reads cold / 3 warm, 2 writes, no text and no id in clear. The report is what leg 8 takes down |
| 7 | **OWED (founder decision 2026-10-29): skip in this dev smoke; run before prod.** Account deletion of a throwaway user (tombstone). Decision 2. See 6.10 for the later run | When it is run: after the deletion job, A's thread with the throwaway shows the throwaway's messages as "Message deleted" and the header as "Deleted account"; A's own messages remain | `jsonPayload.account_job:* AND jsonPayload.step="messaging"` (the `account_job` delivery line, `outcome`, `seq`) and `jsonPayload.message="messaging_purge_done"` with `conversations`, `messages_tombstoned`, `entries_deleted` (counts only, no peer uid) |
| 8 | **Takedown, dry run, then real.** After leg 6 there is an OPEN message report. From `C:/Users/skmk1/Documents/google-claude-project/project/thezerothai/backend` (ADC login as in `docs/runbooks/moderation.md`): `go run ./cmd/opsctl reports list --project dzeroth-dev`, then `reports show --project dzeroth-dev --id <reportId>` (target = `<conv>:<msg>`, 32 hex each; the evidence text is private: read it, do not paste it). Then `go run ./cmd/opsctl messages takedown <target> --project dzeroth-dev --report <reportId> --dry-run`, check the plan, then run it again **without** `--dry-run` | Dry run prints `VISIBLE -> REMOVED`, `2 inbox preview(s) rewritten` (only because the reported message is still the last one of the thread; if anything was sent after it the count is 0 and the Inbox row keeps its snippet, while the thread still converges), `wrote=false`, an `audit:` line and the cost line (<= 4 reads), and writes nothing. The real run prints `wrote=true` and resolves the report as TAKEDOWN. On a device that **cached** the thread (leave A's thread open first, or open it once before the takedown), the next poll cold-opens it and the bubble reads **"This message was removed"**; the Inbox row for that conversation shows the same snippet at the next refresh, in the same position. The report keeps the evidence copy until resolved + 90 days | `B AND jsonPayload.kind="poll" AND jsonPayload.since_retired=true` once per device with a cached thread (reads 2, VALIDATION `since_token`), followed by a `list_messages` cold open; a `jsonPayload.kind="list_conversations"` line at the Inbox refresh that returns the rewritten entry. The `opsctl` audit line is on your terminal (`audit: messages takedown ... wrote=true`), not in Cloud Logging |

Notes: legs 1 to 6 and 8 need only A, B, C. Leg 7 is owed (decision 2, founder 2026-10-29), so the allowlists stay A, B, C throughout and there is no second plan. Leg 5 runs on the founder's Android phone with the dev app (decision 3). Idempotency keys come from the app, so retries do not double-send. Compare the day with `make cost PROJECT_ID=dzeroth-dev`; the messaging calls must stay inside the budgets above (a few hundred reads in all).

### 6.10 Leg 7 in detail (OWED: not part of this dev smoke, founder decision 2026-10-29; run it later with a throwaway user, before prod)
Kept so the later run is ready. Recommended path: swap C for D.
1. Create a throwaway account D (a verified email or Google account; the API refuses unverified emails). Sign it up in the dev web app and set a handle.
2. In your local tfvars set `feature_messaging_allowlist` and `feature_account_lifecycle_allowlist` to `<uidA>,<uidB>,<uidD>` (C out, D in; still 3 each). Make a **new saved plan** exactly as section 4 with the same `-target`; its name-keyed check must show only `~ FEATURE_MESSAGING_ALLOWLIST: 3 uid(s) -> 3 uid(s)` and `~ FEATURE_ACCOUNT_LIFECYCLE_ALLOWLIST: 3 uid(s) -> 3 uid(s)`, plus the revision line; any other line is a stop. Apply on your OK, validate, route (section 5 steps 1 and 2), everyone signs in fresh.
3. D and A follow each other; D sends A three messages and A replies once ("w7 d1".."d3").
4. D: Settings, **Delete account**, confirm (a sign-in no older than 5 minutes is asked for first). Wait for the job (a few minutes; the DELETING start gate is 120 s, repeated `disable_revoke` lines are expected, `docs/runbooks/account-deletion.md` section 6).
5. A opens the thread (or the Inbox): D's messages read "Message deleted", the header "Deleted account"; A's own message stays. Logs as in the leg 7 row. D's tombstone does not turn into "This message was removed" if a takedown follows (a `REMOVED` message stays `REMOVED`).
6. **Swap C back:** restore both tfvars lines to `<uidA>,<uidB>,<uidC>`, a new targeted plan whose check shows the two allowlist lines again, apply, validate, route. D's uid is gone from Auth, so the dev allowlists end at the original three.
The owed state is recorded in 10.1. If you use alternative (c) (delete C itself), skip steps 2 and 6 and expect C unusable afterwards.

## 7. The send-to-render p95 (the W7-23 method, `docs/reviews/cost-model.md` section 14 "Owed at W7-24")

**What is measured and what differs from W7-23.** W7-23 defined `t_render` as the client time at which B's UI first draws the message, bounded by clock skew. Here, both timestamps come from the **server request log**, so no clock-skew bound is needed: `t_send` is the log time of A's `SendMessage` line (`kind="send"`, server commit), `t_deliver` is the log time of B's first `ListMessages` poll for that conversation after it with `results >= 1`. It **leaves out the client render and the return trip, about 0.1 to 0.5 s**; add that range to the reported figure. Optional cross-check of the client side: DevTools, Network, B's `ListMessages` response row for three of the sends (its end time to the bubble drawing is the omitted part).

**Run it.** B on **web**, signed in, the thread with A open and visible the whole time (so the poller is hot, 15 s). A sends **about 20** messages (any client; keep A's own thread otherwise untouched) at **random offsets, uniform 0 to 30 s apart** so the sends are not phase-locked to B's poll (a coin flip on a timer app or `shuf -i 0-30 -n 1` is enough). Do not touch B's tab. Note the start and end time. Cost to dev: about 20 sends x 10 reads plus 20 minutes of polls (80 x 1.4), under 400 reads. An **Android** push-triggered pull is a separate number (not the trigger): note the time from the send to the message on screen on the handset for a few sends.

**Compute it** (fresh logs, run right after; `CONV` is the 32-hex id from the `/messages/<id>` URL, A and B are the testers' uids kept in the shell):
```bash
TF=C:/Users/skmk1/Documents/google-claude-project/project/thezerothai/infra/terraform/envs/dev/terraform.tfvars
ALL=$(grep -E '^feature_messaging_allowlist[[:space:]]*=' "$TF" | sed -E 's/^[^"]*"([^"]*)".*/\1/' | tr -d '\r')
UID_A=$(printf '%s' "$ALL" | cut -d, -f1); UID_B=$(printf '%s' "$ALL" | cut -d, -f2)     # whichever two of the three you used as sender (A) and reader (B); never echoed
CONV_ID=<the 32 hex characters at the end of the /messages/<id> URL>
HA=$(h16 "$UID_A"); HB=$(h16 "$UID_B"); HC=$(h16 "$CONV_ID")       # `h16` from section 6; HC = conversation_hash
cat > "$LOCALAPPDATA/Temp/w7-p95.jq" <<'EOF'
def t: .timestamp | sub("Z$"; "") | split(".") | ((.[0] + "Z" | fromdateiso8601) + (("0." + (.[1] // "0")) | tonumber));
def r: . * 10 | round / 10;
([.[] | select(.jsonPayload.kind == "send" and .jsonPayload.uid_hash == $A and .jsonPayload.conversation_hash == $C and (.jsonPayload.refused_reason // "") == "" and (.jsonPayload.limit_name // "") == "") | t] | sort) as $sends
| ([.[] | select(.jsonPayload.kind == "poll" and .jsonPayload.uid_hash == $B and .jsonPayload.conversation_hash == $C and (.jsonPayload.results // 0) >= 1) | t] | sort) as $polls
| [$sends[] as $s | ([$polls[] | select(. > $s)] | first) as $p | select($p != null) | ($p - $s)] | sort as $d
| {sends: ($sends | length), matched: ($d | length), p50_s: ($d[(($d | length) * 0.5 | ceil) - 1] | r), p95_s: ($d[(($d | length) * 0.95 | ceil) - 1] | r), max_s: ($d | last | r), all_s: ($d | map(r))}
EOF
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND jsonPayload.message="request" AND (jsonPayload.kind="send" OR jsonPayload.kind="poll")' \
  --project=dzeroth-dev --freshness=1h --limit=2000 --format=json \
| jq -c --arg A "$HA" --arg B "$HB" --arg C "$HC" -f "$LOCALAPPDATA/Temp/w7-p95.jq"
```
`matched` must equal `sends` (a send with no later `results >= 1` poll means B's poller missed it: look at that gap, it is the finding). Nearest-rank p95 (the 19th of 20). **Expected:** gaps spread over 0 to 15 s, **p95 near 15 s against the 20 s trigger** (about 5 s of headroom), plus the 0.1 to 0.5 s omitted. **A p95 above 18 s means the poller is late** (a throttled hidden tab, retries) and is the finding; above 20 s with user complaints is the stage-ladder trigger.

**Record it** in two places: (1) `docs/reviews/cost-model.md` section 14, under "Owed at W7-24: send-to-render p95 on dev", a new "Measured at W7-24" paragraph with the date, n, p50 / p95 / max, the omitted-client note, and the first real `poll_reads` and `msg_reads` of section 9 (`results`, `fs_reads` of the poll lines, mean over the window) against the 1.41 modelled; and (2) section 10.2 below. Also record that the `changedAt` index check passed (section 3).

## 8. What to watch (15 minutes after the route, then after the first day)

- 5xx on the messaging RPCs, expected empty: `logName="projects/dzeroth-dev/logs/run.googleapis.com%2Frequests" AND httpRequest.requestUrl=~"messaging.v1.MessagingService" AND httpRequest.status>=500`.
- Error Reporting stays quiet for the new revision; no `ERROR` severity from `api`.
- Contention and refusals: `jsonPayload.message=~"^messaging_.*_contention"` (WARN, `messaging_txn_contention` on the request line above 1 attempt is the hot-entry signal), `jsonPayload.limit_name=~"^(messages_|request_unanswered|dm_new_daily)"`, `jsonPayload.refused_reason:*`.
- Poll share and cost: `docs/runbooks/messaging.md` section 4 (`kind=poll` share of requests, ListMessages p50).
- Push: `jsonPayload.message="notification_delivery" AND jsonPayload.type="message"`: `outcome`, `pushed`, `suppressed`, `push_throttled`.
- Cost: `make cost PROJECT_ID=dzeroth-dev`; a few hundred extra reads, writes well under 20,000 a day.

## 9. Rollback, the kill switch and the fallback

**Trigger.** Messaging RPC error rate above 2% for 15 minutes, any message or participant list shown to the wrong person (authz finding: stop at once), a poll storm (poll share above 35% of requests for a day), an unexpected `FEATURE_DISABLED` for an allowlisted tester, or a spam wave in reports.

**Kill switch = the flag, through Terraform:** set `feature_messaging = "off"` in your local tfvars (the allowlist line may stay; mode `off` ignores it) and make the same targeted plan as section 4. Expect exactly **one `~ FEATURE_MESSAGING: allowlist -> off`** (plus the revision line), 0 added, 0 removed. Apply the saved plan with your OK, then route (section 5 step 2). `off` makes every messaging RPC `FEATURE_DISABLED` with no read past the interceptor's, hides the destination, routes and profile button, and stops message pushes. **Stored conversations stay** and come back with the flag, and account deletion still erases them whatever the flag. No data migration. Only mode `off` is the kill switch (an empty allowlist or percent 0 is a rollout).

**Fast fallback, seconds, no Terraform:** `gcloud run services update-traffic api --project=dzeroth-dev --region=asia-south1 --to-revisions=<SERVING recorded at step 0>=100`. That revision has `MESSAGING` off (the code default), so the feature goes dark for everyone. There is no rollback floor for `MESSAGING` (`flag-ceiling.json` `rollback_floors` holds only `PRIVATE_ACCOUNTS`). Then make the Terraform change so state and live agree, and **do not run `deploy-dev` in between** (it builds from the template, which still carries the flag until Terraform changes).

## 10. Afterwards, and the results record

**The flag's planned state in dev after the smoke:** `feature_messaging = "allowlist"` with the same 3 uids stays (dev's planned state; the ceiling is `allowlist` / 3 / percent 0). Nothing is raised. The tfvars in the main checkout keep the two lines so a later targeted plan says `No changes` and a later apply keeps the flag. Prod stays `off`; the ramp is in the plan's Rollout plan section and needs the held prod apply (`docs/pending.md` 1.2), the prod-blocking findings of `docs/reviews/security-w7-messaging.md` fixed, and your launch decision.

**Record the results here** (fill in after the run, the way `w3-part-b-rollout.md` section 9 does), then update `docs/plans/ui-w7-messaging.md` (W7-24 to Done), `docs/pending.md` 3.16 and the new row for the apply, and `docs/reviews/cost-model.md` section 14. Do not write uids, tokens or message text in the repo; testers are named by handle and a uid hash prefix of 6 characters.

### 10.1 Smoke results, dev (to fill in)
| Step | Result | Evidence (times UTC, `rpc` and `kind`, `fs_reads` / `fs_writes`, no text) |
| --- | --- | --- |
| Preconditions (W7-27 deployed, fieldOverrides, allowlist hashes, serving revision) | | |
| `changedAt` index check (section 3) | | |
| Plan counts and the four env lines (section 4) | | |
| Apply, validate-revision, route; new revision name and image | | |
| 0. Messages item for A, B, C; not for the smoke account | | |
| 1. Mutual pair sends both ways | | |
| 2. Request, accept, delete (and the fourth send refused) | | |
| 3. Block refusal and the cohort refusal | | |
| 4. Web polling | | |
| 5. Android push and deep link (and the request negative) | | |
| 6. Report a message | | |
| 7. Throwaway account deletion, tombstone | owed (founder decision 2026-10-29) | Skipped here; covered meanwhile by the W7-20 emulator eraser tests. Run it with a throwaway user before prod (`docs/pending.md` 3.16). |
| 8. Takedown dry run, real takedown, "This message was removed" on a cached device | | |
| Watch window (5xx, ERROR, contention) | | |
| Rollback or flag-off check | | |

### 10.2 Send-to-render p95, dev (to fill in)
n sends, matched, p50 / p95 / max (server-side, seconds), the omitted client render and return trip (0.1 to 0.5 s), Android push-to-screen notes, and the first real `poll_reads` and `msg_reads` against the modelled 1.41. Verdict against the 20 s trigger.

## 11. Not verified here (and why)
- Every smoke leg: no tester credential exists on the preparing machine, and the app flows are read from the client code and the runbooks, not run. The exact button labels are the ones in `app/lib/features/messages` (Message requests, Accept, Delete, Block, Delete conversation, Report message, "This message was removed", "Message deleted").
- The plan itself: no `terraform plan` was run (it needs the real tfvars in the main checkout). The expected shape comes from the live service (151 env entries, every `main.tf` name already live) and the `main.tf` change (two added entries and the two flag values).
- The `changedAt` check against a **real tester's** inbox: only a non-existent parent was queried (index enforcement does not depend on the data).
- Whether W7-27 and its successors change the poll or send read costs: the figures above are W7-23's.
