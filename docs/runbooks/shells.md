# Runbook: `shells` (W8 coming-soon pages)

| Flag | Env / Terraform | Gates | Default |
| --- | --- | --- | --- |
| `shells` | `FEATURE_SHELLS[_ALLOWLIST\|_PERCENT]` / `feature_shells*` | client only (no RPC): the Creator tools, Premium, Advertise and Calls pages, their drawer rows (under 600 dp) and the rail "More" menu (600 dp and up). Plan: `docs/plans/ui-w8-shells.md` | off |

- **Entries need `shells` and `ui_shell`.** With `ui_shell` off there is no entry in the legacy layout (founder decision F6, 2026-10-28). The routes need `shells` only; with it off, a typed `/creator-studio`, `/premium`, `/advertise` or `/calls` lands on Home.
- **Which pages exist** is the client constant `kVisibleShells`, not the flag: one flag turns all of them on or off for a caller.
- **Cost:** 0 reads/writes and 0 RPCs; the flag already travels in `GetMe.enabled_features`. The only cost is the web bundle (plan, Cost section).
- **Ramp:** dev allowlist (3 uids that also have `ui_shell`), ceiling in `scripts/promotion/flag-ceiling.json` (founder review). Prod: the founder accepted a prod raise up to `on` on all platforms (2026-10-28): allowlist, then `on`, each step a Terraform change plus a `v*` tag, a production-reviewer GO and `promote-prod` (ADR-0019). It reaches users only once `ui_shell` is on in prod. `flag-ceiling.json` has no `prod` block for any flag yet, so that decision lives here and in the plan, not in the file.
- **Rollback:** set `FEATURE_SHELLS=off` (or shrink the allowlist) and deploy; clients drop the entries and routes on their next `GetMe`. One page only: remove its kind from `kVisibleShells` by PR (web on the next deploy, mobile on the next store build).
- **Failure modes:**
  - **A page is visible to a user outside the allowlist:** roll back as above, then check `GetMe.enabled_features` for that uid.
  - **A store rejects a build over the pages** (placeholder content, or shown Premium prices without store billing; risk accepted by the founder): drop the cited kind from `kVisibleShells` for the store build and resubmit, or set `shells` off. Web is unaffected.
  - **The Premium pop-up opens without a tap,** or a page reads as something you can buy today: roll back as above and file a bug; the plan's tap-only and copy-guard tests should have caught it.

## Dev rollout (W8-11): the exact commands (founder; each step after its OK)

Prepared 2026-10-28 by the assistant, which has no GCP credentials or Terraform in its container and never sees the uids. Nothing here has been run.
The plan output below is **expected**, not captured: run step 2 and compare.

**Prerequisites.**
- PR #392 (W8) is merged and its `deploy-dev` run succeeded: that ships the API with `FEATURE_SHELLS` registered (default off) and the dev web build with the pages. Until then the flag change does nothing visible.
- No other dev apply in flight (serialise with W3–W7 rollouts, `pending.md` 3.10: never a full `terraform apply` in `envs/dev`).
- The cohort is the 3 testers that already have `ui_shell`: entries need `shells` **and** `ui_shell` (F6), so the lines copy `feature_ui_shell_allowlist`. No uid is typed or pasted.

Run from your **MAIN checkout** (the real gitignored `terraform.tfvars` is there), Windows Git Bash, `export GOWORK=off`, `gcloud` and `terraform` on the PATH.

**Step 0: pre-flight.**
```bash
cd <the repo root of your MAIN checkout> && git pull --ff-only
gh run list --workflow deploy-dev.yml --limit 3 --json status,conclusion,headSha   # none in_progress; the newest is success and includes #392
```

**Step 1: the tfvars lines.**
```bash
cd infra/terraform/envs/dev
grep -q "^feature_shells" terraform.tfvars && echo "STOP: the W8 lines are already in terraform.tfvars"
UIDS=$(grep -E '^feature_ui_shell_allowlist[[:space:]]*=' terraform.tfvars | sed -E 's/^[^"]*"([^"]*)".*/\1/' | tr -d '\r')
[ "$(printf '%s' "$UIDS" | tr ',' '\n' | grep -c .)" = 3 ] && echo "3 uids" || echo "STOP: not 3 uids"
```
Paste the next block only if the checks printed `3 uids` and no `STOP`:
```bash
cat >> terraform.tfvars <<EOF

# W8 coming-soon pages (W8-11, ADR-0026): the same 3 testers as ui_shell. Remove these lines to roll back.
feature_shells           = "allowlist"
feature_shells_allowlist = "$UIDS"
EOF
```

**Step 2: the targeted plan.**
```bash
PLAN="$LOCALAPPDATA/Temp/w8-11-dev.tfplan"
terraform init -backend-config="bucket=dzeroth-tfstate" -lockfile=readonly      # only if .terraform is missing or stale
terraform plan -input=false -out="$PLAN" \
  -target=module.cloud_run_api.google_cloud_run_v2_service.api \
  -target=module.budget.google_pubsub_topic.billing_alerts
terraform show -json "$PLAN" | jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | .address + "  " + (.change.actions | join(",")), (select(.address | endswith("service.api")) | (.change.before.template[0].containers[0].env | map(.name)) as $had | .change.after.template[0].containers[0].env[] | select(.name as $n | ($had | index($n)) | not) | "  + env " + .name + "=" + (if (.name | test("ALLOWLIST")) then ((.value | split(",") | map(select(. != "")) | length | tostring) + " uid(s)") else .value end))' | tr -d '\r'
```
**Expected:** `module.cloud_run_api.google_cloud_run_v2_service.api  update`, then exactly three lines `+ env FEATURE_SHELLS=allowlist`, `+ env FEATURE_SHELLS_ALLOWLIST=3 uid(s)` and `+ env FEATURE_SHELLS_PERCENT=0`, and `Plan: 0 to add, 1 to change, 0 to destroy.` in the plan itself.
**STOP and ask** (do not apply) on any other resource, any destroy or replace, a removed or changed env entry, any attribute change other than `template.revision` and these three entries, a mode other than `allowlist`, or a count other than 3.

**Step 3: apply the saved plan only.**
```bash
terraform apply "$PLAN"        # expect: Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

**Step 4: route traffic.** The apply creates a 0% revision (dev traffic is pinned, as in `w3-part-a-rollout.md` step 4). Do not route while a `deploy-dev` run is in flight.
```bash
P="--project=dzeroth-dev --region=asia-south1"
SERVING=$(gcloud run services describe api $P --format=json | jq -r '.status.traffic[] | select(.percent==100) | .revisionName' | tr -d '\r')   # the instant fallback
NEW=$(gcloud run services describe api $P --format="value(status.latestCreatedRevisionName)" | tr -d '\r')
[ "$NEW" != "$SERVING" ] || echo "STOP: no new revision"
gcloud run revisions describe $NEW $P --format="value(spec.containers[0].image)"          # must equal the same command on $SERVING
gcloud run revisions describe $NEW $P --format=json > "$LOCALAPPDATA/Temp/w8-11-new-rev.json"
cd ../../../.. && bash scripts/promotion/validate-revision.sh "$LOCALAPPDATA/Temp/w8-11-new-rev.json" scripts/promotion/flag-ceiling.json dev   # all checks passed; SHELLS allowlist 3/3
gcloud run services update-traffic api $P --to-revisions=$NEW=100 --quiet
# Fallback: gcloud run services update-traffic api $P --to-revisions=$SERVING=100
```
The new revision's startup `feature_flags` log line lists `shells` in allowlist mode.

**Step 5: smoke on dev web** (`https://dzeroth-dev.web.app`, one allowlisted tester and one other account; browser devtools for the widths):
- [ ] 360 dp: the drawer shows Creator tools, Premium, Advertise, Calls after the feature rows and before Settings; the bottom bar has no More.
- [ ] 600 and 1200 dp: the rail's last item is More and opens a menu with the four entries; the account menu is still Profile / Settings / Sign out.
- [ ] Each page opens and Back returns; on Creator tools, More is the selected rail item and the four counts match the profile.
- [ ] Premium opens as a pop-up over the feed with Plus ₹235/month and Premium ₹850/month, incl. GST; Close returns to the feed; browser Back after closing does not reopen it (review M-1).
- [ ] The other account sees no entry, and a typed `/premium` or `/calls` lands on Home.
- [ ] The network panel shows no `/api/` request while on a shell page.

Record the result in `pending.md` 3.17 and set W8-11's status in the plan.

**Rollback:** remove the two lines from `terraform.tfvars` (or set `feature_shells = "off"`), the same targeted plan (expect only the three `FEATURE_SHELLS*` env changes), apply, route as step 4. Instant fallback: route traffic back to `$SERVING`.

## Prod raise (prepared, not applied; founder decision F2, ADR-0026 D5)
Only after **both** `ui_shell` is on in prod (otherwise nobody sees an entry, F6) and the dev smoke above has passed.
1. **Allowlist first:** in your prod `terraform.tfvars`, `feature_shells = "allowlist"` and `feature_shells_allowlist = "<the prod testers' uids>"`. Run the targeted prod plan (the same two `-target`s; expect only the three `FEATURE_SHELLS*` env entries), give your OK, apply. It ships through a `v*` tag, a production-reviewer GO and `promote-prod` (ADR-0019, `docs/runbooks/release.md`).
2. **Then `on`:** `feature_shells = "on"` (the allowlist line can go), by the same path.

Before step 1, recheck the store guidelines quoted in `docs/reviews/security-review-w8.md` for the store builds that will carry the pages.
