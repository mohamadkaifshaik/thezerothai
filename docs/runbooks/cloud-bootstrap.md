# Cloud bootstrap (one-time, human-run)

Everything here needs a human's Google/GitHub credentials, so no agent or CI job runs it. Run it top to bottom, once
per environment where marked. Firestore location is **`asia-south1`** (confirmed by the founder on 2026-09-27; ADR-0007). It cannot be changed later.

Already done in the repo: `infra/terraform/envs/{dev,prod}/terraform.tfvars` (gitignored) are filled in, except for
`billing_account`. The web cache assets (`app/web/sqlite3.wasm`, `drift_worker.js`) are also in place.

## 0. Tools (Windows)
```powershell
winget install Google.CloudSDK
winget install GitHub.cli
npm i -g firebase-tools
dart pub global activate flutterfire_cli
```
Then: `gcloud auth login`, `gcloud auth application-default login`, `gh auth login`, `firebase login`.

## 1. Projects + billing
```bash
gcloud billing accounts list                       # copy the ACCOUNT_ID into both terraform.tfvars
for p in dzeroth-dev dzeroth-prod; do
  gcloud projects create $p                        # skip if they already exist
  gcloud billing projects link $p --billing-account=<ACCOUNT_ID>
done
```
The budget module requires your user to hold **Billing Account Costs Manager** (or Administrator) on the billing
account. Grant it under Console → Billing → Account management.

## 2. Terraform state bucket (once, shared)
```bash
gcloud storage buckets create gs://dzeroth-tfstate --project=dzeroth-prod --location=us-central1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://dzeroth-tfstate --versioning
```
Using `us-central1` keeps the bucket inside the free 5 GB tier.

## 3. First apply (per env: dev first, then prod)
```bash
cd infra/terraform/envs/dev
terraform init -backend-config="bucket=dzeroth-tfstate"
terraform plan -out=tfplan          # review it: no fixed-cost resources, firestore_location = asia-south1
terraform apply tfplan
terraform output                    # needed for step 6
```
This first apply has to be local. The GitHub OIDC login (Workload Identity Federation) that CI uses does not exist until it runs.

## 4. Firebase (console, per project)
1. Add Firebase to the project if Terraform's `firebase` module did not already do it.
2. Authentication → Sign-in method: enable **Email/Password**, **Google** and **Apple**. **Never enable Phone** (it is billed per SMS).
3. Run `flutterfire configure --project=dzeroth-dev` from `app/`. This overwrites `lib/firebase_options.dart`. Repeat for prod when you release.
4. Android: `keytool -list -v -keystore %USERPROFILE%\.android\debug.keystore -alias androiddebugkey -storepass android`,
   then add the SHA-1 and SHA-256 to the Android app (`com.dzeroth.dzeroth`). Add the release/Play signing keys later.
5. Web Google sign-in: copy the Web OAuth client ID (Auth → Google provider) and pass it as `--dart-define=GOOGLE_WEB_CLIENT_ID=...`.
6. App Check:
   - Register a reCAPTCHA v3 key for the web domain.
   - Set `enable_recaptcha_app_check = true` and the secret in tfvars, then re-apply.
   - Pass `--dart-define=RECAPTCHA_SITE_KEY=...` to web builds.
   - In the console, turn on Play Integrity (Android) and App Attest (iOS).

## 5. Apple Sign-In
Needs the Apple Developer Program ($99/yr, which is outside GCP).
1. Enable the "Sign in with Apple" capability for `com.dzeroth.dzeroth` and in Xcode (Runner).
2. Create a Services ID and a Sign in with Apple key.
3. Enter both in Firebase Auth → Apple.

## 6. GitHub (repo `mohamadkaifshaik/thezerothai`)
```bash
for e in dev prod production-traffic-10 production-traffic-100; do
  gh api -X PUT repos/mohamadkaifshaik/thezerothai/environments/$e
done
```
Add yourself as a **required reviewer** on `production-traffic-10` and `production-traffic-100` (Settings → Environments)
— this is the human gate that must pass before any traffic moves.

Also restrict the `prod` environment itself (used by `build-and-stage`, i.e. the image build + `--no-traffic --tag rc`
deploy + smoke test) to deployments started from a `v*` tag, so that job can't even run from a branch or an
unprotected ref:

```bash
gh api -X PUT repos/mohamadkaifshaik/thezerothai/environments/prod \
  -f 'deployment_branch_policy[protected_branches]=false' \
  -f 'deployment_branch_policy[custom_branch_policies]=true'

gh api -X POST repos/mohamadkaifshaik/thezerothai/environments/prod/deployment-branch-policies \
  -f name='v*' -f type='tag'
```

Repo variables come from `terraform output` in each env. Use `DEV_*` and `PROD_*`:

| Variable | Source |
|---|---|
| `*_PROJECT_ID` | `dzeroth-dev` / `dzeroth-prod` |
| `*_REGION` | `asia-south1` |
| `*_SERVICE_NAME` | `api` |
| `*_ARTIFACT_REGISTRY_URL` | `artifact_registry_url` |
| `*_DEPLOY_WORKLOAD_IDENTITY_PROVIDER` | `deploy_workload_identity_provider` |
| `*_CI_DEPLOY_SA_EMAIL` | `ci_deploy_service_account_email` |
| `*_PLAN_WORKLOAD_IDENTITY_PROVIDER` | `plan_workload_identity_provider` |
| `*_PLAN_SA_EMAIL` | `tf_plan_service_account_email` |
| `*_HOSTING_SITE_ID` | `hosting_site_id` from tfvars |
| `*_CORS_ORIGINS_JSON`, `*_FOUNDER_EMAILS_JSON` | the tfvars lists as JSON |
| `*_API_BASE_URL` | `cloud_run_url` (the deterministic `https://api-<project_number>.<region>.run.app` URL) — used by Android/iOS builds, which call Cloud Run directly (no Hosting rewrite). Web builds hardcode `/api` instead. |
| `*_RECAPTCHA_SITE_KEY` | reCAPTCHA v3 site key from step 4.6 (public site key, not the secret) — used as `--dart-define=RECAPTCHA_SITE_KEY=...` on every CI Flutter build |
| `*_GOOGLE_WEB_CLIENT_ID` | Web OAuth client ID from step 4.5 (Firebase Auth → Google provider) — used as `--dart-define=GOOGLE_WEB_CLIENT_ID=...` on every CI Flutter build |
| `TF_STATE_BUCKET` | `dzeroth-tfstate` |
| `BILLING_ACCOUNT` | the billing account ID |

Set each one with `gh variable set NAME --body "value"`.

### 6a. Tag protection for `v*` (prod releases)

**What the WIF pin actually does — and doesn't do (M6c).** The prod WIF
provider's `attribute_condition` pins `assertion.job_workflow_ref` to
`.github/workflows/release-prod.yml@refs/tags/v*` and `assertion.environment`
to the GitHub Environments the release workflow uses (`prod`,
`production-traffic-10`, `production-traffic-100`) — see `modules/iam`. This
only constrains *which workflow file, at which ref pattern, running with which
declared environment* is allowed to exchange its OIDC token for GCP
credentials at all. It stops:
- a different workflow (or the same file copied/modified on a branch, a PR,
  or a fork) from ever minting a usable deploy token, and
- a job in `release-prod.yml` that doesn't declare one of the three protected
  environments from minting one.

It does **not** vet the *contents* of `release-prod.yml` at the tagged commit.
`job_workflow_ref` matches on file path + ref, not on file contents — so
whoever can get a modified `release-prod.yml` onto a commit and then attach a
`v*` tag to it still gets a usable token; the WIF pin alone would not catch
that. The controls that actually catch it are:
1. **Branch protection on `main`** (required PR review + status checks) —
   `release-prod.yml` can only change via a reviewed PR, so a malicious edit
   has to pass code review before it can reach any commit.
2. **The tag protection ruleset below** — only trusted people can create/move
   a `v*` tag, so even a compromised or careless push can't tag an unreviewed
   commit into existence as a release.
3. **Required reviewers on `production-traffic-10` / `production-traffic-100`**
   (previous step) — a human must approve before any traffic actually shifts,
   regardless of what the build job did.
4. **The `production-reviewer` `VERDICT: GO` file check** in `promote-10` —
   an independent, reviewable artifact gating the first traffic shift.

None of these is sufficient alone; together they mean a token being mintable
is necessary but never sufficient to ship a change to prod traffic.

Add a **tag protection ruleset** so `v*` tags can only be created/updated by
people you trust to cut a release, with a **bypass actor** for repository
admins (so the owner isn't locked out of cutting a release themselves —
`actor_type=RepositoryRole` + `actor_id=5` is the built-in "Admin" repository
role; `bypass_mode=always` lets that role bypass the ruleset in any context,
not just pull requests):

```bash
gh api -X POST repos/mohamadkaifshaik/thezerothai/rulesets \
  -f name='protect-version-tags' \
  -f target='tag' \
  -f enforcement='active' \
  -f 'conditions[ref_name][include][]=refs/tags/v*' \
  -f 'rules[][type]=creation' \
  -f 'rules[][type]=update' \
  -f 'rules[][type]=deletion' \
  -f 'bypass_actors[][actor_id]=5' \
  -f 'bypass_actors[][actor_type]=RepositoryRole' \
  -f 'bypass_actors[][bypass_mode]=always'
```

(Or Settings → Rules → Rulesets → New tag ruleset → target `v*` → restrict who
can create/update/delete matching tags, with "Repository admin" added as a
bypass so admins can still tag releases directly, in the GitHub UI — the API
call above is equivalent.)

## 7. Custom domain
Firebase console → Hosting → Add custom domain, then add the TXT/A records at your DNS provider. After that, add
`https://<domain>` to `cors_origins` in the prod tfvars and re-apply.

## 8. Verify
```bash
curl -fsS "$(terraform -chdir=infra/terraform/envs/dev output -raw cloud_run_url)/healthz"
```
This needs one image deployed first, via `deploy-dev.yml` on a push to `main`.
Then check the budget: Console → Billing → Budgets should list a $5 budget with 25/50/90/100% alerts.
