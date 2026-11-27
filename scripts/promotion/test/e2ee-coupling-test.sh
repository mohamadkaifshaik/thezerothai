#!/usr/bin/env bash
# Fixture tests for the E2EE coupling rules in validate-revision.sh (section 2b). Run by test/run.sh; also runs alone:
#   bash scripts/promotion/test/e2ee-coupling-test.sh
# No network, no credentials. "A covers B": wherever B can be on for a uid, A is on for that uid.
#   rule 1  DM_SHARE_CHECK covers E2EE_DM                    (owner decision 2026-11-25)
#   rule 2  E2EE_REQUIRED covers MESSAGING: prod fails, dev warns (plan §1.4)
#   rule 3  DM_SHARE_CHECK covers E2EE_REQUIRED              (plan §1.4)
#   rule 4  E2EE_REQUIRED and DEVICE_SIGN_OUT cover E2EE_CLAIM (apiserver.coupleE2EE)
# Most cases use a test ceiling that lets the six flags reach "on" with any percent in both envs (and gives prod dev's
# scaling), so only the coupling rules decide; a few use the committed ceiling for today's dev stage.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
p=$(dirname "$here")
fx=$here/fixtures
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0
V="$p/validate-revision.sh"
ceil=$p/flag-ceiling.json

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
# expect_no_msg <name> <want-exit> <pattern> <command...>: like expect, and the output must NOT contain the pattern
expect_no_msg() {
  local name=$1 want=$2 pat=$3
  shift 3
  expect "$name" "$want" "$@"
  if grep -q -- "$pat" "$tmp/out"; then
    echo "FAIL $name: output has '$pat'"
    sed 's/^/    /' "$tmp/out"
    failed=$((failed + 1))
  fi
}

# The test ceiling: the six coupled flags may be anything in both envs; prod gets dev's scaling caps.
tc=$tmp/ceil-open
jq 'reduce ("DM_SHARE_CHECK", "E2EE_DM", "E2EE_REQUIRED", "E2EE_CLAIM", "DEVICE_SIGN_OUT", "MESSAGING") as $f
    (.; .envs.dev.flags[$f] = {"mode": "on", "max_allowlist": 6, "max_percent": 100})
  | .envs.prod = .envs.dev' "$ceil" | tr -d '\r' >"$tc"

# fl <FLAG> <mode> [allowlist] [percent]: the env entries for one flag (an empty allowlist or percent is left unset)
fl() {
  jq -nc --arg f "$1" --arg m "$2" --arg l "${3-}" --arg p "${4-}" \
    '[{name: "FEATURE_\($f)", value: $m}]
     + (if $l != "" then [{name: "FEATURE_\($f)_ALLOWLIST", value: $l}] else [] end)
     + (if $p != "" then [{name: "FEATURE_\($f)_PERCENT", value: $p}] else [] end)'
}
# rv <fl output...>: writes $tmp/r, the ok revision plus those env entries
rv() {
  printf '%s\n' "$@" | jq -s 'add // []' >"$tmp/add.json"
  jq --slurpfile a "$tmp/add.json" '.spec.containers[0].env += $a[0]' "$fx/revision-ok.json" | tr -d '\r' >"$tmp/r"
}
A=fake-uid-A B=fake-uid-B C=fake-uid-C

# --- baseline: every coupled flag off (unset) passes in both envs, and dev prints no warning
expect_no_msg "baseline dev, all off, no warning" 0 "WARN" "$V" "$fx/revision-ok.json" "$tc" dev
expect "baseline prod, all off" 0 "$V" "$fx/revision-ok.json" "$tc" prod

# --- rule 1: DM_SHARE_CHECK covers E2EE_DM
rv "$(fl E2EE_DM allowlist "$A,$B")" "$(fl DM_SHARE_CHECK allowlist "$A,$B,$C")"
expect "r1 allowlist inside a wider allowlist" 0 "$V" "$tmp/r" "$tc" dev
# the uid-leak assertion is only meaningful if the revision really carries the fixture uids
if grep -q 'fake-uid-A' "$tmp/r"; then pass=$((pass + 1)); else echo "FAIL fixture revision carries no fake uid"; failed=$((failed + 1)); fi
rv "$(fl E2EE_DM allowlist "$A,$B")" "$(fl DM_SHARE_CHECK allowlist "$A,$B")"
expect "r1 equal allowlists" 0 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM allowlist "$A,$B")" "$(fl DM_SHARE_CHECK allowlist "$A")"
expect_msg "r1 allowlist not a superset (dev fails too)" 1 "1 of 2 E2EE_DM allowlist uid(s) are not in the DM_SHARE_CHECK allowlist" "$V" "$tmp/r" "$tc" dev
expect "r1 allowlist not a superset, prod" 1 "$V" "$tmp/r" "$tc" prod
rv "$(fl E2EE_DM allowlist "$A,$B")" "$(fl DM_SHARE_CHECK allowlist "$C")"
expect_msg "r1 disjoint allowlists" 1 "2 of 2 E2EE_DM" "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM allowlist "$A")"
expect_msg "r1 share check off" 1 "E2EE_DM allowlist has 1 uid(s) but DM_SHARE_CHECK is off" "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM allowlist "")"
expect "r1 empty allowlist is on for nobody" 0 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM allowlist " $A , $A,")" "$(fl DM_SHARE_CHECK allowlist "$A")"
expect "r1 spaces, duplicates and empty entries are ignored" 0 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM allowlist "$A")" "$(fl DM_SHARE_CHECK on)"
expect "r1 share check on covers an allowlist" 0 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM allowlist "$A")" "$(fl DM_SHARE_CHECK percent "$A" 10)"
expect "r1 percent mode's allowlist covers an allowlist" 0 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM allowlist "$A")" "$(fl DM_SHARE_CHECK percent "" 50)"
expect_msg "r1 a percent without the uid does not cover an allowlist" 1 "1 of 1 E2EE_DM" "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM percent "" 10)" "$(fl DM_SHARE_CHECK allowlist "$A,$B")"
expect_msg "r1 percent is not covered by an allowlist" 1 "E2EE_DM is percent, so DM_SHARE_CHECK must be on" "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM percent "" 10)" "$(fl DM_SHARE_CHECK percent "" 10)"
expect "r1 percent is not covered by another percent" 1 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM percent "" 10)" "$(fl DM_SHARE_CHECK percent "" 100)"
expect "r1 percent 100 covers a percent" 0 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM percent "" 10)" "$(fl DM_SHARE_CHECK on)"
expect "r1 on covers a percent" 0 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM on)" "$(fl DM_SHARE_CHECK allowlist "$A")"
expect_msg "r1 on is not covered by an allowlist" 1 "E2EE_DM is on, so DM_SHARE_CHECK must be on" "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_DM on)" "$(fl DM_SHARE_CHECK on)"
expect "r1 on covers on" 0 "$V" "$tmp/r" "$tc" dev
# today's dev stage under the committed ceiling
rv "$(fl E2EE_DM allowlist "$A,$B")" "$(fl DM_SHARE_CHECK allowlist "$A,$B")"
expect "r1 committed ceiling, dev allowlists line up" 0 "$V" "$tmp/r" "$ceil" dev
rv "$(fl E2EE_DM allowlist "$A,$B")"
expect_msg "r1 committed ceiling, dev share check missing" 1 "DM_SHARE_CHECK is off" "$V" "$tmp/r" "$ceil" dev

# --- rule 2: E2EE_REQUIRED covers MESSAGING (prod fails, dev warns)
rv "$(fl MESSAGING allowlist "$A")"
expect_msg "r2 dev uncovered messaging warns and passes" 0 "WARN: E2EE coupling (e2ee_required" "$V" "$tmp/r" "$tc" dev
expect_msg "r2 prod uncovered messaging fails" 1 "FAIL: E2EE coupling (e2ee_required must be on wherever messaging is)" "$V" "$tmp/r" "$tc" prod
rv "$(fl MESSAGING allowlist "$A,$B")" "$(fl E2EE_REQUIRED allowlist "$A,$B")" "$(fl DM_SHARE_CHECK allowlist "$A,$B")"
expect "r2 prod same cohort passes" 0 "$V" "$tmp/r" "$tc" prod
expect_no_msg "r2 dev same cohort, no warning" 0 "WARN" "$V" "$tmp/r" "$tc" dev
rv "$(fl MESSAGING allowlist "$A,$B")" "$(fl E2EE_REQUIRED allowlist "$A")" "$(fl DM_SHARE_CHECK allowlist "$A,$B")"
expect_msg "r2 prod messaging allowlist wider than required" 1 "1 of 2 MESSAGING allowlist uid(s) are not in the E2EE_REQUIRED allowlist" "$V" "$tmp/r" "$tc" prod
rv "$(fl MESSAGING percent "" 5)" "$(fl E2EE_REQUIRED allowlist "$A")" "$(fl DM_SHARE_CHECK on)"
expect "r2 prod messaging percent, required allowlist" 1 "$V" "$tmp/r" "$tc" prod
rv "$(fl MESSAGING percent "" 5)" "$(fl E2EE_REQUIRED on)" "$(fl DM_SHARE_CHECK on)"
expect "r2 prod messaging percent, required on" 0 "$V" "$tmp/r" "$tc" prod
rv "$(fl MESSAGING on)" "$(fl E2EE_REQUIRED percent "" 100)" "$(fl DM_SHARE_CHECK on)"
expect "r2 prod messaging on, required percent 100" 0 "$V" "$tmp/r" "$tc" prod

# --- rule 3: DM_SHARE_CHECK covers E2EE_REQUIRED (messaging off, so rule 2 is quiet)
rv "$(fl E2EE_REQUIRED allowlist "$A")"
expect_msg "r3 required without the share check" 1 "E2EE_REQUIRED allowlist has 1 uid(s) but DM_SHARE_CHECK is off" "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_REQUIRED allowlist "$A")" "$(fl DM_SHARE_CHECK allowlist "$A")"
expect "r3 required inside the share check" 0 "$V" "$tmp/r" "$tc" dev
rv "$(fl E2EE_REQUIRED on)" "$(fl DM_SHARE_CHECK allowlist "$A")"
expect_msg "r3 required on, share check allowlist" 1 "E2EE_REQUIRED is on, so DM_SHARE_CHECK must be on" "$V" "$tmp/r" "$tc" prod

# --- rule 4: E2EE_REQUIRED and DEVICE_SIGN_OUT cover E2EE_CLAIM
base4=("$(fl DM_SHARE_CHECK allowlist "$A,$B")")
rv "${base4[@]}" "$(fl E2EE_CLAIM allowlist "$A")" "$(fl E2EE_REQUIRED allowlist "$A")" "$(fl DEVICE_SIGN_OUT allowlist "$A")"
expect "r4 claim inside both parents" 0 "$V" "$tmp/r" "$tc" prod
rv "${base4[@]}" "$(fl E2EE_CLAIM allowlist "$A")" "$(fl E2EE_REQUIRED allowlist "$A")"
expect_msg "r4 device sign-out off" 1 "E2EE_CLAIM allowlist has 1 uid(s) but DEVICE_SIGN_OUT is off" "$V" "$tmp/r" "$tc" dev
rv "${base4[@]}" "$(fl E2EE_CLAIM allowlist "$A")" "$(fl DEVICE_SIGN_OUT allowlist "$A")"
expect_msg "r4 required off" 1 "E2EE_CLAIM allowlist has 1 uid(s) but E2EE_REQUIRED is off" "$V" "$tmp/r" "$tc" dev
rv "${base4[@]}" "$(fl E2EE_CLAIM allowlist "$A,$B")" "$(fl E2EE_REQUIRED allowlist "$A,$B")" "$(fl DEVICE_SIGN_OUT allowlist "$A")"
expect_msg "r4 claim wider than device sign-out" 1 "1 of 2 E2EE_CLAIM allowlist uid(s) are not in the DEVICE_SIGN_OUT allowlist" "$V" "$tmp/r" "$tc" dev
rv "$(fl DM_SHARE_CHECK on)" "$(fl E2EE_CLAIM percent "" 5)" "$(fl E2EE_REQUIRED on)" "$(fl DEVICE_SIGN_OUT on)"
expect "r4 claim percent, both parents on" 0 "$V" "$tmp/r" "$tc" prod
rv "$(fl DM_SHARE_CHECK on)" "$(fl E2EE_CLAIM percent "" 5)" "$(fl E2EE_REQUIRED on)" "$(fl DEVICE_SIGN_OUT allowlist "$A")"
expect_msg "r4 claim percent, device sign-out allowlist" 1 "E2EE_CLAIM is percent, so DEVICE_SIGN_OUT must be on" "$V" "$tmp/r" "$tc" prod

# --- fail closed
jq '.flags -= ["E2EE_CLAIM"] | del(.envs[].flags.E2EE_CLAIM)' "$tc" | tr -d '\r' >"$tmp/ceil-noclaim"
expect_msg "a coupled flag missing from the ceiling fails" 1 "names E2EE_CLAIM, which the ceiling does not list" "$V" "$fx/revision-ok.json" "$tmp/ceil-noclaim" dev
rv "$(fl E2EE_DM enabled "$A")" "$(fl DM_SHARE_CHECK on)"
expect_msg "an unknown mode on a coupled flag fails" 1 "cannot judge E2EE_DM mode 'enabled'" "$V" "$tmp/r" "$tc" dev
# several broken couplings are each reported (counts and names only): rule 1, rule 2 (prod), rule 4 twice
rv "$(fl E2EE_DM on)" "$(fl E2EE_CLAIM on)" "$(fl MESSAGING on)"
expect_msg "every broken coupling is counted" 1 "RESULT: 4 check(s) failed" "$V" "$tmp/r" "$tc" prod

echo "e2ee coupling tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
