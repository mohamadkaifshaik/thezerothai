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

### 3a. WARNING: every prod apply uses the real tfvars
Always apply prod from `infra/terraform/envs/prod` with the real, gitignored `terraform.tfvars` in that directory.
Never apply with the variable defaults. The defaults in `envs/prod/variables.tf` are `feature_graph = "off"`, an empty
`feature_graph_allowlist` and `feature_graph_percent = 0`, so an apply without the real tfvars **switches the graph off
in prod**.

CI's `plan (prod)` job has no tfvars, so it runs with those defaults. Its plan always shows `FEATURE_GRAPH`
`allowlist -> off` and the allowlist cleared. That is expected and harmless in CI. Never apply it and never "fix" it.

Pre-apply checklist (prod):
1. Confirm you are in `infra/terraform/envs/prod` and that `terraform.tfvars` there is the real one (not missing, not a
   copy of the defaults).
2. Save the plan and review it: `terraform plan -out=tfplan`, then `terraform show tfplan`.
3. Confirm that `FEATURE_GRAPH`, `FEATURE_GRAPH_ALLOWLIST` and `FEATURE_GRAPH_PERCENT` on the `api` service show the
   intended values (no change unless the change is the point of this apply), and that the diff contains only the
   intended change.
4. Show the plan to the founder and get their OK.
5. Apply only that reviewed, saved plan: `terraform apply tfplan`. Never run a bare `terraform apply`.

## 4. Firebase (console, per project)
1. Add Firebase to the project if Terraform's `firebase` module did not already do it.
2. Authentication → Sign-in method: enable **Email/Password**, **Google** and **Apple**. **Never enable Phone** (it is billed per SMS).
3. Run `flutterfire configure --project=dzeroth-dev` from `app/`. This overwrites `lib/firebase_options.dart`. Repeat for prod when you release.
4. Android: `keytool -list -v -keystore %USERPROFILE%\.android\debug.keystore -alias androiddebugkey -storepass android`,
   then add the SHA-1 and SHA-256 to the Android app (`com.dzeroth.dzeroth`). Add the release/Play signing keys later.
5. Web Google sign-in: copy the Web OAuth client ID (Auth → Google provider) and pass it as `--dart-define=GOOGLE_WEB_CLIENT_ID=...`.
6. App Check: **web is deferred at Stage 0** (ADR-0006 amendment: reCAPTCHA Classic is gone, and reCAPTCHA
   Enterprise / Fraud Defense is a flat $8/month past 10k assessments). Don't create reCAPTCHA keys. When the
   Android/iOS store builds exist, register Play Integrity (Android) and App Attest (iOS) in Firebase console →
   App Check, and add the debug-provider tokens for internal test builds.

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
| `*_RECAPTCHA_SITE_KEY` | leave **unset** at Stage 0 (web App Check deferred, ADR-0006 amendment). When revisited: the reCAPTCHA Enterprise (Fraud Defense) *site* key |
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
   tag, and the revision behind the `candidate` traffic tag must be provably built from that tag (its Artifact Registry
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

### 7c. Auth emails from your own domain (done for prod, 2026-09-28)
Prod auth emails come from **"dZeroth" <noreply@dzeroth.com>**. Firebase shows `customDomain: dzeroth.com` and
`useCustomDomain: true`, and the sender display name "dZeroth" is set on the verify, reset and change-email templates.
Dev keeps Firebase's default sender, because `dev.dzeroth.com` is a CNAME and can't also hold an SPF TXT record.

DNS at Squarespace (Host column as typed in Squarespace; never include `dzeroth.com` in Host, or it gets doubled):
| Host | Type | Value |
|---|---|---|
| `@` | TXT | `v=spf1 include:_spf.firebasemail.com ~all` (the **only** SPF record) |
| `@` | TXT | `firebase=dzeroth-prod` |
| `firebase1._domainkey` | CNAME | `mail-dzeroth-com.dkim1._domainkey.firebasemail.com` |
| `firebase2._domainkey` | CNAME | `mail-dzeroth-com.dkim2._domainkey.firebasemail.com` |
| `_dmarc` | TXT | `v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s` (a Squarespace default; keep exactly one) |

Still to do:
- Set the **public-facing name** (Firebase project settings → General) to `dZeroth`, so `%APP_NAME%` in subjects reads well.
- After the first prod release, set **Customize action URL** to `https://dzeroth.com/__/auth/action`.

### 7d. privacy@dzeroth.com (inbound only, $0)
Squarespace's free forwarding is disabled for this domain, and Google Workspace and Zoho are paid, so
**ImprovMX (free: 1 domain, 25 aliases, 500 forwards/day)** forwards `privacy@dzeroth.com` to the founder's Gmail.
DNS: `@` MX `mx1.improvmx.com` (10) and `@` MX `mx2.improvmx.com` (20). No SPF change is needed: ImprovMX's include
only matters for its paid SMTP. Replies go out from the founder's Gmail (visible only to that correspondent, never
published). Gmail filter: `to:privacy@dzeroth.com` → Never send to Spam + label "Privacy requests" (forwarded mail
otherwise lands in spam). Requests are handled per `docs/runbooks/account-deletion.md`.

## 8. Verify
```bash
curl -fsS "$(terraform -chdir=infra/terraform/envs/dev output -raw cloud_run_url)/health"
```
This needs one image deployed first, via `deploy-dev.yml` on a push to `main`.
Then check the budget: Console → Billing → Budgets should list a $5 budget with 25/50/90/100% alerts.

## 9. API key restrictions (security audit M3)

Firebase auto-creates three unrestricted API keys (browser, Android, iOS) the moment you add a web/Android/iOS app
to a project — before Terraform ever runs. `infra/terraform/modules/apikeys` brings the three that already exist in
`dzeroth-dev`/`dzeroth-prod` under management via `import` blocks (`envs/{dev,prod}/import_apikeys.tf`), then
restricts them. There is no `google_apikeys_key` data source and no way to create a *replacement* key without
orphaning every already-shipped app build that has the old one baked in (`google-services.json` /
`GoogleService-Info.plist` / `firebase_options*.dart`) — importing the real one is the only option.

**One-time per project, before the first `apply` that touches `modules/apikeys`:** the Apikeys management API itself
must be enabled (it's in `modules/project-services`' default list now, but a project that already ran its first
apply before this change needs a targeted apply to pick it up — a plain `terraform apply` would otherwise fail the
`import` reads with `SERVICE_DISABLED`, since the API has to be reachable to even read the current state of the
resource being imported):
```bash
terraform apply -target=module.project_services
```

**Finding the UIDs** (needed for `browser_key_uid` / `android_key_uid` / `ios_key_uid` in `terraform.tfvars`):
```bash
gcloud services api-keys list --project=dzeroth-dev --format="table(uid,displayName)"
```

**What's restricted and why** (see `envs/{dev,prod}/main.tf` for the exact lists — kept in sync with what
`app/pubspec.yaml` + `app/lib/app/bootstrap.dart` actually use, re-verify both if either changes):
- **Browser key:** `browser_key_restrictions.allowed_referrers` = this env's real web origins (custom domain +
  `*.web.app` + `*.firebaseapp.com` — Firebase Auth's popup/iframe runs on `firebaseapp.com`, so that origin must
  stay allowed) + `http://localhost:5000/*` and `:8080/*` in dev only, for `flutter run -d chrome`. **A port
  wildcard (`http://localhost:*`) does NOT work** — verified live 2026-09-27: Google's referrer matcher only
  wildcards a trailing path segment, not a port number, so it returns `API_KEY_HTTP_REFERRER_BLOCKED` exactly like
  an origin that isn't listed at all. List every port explicitly.
- **Android/iOS keys:** no app restriction yet. iOS *could* be restricted by bundle ID today (`com.dzeroth.dzeroth`,
  static, known without an Apple Developer account) and is. Android needs a **SHA-1** fingerprint (not the SHA-256
  Firebase asks for elsewhere) from a Play App Signing certificate, which doesn't exist until the app has a Play
  Console listing:
  1. Create the app in Play Console (internal testing track is enough).
  2. Play Console → Setup → App integrity → App signing key certificate → copy the SHA-1.
  3. Add it to `terraform.tfvars`: `android_allowed_applications = [{ package_name = "com.dzeroth.dzeroth", sha1_fingerprint = "..." }]`.
  4. `terraform plan`/`apply` — this only ADDS a restriction (the key currently has none on this axis), so it can't
     break anything already working; it can only reject apps that aren't the real signed one.
- **`api_targets`** on every key: trimmed from Firebase's default (~26 services covering every Firebase product,
  whether or not this app uses it) to what the app's Firebase SDKs actually call — `identitytoolkit.googleapis.com`
  + `securetoken.googleapis.com` (Firebase Auth) + `firebaseinstallations.googleapis.com` (baseline every Firebase
  app needs; harmless, no PII, if unused) on all three, plus `firebaseappcheck.googleapis.com` on Android/iOS only
  (they activate real App Check providers in release builds; web defers App Check per ADR-0006 amendment). Notably
  **not** `firestore.googleapis.com` or `firebasestorage.googleapis.com` — Firestore is server-side only (Go Admin
  SDK) and media uploads are plain GCS via signed URLs, never the Firebase Storage SDK (see section 10 below).

**Verification after applying to an env:**
```bash
# Disallowed referrer -> expect 403 API_KEY_HTTP_REFERRER_BLOCKED
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=<browser key string>" \
  -H 'Content-Type: application/json' -H 'Referer: https://evil.example.com/' -d '{"returnSecureToken":true}'
# Allowed referrer -> expect 400 ADMIN_ONLY_OPERATION (anonymous sign-up is off) or another normal
# identitytoolkit business error, NOT a 403/API_KEY_HTTP_REFERRER_BLOCKED.
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=<browser key string>" \
  -H 'Content-Type: application/json' -H 'Referer: https://dev.dzeroth.com/' -d '{"returnSecureToken":true}'
```
Get the key string once, for testing only, with `gcloud services api-keys get-key-string <key resource name>` — it's
not a secret Firebase asks you to keep hidden (it's shipped in every client build and is safe in public code; real
protection is these restrictions plus Firestore/Storage rules), but avoid leaving it sitting around in shell history
or logs anyway. Then load the real site in a browser and confirm sign-in still renders and works end to end (a
headless Chrome + puppeteer load of the Hosting URL, checking for console/request errors and a screenshot, is enough
to catch a white-screen regression without a full manual pass) — a wrong restriction fails closed for every real
user, not just the curl test above.

## 10. Media bucket protection is IAM + public access prevention, not Storage rules (security audit L5)

`firebase/storage.rules` / `firebase.json`'s `"storage"` key are **never deployed** to `dzeroth-dev` or
`dzeroth-prod`, on purpose — no workflow runs `firebase deploy --only storage` (or `storage:rules`), and none
should. They exist solely so `firebase emulators:start --only ...,storage` (`make emulators` / `make dev` /
`make test-int`) has a rules file to enforce locally; the Storage emulator won't boot at all without that
`firebase.json` key, which is the only reason it's still there.

**Why not just deploy them for real, too?** Deploying Firebase Storage security rules requires the target bucket to
be registered *with Firebase Storage*, and even then those rules only govern requests made through the Firebase
Storage SDK/REST API (`firebasestorage.googleapis.com`). This app's media buckets
(`infra/terraform/modules/media-buckets`, plain `google_storage_bucket` resources) are never registered with
Firebase Storage, and `app/pubspec.yaml` has no `firebase_storage` dependency — every real request is a V4 signed
PUT (uploads, issued by the API) or a public HTTPS GET (`storage.googleapis.com/<project>-media/...`, approved
media), both plain GCS, both invisible to Firebase Storage rules. Registering the buckets just to deploy rules that
can never see the app's actual traffic would be pure theater: a config that *looks* like a security control but
enforces nothing, which is worse than no config at all because it invites the wrong mental model in an incident.

**What actually protects these buckets** (`infra/terraform/modules/media-buckets/main.tf`), enforced by GCS itself,
not an app-layer rules engine:
- `uniform_bucket_level_access = true` on both — no legacy per-object ACLs, IAM only.
- Upload bucket: `public_access_prevention = "enforced"` — fully private, zero public access of any kind. Only the
  runtime service account (`roles/storage.objectAdmin`) and short-lived V4 signed URLs it mints can touch it.
- Media bucket: `public_access_prevention = "inherited"` (deliberately, to allow exactly one public grant) +
  `google_storage_bucket_iam_member` binding `allUsers` → `roles/storage.objectViewer` — public **read**, only.
  Writes still require the runtime service account's `roles/storage.objectAdmin`.
- Both: `force_destroy = false` + `lifecycle { prevent_destroy = true }` on the media bucket.

**Verify live** (ran against dzeroth-dev 2026-09-27; same shape expected on prod). Note `gcloud storage buckets
describe` flattens field names (no `iamConfiguration.` prefix — that's the raw REST API's shape, not this CLI's):
```bash
gcloud storage buckets describe gs://dzeroth-dev-media-upload \
  --format="default(public_access_prevention,uniform_bucket_level_access.enabled)"
# -> public_access_prevention: enforced, uniform_bucket_level_access.enabled: true

gcloud storage buckets describe gs://dzeroth-dev-media \
  --format="default(public_access_prevention,uniform_bucket_level_access.enabled)"
# -> public_access_prevention: inherited, uniform_bucket_level_access.enabled: true (inherited, not enforced,
#    is what lets the allUsers grant below exist at all)

gcloud storage buckets get-iam-policy gs://dzeroth-dev-media
# -> allUsers has roles/storage.objectViewer (public read) and nothing else; api-runtime@... has
#    roles/storage.objectAdmin; the rest are GCP's standard project-editor/owner/viewer legacy bindings
#    (every bucket has these unless explicitly stripped -- not a Terraform-managed grant, not public).

gcloud storage buckets get-iam-policy gs://dzeroth-dev-media-upload
# -> no allUsers / allAuthenticatedUsers binding at all; only api-runtime@... (objectAdmin) plus the same
#    standard project-editor/owner/viewer legacy bindings as above.
```
