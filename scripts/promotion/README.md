# Promotion scripts (Option C, PR 1 of the sequence)

Pure validators for tag-gated, fail-closed promotion of the Cloud Run `api` service. **Not wired into any workflow.**
`deploy-dev.yml` is unchanged. Each script reads JSON that a thin wrapper (PR 2) will fetch with gcloud, so the
logic is testable with no credentials.

| Script | Input | Fails when |
|---|---|---|
| `validate-revision.sh <revision.json> <ceiling> <env>` | `gcloud run revisions describe --format=json` | unknown `FEATURE_*` name, `FEATURE_*` from `valueFrom`, duplicate var, bad mode/percent, effective mode above the ceiling, allowlist or percent above the ceiling, minScale differs, maxScale is not an integer in 1..ceiling (0 means unlimited) |
| `check-traffic.sh <service.json> <ceiling> <env> serving` | `gcloud run services describe --format=json` | not exactly one named revision at 100%, `latestRevision` routing, any other revision with a percent, tag outside the allow-list |
| `check-traffic.sh ... staged <candidate> <serving>` | same | serving revision differs from the expected one, or the candidate lacks the 0% `candidate` tag |
| `resolve-rollback.sh <service> <last-good-rev.json> <images.json> <ceiling> <env>` | + `gcloud artifacts docker images list --format=json` | no `last-good` tag, wrong revision JSON, image not pinned by digest, digest gone from Artifact Registry, or the target fails `validate-revision.sh` |
| `check-flag-registry.sh <config.go> <ceiling> [main.tf...]` | repo files | ceiling flag set differs from `flags.LoadSpec` names, a code default differs from `unset_default`, Terraform mentions an unknown `FEATURE_*` name |

`flag-ceiling.json` holds names, modes and **counts** only. Allowlist uids are never stored, printed or logged: the
scripts print flag names and entry counts, and `test/run.sh` fails if any fixture uid appears in stdout/stderr.

## Design decisions
- **The rollback target is the `last-good` tag only**, never "previous revision by number" (v0.4.0 notes: Terraform-made
  revisions were never smoke-tested). It goes through the same validator as a candidate.
- **An unset `FEATURE_<N>` is evaluated as its code default, not assumed off.** `GRAPH` and `POSTS` default to **on** in dev
  (`graphDefaultMode`, `config.go`); everything else defaults to off. `unset_default` records this and
  `check-flag-registry.sh` re-derives it from `config.go`, so a changed default fails CI.
- Cloud Run omits `value` for empty strings (seen on the real dev revision), so "plain value" means "no
  `valueFrom`/`valueSource`", not "has `value`".
- jq output is passed through `tr -d '\r'` (the Windows jq build can emit CRLF); `.gitattributes` forces LF here.

## Verified against the live dev service (read-only, 2026-10-19)
- `status.traffic`: `api-00144-xt7` 100% (tag `cand`), `api-00089-wuw` 0% (tag `p8-t1`). No `latest` entry.
- The real revision JSON passes `validate-revision.sh` (11 flags, lifecycle and removed_ids allowlists 1/1, maxScale 3, minScale 0).
- `FEATURE_MEDIA/ENGAGEMENT/REPLIES/PROFILE_SNAPSHOT/QUOTES` are **absent** on the serving revision (the #144/#158 Terraform
  vars are unapplied). They evaluate as off. PR 2 should not rely on absence long-term: apply the vars (own approval) so
  the gate sees explicit `off`.
- Artifact Registry `api/api` holds 260 versions = 130 images + 130 `sha256-<digest>.sbom` manifests; `keep-last-3` counts
  versions, so the three newest are roughly (image, its SBOM, previous image). See the separate retention change.

## Not yet verified (must be resolved before PR 2 wires anything)
- Whether `gcloud run deploy --no-traffic` preserves or changes latest-routing; whether `update-traffic` preserves tags.
  The scripts do not assume either: `check-traffic.sh` re-asserts state after each operation.
- Whether index readiness is checkable with the CI identity; whether unauthenticated smoke checks work with the API-key/auth setup.
- Dev `max_instances`: ADR-0007 says 1 for dev, but no env sets `max_instance_count`, so dev runs the module default
  (3, `modules/cloud-run-api/variables.tf`) and the live revision confirms `maxScale=3`. The ceiling encodes the live
  value (3); either the ADR or Terraform should change, as a separate decision.
- `docs/releases/v0.4.0.md` says "dev destroyed 2026-10-10". Dev is live; the sentence refers to ops alert policies being
  prod-only. The wording is stale and should be corrected in the docs PR.

## Run
`bash scripts/promotion/test/run.sh` (about 1 min on Windows because of process spawn; seconds on Linux).
CI job `promotion-scripts` also runs shellcheck 0.10.0 (`-S warning`: the info-level SC2016 fires on every jq `$var`), actionlint 1.7.7 and the registry check.
shellcheck is not installed on the founder's machine: CI is the only shellcheck gate.

## Review fixes (PR #165 code-review, 2026-10-19)
Fail-open paths found by the reviewer, each now covered by a fixture: an unknown mode in the ceiling (compared as "never exceeded");
a `LoadSpec` line the registry parser could not read (skipped silently; now raw == parsed == names or fail); flag names with
digits; `graphDefaultMode` trusted by name (now checks `config.go` still defines on + a prod override to off); a stale service
status (now requires `observedGeneration == generation` and `Ready=True`); an images list from another repository (digest AND
package must match); `last-good` being the revision already serving (a no-op rollback). `LC_ALL=C sort` for the name diff;
`persist-credentials: false` and `$RUNNER_TEMP` in CI; `lib.sh` is no longer executable.
Known limits (unchanged): only `containers[0]` is inspected (the service has one container); shellcheck's sha256 is
trust-on-first-use; field names of live gcloud JSON were checked against the dev service and revision, not against every gcloud version.

## Scaling ceiling (2026-10-19)
`max_instances` is a cost cap, so it is checked as `1 <= maxScale <= ceiling`, not equality. Dev's Terraform now sets maxScale 1
(#169, applied 2026-10-19; new revisions have 1) while the serving revision `api-00144-xt7` still has 3. The ceiling stays 3
so that revision remains a valid rollback target; tighten it to 1 in a reviewed PR once no revision with maxScale 3 can be a
`last-good` target.

## promote-dev.sh (PR 2a, UNWIRED: no workflow calls it yet)
Orchestrates one dev promotion from validated pieces: validate serving state and that the previous image still exists in Artifact
Registry, deploy a 0% `candidate`, validate it (traffic shape, flag and scaling ceiling, image digest), smoke it (`/health` 200 and an
unauthenticated `GetMe` refused with 401, both checked live on dev 2026-10-19), check Firestore indexes are READY, then either stop
(`DRY_RUN=true`: candidate tag removed, traffic untouched, no `last-good` change) or **prove the rollback target is usable on a
simulated copy of the state before touching any tag**, tag the previously serving revision/image `last-good`, promote, re-assert state
(repairing a lost `last-good` tag once), soak without retries, and roll back to `last-good` only.

**Rollback coverage.** Failures the script itself sees (errors, a failed check or smoke) roll back from an EXIT trap armed just before
traffic moves. A **cancellation or job timeout is different**: the Actions runner signals only the step's own shell, so a trap inside
the script cannot be relied on. The script therefore writes a marker file (`PROMOTE_MARKER`) *before* traffic moves and deletes it only
after final verification; the workflow runs `RECOVER=true bash promote-dev.sh` in an `if: always()` step after the promote step, which
rolls back when the marker still exists and does nothing otherwise. The promote step has its own timeout shorter than the job's so this
step is never cut off. The rollback always re-issues the (idempotent) `update-traffic` and re-checks, because a status read right
after a failed `update-traffic` can be stale. Verified only against the fake gcloud (including a SIGKILL of the script followed by the
recover step); the real runner's cancellation sequence (SIGINT, then SIGTERM about 7.5 s later, then SIGKILL) is from memory.
A failure before traffic moves removes the leftover `candidate` tag. `test/promote-test.sh` runs everything against a stateful fake
gcloud/curl (65 checks); sabotaged copies (rollback removed, candidate ceiling check removed, rollback trap not armed) were confirmed
to fail the suite.

**Not verified against real gcloud:** whether `update-traffic` keeps tags (re-asserted). `tags add` moves an existing tag (Artifact
Registry docs) and the CI identity cannot delete tags, so there is no delete fallback. Known limits: a dry run leaves the service
template pointing at the unpromoted image (Terraform ignores `image`; a later Terraform apply makes a 0% revision from it); the soak
checks `/health` and the 401 probe only, not Cloud Logging 5xx rates; the serving image is protected from Artifact Registry cleanup only
by `keep-last-3` until the `serving` tag lands (#174), so after enough dry-run pushes or 30 days every run refuses at step 1 until it is
re-tagged by hand. The first live run should be a watched manual dispatch.
