# Runbook: rollback

Every deploy is reversible (CLAUDE.md rule). The previous Cloud Run revision is never deleted by a deploy — traffic
is just repointed. This runbook covers backend (Cloud Run), Firestore data changes, and web/mobile.

## Backend (Cloud Run) — dev
Dev always runs the latest `main` build at 100% traffic. To roll back:

```bash
gcloud run revisions list --project=dzeroth-dev --region=asia-south1 --service=api
gcloud run services update-traffic api \
  --project=dzeroth-dev --region=asia-south1 \
  --to-revisions=<previous-revision-name>=100
```

Then either fix forward on `main` (next push redeploys) or revert the offending commit.

## Backend (Cloud Run) — prod
Prod deploys go `--no-traffic --tag candidate` (`.github/workflows/release-prod.yml`, automatic on a `v*` tag) → 10% → 100%
(`.github/workflows/promote-prod.yml`, **manual** `workflow_dispatch`, run once per stage — see `release-rollout`
skill "Manual-approval model on GitHub Free"). There are no `production-traffic-10` / `production-traffic-100`
GitHub Environments and no required-reviewer approval to deny — GitHub Free doesn't offer that for private repos.

**If the bad revision hasn't taken 100% traffic yet** (still at rc / 10%): just don't run `promote-prod.yml` again
for that tag — there is no pending approval to deny, since each stage only happens when the founder explicitly
dispatches it. If 10% traffic is already live and misbehaving, revert it immediately instead of waiting:

```bash
gcloud run services update-traffic api \
  --project=dzeroth-prod --region=asia-south1 \
  --to-revisions=<previous-stable-revision>=100
```

**If it already has 100% traffic and is misbehaving:**

```bash
# Find the previous stable revision (the one traffic pointed to before this release).
gcloud run revisions list --project=dzeroth-prod --region=asia-south1 --service=api

gcloud run services update-traffic api \
  --project=dzeroth-prod --region=asia-south1 \
  --to-revisions=<previous-revision-name>=100
```

This takes effect in seconds and does not require rebuilding an image — Cloud Run keeps old revisions around
(cleaned up incidentally by nothing; they cost nothing extra since Cloud Run bills per-request, not per-revision).

**If the incident is feature-related, not a bad build:** flip the feature flag off first (flags default OFF per
CLAUDE.md) before deciding whether a full revision rollback is even necessary.

## Firestore data changes
Data changes are expand/contract only (CLAUDE.md rule) — never a destructive migration in place:
1. **Expand**: add the new field/collection; old code ignores it, new code writes both old and new shapes.
2. Deploy code that reads/writes both shapes.
3. Backfill with a throttled job (respect the 20k writes/day free quota, or accept a few cents of overage).
4. **Contract**: once 100% of traffic is on new code and the backfill is verified, stop writing the old shape.

Rollback at any point before step 4 is just reverting the code deploy (per the Cloud Run steps above) — the old shape
is still being maintained. Rolling back after contracting requires re-deriving the old field from the new one or
re-running a backfill in the other direction; avoid contracting until confident.

## Firestore rules/indexes
Rules and indexes are deployed via `firebase deploy --only firestore:rules,firestore:indexes` **before** the code
that needs them (see `release-rollout` skill). To roll back rules: `firebase deploy --only firestore:rules` with the
previous `firebase/firestore.rules` checked out. Indexes are additive and safe to leave in place even after a code
rollback (an unused index costs nothing until read traffic uses it, and 1 GiB free storage covers small index sets).

## Web (Firebase Hosting)
Firebase Hosting keeps previous releases:

```bash
firebase hosting:clone <project-id>:<previous-version-or-channel> <project-id>:live
```

Or use the Firebase console → Hosting → release history → "Rollback" on the previous release. Instant, no rebuild.

## Mobile (Android/iOS)
- **Android**: Play Console staged rollout (10% → 50% → 100%) can be **halted** from the Play Console at any stage
  without a new build; halting stops the percentage from increasing further. A full rollback to the previous version
  requires a new release (Play does not support "undo" past what users have already installed) — use a forced-upgrade
  check (Firebase Remote Config, per `release-rollout` skill) to push affected users back down if the new version is
  broken in a way that can't be server-side-flagged off.
- **iOS**: TestFlight phased release can similarly be paused from App Store Connect. A shipped App Store release
  cannot be pulled back from users' devices; use server-side feature flags / a minimum-supported-version bump to
  neutralize a bad client release.

## Pub/Sub / Cloud Scheduler async handlers
All push subscriptions have a DLQ (max 5 delivery attempts, `modules/pubsub`). If a handler is rolled back mid-flight,
messages that failed against the bad revision sit in the DLQ topic (`<topic>-dlq`, 7-day retention) — replay them
manually once the fix is deployed:

```bash
gcloud pubsub subscriptions pull <topic>-dlq-sub --auto-ack --limit=100 --project=<project>
# or re-publish from the DLQ topic back to the original topic via a small one-off script.
```

## After any rollback
- Confirm `/healthz` and the uptime check are green, and Error Reporting is quiet for the restored revision.
- Record what happened and the fix in `docs/reviews/` (or a runbook update if a new failure mode was discovered —
  CLAUDE.md Definition of Done requires runbook updates for new failure modes).
