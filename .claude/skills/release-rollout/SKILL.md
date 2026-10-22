---
name: release-rollout
description: Release process for the Cloud Run API (tagged zero-traffic revision + traffic split), Firebase config, Flutter mobile (TestFlight / Play tracks) and Flutter web on Firebase Hosting, including rollback. Use when deploying or releasing.
---

# Release & rollout (no Cloud Deploy, no staging project)

## Backend (Cloud Run)
1. Merge to main → GitHub Actions: `make ci` → `ko build` → push to Artifact Registry (tag = git SHA) → deploy to **dev** (100%).
2. Tag `vX.Y.Z` (the founder pushes it, or runs `workflow_dispatch` picking that tag; the tag ruleset refuses anyone else,
   including the assistant's App) → `.github/workflows/release-prod.yml` waits for the founder's approval (**approval 1 of 3**,
   see "Approval model" below), then deploys to
   **prod** as a new revision with **no traffic**: `gcloud run deploy api --image=<img>@<digest> --no-traffic --tag=candidate
   --region=asia-south1`, smoke tests `/health` on the `candidate` URL, and builds mobile release artifacts (Android AAB,
   iOS `--no-codesign`) with prod `--dart-define`s. It never shifts traffic and never deploys Firebase Hosting.
3. `production-reviewer` writes `VERDICT: GO` in `docs/reviews/release-vX.Y.Z-readiness.md`.
4. **Manual promotion — `.github/workflows/promote-prod.yml`, `workflow_dispatch` only, run from the `vX.Y.Z` tag
   ref, input `stage` = `10` or `100`.** The founder runs it once with `stage=10` (**approval 2 of 3**), watches ~15 min
   (5xx ratio, p95, Error Reporting), then runs it again with `stage=100` (**approval 3 of 3**). Each run independently re-checks the `VERDICT: GO` file and
   that the revision currently behind the `candidate` traffic tag was actually built from *this* tag (checked via that
   image's Artifact Registry tag, since Cloud Run always pins a revision to a resolved digest) before touching
   traffic — `gcloud run services update-traffic api --to-revisions=<rc-revision>=10`, then later `...=100`. Always
   `--to-revisions`, never `--to-latest` (a newer tag could have been staged as a fresh `candidate` in the meantime).
   `stage=100` also builds the web bundle fresh from the tag *before* shifting traffic, then runs
   `firebase deploy --only hosting,firestore:rules,firestore:indexes` — Hosting is never deployed before 100%.
5. Something wrong, or a need to undo a step: see "Rollback" below (kept apart from these forward steps).

### Approval model (ADR-0019: tag ruleset and required reviewer)
The repository is public, so the earlier "no required reviewers, no tag ruleset" model no longer applies. The decision, settings and
rollout log are in `docs/adr/0019-prod-release-gate-required-reviewers-and-tag-ruleset.md`; the trust model is in
`docs/runbooks/cloud-bootstrap.md` §6a. In short:
- `v*` tags are covered by the tag ruleset `protect-version-tags` (Admin role bypass only): the assistant's App cannot create, move or
  delete one. Only the founder cuts a release tag.
- The `prod` environment has the founder as required reviewer, so a release needs **3 approvals**, in this order:
  1. `release-prod` → `build-and-stage` (after the tag push);
  2. `promote-prod` with `stage=10`;
  3. `promote-prod` with `stage=100`.
  A re-run or a re-dispatch needs its own approval. Mobile build jobs are not gated by this, and `dev` is unaffected.
- **What the founder clicks, and when.** After each trigger the run page shows the job as **"Waiting for review"**, with a **Review deployments**
  button (GitHub's exact wording can vary). Open it, tick `prod`, and click **Approve and deploy**.
  Before approving the first one, compare the tag's commit with the commit the readiness review covered
  (`docs/reviews/release-vX.Y.Z-readiness.md`, its P0 diff checks): this is the control against a modified workflow at a tag. Approve
  `stage=10` only when the candidate is smoke-tested, and `stage=100` only after the ~15 minutes of watching.
- The assistant never approves and never needs to: it has no Administration or Actions-write permission, and it cannot dispatch
  `promote-prod.yml`.
- **Tests never use a `v*` tag and never dispatch `promote-prod.yml`.** A `v*` tag push starts `release-prod.yml`, which stages a prod
  candidate, and an approved `promote-prod` run shifts traffic. To test the mechanism use a different tag pattern (ADR-0019 R1 used
  `zz-adr-test-*`), and check the real behaviour only at the next real release.
- The `VERDICT: GO` file check inside `promote-prod.yml` is a recorded artifact that the approval was informed by, not a second
  machine-enforced human gate.

### Rollback (separate from the forward steps; only when something is wrong)
- **Traffic back to the previous revision** (seconds): `gcloud run services update-traffic api --to-revisions=<previous>=100`. Turn
  feature flags off first if the problem is feature-related.
- **The approval gate itself** (the tag ruleset and the required reviewer): ADR-0019 R5 has the owner-only API calls. They remove the
  controls above, so they are for the owner to run deliberately, not part of a release.

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
