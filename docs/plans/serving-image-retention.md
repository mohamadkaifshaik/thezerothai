# Serving-image retention tag (`serving`): investigation, lifecycle and Terraform plans
Status: **PLANNING ONLY (founder-approved to investigate and prepare plans, 2026-10-19). Nothing applied, no tag created, no image touched.**
Cost: $0 (at most one extra protected image per environment, ~13.5 MB measured dev average incl. its SBOM).

## Question
With dry-run-by-default deploys (`docs/plans/promotion-policy.md`), every push to `main` pushes a new dev image but promotes none. After
three newer pushes the serving image falls out of `keep-last-3`, and `delete-tagged-after-30d` later removes it. Does that break the
service, and what protects it?

## Verified (official docs, fetched 2026-10-19)
- **Cloud Run keeps its own copy of the image** ("Cloud Run keeps this copy of the container image as long as it is used by a serving
  revision") and new instances do **not** pull from the registry ("Container images are not pulled from their container repository when
  a new Cloud Run instance is started"). So deleting the *serving* revision's source image from Artifact Registry does not by itself
  break the running service. The docs say nothing about the copy once no serving revision uses it, and nothing about cleanup policies.
- **`gcloud artifacts docker tags add` moves an existing tag** (tags are unique per repository: "you will move the tag from the original
  version to the newly tagged version"). `roles/artifactregistry.writer` can add or edit tags; **deleting a tag needs
  `roles/artifactregistry.repoAdmin`**, which the CI deploy identity does not have. So no workflow step may rely on `tags delete`
  (the orchestrator's delete fallback was removed for this reason).
  **Correction (deploy-dev run 39637856312, 2026-10-21):** *re-pointing an existing tag* also needs `artifactregistry.tags.delete`:
  `tags add ... :last-good` by `ci-deploy` failed with PERMISSION_DENIED on it, so `writer` alone is not enough to MOVE a tag (creating a
  new one is). `ci-deploy` therefore gets a custom role `arTagMover` (that one permission) bound on the `api` repository
  (`infra/terraform/modules/iam`); still no delete fallback and no `repoAdmin`.
- A KEEP cleanup policy with `tag_prefixes` protects any matching tagged version; KEEP beats DELETE (earlier verification, applied in dev and prod).

## Why a tag is still needed
Not for the running service, but for **the orchestrator's own preconditions**: `promote-dev.sh` refuses to promote unless the
previous (serving) image is still in Artifact Registry (it becomes the `last-good` rollback target, and a rolled-back revision is no
longer "serving", so Cloud Run's internal copy is not guaranteed for it). Without protection, three dry-run pushes make the next
promotion impossible until the serving image is rebuilt. `last-good` protects the *previous* serving image after a promotion, but
nothing protects the *current* serving image between promotions.

## Design: one moving tag `serving`
| Piece | Behaviour |
|---|---|
| Terraform | `protected_tag_prefixes` default gains `"serving"` -> KEEP policy `keep-tag-serving` (TAGGED, prefix `serving`). Preserves `keep-last-3`, `keep-tag-last-good`, `keep-tag-v` and both DELETE policies. |
| Bootstrap (one time, needs separate approval) | Tag the digest that serves now with `serving` (dev: the image of `api-00144-xt7`, `sha256:1f661cec...`) before the policy can age it out. Prod needs nothing: its serving images are protected by `v*`. |
| Orchestrator (follow-up change to #171, after the Terraform is applied) | In promote mode only: step 1 self-heals if the serving digest lacks `serving`; after step 8 (final verification) `tags add REPO@<candidate digest> REPO:serving` moves it to the new serving image. A failure of this last step is a **warning**, not a rollback (the promotion is already verified); it is surfaced in the job summary because protection is then missing. A dry run never touches it. |
| Bound | At most `serving` + `last-good` (+ their SBOM manifests are NOT protected, which is fine) beyond `keep-last-3` and `v*`. |
| Failure modes | `tags add` fails: no tag moves, nothing else changes. The deploy identity cannot delete tags, so no step can strip protection. If `serving` is missing, the next promotion self-heals or refuses with a clear message. |

## Terraform plans (prepared, NOT applied)
- **Dev** (full `terraform plan` from this branch, refresh on): `0 to add, 1 to change, 0 to destroy`; only
  `google_artifact_registry_repository.api`; cleanup policies before = `delete-tagged-after-30d, delete-untagged-after-1d, keep-last-3,
  keep-tag-last-good, keep-tag-v`; after = the same plus `keep-tag-serving`.
- **Prod** (isolated, same method as `docs/runbooks/prod-ar-retention-apply.md`: base commit `28f32fa` plus only this module,
  `-target=module.artifact_registry`, refresh on): `0 to add, 1 to change, 0 to destroy`, identical policy delta. A plain plan from
  `main` still carries the unrelated pending prod changes (Cloud Run env vars, TTLs, FCM, moved blocks), so the isolated base is
  required again. Prod gains no behaviour from `serving` today (no prod workflow uses it); it is included only to keep the shared module
  identical across environments, and can be left out of the prod apply if the founder prefers.

## Not verified / open
- A real `tags add` re-pointing an existing tag in this repository (docs say it moves; an empirical check on a throwaway tag in dev
  needs the founder's approval because it mutates Artifact Registry metadata).
- What Cloud Run does with its internal copy of a revision's image after the revision stops serving (docs silent).
- Whether to bootstrap `serving` by hand or let the first promote-mode run self-heal it (the latter only works while the image still exists).
