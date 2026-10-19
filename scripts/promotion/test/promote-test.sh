#!/usr/bin/env bash
# Behavioural tests for promote-dev.sh against a stateful fake gcloud/curl (test/fakebin). No network, no credentials.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
p=$(dirname "$here")
fx=$here/fixtures
export PATH="$here/fakebin:$PATH"
# The fakes must be executable (git on Windows can drop the bit); otherwise PATH would skip them and the REAL gcloud/curl would run.
for f in gcloud curl sleep; do
  [ -x "$here/fakebin/$f" ] || { echo "FAIL: $here/fakebin/$f is not executable; refusing to run against real tools" >&2; exit 2; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0

IMG_NEW='example-docker.pkg.dev/fake-proj/api/api@sha256:3333333333333333333333333333333333333333333333333333333333333333'
export PROJECT=fake-proj REGION=fake-region SERVICE=api REPO=example-docker.pkg.dev/fake-proj/api/api
export SOAK_SECONDS=30 SOAK_INTERVAL=15 CHECK_INDEXES=true

# setup: fresh state. api-00001-aaa serves (image 1111...), api-00000-zzz holds last-good, all indexes READY.
setup() {
  export FAKE=$tmp/state
  rm -rf "$FAKE"
  mkdir -p "$FAKE"
  jq '.metadata.name="api-00001-aaa"' "$fx/revision-ok.json" >"$FAKE/rev-api-00001-aaa.json"
  jq '.metadata.name="api-00000-zzz"' "$fx/revision-ok.json" >"$FAKE/rev-api-00000-zzz.json"
  cp "$fx/service-ok.json" "$FAKE/service.json"
  jq '. + [{"package":"example-docker.pkg.dev/fake-proj/api/api","version":"sha256:3333333333333333333333333333333333333333333333333333333333333333","tags":["newbuild"]}]
      | map(if .version|test("^sha256:1111") then .tags += ["last-good"] else . end)' "$fx/images-ok.json" >"$FAKE/images.json"
  echo '[{"name":"i1","state":"READY"},{"name":"i2","state":"READY"}]' >"$FAKE/indexes.json"
  : >"$FAKE/calls.log"
}
serving() { jq -r '[.status.traffic[] | select((.percent // 0) == 100)] | first | .revisionName' "$FAKE/service.json" | tr -d '\r'; }
tagrev() { jq -r --arg t "$1" '[.status.traffic[] | select(.tag == $t)] | first | .revisionName // "none"' "$FAKE/service.json" | tr -d '\r'; }
ran() { grep -q -- "$1" "$FAKE/calls.log"; }

# check <name> <condition...>: records a pass/fail from a shell condition
check() {
  local name=$1
  shift
  if "$@"; then pass=$((pass + 1)); else echo "FAIL $name"; failed=$((failed + 1)); fi
}
run() { # run <DRY_RUN> -> sets rc, out
  DRY_RUN=$1 IMAGE=${2:-$IMG_NEW} bash "$p/promote-dev.sh" >"$tmp/out" 2>&1
  rc=$?
}
noleak() { ! grep -q 'fake-uid' "$tmp/out"; }
eq() { [ "$1" = "$2" ]; }

# 1. dry run: validated and smoked, tag removed, traffic never moved
setup; run true
check "dry run exits 0" eq "$rc" 0
check "dry run: serving unchanged" eq "$(serving)" api-00001-aaa
check "dry run: candidate tag removed" eq "$(tagrev candidate)" none
check "dry run: never touched traffic" bash -c '! grep -q -- "--to-revisions" "$0"' "$FAKE/calls.log"
check "dry run: no uid leak" noleak
check "dry run: never tags last-good (AR or traffic)" bash -c '! grep -qE "tags add|tags delete|--update-tags" "$0"' "$FAKE/calls.log"

# 2. dry run refuses when the candidate smoke fails
setup; touch "$FAKE/health-fail"; run true
check "smoke failure fails" eq "$rc" 1
check "smoke failure: serving unchanged" eq "$(serving)" api-00001-aaa
check "smoke failure: candidate tag removed" eq "$(tagrev candidate)" none

# 3. unauthenticated probe answered 200 means auth is open: refuse
setup; echo 200 >"$FAKE/probe-code"; run false
check "open auth refused" eq "$rc" 1
check "open auth: serving unchanged" eq "$(serving)" api-00001-aaa

# 4. candidate over the flag ceiling is refused before smoke or promotion
setup; touch "$FAKE/candidate-engagement-on"; run false
check "ceiling violation refused" eq "$rc" 1
check "ceiling violation: serving unchanged" eq "$(serving)" api-00001-aaa
check "ceiling violation: candidate tag removed" eq "$(tagrev candidate)" none
check "ceiling violation: no promotion call" bash -c '! grep -q -- "--to-revisions" "$0"' "$FAKE/calls.log"

# 5. an index that is not READY blocks promotion
setup; echo '[{"name":"i1","state":"CREATING"}]' >"$FAKE/indexes.json"; run false
check "index not ready refused" eq "$rc" 1
check "index not ready: serving unchanged" eq "$(serving)" api-00001-aaa

# 6. surprise in the serving state (unexpected tag): fail before deploying anything
setup; jq '.status.traffic[0].tag = "surprise"' "$FAKE/service.json" >"$tmp/s" && cp "$tmp/s" "$FAKE/service.json"; run false
check "surprise tag refused" eq "$rc" 1
check "surprise tag: nothing deployed" bash -c '! grep -q "run deploy" "$0"' "$FAKE/calls.log"

# 7. full promotion: serving moves, last-good = previous revision AND previous image
setup; run false
check "promotion exits 0" eq "$rc" 0
check "promotion: serving is the candidate" eq "$(serving)" api-00002-new
check "promotion: last-good traffic tag on previous" eq "$(tagrev last-good)" api-00001-aaa
check "promotion: last-good AR tag on previous image" eq "$(jq -r '[.[] | select(.tags | index("last-good"))] | map(.version[0:12]) | join(",")' "$FAKE/images.json" | tr -d '\r')" sha256:11111
check "promotion: no uid leak" noleak

# 7b. the previous image is gone from Artifact Registry: refuse BEFORE deploying anything or touching any tag
setup; jq 'map(select(.version | test("^sha256:1111") | not))' "$FAKE/images.json" >"$tmp/i" && cp "$tmp/i" "$FAKE/images.json"; run false
check "missing rollback image refused" eq "$rc" 1
check "missing rollback image: serving unchanged" eq "$(serving)" api-00001-aaa
check "missing rollback image: existing last-good untouched" eq "$(tagrev last-good)" api-00000-zzz
check "missing rollback image: nothing deployed" bash -c '! grep -q "run deploy" "$0"' "$FAKE/calls.log"

# 7c. AR tag add fails (not an "already exists" error): nothing changes, no tag is deleted, no promotion
setup; touch "$FAKE/tags-add-fail"; run false
check "tag add failure refused" eq "$rc" 1
check "tag add failure: last-good untouched" eq "$(tagrev last-good)" api-00000-zzz
check "tag add failure: serving unchanged" eq "$(serving)" api-00001-aaa
check "tag add failure: no tag deleted, no promotion" bash -c '! grep -qE "tags delete|--to-revisions" "$0"' "$FAKE/calls.log"
check "tag add failure: candidate tag removed" eq "$(tagrev candidate)" none

# 7d. an "already exists" error is handled by delete + add and the run succeeds
setup; touch "$FAKE/tags-add-exists-once"; run false
check "existing last-good tag moved" eq "$rc" 0
check "existing last-good tag: on the previous image" eq "$(jq -r '[.[] | select(.tags | index("last-good"))] | map(.version[0:12]) | join(",")' "$FAKE/images.json" | tr -d '')" sha256:11111

# 8. update-traffic dropping the last-good tag is repaired, not ignored
setup; touch "$FAKE/drop-last-good-on-promote"; run false
check "tag loss repaired" eq "$rc" 0
check "tag loss: last-good restored" eq "$(tagrev last-good)" api-00001-aaa

# 9. failure after promotion rolls back to last-good and still fails the run
setup; echo api-00002-new >"$FAKE/health-fail-when-serving"; run false
check "post-promotion failure exits 1" eq "$rc" 1
check "post-promotion failure: rolled back" eq "$(serving)" api-00001-aaa
check "post-promotion failure: rollback message" grep -q "rolled back to api-00001-aaa" "$tmp/out"

# 9b. update-traffic applies the change and then errors (set -e path): must still roll back
setup; touch "$FAKE/fail-after-promote-apply"; run false
check "failure after traffic moved exits 1" eq "$rc" 1
check "failure after traffic moved: rolled back" eq "$(serving)" api-00001-aaa

# 9c. the job is cancelled (SIGTERM) during the soak: the exit trap rolls back
setup; touch "$FAKE/term-on-sleep"; run false
check "cancellation exits non-zero" bash -c '[ "$0" != 0 ]' "$rc"
check "cancellation: rolled back" eq "$(serving)" api-00001-aaa
check "cancellation: last-good still on the previous revision" eq "$(tagrev last-good)" api-00001-aaa

# 10. usage errors
setup; DRY_RUN=true IMAGE='example/api:latest' bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "tag-pinned image is a usage error" eq "$rc" 2
setup; DRY_RUN=maybe IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "bad DRY_RUN is a usage error" eq "$rc" 2

setup; SOAK_SECONDS=abc DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "non-numeric SOAK_SECONDS is a usage error" eq "$rc" 2
setup; SOAK_INTERVAL=0 DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "SOAK_INTERVAL=0 is a usage error" eq "$rc" 2

echo "promote-dev tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
