---
name: release-rollout
description: Release process for the Cloud Run API (tagged zero-traffic revision + traffic split), Firebase config, Flutter mobile (TestFlight / Play tracks) and Flutter web on Firebase Hosting, including rollback. Use when deploying or releasing.
---

# Release & rollout (no Cloud Deploy, no staging project)

## Backend (Cloud Run)
1. Merge to main → GitHub Actions: `make ci` → `ko build` → push to Artifact Registry (tag = git SHA) → deploy to **dev** (100%).
2. Tag `vX.Y.Z` (push, or `workflow_dispatch` run picking that tag) → `.github/workflows/release-prod.yml` deploys to
   **prod** as a new revision with **no traffic**: `gcloud run deploy api --image=<img>@<digest> --no-traffic --tag=rc
   --region=asia-south1`, smoke tests `/health` on the `rc` URL, and builds mobile release artifacts (Android AAB,
   iOS `--no-codesign`) with prod `--dart-define`s. It never shifts traffic and never deploys Firebase Hosting.
3. `production-reviewer` writes `VERDICT: GO` in `docs/reviews/release-vX.Y.Z-readiness.md`.
4. **Manual promotion — `.github/workflows/promote-prod.yml`, `workflow_dispatch` only, run from the `vX.Y.Z` tag
   ref, input `stage` = `10` or `100`.** The founder runs it once with `stage=10`, watches ~15 min (5xx ratio, p95,
   Error Reporting), then runs it again with `stage=100`. Each run independently re-checks the `VERDICT: GO` file and
   that the revision currently behind the `rc` traffic tag was actually built from *this* tag (checked via that
   image's Artifact Registry tag, since Cloud Run always pins a revision to a resolved digest) before touching
   traffic — `gcloud run services update-traffic api --to-revisions=<rc-revision>=10`, then later `...=100`. Always
   `--to-revisions`, never `--to-latest` (a newer tag could have been staged as a fresh `rc` in the meantime).
   `stage=100` also builds the web bundle fresh from the tag *before* shifting traffic, then runs
   `firebase deploy --only hosting,firestore:rules,firestore:indexes` — Hosting is never deployed before 100%.
5. Rollback: `gcloud run services update-traffic api --to-revisions=<previous>=100` (seconds). Turn feature flags off first if feature-related.

### Manual-approval model on GitHub Free (private repo, single collaborator)
GitHub Free gives private repos Environments with deployment branch/tag policies, but **not** required reviewers,
and no tag protection rulesets (both need GitHub Pro/Team/Enterprise). So at Stage 0:
- The `prod` Environment's deployment policy (tags matching `v*` only) is the one machine-enforced gate on *which
  ref* can run `release-prod.yml` / `promote-prod.yml` with GCP credentials — both declare `environment: prod` on
  every job that authenticates via WIF, and the prod WIF provider's `attribute_condition` additionally pins
  `job_workflow_ref` to those two exact workflow files at a `refs/tags/v*` ref (`infra/terraform/envs/prod/main.tf`,
  `modules/iam`) so a modified copy of either file on another ref can never mint a usable deploy token.
- There is no second human required to click approve — GitHub Free has nothing that provides one. **The founder
  running `promote-prod.yml` (picking a stage and clicking "Run workflow") is itself the approval.** The
  `VERDICT: GO` file check inside the workflow is a recorded, reviewable artifact that the approval was informed by,
  not a second machine-enforced gate.
- Anyone who can push to the repo can create a `v*` tag (nothing restricts that) and dispatch `promote-prod.yml`. With
  one collaborator (the founder) this is an accepted risk, not a gap.
- **Revisit with an ADR before adding a second collaborator**: upgrade to GitHub Pro/Team to add required reviewers
  on the `prod` environment and a tag protection ruleset on `v*` (see the ready-to-run commands kept in
  `docs/runbooks/cloud-bootstrap.md` §6a) rather than trying to approximate either control in workflow logic — both
  need a human distinct from whoever pushed the tag or dispatched the workflow.

## Firestore indexes & rules
`firebase deploy --only firestore:indexes,firestore:rules --project <env>` in CI **before** the code that needs them.
Index builds are free but take minutes; never deploy code that depends on an index that is still building.

## Data changes
Expand → deploy code that handles both → backfill with a throttled job (respect the 20k writes/day free quota or accept cents) → contract later.

## Flutter
- Version `X.Y.Z+build` in `pubspec.yaml`; changelog from conventional commits.
- Every prod build (web, Android, iOS) passes `--dart-define=FIREBASE_ENV=prod` (selects the prod Firebase project's
  options — dev builds use the default/`dev` value) and `--dart-define=GOOGLE_WEB_CLIENT_ID=$PROD_GOOGLE_WEB_CLIENT_ID`.
  Known gap: Android's checked-in `google-services.json` is still dev's, so native SDK init (Google Sign-In,
  Crashlytics) doesn't yet follow `FIREBASE_ENV` — only the Dart-side Firebase options do.
- Android: AAB → Play internal → closed → production staged (10% → 50% → 100%). Play Console one-time fee applies.
- iOS: IPA → TestFlight → phased release (7 days). Apple Developer Program annual fee applies.
- Web: `flutter build web --release` (built inside `promote-prod.yml` at `stage=100`, from the release tag, before
  traffic shifts) → `firebase deploy --only hosting` (Firebase Hosting keeps previous releases; rollback in one click
  / `firebase hosting:clone`).
- Minimum-supported-version check at app start (Firebase Remote Config, free) for forced upgrades.
- CI builds: GitHub Actions (free minutes for public repos; private repos have a monthly allowance — macOS minutes count 10×, so build iOS only on release tags).
