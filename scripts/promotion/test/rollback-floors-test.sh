#!/usr/bin/env bash
# Fixture tests for rollback floors in resolve-rollback.sh, and for the floor schema check in check-flag-registry.sh.
# Run by test/run.sh. No network, no credentials: a throwaway git repo holds a commit before, at and after the floor, and
# every ceiling is built here from the committed one with its own floors, so the committed floors never decide a case.
#   part 1  a plain floor (no "sticky") in every flag mode: today's behaviour, pinned
#   part 2  "sticky": false is the same as no "sticky"
#   part 3  "sticky": true applies whatever the flag's mode is (Plan 6 Task 7.A, fact F15)
#   part 4  a malformed "sticky" or floor entry refuses in every mode
#   part 5  check-flag-registry.sh refuses a malformed floor at PR time
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
p=$(dirname "$here")
fx=$here/fixtures
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0
R="$p/resolve-rollback.sh"
G="$p/check-flag-registry.sh"
svc=$fx/service-ok.json

# expect <name> <want-exit> <command...>   (stdout+stderr are checked for allowlist uid leaks)
expect() {
  local name=$1 want=$2
  shift 2
  bash "$@" >"$tmp/out" 2>&1
  local rc=$?
  if grep -q 'fake-uid' "$tmp/out"; then
    echo "FAIL $name: output leaked an allowlist uid"
    failed=$((failed + 1))
    return
  fi
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL $name: exit $rc, want $want"
    sed 's/^/    /' "$tmp/out"
    failed=$((failed + 1))
  fi
}
# expect_msg <name> <want-exit> <pattern> <command...>: like expect, and the output must contain the pattern
expect_msg() {
  local name=$1 want=$2 pat=$3
  shift 3
  expect "$name" "$want" "$@"
  if ! grep -q -- "$pat" "$tmp/out"; then
    echo "FAIL $name: output lacks '$pat'"
    sed 's/^/    /' "$tmp/out"
    failed=$((failed + 1))
  fi
}

fr=$tmp/floorrepo
git init -q "$fr" && git -C "$fr" config user.email t@example.invalid && git -C "$fr" config user.name t && git -C "$fr" config commit.gpgsign false
git -C "$fr" commit -q --allow-empty -m before && c_before=$(git -C "$fr" rev-parse HEAD)
git -C "$fr" commit -q --allow-empty -m floor && c_floor=$(git -C "$fr" rev-parse HEAD)
git -C "$fr" commit -q --allow-empty -m after && c_after=$(git -C "$fr" rev-parse HEAD)
git -C "$fr" checkout -q -b side "$c_before" && git -C "$fr" commit -q --allow-empty -m sideways && c_side=$(git -C "$fr" rev-parse HEAD)
git -C "$fr" checkout -q - 2>/dev/null
export ROLLBACK_REPO=$fr

# Ceilings: one PRIVATE_ACCOUNTS floor at c_floor, with the dev ceiling raised so percent and on are legal on the target.
# The flag list is cut to the flags the fixture revision sets plus the two floor flags: validate-revision.sh (the last
# step of every passing rollback) spawns jq per listed flag, which takes minutes per case on Windows with the full list.
base='.flags = ["ACCOUNT_LIFECYCLE", "GRAPH", "LOCATION", "NOTIFICATIONS", "POSTS", "PRIVATE_ACCOUNTS", "REMOVED_IDS", "REPORTS"]
  | .envs.dev.flags.PRIVATE_ACCOUNTS = {"mode": "on", "max_allowlist": 6, "max_percent": 100}'
jq --arg c "$c_floor" "$base"' | .rollback_floors = {"_comment": "test", "PRIVATE_ACCOUNTS": {"commit": $c, "pr": 1, "reason": "test"}}' "$p/flag-ceiling.json" | tr -d '\r' >"$tmp/ceil-plain"
# sticky_ceil <out-name> <json value>: the same ceiling with "sticky" set to that JSON value
sticky_ceil() { jq --argjson s "$2" '.rollback_floors.PRIVATE_ACCOUNTS.sticky = $s' "$tmp/ceil-plain" | tr -d '\r' >"$tmp/$1"; }
sticky_ceil ceil-sticky true
sticky_ceil ceil-sticky-false false

# Rollback targets (last-good is api-00000-zzz), one per flag mode. The allowlist ones carry fake uids: none may be printed.
lg() { jq --argjson e "$2" '.metadata.name = "api-00000-zzz" | .spec.containers[0].env += $e' "$fx/revision-ok.json" | tr -d '\r' >"$tmp/$1"; }
lg lg-unset '[]'
lg lg-off '[{"name":"FEATURE_PRIVATE_ACCOUNTS","value":"off"}]'
lg lg-allowlist '[{"name":"FEATURE_PRIVATE_ACCOUNTS","value":"allowlist"},{"name":"FEATURE_PRIVATE_ACCOUNTS_ALLOWLIST","value":"fake-uid-A,fake-uid-B"}]'
lg lg-percent '[{"name":"FEATURE_PRIVATE_ACCOUNTS","value":"percent"},{"name":"FEATURE_PRIVATE_ACCOUNTS_PERCENT","value":"50"}]'
lg lg-on '[{"name":"FEATURE_PRIVATE_ACCOUNTS","value":"on"},{"name":"FEATURE_PRIVATE_ACCOUNTS_ALLOWLIST","value":"fake-uid-A,fake-uid-B"}]'
# img <out-name> <commit...>: images.json whose last-good digest carries those tags
img() {
  local out=$1
  shift
  jq --argjson t "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '.[0].tags += $t' "$fx/images-ok.json" | tr -d '\r' >"$tmp/$out"
}
img img-before "$c_before"
img img-floor "$c_floor"
img img-after "$c_after"
img img-side "$c_side"
img img-unknown "$(printf '%040d' 7)"
img img-straddle "$c_before" "$c_after"
cp "$fx/images-ok.json" "$tmp/img-notag"

# --- part 1: a plain (non-sticky) floor is unchanged in every mode
for m in off unset; do
  expect_msg "plain floor, flag $m: an older image passes (floor not enforced)" 0 "its rollback floor is not enforced" "$R" "$svc" "$tmp/lg-$m" "$tmp/img-before" "$tmp/ceil-plain" dev
done
expect "plain floor, flag off: an image with no commit tag passes" 0 "$R" "$svc" "$tmp/lg-off" "$tmp/img-notag" "$tmp/ceil-plain" dev
for m in allowlist percent on; do
  expect_msg "plain floor, flag $m: an older image is refused" 1 "older than, or not provably after, the PRIVATE_ACCOUNTS rollback floor ${c_floor:0:8} (flag is $m); roll forward" "$R" "$svc" "$tmp/lg-$m" "$tmp/img-before" "$tmp/ceil-plain" dev
  expect_msg "plain floor, flag $m: an image with no commit tag is refused" 1 "refusing (flag is $m)" "$R" "$svc" "$tmp/lg-$m" "$tmp/img-notag" "$tmp/ceil-plain" dev
done
expect "plain floor, flag allowlist: the image exactly at the floor passes (the floor is inclusive)" 0 "$R" "$svc" "$tmp/lg-allowlist" "$tmp/img-floor" "$tmp/ceil-plain" dev
expect "plain floor, flag on: one commit after the floor passes" 0 "$R" "$svc" "$tmp/lg-on" "$tmp/img-after" "$tmp/ceil-plain" dev
expect "plain floor, flag percent: one commit after the floor passes" 0 "$R" "$svc" "$tmp/lg-percent" "$tmp/img-after" "$tmp/ceil-plain" dev

# --- part 2: sticky false behaves as absent
expect_msg "sticky false, flag off: an older image passes (floor not enforced)" 0 "its rollback floor is not enforced" "$R" "$svc" "$tmp/lg-off" "$tmp/img-before" "$tmp/ceil-sticky-false" dev
expect "sticky false, flag unset: an image with no commit tag passes" 0 "$R" "$svc" "$tmp/lg-unset" "$tmp/img-notag" "$tmp/ceil-sticky-false" dev
expect_msg "sticky false, flag allowlist: an older image is refused, worded as a plain floor" 1 "(flag is allowlist); roll forward" "$R" "$svc" "$tmp/lg-allowlist" "$tmp/img-before" "$tmp/ceil-sticky-false" dev
expect "sticky false, flag allowlist: the image exactly at the floor passes" 0 "$R" "$svc" "$tmp/lg-allowlist" "$tmp/img-floor" "$tmp/ceil-sticky-false" dev

# --- part 3: a sticky floor applies whatever the flag's mode is
expect_msg "a sticky floor refuses an older image with the flag off" 1 "older than, or not provably after, the PRIVATE_ACCOUNTS rollback floor ${c_floor:0:8} (flag is off, sticky floor)" "$R" "$svc" "$tmp/lg-off" "$tmp/img-before" "$tmp/ceil-sticky" dev
expect_msg "a sticky floor refuses an older image with the flag unset (code default off)" 1 "(flag is off, sticky floor)" "$R" "$svc" "$tmp/lg-unset" "$tmp/img-before" "$tmp/ceil-sticky" dev
expect_msg "a sticky floor still refuses with the flag on and allowlisted" 1 "(flag is on, sticky floor)" "$R" "$svc" "$tmp/lg-on" "$tmp/img-before" "$tmp/ceil-sticky" dev
expect_msg "a sticky floor still refuses with the flag in allowlist mode" 1 "(flag is allowlist, sticky floor)" "$R" "$svc" "$tmp/lg-allowlist" "$tmp/img-before" "$tmp/ceil-sticky" dev
expect_msg "a sticky floor still refuses with the flag in percent mode" 1 "(flag is percent, sticky floor)" "$R" "$svc" "$tmp/lg-percent" "$tmp/img-before" "$tmp/ceil-sticky" dev
expect_msg "sticky floor, flag off: an image with no commit tag is refused" 1 "no commit tag" "$R" "$svc" "$tmp/lg-off" "$tmp/img-notag" "$tmp/ceil-sticky" dev
expect_msg "sticky floor, flag off: a commit on another branch is refused" 1 "older than, or not provably after" "$R" "$svc" "$tmp/lg-off" "$tmp/img-side" "$tmp/ceil-sticky" dev
expect_msg "sticky floor, flag off: an image whose commit tag is not in the repo is refused" 1 "older than, or not provably after" "$R" "$svc" "$tmp/lg-off" "$tmp/img-unknown" "$tmp/ceil-sticky" dev
expect_msg "sticky floor, flag off: an image tagged with one commit before and one after the floor is refused" 1 "older than, or not provably after" "$R" "$svc" "$tmp/lg-off" "$tmp/img-straddle" "$tmp/ceil-sticky" dev
expect_msg "sticky floor, flag off: the image exactly at the floor passes (the floor is inclusive)" 0 "its rollback floor is sticky" "$R" "$svc" "$tmp/lg-off" "$tmp/img-floor" "$tmp/ceil-sticky" dev
expect "sticky floor, flag off: one commit after the floor passes" 0 "$R" "$svc" "$tmp/lg-off" "$tmp/img-after" "$tmp/ceil-sticky" dev
expect "sticky floor, flag unset: one commit after the floor passes" 0 "$R" "$svc" "$tmp/lg-unset" "$tmp/img-after" "$tmp/ceil-sticky" dev
expect "sticky floor, flag allowlist: the image exactly at the floor passes" 0 "$R" "$svc" "$tmp/lg-allowlist" "$tmp/img-floor" "$tmp/ceil-sticky" dev
expect "sticky floor, flag on: one commit after the floor passes" 0 "$R" "$svc" "$tmp/lg-on" "$tmp/img-after" "$tmp/ceil-sticky" dev
jq '.rollback_floors.PRIVATE_ACCOUNTS.commit = "abc123"' "$tmp/ceil-sticky" | tr -d '\r' >"$tmp/ceil-sticky-badcommit"
expect_msg "sticky floor, flag off: a malformed floor commit is refused" 1 "not a 40-hex commit" "$R" "$svc" "$tmp/lg-off" "$tmp/img-after" "$tmp/ceil-sticky-badcommit" dev
jq 'del(.rollback_floors.PRIVATE_ACCOUNTS.commit)' "$tmp/ceil-sticky" | tr -d '\r' >"$tmp/ceil-sticky-nocommit"
expect_msg "sticky floor, flag off: a floor with no commit is refused" 1 "not a 40-hex commit" "$R" "$svc" "$tmp/lg-off" "$tmp/img-after" "$tmp/ceil-sticky-nocommit" dev
jq --arg c "$(printf '%040d' 9)" '.rollback_floors.PRIVATE_ACCOUNTS.commit = $c' "$tmp/ceil-sticky" | tr -d '\r' >"$tmp/ceil-sticky-missing"
expect_msg "sticky floor, flag off: a floor commit missing from the checkout is refused" 1 "not in the checkout" "$R" "$svc" "$tmp/lg-off" "$tmp/img-after" "$tmp/ceil-sticky-missing" dev
# sticky is accepted on any floor, not on particular flag names: a second, sticky floor on another flag that is off
jq --arg c "$c_floor" '.rollback_floors.LOCATION = {"commit": $c, "pr": 2, "reason": "test", "sticky": true}' "$tmp/ceil-plain" | tr -d '\r' >"$tmp/ceil-two"
expect_msg "two floors: the sticky one refuses although both flags are off" 1 "the LOCATION rollback floor" "$R" "$svc" "$tmp/lg-off" "$tmp/img-before" "$tmp/ceil-two" dev
expect "two floors: an image at the floor passes both" 0 "$R" "$svc" "$tmp/lg-allowlist" "$tmp/img-floor" "$tmp/ceil-two" dev

# --- part 4: a malformed sticky value fails closed, in every mode and even for an image after the floor
n=0
for bad in '"true"' '"false"' '1' '0' 'null' '[true]' '{"value": true}'; do
  n=$((n + 1))
  sticky_ceil "ceil-bad-$n" "$bad"
  expect_msg "a malformed sticky value fails closed: $bad, flag off, older image" 1 "rollback floor for PRIVATE_ACCOUNTS is malformed" "$R" "$svc" "$tmp/lg-off" "$tmp/img-before" "$tmp/ceil-bad-$n" dev
  expect_msg "a malformed sticky value fails closed: $bad, flag allowlist, image after the floor" 1 "rollback floor for PRIVATE_ACCOUNTS is malformed" "$R" "$svc" "$tmp/lg-allowlist" "$tmp/img-after" "$tmp/ceil-bad-$n" dev
done
for bad in '"0123456789012345678901234567890123456789"' 'true' 'null' '[]'; do
  n=$((n + 1))
  jq --argjson v "$bad" '.rollback_floors.PRIVATE_ACCOUNTS = $v' "$tmp/ceil-plain" | tr -d '\r' >"$tmp/ceil-bad-$n"
  expect_msg "a floor entry that is not an object fails closed: $bad, flag off" 1 "rollback floor for PRIVATE_ACCOUNTS is malformed" "$R" "$svc" "$tmp/lg-off" "$tmp/img-after" "$tmp/ceil-bad-$n" dev
done
# rollback_floors itself not an object: only a missing key means "no floors"; anything else refuses, older image or not
for bad in '"oops"' '[{"commit": "0123456789012345678901234567890123456789", "sticky": true}]' '42' 'false' 'null'; do
  n=$((n + 1))
  jq --argjson v "$bad" '.rollback_floors = $v' "$tmp/ceil-plain" | tr -d '\r' >"$tmp/ceil-bad-$n"
  expect_msg "rollback_floors that is not an object fails closed: $bad, flag on, older image" 1 "rollback_floors must be an object" "$R" "$svc" "$tmp/lg-on" "$tmp/img-before" "$tmp/ceil-bad-$n" dev
  expect_msg "rollback_floors that is not an object fails closed: $bad, flag off, image after" 1 "rollback_floors must be an object" "$R" "$svc" "$tmp/lg-off" "$tmp/img-after" "$tmp/ceil-bad-$n" dev
done
# an underscore key other than "_comment", or a "_comment" that is not a string, is a hidden floor: refuse it
for bad in '._PRIVATE_ACCOUNTS = .PRIVATE_ACCOUNTS' '._note = "x"' '._comment = {"commit": "0123456789012345678901234567890123456789"}' '._comment = [1]' '._comment = 42'; do
  n=$((n + 1))
  jq ".rollback_floors |= ($bad)" "$tmp/ceil-plain" | tr -d '\r' >"$tmp/ceil-bad-$n"
  expect_msg "an underscore floor key fails closed: $bad" 1 "rollback floor key" "$R" "$svc" "$tmp/lg-on" "$tmp/img-after" "$tmp/ceil-bad-$n" dev
done
expect "the plain-string _comment key is still accepted" 0 "$R" "$svc" "$tmp/lg-on" "$tmp/img-after" "$tmp/ceil-plain" dev
unset ROLLBACK_REPO

# --- part 5: check-flag-registry.sh (CI gate) refuses a malformed floor before it can reach a rollback
cfg=$fx/config-ok.go.txt
reg() { jq "$1" "$p/flag-ceiling.json" | tr -d '\r' >"$tmp/reg"; }
expect "registry: the committed floors are well formed" 0 "$G" "$cfg" "$p/flag-ceiling.json"
reg '.rollback_floors.LOCATION.sticky = true | .rollback_floors.E2EE_DM.sticky = false'
expect "registry: sticky true or false on any floor is accepted" 0 "$G" "$cfg" "$tmp/reg"
reg 'del(.rollback_floors)'
expect "registry: no floors at all is accepted" 0 "$G" "$cfg" "$tmp/reg"
for bad in '"true"' '1' 'null' '[true]'; do
  reg ".rollback_floors.E2EE_DM.sticky = $bad"
  expect_msg "registry: sticky $bad is refused" 1 "rollback floor E2EE_DM: \"sticky\" must be the JSON boolean" "$G" "$cfg" "$tmp/reg"
done
reg '.rollback_floors.E2EE_DM.commit = "011e8d83"'
expect_msg "registry: a short floor commit is refused" 1 "rollback floor E2EE_DM: \"commit\" must be a 40-hex commit" "$G" "$cfg" "$tmp/reg"
reg '.rollback_floors.E2EE_DM = "011e8d833a2d594cfb1018ca0be099e45356f136"'
expect_msg "registry: a floor that is not an object is refused" 1 "rollback floor E2EE_DM must be an object" "$G" "$cfg" "$tmp/reg"
reg '.rollback_floors.NOT_A_FLAG = .rollback_floors.E2EE_DM'
expect_msg "registry: a floor for an unregistered flag is refused" 1 "rollback floor NOT_A_FLAG names no registered flag" "$G" "$cfg" "$tmp/reg"
for bad in '[]' 'false' 'null' '"oops"' '42'; do
  reg ".rollback_floors = $bad"
  expect_msg "registry: rollback_floors $bad (not an object) is refused" 1 "rollback_floors must be an object" "$G" "$cfg" "$tmp/reg"
done
reg '.rollback_floors._E2EE_DM = .rollback_floors.E2EE_DM'
expect_msg "registry: an underscore key other than _comment is refused" 1 "rollback floor key _E2EE_DM" "$G" "$cfg" "$tmp/reg"
reg '.rollback_floors._note = "x"'
expect_msg "registry: an underscore note key other than _comment is refused" 1 "rollback floor key _note" "$G" "$cfg" "$tmp/reg"
reg '.rollback_floors._comment = .rollback_floors.E2EE_DM'
expect_msg "registry: an object under _comment is refused" 1 "rollback floor key _comment" "$G" "$cfg" "$tmp/reg"
reg '.rollback_floors._comment = [1]'
expect_msg "registry: an array under _comment is refused" 1 "rollback floor key _comment" "$G" "$cfg" "$tmp/reg"

echo "rollback floor tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
