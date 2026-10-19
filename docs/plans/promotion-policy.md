# Promotion policy (Option C): PR sequence and PR 2 design
Status: DRAFT for founder review, 2026-10-19. Nothing here is wired. Owner: production-deployer. Cost: $0.

## Decisions already made (founder, 2026-10-19)
- PR 1 (#165): validators, flag ceiling, fixtures, CI. Unwired. Each later PR is reviewed on its own.
- Build the Flutter web client **before** promoting the backend candidate; a failed client build blocks promotion.
- Firestore rules and Hosting deploy **after** backend promotion and post-promotion verification; rules/index changes must be
  backward-compatible with the serving backend (expand/contract).
- `last-good` is created on the **actually previously serving image** and an Artifact Registry dry run must show it surviving cleanup
  before dev retention is shortened. Dev retention reduction is a separate change.
- Smoke accounts: approved in principle only; nothing is created until secret storage and ownership are confirmed.

## Sequence
| PR | Content | Gate to start |
|---|---|---|
| 1 (#165) | validators, ceiling, fixtures | review + merge |
| AR (#166) | KEEP `last-good`/`v` | **merged 2026-10-19 and applied in dev and prod**; plans from `main` now preserve it |
| drift (#167) | ignore Cloud Run `template.revision` (cause unverified) | review; merge does not change any resource |
| dev flags | explicit `off` for MEDIA/ENGAGEMENT/REPLIES/PROFILE_SNAPSHOT/QUOTES + 9 config vars equal to code defaults (plan from `main`) | founder approval of the exact plan; creates a 0% revision |
| dev maxScale (#169) | dev `max_instance_count = 1` (ADR-0007) | separate approval; apply AFTER the flags apply (or the flags plan from `main` would carry it); then `flag-ceiling.json` dev `max_instances` 3 -> 1 |
| 2 | `deploy-dev.yml` rewrite with `dry_run` input | items under "Before PR 2" |
| 3 | docs: runbook, release-rollout skill, ADR-0007 amendment | PR 2 verified on dev |
| 4 | smoke accounts + authenticated smoke | secret storage and owner confirmed |

## PR 2 design (deploy-dev, push to `main`)
1. Build + push image (ko, tag = SHA). Build web with the dev `--dart-define`s. **Either failing stops here.**
2. Auth via WIF; fetch service JSON and the serving revision JSON; `check-traffic.sh ... serving` (fail on any surprise).
3. `gcloud run deploy --no-traffic --tag=candidate`; refetch; `check-traffic.sh ... staged <cand> <serving>`;
   `validate-revision.sh` on the candidate revision JSON (ceiling gate).
4. Smoke the candidate URL: `/health` plus an unauthenticated probe expected to return 401 (`UNAUTHENTICATED`), plus the
   authenticated smoke once PR 4 exists.
5. Tag the **currently serving** revision's image `last-good` in Artifact Registry (digest-pinned, from the serving revision JSON, not
   by revision number), and add the traffic tag `last-good` to that revision. Refetch and assert both.
6. `update-traffic --to-revisions=<cand>=100`; refetch; assert exactly one 100% named revision, tags in the allow-list.
7. Post-promotion verification (`/health`, 401 probe, 5xx check from logs for N minutes). On any failure:
   `resolve-rollback.sh` (last-good only) then `update-traffic --to-revisions=<last-good>=100`, refetch, re-assert; the job still fails.
8. Only after 7: `firebase deploy --only firestore:rules,firestore:indexes`, wait for indexes READY, then Hosting.
`dry_run=true` stops after step 4 and never changes traffic or tags.

## Before PR 2 (unverified or blocked; do not assume)
| Item | Status | How to resolve |
|---|---|---|
| `--no-traffic` effect on latest-routing | Google docs silent | the scripts re-assert state after each op; confirm once on dev with approval |
| `update-traffic --to-revisions` keeps other tags | docs silent | same; the allowed-tag check would catch a loss |
| Why prod's template pins `revision` (hypothesis: `--no-traffic`/`--tag`) | unverified | #167 ignores it; step 3 on dev will show whether dev gets pinned too |
| Index readiness checkable with the CI identity | unknown | try read-only `gcloud firestore indexes composite list` from the CI SA on dev |
| Unauthenticated probe vs API key / App Check config | unknown | test the 401 probe on the candidate URL in a dry run |
| Dev TF apply for explicit `FEATURE_MEDIA/ENGAGEMENT/REPLIES/PROFILE_SNAPSHOT/QUOTES=off` | plan prepared 2026-10-19, apply not yet approved | until then the gate relies on code defaults (verified in CI) |
| ADR-0007 says dev max instances 1; live is 3 (module default) | decided 2026-10-19: change Terraform (#169), not the ADR | apply after review |
| Prod-side equivalents (release-prod/promote-prod) | out of scope | prod is untouched by this plan |

## Out of scope / holds
Engagement stays off and its plan unapplied; no `FEATURE_MEDIA` until its own dev plan is approved; prod is untouched; #131 and #93 on hold.
