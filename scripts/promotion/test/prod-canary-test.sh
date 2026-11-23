#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export RUNNER_TEMP="$work" FAKE="$work" GITHUB_STEP_SUMMARY="$work/summary"
export GITHUB_SHA=abc GITHUB_REF=refs/tags/v1 GITHUB_RUN_ID=123
export SERVICE=api PROJECT=demo REGION=local REVISION=new DIGEST=sha256:abc
export SMOKE_EMAIL=test@example.invalid SMOKE_PASSWORD=fixture FIREBASE_API_KEY=fixture
export PATH="$work:$here/fakebin-smoke:$PATH"
[[ -x "$here/fakebin-smoke/curl" ]]
printf '%s\n' '#!/usr/bin/env bash' 'cat "$FAKE/traffic"' > "$work/gcloud"
chmod +x "$work/gcloud"
gate() { bash "$here/../prod-canary.sh" "$@"; }
reject() { if gate "$1" >/dev/null 2>&1; then echo "unexpected success: $2" >&2; exit 1; fi; }
traffic() {
  jq -n --argjson p "$1" '{status:{traffic:[
    {revisionName:"old",percent:(100-$p)},
    {revisionName:"new",tag:"candidate",url:"https://candidate---api.run.app",percent:$p}]}}' > "$work/traffic"
}
age() {
  jq --argjson age "$1" '.started=(now-$age)' "$work/canary.json" > "$work/time"
  mv "$work/time" "$work/canary.json"
}
traffic 0
reject verify skipped
gate capture
reject record missing-split
traffic 10
echo 403 > "$work/signin-code"
reject record failed-smoke
echo 200 > "$work/signin-code"
gate record
reject verify fresh
age 90000
reject verify stale
age 1000
DIGEST=changed reject verify changed-digest
REVISION=changed reject verify changed-revision
traffic 0
reject verify rolled-back
traffic 10
echo 403 > "$work/getprofile-code"
reject verify failed-read
echo 200 > "$work/getprofile-code"
gate verify
traffic 100
gate verify
echo "Production canary fixtures passed"
