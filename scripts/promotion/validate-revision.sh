#!/usr/bin/env bash
# Usage: validate-revision.sh <revision.json> <flag-ceiling.json> <env>
# <revision.json> is `gcloud run revisions describe <rev> --format=json`. Pure: no network, no credentials.
# Fails closed on: unknown FEATURE_* names, FEATURE_* from valueFrom, bad modes/percents, effective mode above
# the env ceiling, allowlist larger than its ceiling, and max/min instance mismatch. Prints names and counts only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
need_tool jq
[ $# -eq 3 ] || { echo "usage: $0 <revision.json> <flag-ceiling.json> <env>" >&2; exit 2; }
rev=$1 ceil=$2 env=$3
need_file "$rev"; need_file "$ceil"
jq -e --arg e "$env" '.envs[$e]' "$ceil" >/dev/null 2>&1 || { echo "FAIL: no ceiling for env '$env'" >&2; exit 2; }
jq -e '.spec.containers[0]' "$rev" >/dev/null 2>&1 || { echo "FAIL: not a revision JSON (.spec.containers[0] missing)" >&2; exit 2; }

known=$(jqr '.flags[]' "$ceil")

# 1. Every FEATURE_* env var must be exactly FEATURE_<N>, _ALLOWLIST or _PERCENT for a known N, set via `value`.
while IFS=$'\t' read -r name has_value; do
  [ -n "$name" ] || continue
  base=$name
  case $name in
    *_ALLOWLIST) base=${name%_ALLOWLIST} ;;
    *_PERCENT) base=${name%_PERCENT} ;;
  esac
  flag=${base#FEATURE_}
  if ! grep -qxF "$flag" <<<"$known"; then fail "unknown feature env var $name"; continue; fi
  [ "$has_value" = "true" ] || fail "$name is not set through a plain value (valueFrom/secret refs are not allowed for flags)"
done < <(jqr '.spec.containers[0].env // [] | .[] | select(.name | startswith("FEATURE_")) | [.name, ((has("valueFrom") or has("valueSource")) | not)] | @tsv' "$rev")

# duplicates (the last one would win at runtime; refuse ambiguity)
dups=$(jqr '[.spec.containers[0].env // [] | .[] | select(.name | startswith("FEATURE_")) | .name] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$rev")
[ -z "$dups" ] || while read -r d; do fail "duplicate env var $d"; done <<<"$dups"

# 2. Effective mode per known flag against the ceiling.
rank() { case $1 in off) echo 0 ;; allowlist) echo 1 ;; percent) echo 2 ;; on) echo 3 ;; *) echo 99 ;; esac; }
envval() { jqr --arg n "$1" '(.spec.containers[0].env // [] | map(select(.name == $n)) | last | .value) // empty' "$rev"; }

while read -r flag; do
  [ -n "$flag" ] || continue
  default=$(jqr --arg e "$env" --arg f "$flag" '.unset_default[$e][$f] // "off"' "$ceil")
  mode=$(envval "FEATURE_$flag"); mode=${mode:-$default}
  cmode=$(jqr --arg e "$env" --arg f "$flag" '.envs[$e].flags[$f].mode // empty' "$ceil")
  if [ -z "$cmode" ]; then fail "flag $flag has no ceiling for env $env"; continue; fi
  if [ "$(rank "$cmode")" -eq 99 ]; then fail "$flag ceiling mode '$cmode' is not off|allowlist|percent|on"; continue; fi
  if [ "$(rank "$mode")" -eq 99 ]; then fail "$flag has invalid mode '$mode'"; continue; fi
  if [ "$(rank "$mode")" -gt "$(rank "$cmode")" ]; then fail "$flag effective mode '$mode' exceeds ceiling '$cmode'"; continue; fi

  pct=$(envval "FEATURE_${flag}_PERCENT"); pct=${pct:-0}
  case $pct in ''|*[!0-9]*) fail "$flag percent is not an integer"; continue ;; esac
  [ "$pct" -le 100 ] || fail "$flag percent $pct > 100"
  maxpct=$(jqr --arg e "$env" --arg f "$flag" '.envs[$e].flags[$f].max_percent // 0' "$ceil")
  # Percent only takes effect in percent mode, but a stray value is still a config we did not approve.
  [ "$pct" -le "$maxpct" ] || fail "$flag percent $pct exceeds ceiling $maxpct"

  list=$(envval "FEATURE_${flag}_ALLOWLIST")
  count=$(printf '%s' "$list" | tr ',' '\n' | tr -d '\r ' | grep -c . || true)
  maxal=$(jqr --arg e "$env" --arg f "$flag" '.envs[$e].flags[$f].max_allowlist // 0' "$ceil")
  [ "$count" -le "$maxal" ] || fail "$flag allowlist has $count entries, ceiling is $maxal"
  note "$flag mode=$mode (ceiling $cmode) allowlist=$count/$maxal percent=$pct/$maxpct"
done <<<"$known"

# 3. Shape: instance caps are cost caps (CLAUDE.md rule 11).
want_max=$(jqr --arg e "$env" '.envs[$e].max_instances' "$ceil")
want_min=$(jqr --arg e "$env" '.envs[$e].min_instances' "$ceil")
got_max=$(jqr '.metadata.annotations["autoscaling.knative.dev/maxScale"] // "unset"' "$rev")
got_min=$(jqr '.metadata.annotations["autoscaling.knative.dev/minScale"] // "unset"' "$rev")
# maxScale is a cost cap: any positive integer at or below the ceiling is fine (a tighter cap is safer, and an older
# revision with the previous cap must stay valid as a rollback target). 0 means unlimited on Cloud Run, so it fails.
case $got_max in
  ''|*[!0-9]*) fail "maxScale is '$got_max', expected an integer <= $want_max" ;;
  *) if [ "$got_max" -lt 1 ] || [ "$got_max" -gt "$want_max" ]; then fail "maxScale is $got_max, expected 1..$want_max"; fi ;;
esac
[ "$got_min" = "$want_min" ] || fail "minScale is $got_min, expected $want_min"
note "scaling min=$got_min max=$got_max"

finish
