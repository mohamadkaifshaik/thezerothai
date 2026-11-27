#!/usr/bin/env bash
# Usage: validate-revision.sh <revision.json> <flag-ceiling.json> <env>
# <revision.json> is `gcloud run revisions describe <rev> --format=json`. Pure: no network, no credentials.
# Fails closed on: unknown FEATURE_* names, FEATURE_* from valueFrom, bad modes/percents, effective mode above
# the env ceiling, allowlist larger than its ceiling, max/min instance mismatch, and a flag stage that breaks an E2EE
# coupling (section 2b). Prints names and counts only.
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
# fuids <FLAG>: the flag's allowlist entries the way flags.splitCSV reads them (split on "," only, trim each entry's
# ends, drop empty entries), sorted and unique (the runtime keeps a set). One per line; nothing for an unset or empty
# list. The one parser for the section 2 count and the section 2b uid comparison. [[:space:]] rather than \s: the
# Windows jq build mangles the backslash.
fuids() {
  envval "FEATURE_${1}_ALLOWLIST" |
    jqr -Rs 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) | .[]' |
    LC_ALL=C sort -u
}

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

  count=$(fuids "$flag" | { grep -c . || true; })
  maxal=$(jqr --arg e "$env" --arg f "$flag" '.envs[$e].flags[$f].max_allowlist // 0' "$ceil")
  [ "$count" -le "$maxal" ] || fail "$flag allowlist has $count entries, ceiling is $maxal"
  note "$flag mode=$mode (ceiling $cmode) allowlist=$count/$maxal percent=$pct/$maxpct"
done <<<"$known"

# 2b. E2EE couplings (E2EE Plan 6 §1.4, owner decision 2026-11-25, PR 6-1 security review L4). "A covers B" means:
# wherever B can be on for a uid, A is on for that uid, judged on this revision's own FEATURE_* values (unset = the
# ceiling's unset_default, as above):
#   B off, or B allowlist with an empty list  -> covered
#   A on, or A percent 100                    -> covers anything
#   B on or percent                           -> A must be on (or percent 100): percent buckets are salted per flag
#                                                name, fnv32a(name:uid)%100 (flags.go), so two cohorts never line up
#   B allowlist                               -> A allowlist or percent, and A's allowlist holds every B uid (the
#                                                allowlist applies in percent mode too)
# B percent with percent 0 (and no allowlist) is on for nobody at runtime, but it is still judged as percent, so A must
# be on: kept strict on purpose, since such a stage is one percent edit away from a live cohort.
# The rules judge each flag's RAW cohort, not the effective one the server computes (apiserver.coupleE2EE narrows a
# flag to its parents). Raw over-approximates effective, so this can only be stricter, never unsafe, and it does not
# depend on mirroring coupleE2EE in bash. Cost if that is too strict: DM_SHARE_CHECK has to be on more widely than the
# server needs while MESSAGING ramps (one stage change).
# Uids are compared in memory only; output carries names, modes and counts, never a uid.
# These helpers call envval without guarding it: section 2 has already run envval for every known flag under set -e,
# so a revision JSON that jq cannot read has stopped the script before here.
fmode() {
  local m
  m=$(envval "FEATURE_$1")
  [ -n "$m" ] || m=$(jqr --arg e "$env" --arg f "$1" '.unset_default[$e][$f] // "off"' "$ceil")
  printf '%s' "$m"
}
fpct() { local v; v=$(envval "FEATURE_${1}_PERCENT"); printf '%s' "${v:-0}"; }
everyone() { local m; m=$(fmode "$1"); [ "$m" = on ] || { [ "$m" = percent ] && [ "$(fpct "$1")" -eq 100 ]; }; }

# covers <A> <B> <fail|warn> <why>
covers() {
  local a=$1 b=$2 sev=$3 why=$4 f m ma mb n missing msg=""
  for f in "$a" "$b"; do
    if ! grep -qxF "$f" <<<"$known"; then fail "E2EE coupling ($why) names $f, which the ceiling does not list"; return; fi
    m=$(fmode "$f")
    case $m in off | allowlist | percent | on) ;; *) fail "E2EE coupling ($why): cannot judge $f mode '$m'"; return ;; esac
  done
  ma=$(fmode "$a")
  mb=$(fmode "$b")
  if [ "$mb" != off ] && ! everyone "$a"; then
    case $mb in
      on | percent) msg="$b is $mb, so $a must be on (a percent cohort cannot be covered by an allowlist or another percent); $a is $ma" ;;
      allowlist)
        n=$(fuids "$b" | { grep -c . || true; })
        if [ "$n" -gt 0 ] && [ "$ma" = off ]; then
          msg="$b allowlist has $n uid(s) but $a is off"
        elif [ "$n" -gt 0 ]; then
          missing=$(LC_ALL=C comm -23 <(fuids "$b") <(fuids "$a") | { grep -c . || true; })
          [ "$missing" -eq 0 ] || msg="$missing of $n $b allowlist uid(s) are not in the $a allowlist ($a is $ma)"
        fi
        ;;
    esac
  fi
  if [ -z "$msg" ]; then note "E2EE coupling: $a covers $b ($a=$ma, $b=$mb)"; return; fi
  if [ "$sev" = warn ]; then warn "E2EE coupling ($why): $msg"; else fail "E2EE coupling ($why): $msg"; fi
}

# 1. Owner decision 2026-11-25: the share check is on wherever encrypted DMs are (wider than E2EE_REQUIRED alone).
covers DM_SHARE_CHECK E2EE_DM fail "dm_share_check must be on wherever e2ee_dm is"
# 2. Plan §1.4: prod MESSAGING never leaves off before E2EE_REQUIRED is in the same cohort. Dev holds old plaintext test
#    data by design, so dev only warns; every other env fails closed.
if [ "$env" = dev ]; then req_sev=warn; else req_sev=fail; fi
covers E2EE_REQUIRED MESSAGING "$req_sev" "e2ee_required must be on wherever messaging is"
# 3. Plan §1.4: the share check is on wherever plaintext is refused (checked directly, not only through rule 1).
covers DM_SHARE_CHECK E2EE_REQUIRED fail "dm_share_check must be on wherever e2ee_required is"
# 4. The server narrows claim_live to e2ee_required && device_sign_out, and e2ee_required itself needs messaging
#    (apiserver.coupleE2EE), so the claim is live only where all three are; refuse a claim cohort the server would
#    silently narrow.
covers E2EE_REQUIRED E2EE_CLAIM fail "e2ee_required must be on wherever claim_live is"
covers DEVICE_SIGN_OUT E2EE_CLAIM fail "device_sign_out must be on wherever claim_live is"
covers MESSAGING E2EE_CLAIM fail "messaging must be on wherever claim_live is"

# 3. Shape: instance caps are cost caps (the cost-caps-are-code rule).
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
