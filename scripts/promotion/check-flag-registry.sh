#!/usr/bin/env bash
# Usage: check-flag-registry.sh <backend/pkg/platform/config/config.go> <flag-ceiling.json> [terraform-main.tf ...]
# CI gate: the ceiling must list exactly the flags registered with flags.LoadSpec, its unset defaults must match what
# config.go does when FEATURE_<N> is unset, its own values must be valid modes, and Terraform may only mention known
# FEATURE_* names. Every LoadSpec call must be one understood line; anything else fails instead of being skipped.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
need_tool jq
[ $# -ge 2 ] || { echo "usage: see header" >&2; exit 2; }
cfg=$1 ceil=$2
shift 2
need_file "$cfg"
need_file "$ceil"

code=$(grep -o 'flags\.LoadSpec("[A-Z0-9_]*"' "$cfg" | sed 's/.*("\(.*\)"/\1/' | LC_ALL=C sort)
listed=$(jqr '.flags | .[]' "$ceil" | LC_ALL=C sort)
[ -n "$code" ] || fail "found no flags.LoadSpec calls in $cfg (pattern drifted?)"
[ "$code" = "$listed" ] || fail "ceiling flags differ from LoadSpec names: $(diff <(echo "$code") <(echo "$listed") | tr '\n' ' ')"
for e in $(jqr '.envs | keys[]' "$ceil"); do
  have=$(jqr --arg e "$e" '.envs[$e].flags | keys | .[]' "$ceil" | LC_ALL=C sort)
  [ "$have" = "$listed" ] || fail "env $e ceilings do not cover exactly the flag list"
done

# Every call must be understood: raw call count == fully parsed lines == names (a call split over lines, or with a
# default expression this script does not know, would otherwise be skipped silently).
raw=$(grep -c 'flags\.LoadSpec(' "$cfg" || true)
parsed=$(grep -c 'flags\.LoadSpec("[A-Z0-9_]*", "[a-z0-9_]*", [A-Za-z.]*)' "$cfg" || true)
names=$(printf '%s\n' "$code" | grep -c . || true)
if [ "$raw" != "$parsed" ] || [ "$raw" != "$names" ]; then
  fail "LoadSpec lines: $raw raw, $parsed parsed, $names names; each call must be one line 'flags.LoadSpec(\"N\", \"n\", <flags.X|graphDefaultMode>)'"
fi

# graphDefaultMode is trusted by meaning, not by name: dev on, prod off must really be what config.go does.
if ! { grep -q 'graphDefaultMode := flags\.On' "$cfg" && grep -q 'env == "prod"' "$cfg" && grep -q 'graphDefaultMode = flags\.Off' "$cfg"; }; then
  fail "config.go no longer defines graphDefaultMode as on with a prod override to off"
fi

# The ceiling's own values must be valid modes (an unknown ceiling mode would otherwise compare as never exceeded).
bad=$(jqr '[(.envs[]?.flags[]?.mode), (.unset_default.dev[]?), (.unset_default.prod[]?)] | map(select(. as $m | ["off","allowlist","percent","on"] | index($m) | not)) | length' "$ceil")
[ "$bad" = "0" ] || fail "ceiling contains $bad value(s) that are not off|allowlist|percent|on"

# Defaults: LoadSpec(..., flags.Off) => unset means off; graphDefaultMode => on in dev, off in prod.
while read -r flag dflt; do
  [ -n "$flag" ] || continue
  got=$(jqr --arg f "$flag" '.unset_default.dev[$f] // "off"' "$ceil")
  prod=$(jqr --arg f "$flag" '.unset_default.prod[$f] // "off"' "$ceil")
  case $dflt in
    flags.Off) if [ "$got" != off ] || [ "$prod" != off ]; then fail "$flag defaults to off in code but the ceiling says dev=$got prod=$prod"; fi ;;
    graphDefaultMode) if [ "$got" != on ] || [ "$prod" != off ]; then fail "$flag uses graphDefaultMode (dev on, prod off) but the ceiling says dev=$got prod=$prod"; fi ;;
    *) fail "$flag has an unrecognised default '$dflt'" ;;
  esac
done < <(grep -o 'flags\.LoadSpec("[A-Z0-9_]*", "[a-z0-9_]*", [A-Za-z.]*)' "$cfg" | sed 's/flags\.LoadSpec("\([A-Z0-9_]*\)", "[a-z0-9_]*", \(.*\))/\1 \2/')

for tf in "$@"; do
  need_file "$tf"
  while read -r n; do
    base=${n%_ALLOWLIST}
    base=${base%_PERCENT}
    flag=${base#FEATURE_}
    grep -qxF "$flag" <<<"$listed" || fail "$tf sets unknown flag env var $n"
  done < <(grep -o '"FEATURE_[A-Z0-9_]*"' "$tf" | tr -d '"' | sort -u)
done
note "$(echo "$code" | wc -l | tr -d ' ') flags registered"
finish
