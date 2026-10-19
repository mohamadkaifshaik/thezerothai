# Dev Artifact Registry retention reduction (PREPARED, NOT APPLIED)
Status: **Step 1 (dry run) APPLIED to dzeroth-dev on 2026-10-19** (founder-approved; plan 1 add / 1 change / 0 destroy; post-apply plan shows no changes; `serving` tag set on `42be…79ef` beforehand). Nothing is deleted while `cleanup_policy_dry_run = true`. **Step 2 (live deletion) is NOT applied and needs the founder's separate approval after the real dry-run audit log is reviewed.**
Cost: $0 (it reduces storage; dev repo is ~1.87 GB, free tier 0.5 GB, about $0.13/month over).

## Proposal (dev only; prod keeps the module defaults 3 versions / 30 days)
| | Now | Proposed |
|---|---|---|
| keep newest N versions (SBOM manifests count) | 3 | **6** (id becomes `keep-last-6`) |
| delete TAGGED versions older than | 30 days | **3 days** (id `delete-tagged-after-3d`) |
| KEEP `last-good`, `serving`, `v*` | yes | unchanged |
| delete untagged after 1 day | yes | unchanged |
| mode | live | **DRY RUN first** (`cleanup_policy_dry_run = true`): evaluate and log, delete nothing |
Why 3 days: at about 7 pushes/day (every merge to `main` pushes an image) a 7-day window holds about 49 images (~660 MB at the measured ~13.5 MB per image
with its SBOM), above the 0.5 GB free tier; 3 days holds about 21 (~285 MB).

## Two-step rollout (two separate approvals)
1. **Step 1 (this PR's plan): dry run.** Adds `google_project_iam_audit_config` (Data Access **DATA_WRITE** for `artifactregistry.googleapis.com`, the only way to see dry-run
   results; dev has no audit configs today) and switches the repo to the new numbers with `cleanup_policy_dry_run = true`. Plan: **1 to add, 1 to change, 0 to destroy**
   (audit config; the repository's policies and dry-run flag). Policies after: `delete-tagged-after-3d, delete-untagged-after-1d, keep-last-6, keep-tag-last-good, keep-tag-serving, keep-tag-v`.
   Cleanup runs about daily; wait for at least one run, then inspect the audit log for the versions it WOULD delete and confirm the serving and rollback images are not in it.
2. **Step 2 (later PR + approval): live.** Set `cleanup_policy_dry_run = false` only after the dry-run log shows the serving image (revision `api-00171-maf`, digest below) and the
   `last-good` image (`api-00144-xt7`, `sha256:1f661cec...`) retained.

## PREREQUISITE (do not apply step 1 before this)
The current serving image has **no `serving` tag**; `serving` and `last-good` are both still on the previous image. Simulation on live data (278 versions) with 10 newer pushes
after the window: the serving image is **deleted** unless it carries `serving`; the `last-good` image is kept either way. Fix either by the next verified promotion (PR #179 moves the tag
automatically) or by a one-off `tags add` that the founder confirms:
`sha256:42be6c3ba95031f66f4e7c700fd0e4b03e20db334d6542cc24198fe8ea1e79ef` (revision `api-00171-maf`, built from commit `3a82961`).

## Simulation (my model of AR semantics on live data, 2026-10-20; KEEP beats DELETE, `last-good`/`serving`/`v` prefixes kept)
| Scenario | images kept (of 139) | serving image 42be | last-good image 1f66 |
|---|---|---|---|
| current policy (keep 3, 30 d), today | 139 | kept | kept |
| proposed (keep 6, 7 d), today | 38 | kept | kept |
| proposed, +10 d, no newer pushes | 4 | kept (newest) | kept |
| proposed (keep 6 or 3 d), 10 newer pushes, **serving tag NOT on 42be** | 4 | **deleted** | kept |
| proposed, 10 newer pushes, serving tag on 42be | 5 | kept | kept |
Rollback consequence of the reduction: dev rollback relies only on `last-good` (the image of the revision that served before the last promotion) and `serving`; older SHA-tagged images
disappear after 3 days, which is acceptable because dev rolls back to `last-good`, never to an arbitrary older image. SBOM manifests of protected images are not protected (not needed to pull or roll back).
The simulation approximates AR; the dry run is the real check.

## Not verified
Exact AR dry-run audit-log format and delay (docs: about a day); whether Data Access audit logs add any cost beyond the free log quota (expected negligible).
