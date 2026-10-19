#!/usr/bin/env bash
# Usage: check-flag-registry.sh <backend/pkg/platform/config/config.go> <flag-ceiling.json> [terraform-main.tf ...]
# CI gate: the ceiling must list exactly the flags registered with flags.LoadSpec, its unset defaults must match what
# config.go does when FEATURE_<N> is unset, and Terraform may only mention known FEATURE_* names.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
need_tool jq
[ $# -ge 2 ] || { echo "usage: see header" >&2; exit 2; }
cfg=$1 ceil=$2; shift 2
need_file "$cfg"; need_file "$ceil"

code=$(grep -o 'flags\.LoadSpec("[A-Z_]*"' "$cfg" | sed 's/.*("\(.*\)"/\1/' | sort)
listed=$(jqr '.flags | sort | .[]' "$ceil")
[ -n "$code" ] || fail "found no flags.LoadSpec calls in $cfg (pattern drifted?)"
[ "$code" = "$listed" ] || fail "ceiling flags differ from LoadSpec names: $(diff <(echo "$code") <(echo "$listed") | tr '\n' ' ')"
for e in $(jqr '.envs | keys[]' "$ceil"); do
  have=$(jqr --arg e "$e" '.envs[$e].flags | keys | sort | .[]' "$ceil")
  [ "$have" = "$listed" ] || fail "env $e ceilings do not cover exactly the flag list"
done

# Defaults: LoadSpec(..., flags.Off) => unset means off; graphDefaultMode => on in dev, off in prod.
while read -r flag dflt; do
  [ -n "$flag" ] || continue
  got=$(jqr --arg f "$flag" '.unset_default.dev[$f] // "off"' "$ceil")
  prod=$(jqr --arg f "$flag" '.unset_default.prod[$f] // "off"' "$ceil")
  case $dflt in
    flags.Off) [ "$got" = off ] && [ "$prod" = off ] || fail "$flag defaults to off in code but the ceiling says dev=$got prod=$prod" ;;
    graphDefaultMode) [ "$got" = on ] && [ "$prod" = off ] || fail "$flag uses graphDefaultMode (dev on, prod off) but the ceiling says dev=$got prod=$prod" ;;
    *) fail "$flag has an unrecognised default '$dflt'" ;;
  esac
done < <(grep -o 'flags\.LoadSpec("[A-Z_]*", "[a-z_]*", [A-Za-z.]*)' "$cfg" | sed 's/flags\.LoadSpec("\([A-Z_]*\)", "[a-z_]*", \(.*\))/\1 \2/')

for tf in "$@"; do
  need_file "$tf"
  while read -r n; do
    base=${n%_ALLOWLIST}; base=${base%_PERCENT}; flag=${base#FEATURE_}
    grep -qxF "$flag" <<<"$listed" || fail "$tf sets unknown flag env var $n"
  done < <(grep -o '"FEATURE_[A-Z_]*"' "$tf" | tr -d '"' | sort -u)
done
note "$(echo "$code" | wc -l | tr -d ' ') flags registered"
finish
