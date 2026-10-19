#!/usr/bin/env bash
# Usage: check-traffic.sh <service.json> <flag-ceiling.json> <env> serving
#        check-traffic.sh <service.json> <flag-ceiling.json> <env> staged <candidate-rev> <expected-serving-rev>
# <service.json> is `gcloud run services describe <svc> --format=json`; the *status* traffic is checked, never the template.
# serving: exactly one revision holds 100%, named (not latestRevision), nobody else has a percent, tags are in the allow-list.
# staged:  the above for <expected-serving-rev>, plus <candidate-rev> carries the `candidate` tag with no traffic.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
need_tool jq
[ $# -ge 4 ] || { echo "usage: see header" >&2; exit 2; }
svc=$1 ceil=$2 env=$3 mode=$4
need_file "$svc"; need_file "$ceil"
jq -e '.status.traffic | type == "array"' "$svc" >/dev/null 2>&1 || { echo "FAIL: .status.traffic missing" >&2; exit 2; }

# Freshness: a stale status (e.g. after a failed update-traffic) can still look valid.
gen=$(jqr '.metadata.generation // empty' "$svc")
obs=$(jqr '.status.observedGeneration // empty' "$svc")
[ -n "$gen" ] && [ "$gen" = "$obs" ] || fail "status is stale or incomplete (generation '$gen', observedGeneration '$obs')"
[ "$(jqr '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length' "$svc")" = "1" ] || fail "service is not Ready"

holders=$(jqr '[.status.traffic[] | select((.percent // 0) > 0)] | length' "$svc")
[ "$holders" = "1" ] || fail "expected exactly 1 revision with traffic, found $holders"
total=$(jqr '[.status.traffic[] | (.percent // 0)] | add // 0' "$svc")
[ "$total" = "100" ] || fail "traffic percents sum to $total, expected 100"
serving=$(jqr '[.status.traffic[] | select((.percent // 0) == 100)] | first | .revisionName // empty' "$svc")
[ -n "$serving" ] || fail "no named revision holds 100% (latestRevision routing is not allowed)"
[ "$(jqr '[.status.traffic[] | select(.latestRevision == true)] | length' "$svc")" = "0" ] || fail "a traffic entry uses latestRevision"

allowed=$(jqr --arg e "$env" '.envs[$e].allowed_tags[]' "$ceil")
while read -r tag; do
  [ -n "$tag" ] || continue
  grep -qxF "$tag" <<<"$allowed" || fail "unexpected traffic tag '$tag'"
done < <(jqr '.status.traffic[] | .tag // empty' "$svc")
note "serving revision: ${serving:-none}"

if [ "$mode" = "staged" ]; then
  [ $# -eq 6 ] || { echo "staged needs <candidate-rev> <expected-serving-rev>" >&2; exit 2; }
  cand=$5 want=$6
  [ "$serving" = "$want" ] || fail "serving revision is '$serving', expected '$want'"
  [ "$(jqr --arg r "$cand" '[.status.traffic[] | select(.tag == "candidate" and .revisionName == $r and (.percent // 0) == 0)] | length' "$svc")" = "1" ] \
    || fail "revision '$cand' does not carry the 0% 'candidate' tag"
  [ "$cand" != "$serving" ] || fail "candidate and serving are the same revision"
elif [ "$mode" != "serving" ]; then
  echo "unknown mode $mode" >&2; exit 2
fi
finish
