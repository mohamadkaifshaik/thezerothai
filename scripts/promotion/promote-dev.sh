#!/usr/bin/env bash
# Tag-gated, fail-closed promotion of the dev Cloud Run service. Called by .github/workflows/deploy-dev.yml.
#
# Required env: PROJECT REGION SERVICE IMAGE (built image, pinned by @sha256 digest) REPO (Artifact Registry
#   <host>/<project>/<repo>/<image>, no tag) DRY_RUN (true|false). Optional: CEILING (default flag-ceiling.json),
#   SOAK_SECONDS (integer >= 0, default 120), SOAK_INTERVAL (integer >= 1, default 15), CHECK_INDEXES (default true).
# Exit codes: 0 promoted (or dry run completed with traffic untouched), 1 refused or failed (after a rollback when traffic had
# already moved), 2 usage.
#
# Order: validate serving state and that the previous image still exists -> deploy a 0% `candidate` -> validate it (traffic shape,
# ceiling, digest) -> smoke -> [dry run stops here and removes the tag] -> prove the rollback target is usable WITHOUT touching any
# tag -> only then tag the previously serving image/revision `last-good` -> promote -> re-assert state -> soak -> on ANY failure after
# traffic moved (including cancellation or timeout) roll back to `last-good` only. Never prints revision JSON (allowlist uids).
# Verified against the live dev service: GET /health and an unauthenticated GetMe (HTTP 401) behave as probed below.
# NOT verified on Google's side: whether `--no-traffic`/`update-traffic` keep other tags, and the exact error text of
# `artifacts docker tags add` for an existing tag (the script only falls back to delete+add on an "already exists" error).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
need_tool jq
need_tool gcloud
need_tool curl
for v in PROJECT REGION SERVICE IMAGE REPO DRY_RUN; do
  [ -n "${!v:-}" ] || { echo "FAIL: $v is required" >&2; exit 2; }
done
case $DRY_RUN in true | false) ;; *) echo "FAIL: DRY_RUN must be true or false" >&2; exit 2 ;; esac
case $IMAGE in *@sha256:*) digest=sha256:${IMAGE##*@sha256:} ;; *) echo "FAIL: IMAGE must be pinned by digest" >&2; exit 2 ;; esac
ceil=${CEILING:-$here/flag-ceiling.json}
soak=${SOAK_SECONDS:-120}
interval=${SOAK_INTERVAL:-15}
check_indexes=${CHECK_INDEXES:-true}
case $soak in '' | *[!0-9]*) echo "FAIL: SOAK_SECONDS must be an integer >= 0" >&2; exit 2 ;; esac
case $interval in '' | *[!0-9]*) echo "FAIL: SOAK_INTERVAL must be an integer >= 1" >&2; exit 2 ;; esac
[ "$interval" -ge 1 ] || { echo "FAIL: SOAK_INTERVAL must be an integer >= 1" >&2; exit 2; }
env=dev
work=$(mktemp -d)
moved=0             # 1 from just before traffic is pointed at the candidate until the run is fully verified
cleanup_candidate=0 # 1 while a candidate tag we created may be left behind
cand=""

step() { echo "== $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
svc_json() { gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format=json | tr -d '\r' >"$1"; }
rev_json() { gcloud run revisions describe "$2" --project="$PROJECT" --region="$REGION" --format=json | tr -d '\r' >"$1"; }
traffic() { gcloud run services update-traffic "$SERVICE" --project="$PROJECT" --region="$REGION" --quiet "$@" >/dev/null; }
check() { bash "$here/check-traffic.sh" "$@" >"$work/check.out" 2>&1 || { cat "$work/check.out" >&2; return 1; }; }
tag_revision() { jqr --arg t "$2" '[.status.traffic[] | select(.tag == $t)] | first | .revisionName // empty' "$1"; }
tag_url() { jqr --arg t "$2" '[.status.traffic[] | select(.tag == $t)] | first | .url // empty' "$1"; }
serving_of() { jqr '[.status.traffic[] | select((.percent // 0) == 100)] | first | .revisionName // empty' "$1"; }

# Smoke: /health must be 200 and an unauthenticated GetMe must be refused with 401 (proves auth is enforced).
# `smoke URL retry` retries transient failures (cold start of a fresh candidate); the soak calls it WITHOUT retries so a
# flapping revision fails a tick instead of being retried into a pass.
smoke() {
  local url=$1 code
  local retry=()
  if [ "${2:-}" = "retry" ]; then retry=(--retry 5 --retry-delay 3 --retry-all-errors); fi
  curl -fsS "${retry[@]}" --max-time 15 "$url/health" >/dev/null || { echo "health failed at $url" >&2; return 1; }
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST -H 'content-type: application/json' -d '{}' \
    "$url/dzeroth.identity.v1.IdentityService/GetMe") || true
  [ "$code" = "401" ] || { echo "unauthenticated GetMe returned '$code', expected 401" >&2; return 1; }
}

# Every command is checked explicitly: this also runs from the EXIT trap, where `set -e` does not apply.
rollback() {
  moved=0 # one attempt only; the exit trap must not repeat it
  step "ROLLBACK to the last-good revision"
  local s r target serving
  s=$work/rb-svc.json
  svc_json "$s" || die "rollback: cannot read the service"
  target=$(tag_revision "$s" last-good)
  [ -n "$target" ] || die "no last-good tag; cannot roll back automatically. Serving state needs manual review"
  serving=$(serving_of "$s")
  if [ "$serving" = "$target" ]; then
    echo "traffic is already on last-good ($target); nothing to roll back"
    traffic --remove-tags=candidate || true
    return 0
  fi
  rev_json "$work/rb-rev.json" "$target" || die "rollback: cannot read $target"
  gcloud artifacts docker images list "$REPO" --include-tags --format=json | tr -d '\r' >"$work/rb-images.json" || die "rollback: cannot list images"
  r=$(bash "$here/resolve-rollback.sh" "$s" "$work/rb-rev.json" "$work/rb-images.json" "$ceil" "$env") || die "rollback target failed validation; manual review"
  traffic --to-revisions="$r=100" || die "rollback: update-traffic failed; manual review"
  svc_json "$s" || die "rollback: cannot re-read the service"
  check "$s" "$ceil" "$env" serving || die "state after rollback is not the expected shape"
  [ "$(serving_of "$s")" = "$r" ] || die "rollback did not land on $r"
  traffic --remove-tags=candidate || true
  echo "rolled back to $r"
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    if [ "$moved" = 1 ]; then
      echo "run ended abnormally after traffic moved (exit $rc); rolling back" >&2
      (rollback) || echo "ROLLBACK DID NOT COMPLETE: review the service by hand" >&2
    elif [ "$cleanup_candidate" = 1 ]; then
      traffic --remove-tags=candidate 2>/dev/null || true
    fi
  fi
  rm -rf "$work"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 143' TERM # a cancelled/timed-out job still runs on_exit, so a moved candidate is rolled back
trap 'exit 130' INT

step "1/8 validate the serving state"
svc_json "$work/s0.json"
check "$work/s0.json" "$ceil" "$env" serving || die "serving state is not what the policy expects; refusing to deploy"
prev=$(serving_of "$work/s0.json")
rev_json "$work/prev.json" "$prev"
bash "$here/validate-revision.sh" "$work/prev.json" "$ceil" "$env" >/dev/null || die "serving revision $prev fails the flag/scaling ceiling"
prev_image=$(jqr '.spec.containers[0].image' "$work/prev.json")
case $prev_image in *@sha256:*) ;; *) die "serving revision image is not pinned by digest" ;; esac
prev_digest=sha256:${prev_image##*@sha256:}
gcloud artifacts docker images list "$REPO" --include-tags --format=json | tr -d '\r' >"$work/images.json"
[ "$(jqr --arg d "$prev_digest" --arg p "$REPO" '[.[] | select(.version == $d and .package == $p)] | length' "$work/images.json")" -ge 1 ] \
  || die "the serving revision's image is no longer in Artifact Registry; nothing could be rolled back to. Refusing before any change"

step "2/8 deploy a 0% candidate"
cleanup_candidate=1
gcloud run deploy "$SERVICE" --project="$PROJECT" --region="$REGION" --image="$IMAGE" --no-traffic --tag=candidate --quiet >/dev/null
svc_json "$work/s1.json"
cand=$(tag_revision "$work/s1.json" candidate)
[ -n "$cand" ] || die "no candidate tag after deploy"
[ "$cand" != "$prev" ] || die "candidate is the serving revision (image unchanged?)"
check "$work/s1.json" "$ceil" "$env" staged "$cand" "$prev" || die "state after the candidate deploy is unexpected (serving moved, or tag lost)"

step "3/8 validate the candidate"
rev_json "$work/cand.json" "$cand"
cand_image=$(jqr '.spec.containers[0].image' "$work/cand.json")
[ "sha256:${cand_image##*@sha256:}" = "$digest" ] || die "candidate runs a different image than the one built"
bash "$here/validate-revision.sh" "$work/cand.json" "$ceil" "$env" >/dev/null || die "candidate fails the flag/scaling ceiling"

step "4/8 smoke the candidate"
smoke "$(tag_url "$work/s1.json" candidate)" retry || die "candidate smoke failed"
if [ "$check_indexes" = "true" ]; then
  gcloud firestore indexes composite list --project="$PROJECT" --format=json | tr -d '\r' >"$work/indexes.json" || die "cannot list Firestore indexes with this identity"
  [ "$(jqr '[.[] | select(.state != "READY")] | length' "$work/indexes.json")" = "0" ] || die "a Firestore index is not READY"
fi

if [ "$DRY_RUN" = "true" ]; then
  step "dry run: removing the candidate tag, traffic never moved"
  traffic --remove-tags=candidate
  cleanup_candidate=0
  svc_json "$work/s2.json"
  check "$work/s2.json" "$ceil" "$env" serving || die "state after the dry run is unexpected"
  [ "$(serving_of "$work/s2.json")" = "$prev" ] || die "serving revision changed during a dry run"
  echo "dry run ok: candidate $cand validated and smoked; serving still $prev"
  exit 0
fi

step "5/8 prove the rollback target is usable, then record it as last-good"
# Pure simulation first: the same resolver and validator on a copy of the state in which last-good already points at the previous
# revision/image. Nothing is tagged until this passes, so a refusal never destroys an existing good last-good.
jq --arg p "$prev" '.status.traffic |= (map(if .tag == "last-good" then del(.tag) else . end) | map(select(has("percent") or has("tag"))))
  | .status.traffic |= map(if .revisionName == $p then .tag = "last-good" else . end)' "$work/s1.json" >"$work/sim-svc.json"
jq --arg d "$prev_digest" 'map(.tags |= map(select(. != "last-good"))) | map(if .version == $d then .tags += ["last-good"] else . end)' "$work/images.json" >"$work/sim-images.json"
PREFLIGHT=1 bash "$here/resolve-rollback.sh" "$work/sim-svc.json" "$work/prev.json" "$work/sim-images.json" "$ceil" "$env" >/dev/null 2>"$work/pre.err" \
  || { cat "$work/pre.err" >&2; die "rollback target is not usable; refusing to promote (no tag was changed)"; }

if ! gcloud artifacts docker tags add "$REPO@$prev_digest" "$REPO:last-good" --quiet >/dev/null 2>"$work/tag.err"; then
  if grep -qiE 'already exists|ALREADY_EXISTS' "$work/tag.err"; then
    gcloud artifacts docker tags delete "$REPO:last-good" --quiet >/dev/null 2>"$work/tag.err" || { head -n 1 "$work/tag.err" >&2; die "could not move the existing last-good tag (nothing was changed)"; }
    gcloud artifacts docker tags add "$REPO@$prev_digest" "$REPO:last-good" --quiet >/dev/null 2>"$work/tag.err" \
      || { head -n 1 "$work/tag.err" >&2; die "last-good was removed but could not be re-added; the Artifact Registry tag is missing, fix by hand before promoting"; }
  else
    head -n 1 "$work/tag.err" >&2
    die "could not tag the previous image last-good (nothing was changed)"
  fi
fi
traffic --update-tags="last-good=$prev"
svc_json "$work/s3.json"
[ "$(tag_revision "$work/s3.json" last-good)" = "$prev" ] || die "last-good traffic tag is not on $prev"
gcloud artifacts docker images list "$REPO" --include-tags --format=json | tr -d '\r' >"$work/images2.json"
[ "$(jqr --arg d "$prev_digest" '[.[] | select(.version == $d and (.tags | index("last-good")))] | length' "$work/images2.json")" = "1" ] || die "last-good is not on the previous image in Artifact Registry"

step "6/8 promote $cand"
moved=1 # from here on any non-zero exit (error, cancel, timeout) triggers a rollback to last-good
cleanup_candidate=0
traffic --to-revisions="$cand=100"
svc_json "$work/s4.json"
# Tags may or may not survive update-traffic (unverified); repair last-good once, then require it.
if [ -z "$(tag_revision "$work/s4.json" last-good)" ]; then
  traffic --update-tags="last-good=$prev"
  svc_json "$work/s4.json"
fi
if ! check "$work/s4.json" "$ceil" "$env" serving || [ "$(tag_revision "$work/s4.json" last-good)" != "$prev" ] \
  || [ "$(serving_of "$work/s4.json")" != "$cand" ]; then
  echo "state after promotion is not what was intended" >&2
  rollback
  exit 1
fi

step "7/8 soak ${soak}s on the serving revision (no retries)"
url=$(jqr '.status.url' "$work/s4.json")
elapsed=0
while [ "$elapsed" -lt "$soak" ]; do
  if ! smoke "$url"; then
    echo "smoke failed during the soak" >&2
    rollback
    exit 1
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

step "8/8 final verification"
svc_json "$work/s5.json"
check "$work/s5.json" "$ceil" "$env" serving || die "final state check failed"
[ "$(serving_of "$work/s5.json")" = "$cand" ] || die "final serving revision is not the candidate"
moved=0 # verified end to end; nothing left to roll back
echo "promoted $cand (last-good = $prev)"
