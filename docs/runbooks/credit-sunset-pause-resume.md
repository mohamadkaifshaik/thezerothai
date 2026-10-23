# Runbook: credit sunset - pause the whole system, resume later, or fall back to the free tier

Audience: the founder, on Windows, under stress. Use **Git Bash** for every command here (PowerShell quoting differs).
Related: `docs/runbooks/cost-spike.md`, `docs/runbooks/abuse-spike.md`, `docs/runbooks/rollback.md`,
`docs/runbooks/cloud-bootstrap.md`, `docs/runbooks/authenticated-smoke.md`. Credit-mode knobs: see ADR-0022.

Context: the promotional credit pool (INR 23,000 spend cap) expires **2026-12-26**. Plan: **pause on 2026-12-24**.
After expiry, charges may hit a payment method, so everything that can bill must be stopped BEFORE expiry.

> **UNVERIFIED, read this first.** If the billing account is a Free-Trial-type account and is not funded after the
> credit ends, Google may **stop or delete resources** (and possibly the projects) after some grace period. I could not
> verify the terms for this account. Therefore **the data export (section 3, step A) is mandatory and the copy must
> end up OUTSIDE Google Cloud**. A backup that lives in the same project dies with the project.

## Shared shell setup (every command below assumes it)

```bash
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"   # same as cost-spike.md
ENV=prod                                  # or dev
PROJ=dzeroth-$ENV                         # dzeroth-prod | dzeroth-dev
R=asia-south1
P="--project=$PROJ --region=$R"           # service name is "api" in both envs (locals.service_name)
URL=$("$G" run services describe api $P --format="value(status.url)")
echo "$URL"
```

---

## 1. TL;DR - three levers, mildest first

| Lever | When | One-line command (prod; swap project for dev) | Reverse |
|---|---|---|---|
| **L1 Degraded mode** | Cost spike, still want users reading | `"$G" run services update api $P --update-env-vars DEGRADED_MODE=readonly --quiet` then **shift traffic to the new revision** (prod pins traffic; see `cost-spike.md` "Flip degraded mode"). `nomedia` = only stop uploads. | `DEGRADED_MODE=off`, same traffic shift |
| **L2 PAUSE** (primary) | Credit expiring, runaway abuse, "stop it NOW" | `"$G" run services remove-iam-policy-binding api $P --member=allUsers --role=roles/run.invoker` | `add-iam-policy-binding` with the same args |
| **L3 Shutdown** (last resort) | Everything else failed and money is leaving | `"$G" billing projects unlink dzeroth-prod` | Re-link billing; **deleted/stopped resources may not come back** |

L2 also needs: the deploy workflows disabled, and the `publish-scheduled` Scheduler job paused if it exists. **Do NOT pause `daily-maintenance`**: ADR-0022 keeps it running while paused (1 request a day, free) because it is the account-deletion backstop, a privacy obligation, and the pubsub-push service account keeps `run.invoker` so it still reaches the service. Full checklist in section 3.
**Do the export (section 3A) BEFORE L2 on the planned pause. In an emergency, do L2 first, export after.**

L3 destroys or strands: Cloud Run service, Firestore data access, GCS media, Pub/Sub, Scheduler. It affects BOTH
projects if they share the billing account (`dzeroth-dev` and `dzeroth-prod`). Human decision only, same rule as
`cost-spike.md` "Last resort".

---

## 2. Option analysis for PAUSE

Costs are **estimates in INR/month, approximate** (USD 1 about INR 85-90). Check real numbers on the GCP pricing pages
and in Billing > Reports. "Free" means inside the Stage 0 free-tier allowance (`free-tier-budget` skill).

| # | Method | Level | Stops serving? | Cost while paused (est.) | Reversible | Verdict / risk |
|---|---|---|---|---|---|---|
| 1 | **Remove `allUsers` invoker** (`google_cloud_run_v2_service_iam_member.public_invoker` in `modules/cloud-run-api`) | Service IAM, instant, no new revision | Yes: public callers get 403. Hosting `/api/**` rewrite also gets 403. | Cloud Run 0 | Instant, one command, no data change, no revision change | **PRIMARY.** Does NOT block Pub/Sub push and Scheduler, because the `pubsub_push_invoker` binding stays (so pause the scheduler job too). A later `terraform apply` re-adds the binding (un-pauses silently), see warning below. |
| 2 | `--ingress=internal` (module hardcodes `INGRESS_TRAFFIC_ALL`) | Service setting | Yes: public callers get 404 | 0 | One command back (`--ingress=all`) | **FALLBACK.** Unverified: whether Pub/Sub push and Scheduler (Google-internal callers) are still allowed in; test after. Terraform apply resets it to `all`. |
| 3 | `--max-instances=0` / scale to 0 | Revision template | **Do not use.** Creates a new 0%-traffic revision (the prod traffic-pin trap in `cost-spike.md`); `0` is rejected or means "no limit" depending on version. Min is already 0, so there is nothing to scale down. | n/a | n/a | Rejected. |
| 4 | **Delete the Cloud Run service** | Service | Yes | 0 | **NOT identical.** Terraform recreates it from `var.image` in tfvars (a placeholder or stale image, since `image` is in `ignore_changes`), losing revision history, the `candidate` / last-good tags, and any env vars set with gcloud. URL `api-<project number>.asia-south1.run.app` stays the same. | Not recommended. Only if the service itself is compromised. |
| 5 | Pause Cloud Scheduler job | Scheduler | Stops cron only. Pause `publish-scheduled` if it exists (ADR-0021; not in `envs/prod/main.tf` yet). **Keep `daily-maintenance` running** (ADR-0022: account-deletion backstop). Dev: no jobs, `jobs = {}` | 0 (free tier: 3 jobs per billing account; paused still counts) | `resume` | **Required companion** to method 1 or 2, not a pause by itself. |
| 6 | Disable GitHub deploy workflows | GitHub | Prevents a push/tag from re-deploying | 0 | `gh workflow enable` | **Required companion** (below). |
| 7 | Firebase Hosting disable (`firebase hosting:disable`) | Hosting | Static web shell gone ("Site Not Found") | Hosting is free here, so saves ~0 | Needs a rebuilt web bundle and redeploy | Optional cosmetic. With method 1 the web shell still loads but every API call fails. A maintenance page is a follow-up. |
| 8 | App Check / FCM / Firebase Auth | n/a | n/a | 0 (no-cost tiers) | n/a | Leave alone. Nothing to pause. |

### What still costs money while paused (all small, none needs the service running)

| Item | Why it keeps costing | Est. INR/month |
|---|---|---|
| Firestore storage | Inside 1 GiB free if DB is small; over that about USD 0.18/GiB-month (asia-south1: check) | 0 to a few INR |
| Firestore weekly backups (`google_firestore_backup_schedule.weekly`, prod, 14-day retention) | Backup storage is billed | A few INR; can be switched off by `weekly_backup_enabled = false` (variable exists in `modules/firestore`, set in `envs/prod/main.tf`) |
| GCS `dzeroth-prod-media`, `dzeroth-prod-media-upload` (us-central1) | Free up to 5 GB-months, then ~USD 0.02/GB | 0 to ~2 INR per GB over |
| Artifact Registry (asia-south1, keep last 3 images) | Free up to 0.5 GB, then per GB | 0 to a few INR |
| Secret Manager | Free up to 6 active versions | 0 |
| Cloud Monitoring uptime check + alert policies | Uptime check is free; ADR-0011 log metric + alert: Cloud Monitoring alerting is not charged before 2027-09-01 per ADR-0022's reading of the pricing page (UNVERIFIED for your account) | ~0 (prod). Alerts WILL fire while paused, see warning. |
| Pub/Sub topics/subscriptions | Idle, no messages | 0 |
| Domain `dzeroth.com` | Paid at the registrar, outside GCP | per registrar |
| Cloud Run / Scheduler / Hosting | Free or zero when idle | 0 |

**Expected total while paused: roughly INR 0-100/month (estimate, UNVERIFIED).** ADR-0022 puts the paused state at INR 0-15 per month (before GST) plus a one-off export of INR 3-180; the largest items are Firestore storage and weekly backups.

### Recommendation

- **Primary:** method 1 (remove `allUsers`) + pause `publish-scheduled` if it exists (never `daily-maintenance`) + disable deploy workflows. It is service-level, instant,
  leaves revisions, tags, env vars, data, URL and IAM for everything else untouched, and is one command to undo.
- **Fallback:** method 2 (`--ingress=internal`) if the IAM command fails or you want a second layer. Never delete the service.

Warnings that apply to both:
1. **`terraform apply` silently un-pauses.** The module declares the `allUsers` binding and `INGRESS_TRAFFIC_ALL`; any
   apply from `envs/prod` re-adds them. Do not apply while paused. (`terraform.yml` only plans, it never applies, so CI
   cannot undo the pause; a human apply can.) The same apply would also reset `DEGRADED_MODE` to the hardcoded `"off"`.
2. **Alert noise.** The prod uptime check on `/health` fails when paused and the `uptime_failing` alert will email
   `founder_emails`. Expect it; do not read it as a new incident.
3. **Messages queue up?** Pub/Sub push is not blocked by method 1, but with no traffic nothing publishes. Push
   subscriptions retry and dead-letter after 5 attempts (`modules/pubsub`), so a stray message is not a cost risk.

### Terraform way (PROPOSED, DOES NOT EXIST YET - follow-up ticket F1)

Proposed variable, in `envs/<env>/variables.tf` + passed to `modules/cloud-run-api`:

```hcl
# DOES NOT EXIST YET. Proposed only.
variable "service_paused" { type = bool, default = false }
# module: public_invoker gets   count = var.service_paused ? 0 : 1
#         scheduler jobs get    paused = var.service_paused   (provider support unverified)
```
Founder would set `service_paused = true` in the real `terraform.tfvars`, then follow the prod apply checklist in
`cloud-bootstrap.md` section 3a (plan, review, founder OK, `apply tfplan`). Until that ticket ships, **use the gcloud commands below**
(they work without Terraform). After a gcloud pause, `terraform plan` will show the binding as a diff to re-add:
that is expected and you must not apply it until you want to resume.

---

## 3. PAUSE checklist (target day 2026-12-24). Do dev first, then prod.

### A. MANDATORY pre-pause export (prod; dev only if it holds data you care about)
Cost estimate: Firestore export bills **1 read per document** (the free quota is 50k reads/day; spread over days if
larger) plus a little storage; GCS download from `us-central1` to your PC is likely inside the free 100 GB North-America
egress, but asia-south1 egress is NOT free-tier eligible (about USD 0.12/GB). Expect INR 0-100 for a small DB (estimate).

- [ ] **A1. Final Firestore export** to a temporary bucket in the same project. (Export-bucket location compatibility with an
  `asia-south1` database is UNVERIFIED; if it errors, create the bucket in the location the error message names.)
  ```bash
  STAMP=$(date +%Y%m%d)
  "$G" storage buckets create gs://$PROJ-pause-export --project=$PROJ --location=$R
  "$G" firestore export gs://$PROJ-pause-export/firestore-$STAMP --project=$PROJ
  ```
  Expected: `Waiting for [projects/.../operations/...] to finish...done.` and an `outputUriPrefix`.
- [ ] **A2. Copy the export OFF Google Cloud** to your PC (and a second disk or cloud storage you own).
  ```bash
  mkdir -p ~/dzeroth-backup-$STAMP && "$G" storage cp -r gs://$PROJ-pause-export/firestore-$STAMP ~/dzeroth-backup-$STAMP/
  ```
- [ ] **A3. Copy media** (prod buckets `dzeroth-prod-media` and `dzeroth-prod-media-upload`; dev is `dzeroth-dev-...`):
  ```bash
  "$G" storage cp -r gs://$PROJ-media ~/dzeroth-backup-$STAMP/media
  ```
- [ ] **A4. Export Firebase Auth users** (Firestore exports do NOT include Auth accounts). The file contains password
  hashes and PII: keep it encrypted (e.g. a password-protected archive), never in the repo or in chat.
  ```bash
  firebase auth:export ~/dzeroth-backup-$STAMP/auth-users.json --format=json --project $PROJ
  ```
- [ ] **A5. Verify the copies**: folder sizes non-zero, the export has `*.overall_export_metadata`, user count matches Firebase console > Authentication.
- [ ] **A6. Save the Terraform inputs**: your real, gitignored `infra/terraform/envs/prod/terraform.tfvars` (and dev) into the same encrypted backup. They are not in git.

### B. Record the rollback point
- [ ] **B1.** Write down the serving revision and tags (needed at resume and by `rollback.md`):
  ```bash
  "$G" run services describe api $P --format=json | python -c "import json,sys; d=json.load(sys.stdin); print([(t.get('revisionName'),t.get('percent'),t.get('tag')) for t in d['status']['traffic']]); print(d['spec']['template']['spec']['containers'][0]['image'])"
  "$G" run services get-iam-policy api $P
  ```
  Expect `allUsers` under `roles/run.invoker` (and the push service account). Paste the output into your private notes.
- [ ] **B2.** Optional: tell users (post/status page) before pausing.

### C. Stop deploys (so nothing re-creates revisions or un-pauses)
`deploy-dev.yml` runs on every push to `main` (it skips docs-only pushes) and even a "dry run" builds, pushes to Artifact
Registry and creates a 0% revision, whose smoke would then fail. `DEV_PROMOTE` alone is not enough. Run as the founder
(the assistant's App has no Actions-write permission):
- [ ] **C1.**
  ```bash
  for w in deploy-dev.yml release-prod.yml promote-prod.yml; do gh workflow disable $w --repo <owner>/thezerothai; done
  gh workflow list --repo <owner>/thezerothai --all     # the three show "disabled_manually"
  ```
  (`terraform.yml` is plan-only and `ci.yml` only builds/tests; leave them. `release-prod` triggers on `v*` tag pushes: also simply **do not push tags**.)
- [ ] **C2.** Belt and braces: set repo variable `DEV_PROMOTE` to `false` (GitHub > Settings > Secrets and variables > Actions > Variables).

### D. Pause the scheduler job(s) that are safe to pause (prod only has `daily-maintenance`, which stays RUNNING)
- [ ] **D1.**
  ```bash
  # Today prod has only `daily-maintenance`. Leave it ENABLED (ADR-0022: account-deletion backstop; 1 request a day, free).
  # If `publish-scheduled` exists (ADR-0021), pause it:
  "$G" scheduler jobs pause publish-scheduled --project=dzeroth-prod --location=asia-south1
  "$G" scheduler jobs list --project=dzeroth-prod --location=asia-south1     # publish-scheduled PAUSED, daily-maintenance ENABLED
  ```
  Dev: `jobs = {}`, so `list` shows nothing; that is correct. (If a job was ever added there, pause it the same way.)

### E. Stop serving (L2) - dev, then prod
- [ ] **E1.** Remove the public invoker. Run once with `ENV=dev`, then again with `ENV=prod` (re-run the setup block).
  ```bash
  "$G" run services remove-iam-policy-binding api $P --member=allUsers --role=roles/run.invoker
  ```
  Expected: `Updated IAM policy for service [api].` and the policy no longer lists `allUsers`.
- [ ] **E2. Fallback only if E1 failed or you want a second layer:**
  ```bash
  "$G" run services update api $P --ingress=internal
  ```
  Check afterwards that no new revision took traffic: re-run B1.

### F. Reduce standing cost (optional, after export is safe)
- [ ] **F1.** Prod weekly backups: leave on until you have verified the export, then optionally `weekly_backup_enabled = false` via Terraform later (do not edit by gcloud; saves only a few INR).
- [ ] **F2.** Delete the temp export bucket only when the local copy is verified (**destructive, confirm first**): `"$G" storage rm -r gs://$PROJ-pause-export`. Or keep it (pennies) as a second copy while you still have credit.
- [ ] **F3.** Silence or ignore the expected `uptime_failing` emails.

### G. VERIFY it is paused
| Check | Command / place | Expected |
|---|---|---|
| Public API blocked | `curl -s -o /dev/null -w "%{http_code}\n" "$URL/health"` | **403** (method 1) or **404** (ingress internal) |
| Hosting API rewrite | open the web app, any action | errors; static shell may still load |
| IAM | `"$G" run services get-iam-policy api $P` | no `allUsers` |
| Scheduler | `"$G" scheduler jobs list --project=dzeroth-prod --location=$R` | `publish-scheduled` PAUSED if it exists; `daily-maintenance` stays ENABLED |
| Workflows | `gh workflow list --all` | three disabled |
| Cloud Run metrics | Console > Cloud Run > api > Metrics | request count flat at 0 after ~5 min, instance count 0 |
| **Spend stopped** | Console > Billing > Reports, group by SKU, filter project; **untick "Credits"** so you see gross cost | no Cloud Run / Firestore-ops SKUs rising next day; only small storage SKUs |

---

## 4. RESUME checklist (funded) - reverse order

Time: about 30-60 minutes including smoke (IAM change propagates in about 1-2 minutes; web redeploy only if you disabled Hosting).

- [ ] **R0. Fund the billing account first** (Billing > payment method / upgrade from trial; budget alerts in place). Check projects are still linked: `"$G" billing projects describe dzeroth-prod`. Look for `billingEnabled: true`.
- [ ] **R1. Check the data survived**
  - Firestore: Console > Firestore, or `"$G" firestore databases list --project=$PROJ`; spot-check `users`, `posts`. If gone, restore from your local export: copy it back to a bucket and `"$G" firestore import gs://.../firestore-<STAMP> --project=$PROJ`.
  - Media: `"$G" storage ls gs://$PROJ-media | head`. If gone, `"$G" storage cp -r ~/dzeroth-backup-<STAMP>/media/* gs://$PROJ-media/`.
  - Cloud Run: `"$G" run services describe api $P` shows the B1 revision; if the project/service was removed, rebuild via `cloud-bootstrap.md` (Terraform from your saved tfvars) and a fresh `release-prod` + `promote-prod` run.
  - Auth: `firebase auth:import` from the export if users are missing (`--hash-algo` flags per the export; PII, handle carefully).
- [ ] **R2. Keep risky flags OFF.** Before opening the door, confirm `FEATURE_*` and `DEGRADED_MODE` on the service: `"$G" run services describe api $P --format="value(spec.template.spec.containers[0].env)"`. Features stay at their pre-pause values, in particular nothing new turned on; consider resuming with `DEGRADED_MODE=readonly` for the first hour (cost-spike.md procedure), then `off`.
- [ ] **R3. Re-enable deploy workflows** only after R5 passes: `gh workflow enable deploy-dev.yml ...` (all three), and restore `DEV_PROMOTE` to its previous value.
- [ ] **R4. Resume scheduler:** `"$G" scheduler jobs resume publish-scheduled --project=dzeroth-prod --location=asia-south1` (only if you paused it; `daily-maintenance` was never paused).
- [ ] **R5. Reopen the service (dev first, then prod):**
  ```bash
  "$G" run services add-iam-policy-binding api $P --member=allUsers --role=roles/run.invoker
  # if you used the fallback: "$G" run services update api $P --ingress=all
  curl -s -o /dev/null -w "%{http_code}\n" "$URL/health"     # expect 200
  ```
  If Terraform was used: confirm `plan` shows no unexpected diff (the allUsers binding present), real tfvars in place, per `cloud-bootstrap.md` section 3a.
- [ ] **R6. Smoke test:** run the authenticated smoke from your own terminal per `docs/runbooks/authenticated-smoke.md` ("Usage (prod)"); dev's runs in the `deploy-dev` workflow.
- [ ] **R7. Optional web:** if Hosting was disabled, redeploy (`promote-prod` at `stage=100` rebuilds web from a tag and runs `firebase deploy --only hosting,...`).
- [ ] **R8. First 24 hours - watch:** Billing > Reports by SKU (credits unticked) at +1h, +6h, +24h; Cloud Run 5xx and instance count (max 3); Firestore Usage tab (50k reads / 20k writes per day); budget emails; Logs Explorer `severity>=ERROR`. If any number surprises you, go to `cost-spike.md`.

### Revert to the free tier (instead of paying)
Goal: the Stage 0 profile. **It is not INR 0**: ADR-0022 puts Stage 0 as configured at about INR 434 / 1,626 / 3,396 a month at 300 / 1,000 / 3,000 daily users (before GST), because egress to India is always billed and reads pass the free quota at about 215 daily users; a stricter variant (Vision cap 1,000 plus reject) is about INR 56 / 343 / 2,114. Pausing is the only INR 0-15 state. Credit-mode knobs (min instances, caps) are named in **see ADR-0022**; this is the checklist.
- [ ] Confirm the live service has `min_instance_count = 0` (the module hardcodes 0; if a credit-mode change raised it, revert it through the module and a reviewed prod apply). Check: `"$G" run services describe api $P --format="value(spec.template.scaling)"`.
- [ ] Restore caps to Stage 0: max instances 3 prod / 1 dev, concurrency 80, 512 MiB, per ADR-0022's list; keep them as code, with the cost note in the PR.
- [ ] Back to free-tier-only features: Vision cap (`VISION_MONTHLY_CAP`), media on/off per `free-tier-budget`.
- [ ] Consider `weekly_backup_enabled`, the ADR-0011 alert and the budget amount (INR 500) as before.
- [ ] The free tier still needs a billing account in good standing (a funded or card-backed account). Daily Firestore free quotas then apply as in `free-tier-budget`.
- [ ] Re-run the resume checklist from R1.

---

## 5. Pre-expiry calendar

| Date | Task |
|---|---|
| **2026-10-23 (today)** | Read this runbook. Open Billing > Credits and write down: credits remaining, exact expiry date/time and time zone, account type (trial or paid), payment method attached or not. |
| By **2026-11-15** | **Rehearse on dev** (sections 3C-3G and 4 R5-R6, dev only). Fix any command that does not work here and update this file. |
| Monthly (11-23, 12-07) | Billing check below; compare burn rate with the credit left. |
| **2026-12-14 (T-10)** | Billing checklist. Decide: pause, fund, or free tier. Create `dzeroth-prod-pause-export` bucket; take a trial export + download. Announce the planned pause to users. |
| **2026-12-20 (T-4)** | Rehearsal of prod export. Confirm `gh` login, `firebase` login, `gcloud auth list` all work. Confirm who is reachable on the day. |
| **2026-12-22 (T-2)** | Freeze: no merges, no tags. Last release must be settled. |
| **2026-12-24 (pause day)** | Section 3 end to end, dev then prod. Take a screenshot of the Reports page. |
| **2026-12-26 (expiry)** | Check Billing > Reports (credits unticked), no growing Cloud Run/Firestore ops SKUs; confirm 403 on `/health`. |
| **2026-12-27 (T+1)** | Verify: no charge, resources still exist (`run services list`, `firestore databases list`, `storage ls`), payment method behaviour, alert emails. |

### Billing console checklist (Console > Billing)
- [ ] **Credits**: remaining amount, expiry date, which projects/products it covers, free-trial vs paid account banner.
- [ ] **Payment method**: attached or not. Not attached = charges cannot be collected, but resource-stop risk applies (see UNVERIFIED note). Attached = real money may be charged after expiry.
- [ ] **Budgets & alerts**: the INR 500 budgets in `modules/budget` (thresholds 25/50/90/100% + forecast). **Warning, UNVERIFIED:** the module does not set `credit_types_treatment`; if the default is "include all credits" the alerts measure spend AFTER credits (about 0) and will not fire while credits cover the bill. Do not rely on them during the credit period.
- [ ] **Reports**: group by SKU, filter by project; compare with and without "Credits" ticked to see gross spend.
- [ ] **Billing account link**: both `dzeroth-dev` and `dzeroth-prod` linked to the same account (they share the Cloud Run and Scheduler free tiers).

---

## 6. Emergency scenarios

Always set the shell block at the top first. The first command is the fastest safe action.

| Scenario | First command | Who/what to check next |
|---|---|---|
| **Cost spike** (budget email, reads near 50k/day) | L1: `"$G" run services update api $P --update-env-vars DEGRADED_MODE=readonly --quiet` then shift traffic (`cost-spike.md`) | Dashboard "Free-tier budget"; cause in Logs; `cost-spike.md` |
| **Credit nearly spent early** (Credits remaining dropping faster than the calendar) | L1 readonly now; then compare Reports by SKU (credits unticked) | Decide: fund, free-tier profile, or run section 3 early. Move the export up. |
| **Abuse flood** (sign-ups, scraping, instances pinned at 3) | `abuse-spike.md` section 2 sign-up kill switch; if it continues, **L2** (remove `allUsers`) | `abuse-spike.md`; disable accounts; billing reports |
| **Accidental high bill** (unexpected SKU) | L2 on the project with the cost, then find the SKU in Reports (group by SKU and by resource) | Check for forgotten resources (next row); only if money still flows after L2, consider **L3** with explicit founder decision |
| **Forgotten service** (dev project or a leftover bucket/job keeps costing) | `"$G" run services list --project=dzeroth-dev`, `"$G" scheduler jobs list --project=dzeroth-prod --location=asia-south1`, `"$G" storage ls --project=$PROJ`, `"$G" pubsub topics list --project=$PROJ` | Reports by SKU; delete only after confirming; recall the 3-job scheduler limit across both projects |

---

## 7. What I could not verify

- Account type and credit terms: Free-Trial vs promotional vs paid, behaviour after expiry (resources stopped/deleted? grace period?), exact expiry time and zone. **No gcloud/Console access was available.**
- Live GCP state: actual IAM policy, serving revision, Scheduler job state, bucket contents/sizes, whether a payment method is attached.
- Whether `--ingress=internal` still lets Pub/Sub push and Scheduler reach `/internal/*`; whether a `services update --ingress` creates a revision.
- The budget `credit_types_treatment` default (affects whether INR 500 alerts fire during the credit period).
- Export bucket location rules for an `asia-south1` Firestore database; exact export, egress and backup costs (all INR figures are estimates).
- That the scheduler provider supports a `paused` attribute for the proposed Terraform variable.
- The GitHub `<owner>/thezerothai` repo slug (placeholder in `terraform.tfvars.example`).

## 8. Follow-up tickets this runbook assumes

| # | Ticket |
|---|---|
| F1 | Terraform `service_paused` variable (public invoker `count`, scheduler `paused`, optional alert disable) in `modules/cloud-run-api` / `modules/scheduler` and both envs. **Does not exist yet.** |
| F2 | A tested helper script `scripts/pause.sh` / `resume.sh` wrapping sections 3 and 4 (dry-run flag, prints before/after). |
| F3 | Budget-triggered automatic pause (Cloud Function on `billing-alerts` calling L1, never L3). |
| F4 | Gross-spend budget (credits excluded) so alerts work during the credit period. |
| F5 | Maintenance page on Hosting for the paused state, and an option to mute the uptime alert while paused. |
| F6 | Dev rehearsal of this runbook, with results written back here. |
