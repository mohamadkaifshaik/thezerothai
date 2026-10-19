# Runbook: applying Artifact Registry retention to prod without unrelated changes

> **Executed 2026-10-19 and verified (see Record below). Do not reuse this procedure after `main`'s next prod apply or any
> later change to the AR module:** applying from the old base commit would revert those changes. Re-derive the base then.

Why this exists: `infra/terraform/envs/prod` on `main` carries merged-but-unapplied work (new Cloud Run env vars, Firestore
TTLs, FCM IAM, `fcm.googleapis.com`, a Pub/Sub grant), three pending `moved` blocks for the monitoring alert policies
(prod state still holds the old addresses, so deleting the blocks would destroy and recreate the policies), and a Cloud Run
`template.revision` drift (`api-00010-zah -> null`) that any refreshing plan would try to "fix" by creating a new revision.
`-target` on `main` fails ("Moved resource instances excluded by targeting").

Approach: plan and apply from the commit prod was last applied from (`28f32fa`, 2026-10-09) plus only the module change in
this PR, so the plan contains nothing else. The module change is byte-identical on that base (`f0624fb`).

```bash
git worktree add --detach .claude/worktrees/ar-prod-base f0624fb   # 28f32fa + the module change; a SHA, not a movable branch
cd .claude/worktrees/ar-prod-base/infra/terraform/envs/prod
cp <path-to>/terraform.tfvars .                      # gitignored; delete again after
terraform init -reconfigure -backend-config="bucket=dzeroth-tfstate"
terraform plan -input=false -target=module.artifact_registry -out=ar.tfplan
terraform show ar.tfplan     # read it: only cleanup_policies change, 0 to add, 1 to change, 0 to destroy
terraform show -json ar.tfplan | jq -e '[.resource_changes[]|select(.change.actions!=["no-op"])|{a:.address,x:.change.actions}]==[{"a":"module.artifact_registry.google_artifact_registry_repository.api","x":["update"]}]'
# must print true (checks address AND action: a delete+create replace would wipe every image)
# apply only after the founder approves this exact plan:
terraform apply ar.tfplan
```

After apply (read-only checks): `gcloud artifacts repositories describe api --project=dzeroth-prod --location=asia-south1`
shows five policies (`keep-last-3`, `keep-tag-last-good`, `keep-tag-v`, two DELETE); the serving digest still carries `v0.4.0`.
Policies run as a background job, within about a day. Rollback uses the same isolated worktree and saved-plan flow with
the two KEEP policies removed from the module there; never run `terraform apply` here without a reviewed `ar.tfplan`.
Warning: without the KEEP policies, `v*` images older than 30 days become deletable (the serving `v0.4.0` image included).
Afterwards delete `ar.tfplan`, `.terraform/` and the copied `terraform.tfvars` from the worktree.
Do not use the same worktree for `main`'s prod plan: the later full prod apply (Cloud Run env vars, TTLs, FCM) is a separate
approval and must first deal with the `template.revision` drift.

## Record: applied 2026-10-19 (founder-approved, plan-then-OK)
| Env | How | Plan | Result |
|---|---|---|---|
| prod | saved plan from `chore/prod-ar-retention-base` (`28f32fa` + `f0624fb`), `-target=module.artifact_registry`; a fresh re-plan hashed identical to the reviewed one before apply | 0 add, 1 change, 0 destroy (AR repository only) | `Apply complete`; follow-up plan "No changes" |
| dev | saved plan from `chore/ar-protect-release-tags`, `-target=module.artifact_registry` | 0 add, 1 change, 0 destroy | `Apply complete! 0 added, 1 changed, 0 destroyed`; follow-up plan "No changes" |

Live policies in both envs afterwards: `keep-last-3` (KEEP, mostRecentVersions 3), `keep-tag-last-good` (KEEP, TAGGED, prefix `last-good`),
`keep-tag-v` (KEEP, TAGGED, prefix `v`), `delete-tagged-after-30d`, `delete-untagged-after-1d`. **Preserve this configuration.**
Prod: the serving digest `sha256:c1a5e07e...` (revision `api-00010-zah`) carries `v0.4.0`; `v0.1.0` is also tagged. Dev: 260 versions
before and after (nothing deleted); no dev image carries `last-good` yet, so dev rollback images are still protected only by the older policies.
Cloud Run traffic, code and flags were not touched. Until this PR merges, a plan from `main` wants to REMOVE the two KEEP policies.
