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
[ -x "$here/fakebin-smoke/curl" ] || { echo "FAIL: $here/fakebin-smoke/curl is not executable; refusing to run against real tools" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0

IMG_NEW='example-docker.pkg.dev/fake-proj/api/api@sha256:3333333333333333333333333333333333333333333333333333333333333333'
export PROJECT=fake-proj REGION=fake-region SERVICE=api REPO=example-docker.pkg.dev/fake-proj/api/api
export PROMOTE_MARKER=$tmp/marker
export SOAK_SECONDS=30 SOAK_INTERVAL=15 CHECK_INDEXES=true
# The authenticated smoke runs in every test below (promote mode fails closed without secrets). Made-up values, easy to grep for.
SMOKE_EMAIL_V='smoke.dev@example.invalid'
SMOKE_PASSWORD_V='FAKE-DEV-PW-xyz'
TOKEN_V='FAKE-ID-TOKEN-xyz'
export SMOKE_EMAIL=$SMOKE_EMAIL_V SMOKE_PASSWORD=$SMOKE_PASSWORD_V FIREBASE_API_KEY=FAKE-DEV-KEY-123

# setup: fresh state. api-00001-aaa serves (image 1111...), api-00000-zzz holds last-good, all indexes READY.
setup() {
  export FAKE=$tmp/state
  rm -rf "$FAKE" "$PROMOTE_MARKER"
  mkdir -p "$FAKE"
  jq '.metadata.name="api-00001-aaa"' "$fx/revision-ok.json" >"$FAKE/rev-api-00001-aaa.json"
  jq '.metadata.name="api-00000-zzz"' "$fx/revision-ok.json" >"$FAKE/rev-api-00000-zzz.json"
  cp "$fx/service-ok.json" "$FAKE/service.json"
  jq '. + [{"package":"example-docker.pkg.dev/fake-proj/api/api","version":"sha256:3333333333333333333333333333333333333333333333333333333333333333","tags":["newbuild"]}]
      | map(if .version|test("^sha256:1111") then .tags += ["last-good", "serving"] else . end)' "$fx/images-ok.json" >"$FAKE/images.json"
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
check "dry run: never touches the serving tag" bash -c '! grep -q ":serving" "$0"' "$FAKE/calls.log"
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
check "promotion: serving tag moved to the new image only" eq "$(jq -r '[.[] | select(.tags | index("serving"))] | map(.version[0:12]) | join(",")' "$FAKE/images.json" | tr -d $'')" sha256:33333
check "promotion: marker cleared after verification" bash -c '[ ! -e "$0" ]' "$PROMOTE_MARKER"

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

# 7d. last-good already sits on a DIFFERENT image: tags add moves it (docs), no delete is ever issued
setup; jq 'map(.tags |= map(select(. != "last-good"))) | map(if (.version|test("^sha256:2222")) then .tags += ["last-good"] else . end)' "$FAKE/images.json" >"$tmp/i" && cp "$tmp/i" "$FAKE/images.json"; run false
check "tag move: run succeeds" eq "$rc" 0
check "tag move: last-good now only on the previous image" eq "$(jq -r '[.[] | select(.tags | index("last-good"))] | map(.version[0:12]) | join(",")' "$FAKE/images.json" | tr -d $'')" sha256:11111
check "tag move: no tags delete issued" bash -c '! grep -q "tags delete" "$0"' "$FAKE/calls.log"

# 7e. the serving tag cannot be moved after a verified promotion: warn, do not roll back
setup; touch "$FAKE/tag-fail-serving"; run false
check "serving tag failure does not fail a verified promotion" eq "$rc" 0
check "serving tag failure: still promoted" eq "$(serving)" api-00002-new
check "serving tag failure: loud warning" grep -q "could not move the serving tag" "$tmp/out"
check "serving tag failure: marker cleared" bash -c '[ ! -e "$0" ]' "$PROMOTE_MARKER"

# 7f. the serving image lost its serving tag: promote mode re-tags it before deploying (self-heal), and it ends on the new image
setup; jq 'map(.tags |= map(select(. != "serving")))' "$FAKE/images.json" >"$tmp/i" && cp "$tmp/i" "$FAKE/images.json"; run false
check "self-heal run succeeds" eq "$rc" 0
check "self-heal: announced" grep -q "has no serving tag" "$tmp/out"
check "self-heal: serving tag ends on the new image" eq "$(jq -r '[.[] | select(.tags | index("serving"))] | map(.version[0:12]) | join(",")' "$FAKE/images.json" | tr -d $'')" sha256:33333

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

# 9d. update-traffic fails BEFORE applying (status may still look unchanged): rollback must still re-issue the idempotent command
setup; touch "$FAKE/fail-before-promote-apply"; run false
check "failure before apply exits 1" eq "$rc" 1
check "failure before apply: serving is the previous revision" eq "$(serving)" api-00001-aaa
check "failure before apply: rollback re-issued the traffic command" grep -q -- "--to-revisions=api-00001-aaa=100" "$FAKE/calls.log"
check "failure before apply: marker cleared" bash -c '[ ! -e "$0" ]' "$PROMOTE_MARKER"

# 9e. the script is SIGKILLed during the soak (runner gave up waiting): no trap runs, the marker survives, and the workflow's
# always() recover step rolls back
setup; touch "$FAKE/kill9-on-sleep"; run false
check "kill -9: run did not finish" bash -c '[ "$0" != 0 ]' "$rc"
check "kill -9: unverified candidate is serving" eq "$(serving)" api-00002-new
check "kill -9: marker survived" bash -c '[ -e "$0" ]' "$PROMOTE_MARKER"
rm -f "$FAKE/kill9-on-sleep"
RECOVER=true bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "recover exits 0" eq "$rc" 0
check "recover: rolled back to last-good" eq "$(serving)" api-00001-aaa
check "recover: marker cleared" bash -c '[ ! -e "$0" ]' "$PROMOTE_MARKER"
check "recover: no uid leak" noleak

# 9f. recover with no marker does nothing at all (no cloud calls)
setup; RECOVER=true bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "recover without marker exits 0" eq "$rc" 0
check "recover without marker: no cloud call" bash -c '[ ! -s "$0" ]' "$FAKE/calls.log"

# 10. usage errors
setup; DRY_RUN=true IMAGE='example/api:latest' bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "tag-pinned image is a usage error" eq "$rc" 2
setup; DRY_RUN=maybe IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "bad DRY_RUN is a usage error" eq "$rc" 2

setup; SOAK_SECONDS=abc DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "non-numeric SOAK_SECONDS is a usage error" eq "$rc" 2
setup; SOAK_INTERVAL=0 DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "SOAK_INTERVAL=0 is a usage error" eq "$rc" 2
setup; SOAK_INTERVAL=08 SOAK_SECONDS=30 DRY_RUN=false IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "SOAK_INTERVAL=08 is not read as octal (real soak runs)" eq "$rc" 0
setup; env -u PROMOTE_MARKER DRY_RUN=false IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "promoting without PROMOTE_MARKER is a usage error" eq "$rc" 2
check "promoting without PROMOTE_MARKER: nothing was touched" bash -c '[ ! -s "$0" ]' "$FAKE/calls.log"
setup; env PATH="/usr/bin:/bin" RECOVER=true PROMOTE_MARKER="$tmp/none" PROJECT=p REGION=r SERVICE=s REPO=x bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "recover with no marker does not need any tool" eq "$rc" 0

# 11. authenticated smoke (step 4b)
signins() { cat "$FAKE/argv.log" 2>/dev/null | grep -c 'signInWithPassword' || true; }
nosecrets() { env -u SMOKE_EMAIL -u SMOKE_PASSWORD "$@"; }
out_line() { grep -n -m1 -F -- "$1" "$tmp/out" | cut -d: -f1; }
no_traffic_change() { ! grep -qE -- '--to-revisions|--update-tags|tags add' "$FAKE/calls.log"; }

# (a) secrets present and the smoke passes: the run promotes as before, and signs in exactly once
setup; run false
check "auth smoke pass: promotes" eq "$rc" 0
check "auth smoke pass: serving is the candidate" eq "$(serving)" api-00002-new
check "auth smoke pass: step announced" grep -q '4b/8 authenticated smoke' "$tmp/out"
check "auth smoke pass: PASS line" grep -q 'authenticated smoke: PASS' "$tmp/out"
# (e) the soak makes no sign-in call: exactly the two smokes sign in (authenticated smoke: 4 curl calls; bookmarks smoke: 3) in a run that soaked
check "soak ran" grep -q '7/8 soak' "$tmp/out"
check "no sign-in during the soak (exactly two sign-ins in the whole run: authenticated smoke + bookmarks smoke)" eq "$(signins)" 2
check "authenticated smoke ran once (4 calls: sign-in, 401, GetMe, GetProfile) and the bookmarks smoke once (3 calls: sign-in, ListBookmarks, AddBookmark)" eq "$(cat "$FAKE/calls")" 7
check "bookmarks smoke ran after the authenticated smoke" test "$(out_line 'authenticated smoke: PASS')" -lt "$(out_line 'bookmarks smoke: PASS')"
check "bookmarks smoke pass: PASS line" grep -q 'bookmarks smoke: PASS' "$tmp/out"
# the dev Referer and the given API key reach the sign-in call
check "sign-in carries the dev Referer" grep -qxF 'Referer: https://dzeroth-dev.web.app/' "$FAKE/argv.1"
check "sign-in uses the given API key" grep -q 'key=FAKE-DEV-KEY-123' "$FAKE/argv.1"
# the bookmarks smoke is the second sign-in (call 5: the authenticated smoke made calls 1-4) with the same Referer and key
check "bookmarks smoke sign-in carries the dev Referer" grep -qxF 'Referer: https://dzeroth-dev.web.app/' "$FAKE/argv.5"
check "bookmarks smoke sign-in uses the given API key" grep -q 'key=FAKE-DEV-KEY-123' "$FAKE/argv.5"
check "bookmarks smoke calls the same candidate URL as the authenticated smoke" bash -c 'a=$(tail -n 1 "$0" | sed "s|/dzeroth.[^ ]*$||"); b=$(tail -n 1 "$1" | sed "s|/dzeroth.[^ ]*$||"); [ -n "$a" ] && [ "$a" = "$b" ]' "$FAKE/argv.3" "$FAKE/argv.6"
# (f) secrecy
for sec in "$SMOKE_EMAIL_V" "$SMOKE_PASSWORD_V" "$TOKEN_V"; do
  # Under GITHUB_ACTIONS=true the smoke prints exactly one `::add-mask::<token>` line (it is what keeps the token out of the log).
  check "auth smoke: output has no $sec" bash -c '! grep -v "^::add-mask::" "$1" | grep -qF -- "$0"' "$sec" "$tmp/out"
  check "auth smoke: no recorded argv has $sec" bash -c '! grep -qF -- "$0" "$1" "$2"' "$sec" "$FAKE/argv.log" "$FAKE/calls.log"
done
check "auth smoke: the password did reach curl on stdin (the checks above are not vacuous)" grep -qF "$SMOKE_PASSWORD_V" "$FAKE/stdin.1"

# the same on a dry run (it also signs in: step 4b is before the dry-run exit)
setup; run true
check "auth smoke dry run: completes" eq "$rc" 0
check "auth smoke dry run: PASS line" grep -q 'authenticated smoke: PASS' "$tmp/out"
check "auth smoke dry run: two sign-ins (authenticated smoke + bookmarks smoke)" eq "$(signins)" 2
check "auth smoke dry run: traffic untouched" no_traffic_change

# (b) the smoke fails: handled like a failed step 4 (die before anything moves, candidate tag removed)
setup; echo 400 >"$FAKE/signin-code"; run false
check "auth smoke failure fails the run" eq "$rc" 1
check "auth smoke failure: named" grep -q 'FAIL: authenticated smoke failed' "$tmp/out"
check "auth smoke failure: FAIL line from the smoke" grep -q 'authenticated smoke: FAIL at sign-in' "$tmp/out"
check "auth smoke failure: serving unchanged" eq "$(serving)" api-00001-aaa
check "auth smoke failure: no traffic change, no last-good tagging" no_traffic_change
check "auth smoke failure: last-good untouched" eq "$(tagrev last-good)" api-00000-zzz
check "auth smoke failure: candidate tag removed (same cleanup as step 4)" eq "$(tagrev candidate)" none
check "auth smoke failure: marker never written" bash -c '[ ! -e "$0" ]' "$PROMOTE_MARKER"
check "auth smoke failure: nothing secret printed" bash -c '! grep -qF -e "$0" -e "$1" "$2"' "$SMOKE_PASSWORD_V" "$SMOKE_EMAIL_V" "$tmp/out"
setup; echo 200 >"$FAKE/getme-unauth-code"; run false
check "auth not enforced (unauthenticated GetMe 200) fails the run" eq "$rc" 1
check "auth not enforced: no traffic change" no_traffic_change
setup; echo 403 >"$FAKE/signin-code"; run true
check "auth smoke failure also fails a dry run" eq "$rc" 1
check "auth smoke failure (dry run): candidate tag removed" eq "$(tagrev candidate)" none

# (g) the dev-only bookmarks smoke (step 4b, right after the authenticated smoke): a failure is handled exactly like a failed smoke
setup; echo 500 >"$FAKE/listbm-code"; run false
check "bookmarks smoke failure fails the run" eq "$rc" 1
check "bookmarks smoke failure: named" grep -q 'FAIL: bookmarks smoke failed' "$tmp/out"
check "bookmarks smoke failure: FAIL line from the smoke" grep -q 'bookmarks smoke: FAIL at list-bookmarks' "$tmp/out"
check "bookmarks smoke failure: the authenticated smoke had passed first" grep -q 'authenticated smoke: PASS' "$tmp/out"
check "bookmarks smoke failure: serving unchanged" eq "$(serving)" api-00001-aaa
check "bookmarks smoke failure: no traffic change, no last-good tagging" no_traffic_change
check "bookmarks smoke failure: last-good untouched" eq "$(tagrev last-good)" api-00000-zzz
check "bookmarks smoke failure: candidate tag removed" eq "$(tagrev candidate)" none
check "bookmarks smoke failure: marker never written" bash -c '[ ! -e "$0" ]' "$PROMOTE_MARKER"
check "bookmarks smoke failure: nothing secret printed" bash -c '! grep -qF -e "$0" -e "$1" "$2"' "$SMOKE_PASSWORD_V" "$SMOKE_EMAIL_V" "$tmp/out"
# strict (any mismatch fails the promotion): the flag globally off (List 400) and a write that went through (Add 200)
setup; echo 400 >"$FAKE/listbm-code"; run false
check "flag off (List 400): the run fails, it does not promote" eq "$rc" 1
check "flag off (List 400): FAIL line names the step" grep -q 'bookmarks smoke: FAIL at list-bookmarks' "$tmp/out"
check "flag off (List 400): no traffic change" no_traffic_change
setup; echo 200 >"$FAKE/addbm-code"; run false
check "Add 200 (allowlisted by mistake): the run fails" eq "$rc" 1
check "Add 200: FAIL at add-bookmark" grep -q 'bookmarks smoke: FAIL at add-bookmark' "$tmp/out"
check "Add 200: serving unchanged, candidate tag removed" bash -c '[ "$0" = api-00001-aaa ] && [ "$1" = none ]' "$(serving)" "$(tagrev candidate)"
setup; echo 500 >"$FAKE/addbm-code"; run true
check "bookmarks smoke failure also fails a dry run" eq "$rc" 1
check "bookmarks smoke failure (dry run): candidate tag removed" eq "$(tagrev candidate)" none
setup; echo 400 >"$FAKE/signin-code"; run false
check "a failed authenticated smoke never reaches the bookmarks smoke" bash -c '! grep -q "bookmarks smoke" "$0"' "$tmp/out"

# (c) no secrets, dry run: skipped with a notice, the dry run completes
setup; nosecrets env DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "no secrets, dry run: completes" eq "$rc" 0
check "no secrets, dry run: skipped with a notice" grep -q 'authenticated smoke SKIPPED: the smoke secrets are unavailable' "$tmp/out"
check "no secrets, dry run: the notice names the dev-only bookmarks smoke too" grep -q 'dev-only bookmarks smoke is skipped' "$tmp/out"check "no secrets, dry run: the bookmarks smoke did not run" bash -c '! grep -q "bookmarks smoke:" "$0"' "$tmp/out"
check "no secrets, dry run: no sign-in attempted" eq "$(signins)" 0
check "no secrets, dry run: traffic untouched" no_traffic_change
check "no secrets, dry run: candidate tag removed" eq "$(tagrev candidate)" none
setup; SMOKE_PASSWORD='' env DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "empty password, dry run: skipped" grep -q 'authenticated smoke SKIPPED' "$tmp/out"

# (d) no secrets, promote mode: fails closed, traffic untouched
setup; nosecrets env DRY_RUN=false IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "no secrets, promote: fails closed" eq "$rc" 1
check "no secrets, promote: says why" grep -q 'authenticated smoke is required when promoting: SMOKE_\* secrets are missing' "$tmp/out"
check "no secrets, promote: the bookmarks smoke did not run" bash -c '! grep -q "bookmarks smoke:" "$0"' "$tmp/out"
check "no secrets, promote: serving unchanged" eq "$(serving)" api-00001-aaa
check "no secrets, promote: no traffic change, no last-good tagging" no_traffic_change
check "no secrets, promote: candidate tag removed" eq "$(tagrev candidate)" none
check "no secrets, promote: no sign-in attempted" eq "$(signins)" 0
setup; SMOKE_EMAIL='' env DRY_RUN=false IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "empty email, promote: fails closed" eq "$rc" 1

# the API key (web block of the options file) and Referer defaults; SMOKE_REFERER is overridable
setup; env -u FIREBASE_API_KEY FIREBASE_OPTIONS_FILE="$fx/firebase-options-prod.dart.txt" DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "API key derived from the options file: run passes" eq "$rc" 0
check "API key derived from the web block" grep -q 'key=FAKE-WEB-KEY' "$FAKE/argv.1"
setup; env -u FIREBASE_API_KEY FIREBASE_OPTIONS_FILE="$tmp/missing.dart" DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "unreadable options file fails" eq "$rc" 1
check "unreadable options file: candidate tag removed" eq "$(tagrev candidate)" none
setup; SMOKE_REFERER=https://dev.dzeroth.com/ DRY_RUN=true IMAGE=$IMG_NEW bash "$p/promote-dev.sh" >"$tmp/out" 2>&1; rc=$?
check "SMOKE_REFERER override is honoured" grep -qxF 'Referer: https://dev.dzeroth.com/' "$FAKE/argv.1"

echo "promote-dev tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
