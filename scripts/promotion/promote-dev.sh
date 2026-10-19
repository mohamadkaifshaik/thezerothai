#!/usr/bin/env bash
# Tag-gated, fail-closed promotion of the dev Cloud Run service. Called by .github/workflows/deploy-dev.yml.
#
# Required env: PROJECT REGION SERVICE IMAGE (built image, pinned by @sha256 digest) REPO (Artifact Registry
#   <host>/<project>/<repo>/<image>, no tag) DRY_RUN (true|false). Optional: CEILING (default flag-ceiling.json),
#   SOAK_SECONDS (default 120), SOAK_INTERVAL (default 15), CHECK_INDEXES (default true).
# Exit codes: 0 promoted (or dry run completed with traffic untouched), 1 refused or failed (after an attempted rollback
# when traffic had already moved), 2 usage.
#
# Order: validate serving state -> deploy a 0% `candidate` -> validate it (traffic shape, ceiling, digest) -> smoke ->
# [dry run stops here and removes the tag] -> tag the previously serving image/revision `last-good` -> promote ->
# re-assert state -> soak -> on any failure roll back to `last-good` only. Never prints revision JSON (allowlist uids).
# Verified against the live dev service: GET /health and an unauthenticated GetMe (HTTP 401) behave as probed below.
# NOT verified on Google's side: whether `--no-traffic`/`update-traffic` keep other tags; every operation is re-asserted.
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
env=dev
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

step() { echo "== $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
svc_json() { gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format=json | tr -d '\r' >"$1"; }
rev_json() { gcloud run revisions describe "$2" --project="$PROJECT" --region="$REGION" --format=json | tr -d '\r' >"$1"; }
traffic() { gcloud run services update-traffic "$SERVICE" --project="$PROJECT" --region="$REGION" --quiet "$@" >/dev/null; }
check() { bash "$here/check-traffic.sh" "$@" >"$work/check.out" 2>&1 || { cat "$work/check.out" >&2; return 1; }; }
tag_revision() { jqr --arg t "$2" '[.status.traffic[] | select(.tag == $t)] | first | .revisionName // empty' "$1"; }
tag_url() { jqr --arg t "$2" '[.status.traffic[] | select(.tag == $t)] | first | .url // empty' "$1"; }

# Smoke: /health must be 200 and an unauthenticated GetMe must be refused with 401 (proves auth is enforced).
smoke() {
  local url=$1 code
  curl -fsS --retry 5 --retry-delay 3 --retry-all-errors --max-time 15 "$url/health" >/dev/null || { echo "health failed at $url" >&2; return 1; }
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST -H 'content-type: application/json' -d '{}' \
    "$url/dzeroth.identity.v1.IdentityService/GetMe") || true
  [ "$code" = "401" ] || { echo "unauthenticated GetMe returned '$code', expected 401" >&2; return 1; }
}

rollback() {
  step "ROLLBACK to the last-good revision"
  local s r target
  s=$work/rb-svc.json
  svc_json "$s"
  target=$(tag_revision "$s" last-good)
  [ -n "$target" ] || die "no last-good tag; cannot roll back automatically. Serving state needs manual review"
  rev_json "$work/rb-rev.json" "$target"
  gcloud artifacts docker images list "$REPO" --include-tags --format=json | tr -d '\r' >"$work/rb-images.json"
  r=$(bash "$here/resolve-rollback.sh" "$s" "$work/rb-rev.json" "$work/rb-images.json" "$ceil" "$env") || die "rollback target failed validation; manual review"
  traffic --to-revisions="$r=100"
  svc_json "$s"
  check "$s" "$ceil" "$env" serving || die "state after rollback is not the expected shape"
  [ "$(jqr '[.status.traffic[] | select((.percent // 0) == 100)] | first | .revisionName' "$s")" = "$r" ] || die "rollback did not land on $r"
  echo "rolled back to $r"
}

step "1/8 validate the serving state"
svc_json "$work/s0.json"
check "$work/s0.json" "$ceil" "$env" serving || die "serving state is not what the policy expects; refusing to deploy"
prev=$(jqr '[.status.traffic[] | select((.percent // 0) == 100)] | first | .revisionName' "$work/s0.json")
rev_json "$work/prev.json" "$prev"
bash "$here/validate-revision.sh" "$work/prev.json" "$ceil" "$env" >/dev/null || die "serving revision $prev fails the flag/scaling ceiling"
prev_image=$(jqr '.spec.containers[0].image' "$work/prev.json")
case $prev_image in *@sha256:*) ;; *) die "serving revision image is not pinned by digest" ;; esac

step "2/8 deploy a 0% candidate"
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
smoke "$(tag_url "$work/s1.json" candidate)" || die "candidate smoke failed"
if [ "$check_indexes" = "true" ]; then
  gcloud firestore indexes composite list --project="$PROJECT" --format=json | tr -d '\r' >"$work/indexes.json" || die "cannot list Firestore indexes with this identity"
  [ "$(jqr '[.[] | select(.state != "READY")] | length' "$work/indexes.json")" = "0" ] || die "a Firestore index is not READY"
fi

if [ "$DRY_RUN" = "true" ]; then
  step "dry run: removing the candidate tag, traffic never moved"
  traffic --remove-tags=candidate
  svc_json "$work/s2.json"
  check "$work/s2.json" "$ceil" "$env" serving || die "state after the dry run is unexpected"
  [ "$(jqr '[.status.traffic[] | select((.percent // 0) == 100)] | first | .revisionName' "$work/s2.json")" = "$prev" ] || die "serving revision changed during a dry run"
  echo "dry run ok: candidate $cand validated and smoked; serving still $prev"
  exit 0
fi

step "5/8 record the previously serving revision as last-good"
prev_digest=sha256:${prev_image##*@sha256:}
gcloud artifacts docker tags add "$REPO@$prev_digest" "$REPO:last-good" --quiet >/dev/null 2>&1 \
  || { gcloud artifacts docker tags delete "$REPO:last-good" --quiet >/dev/null 2>&1 || true; gcloud artifacts docker tags add "$REPO@$prev_digest" "$REPO:last-good" --quiet >/dev/null; }
traffic --update-tags="last-good=$prev"
svc_json "$work/s3.json"
[ "$(tag_revision "$work/s3.json" last-good)" = "$prev" ] || die "last-good traffic tag is not on $prev"
gcloud artifacts docker images list "$REPO" --include-tags --format=json | tr -d '\r' >"$work/images.json"
[ "$(jqr --arg d "$prev_digest" '[.[] | select(.version == $d and (.tags | index("last-good")))] | length' "$work/images.json")" = "1" ] || die "last-good is not on the previous image in Artifact Registry"

step "6/8 promote $cand"
traffic --to-revisions="$cand=100"
svc_json "$work/s4.json"
# Tags may or may not survive update-traffic (unverified); repair last-good once, then require it.
if [ -z "$(tag_revision "$work/s4.json" last-good)" ]; then
  traffic --update-tags="last-good=$prev"
  svc_json "$work/s4.json"
fi
if ! check "$work/s4.json" "$ceil" "$env" serving || [ "$(tag_revision "$work/s4.json" last-good)" != "$prev" ] \
  || [ "$(jqr '[.status.traffic[] | select((.percent // 0) == 100)] | first | .revisionName' "$work/s4.json")" != "$cand" ]; then
  echo "state after promotion is not what was intended" >&2
  rollback
  exit 1
fi

step "7/8 soak ${soak}s on the serving revision"
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

step "8/8 done"
svc_json "$work/s5.json"
check "$work/s5.json" "$ceil" "$env" serving || die "final state check failed"
echo "promoted $cand (last-good = $prev)"
