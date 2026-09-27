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

**Founder decision, GitHub Free plan (binding):** this repo is private on the GitHub Free plan, which does not offer
environment *required reviewers* or *tag protection rulesets* for private repos (both need GitHub Pro/Team/Enterprise).
There is exactly one collaborator (the founder) at Stage 0, so prod promotion is a **manual `workflow_dispatch`
workflow that the founder runs deliberately** (`promote-prod.yml`) instead of a required-reviewer-gated job —
clicking "Run workflow" and picking a stage **is** the approval. See §6a below and the `release-rollout` skill
("Manual-approval model on GitHub Free") for the full trust model and what to do when a second collaborator joins.

Only two environments are needed — `dev` and `prod`. Do not create `production-traffic-10` / `production-traffic-100`
(they would need required reviewers, which this plan doesn't have — see the cleanup note in §6a if they already exist
from an earlier setup):

```bash
for e in dev prod; do
  gh api -X PUT repos/mohamadkaifshaik/thezerothai/environments/$e
done
```

Restrict the `prod` environment (used by every job in `release-prod.yml` and `promote-prod.yml` that authenticates to
GCP — both declare `environment: prod`) to deployments started from a `v*` tag, so those jobs can't even run from a
branch or an unprotected ref. This deployment branch/tag policy **is** available on GitHub Free for private repos
(unlike required reviewers):

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

### 6a. Free-plan trust model for prod releases (no branch protection, no tag ruleset, no required reviewers)

**Founder decision, confirmed against the live repo 2026-09-27:** both the branch-protection API and the
repository-rulesets API return `403 Upgrade to GitHub Pro or make this repository public` on this repo today —
private repos on GitHub Free simply don't have these features, full stop. Environment *required reviewers* are
likewise a Pro/Team/Enterprise feature. None of that is a config mistake to fix; it's the plan we're on. Prod
promotion is redesigned around what Free **does** give private repos (Environments + deployment branch/tag
policies) plus a manual human step, not an approximation of the paid controls:

1. **The `prod` Environment's deployment branch/tag policy** (tags matching `v*` only, set up in step 6 above) — the
   one machine-enforced gate on *which ref* can even start a job that declares `environment: prod`.
2. **The WIF pin.** The prod WIF provider's `attribute_condition` (see `infra/terraform/envs/prod/main.tf`,
   `modules/iam`) requires `assertion.job_workflow_ref` to start with `release-prod.yml@refs/tags/v` or
   `promote-prod.yml@refs/tags/v`, and `assertion.environment == 'prod'`. This constrains *which workflow file, at
   which ref pattern, declaring which environment* can ever exchange its OIDC token for GCP credentials — it stops a
   different workflow, or the same file copied/modified onto a branch, a PR, or a fork, from minting a usable deploy
   token.
3. **`promote-prod.yml` is `workflow_dispatch`-only and re-validates on every run**: the ref must be a tag matching
   `^v[0-9]+\.[0-9]+\.[0-9]+$`, `docs/reviews/release-<tag>-readiness.md` must contain `VERDICT: GO` for that exact
   tag, and the revision behind the `rc` traffic tag must be provably built from that tag (its Artifact Registry
   image tag) before any `gcloud run services update-traffic` runs.
4. **The founder is the only collaborator.** Running `promote-prod.yml` — choosing a stage and clicking "Run
   workflow" — **is** the approval; there is no other human available to review it, and GitHub Free has no feature
   that would insert one.

**What this does not catch.** The WIF pin matches on file path + ref, not file *contents* — someone who could get a
modified `release-prod.yml`/`promote-prod.yml` onto a commit and then push a `v*` tag pointing at it would still get
a usable token; nothing here re-vets the workflow's contents at the tagged commit the way branch protection + a tag
ruleset would. The only reason that's an acceptable risk at Stage 0 is that there is one collaborator with push
access, so there's no one else's compromised or careless push to defend against yet.

**Revisit via an ADR before adding a second collaborator to this repo.** Upgrade to GitHub Pro or Team, then:
- Add required reviewers on the `prod` environment (Settings → Environments → `prod`) — a human distinct from
  whoever pushed the tag / dispatched the workflow must approve before the job runs.
- Add branch protection on `main` (required PR review + status checks) so `release-prod.yml`/`promote-prod.yml` can
  only change via a reviewed PR.
- Add a **tag protection ruleset** so `v*` tags can only be created/updated by people you trust to cut a release,
  with a **bypass actor** for repository admins (so the owner isn't locked out of cutting a release themselves —
  `actor_type=RepositoryRole` + `actor_id=5` is the built-in "Admin" repository role; `bypass_mode=always` lets that
  role bypass the ruleset in any context, not just pull requests). This call 403s today; keep it for after the
  upgrade:

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

  (Or Settings → Rules → Rulesets → New tag ruleset → target `v*` → restrict who can create/update/delete matching
  tags, with "Repository admin" added as a bypass so admins can still tag releases directly, in the GitHub UI — the
  API call above is equivalent.)

**Cleanup done (2026-09-27):** the `production-traffic-10` and `production-traffic-100` GitHub Environments were
created by accident by a failed required-reviewers call (Free plan). Before deletion they were verified empty: no
protection rules, variables, secrets or deployments. They have been deleted, and only `dev` and `prod` remain. Recreate
one with `gh api -X PUT repos/mohamadkaifshaik/thezerothai/environments/<name>` if a future plan needs it.

## 7. Custom domain (dzeroth.com)
Layout: `dzeroth.com` serves prod web (Hosting site `dzeroth-prod`), `www.dzeroth.com` 301-redirects to it, and
`dev.dzeroth.com` serves dev web (`dzeroth-dev`). The Hosting domains are Terraform-managed (`custom_domains` in
`envs/*/main.tf`, applied 2026-09-27). DNS is at **Squarespace**, which has no API, so the records are added by hand.

### 7a. Hosting records (Squarespace → Domains → dzeroth.com → DNS → Custom records)
| Host | Type | Value | For |
|---|---|---|---|
| `@` | A | `199.36.158.100` | dzeroth.com → Firebase Hosting |
| `@` | TXT | `hosting-site=dzeroth-prod` | ownership proof |
| `www` | CNAME | `dzeroth-prod.web.app` | www redirect |
| `dev` | CNAME | `dzeroth-dev.web.app` | dev web |

Keep the existing `@ TXT v=spf1 -all` until 7c replaces it. Source of truth for these values:
`terraform -chdir=infra/terraform/envs/prod output custom_domain_dns_records` (and `envs/dev`). Check progress with
the `custom_domain_status` output: the target is `HOST_ACTIVE` / `OWNERSHIP_ACTIVE` / `CERT_ACTIVE`, and the managed
TLS certificate can take up to 24 h after DNS resolves. `dzeroth.com` shows Firebase's "Site not found" page until
the first prod release deploys web (`promote-prod.yml`, stage 100).

### 7b. Already done (2026-09-27)
- Upload-bucket CORS includes `https://dzeroth.com` (prod) and `https://dev.dzeroth.com` (dev): tfvars, the
  `.example` files, and the `*_CORS_ORIGINS_JSON` repo variables.
- Firebase Auth authorized domains include `dzeroth.com` and `www.dzeroth.com` (prod) and `dev.dzeroth.com` (dev),
  which Google sign-in and email links need. They were set through the Identity Toolkit admin API, since Terraform
  support would require upgrading to Identity Platform:
  ```bash
  TOKEN=$(gcloud auth print-access-token)
  curl -X PATCH -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: <project>" -H "Content-Type: application/json"     -d '{"authorizedDomains":["localhost","<project>.firebaseapp.com","<project>.web.app","<custom domains>"]}'     "https://identitytoolkit.googleapis.com/admin/v2/projects/<project>/config?updateMask=authorizedDomains"
  ```
  PATCH replaces the whole list, so GET `.../config` first and include every existing domain.

### 7c. Auth emails from your own domain (fixes verification mail landing in spam)
Do this for **prod** (`dzeroth.com`, so mail comes from `noreply@dzeroth.com`). Dev keeps Firebase's default sender:
`dev.dzeroth.com` is a CNAME, and a CNAME name can't also hold the SPF TXT record this needs. Testers can mark the
dev email "Not spam" once.
1. Firebase console (dzeroth-prod) → Authentication → Templates → Email address verification → edit → **Customize
   domain** → `dzeroth.com`. Firebase shows the records to add: a verification TXT, two DKIM CNAMEs
   (`firebase1._domainkey`, `firebase2._domainkey`) and an SPF include.
2. Add them at Squarespace. **SPF:** a name may have only one `v=spf1` record, so *replace* `@ TXT v=spf1 -all`
   with the SPF value Firebase gives (e.g. `v=spf1 include:_spf.firebasemail.com ~all`). Don't add a second one.
3. Add DMARC for deliverability: `_dmarc` TXT `v=DMARC1; p=none`. Tighten it to `p=quarantine` once mail is flowing.
4. Back in Templates: set the sender name (e.g. "dZeroth"), and after the first prod release set **Customize
   action URL** to `https://dzeroth.com/__/auth/action`, so verification links show your domain.

## 8. Verify
```bash
curl -fsS "$(terraform -chdir=infra/terraform/envs/dev output -raw cloud_run_url)/health"
```
This needs one image deployed first, via `deploy-dev.yml` on a push to `main`.
Then check the budget: Console → Billing → Budgets should list a $5 budget with 25/50/90/100% alerts.
