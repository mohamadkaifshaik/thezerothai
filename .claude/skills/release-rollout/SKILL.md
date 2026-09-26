---
name: release-rollout
description: Release process for the Cloud Run API (tagged zero-traffic revision + traffic split), Firebase config, Flutter mobile (TestFlight / Play tracks) and Flutter web on Firebase Hosting, including rollback. Use when deploying or releasing.
---

# Release & rollout (no Cloud Deploy, no staging project)

## Backend (Cloud Run)
1. Merge to main → GitHub Actions: `make ci` → `ko build` → push to Artifact Registry (tag = git SHA) → deploy to **dev** (100%).
2. Tag `vX.Y.Z` → deploy to **prod** as a new revision with **no traffic**:
   `gcloud run deploy api --image=<img>@<digest> --no-traffic --tag=rc --region=asia-south1`
3. Smoke test the tagged URL `https://rc---api-<hash>.a.run.app` (e2e smoke with test accounts, < 100 requests).
4. `production-reviewer` writes `VERDICT: GO` in `docs/reviews/release-vX.Y.Z-readiness.md`.
5. Shift traffic: `gcloud run services update-traffic api --to-tags=rc=10` → watch 15 min (5xx ratio, p95, Error Reporting)
   → `--to-latest` (100%). Traffic splitting is free.
6. Rollback: `gcloud run services update-traffic api --to-revisions=<previous>=100` (seconds). Turn feature flags off first if feature-related.

## Firestore indexes & rules
`firebase deploy --only firestore:indexes,firestore:rules --project <env>` in CI **before** the code that needs them.
Index builds are free but take minutes; never deploy code that depends on an index that is still building.

## Data changes
Expand → deploy code that handles both → backfill with a throttled job (respect the 20k writes/day free quota or accept cents) → contract later.

## Flutter
- Version `X.Y.Z+build` in `pubspec.yaml`; changelog from conventional commits.
- Android: AAB → Play internal → closed → production staged (10% → 50% → 100%). Play Console one-time fee applies.
- iOS: IPA → TestFlight → phased release (7 days). Apple Developer Program annual fee applies.
- Web: `flutter build web --release` → `firebase deploy --only hosting` (Firebase Hosting keeps previous releases; rollback in one click / `firebase hosting:clone`).
- Minimum-supported-version check at app start (Firebase Remote Config, free) for forced upgrades.
- CI builds: GitHub Actions (free minutes for public repos; private repos have a monthly allowance — macOS minutes count 10×, so build iOS only on release tags).
