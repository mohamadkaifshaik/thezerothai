#!/usr/bin/env bash
set -euo pipefail
traffic=$(gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format=json)
file="$RUNNER_TEMP/canary.json"
candidate=$(jq -er --arg rev "$REVISION" '[.status.traffic[] | select(.tag=="candidate" and .revisionName==$rev) | .url] | select(length==1) | first' <<<"$traffic")
[[ "$candidate" =~ ^https://[a-z0-9-]+[.]([a-z0-9-]+[.])*run[.]app$ ]]
# Tagged entries can coexist with the untagged entry for the same revision.
split=$(jq -c '[.status.traffic[] | select((.percent // 0)>0)] | group_by(.revisionName) |
  map({revision: .[0].revisionName, percent: map(.percent)|add}) | sort_by(.revision)' <<<"$traffic")
case "$1" in
  capture)
    jq -en --argjson split "$split" --arg rev "$REVISION" --arg digest "$DIGEST" --arg sha "$GITHUB_SHA" --arg tag "$GITHUB_REF" '
      ($split | map(select(.revision != $rev))) as $stable |
      select(($stable|length)==1 and ($stable[0].percent==100 or $stable[0].percent==90)) |
      {revision:$rev,digest:$digest,sha:$sha,tag:$tag,baseline:$stable[0].revision}' > "$file"
    echo "Rollback revision before canary: $(jq -r .baseline "$file")." >> "$GITHUB_STEP_SUMMARY"
    bash "$(dirname "$0")/authenticated-smoke.sh" "$candidate"
    ;;
  record|verify)
    jq -e --arg rev "$REVISION" --arg digest "$DIGEST" --arg sha "$GITHUB_SHA" --arg tag "$GITHUB_REF" '
      .revision==$rev and .digest==$digest and .sha==$sha and .tag==$tag and (.baseline|length)>0' "$file" >/dev/null
    baseline=$(jq -r .baseline "$file")
    if [[ "$1" == verify ]]; then
      jq -e '.authenticatedSmoke == true and now-.started >= 900 and now-.started <= 86400' "$file" >/dev/null
    fi
    jq -en --argjson split "$split" --arg rev "$REVISION" --arg base "$baseline" --arg phase "$1" '
      $split == ([{revision:$rev,percent:10},{revision:$base,percent:90}]|sort_by(.revision)) or
      ($phase=="verify" and $split==[{revision:$rev,percent:100}])' >/dev/null
    bash "$(dirname "$0")/authenticated-smoke.sh" "$candidate"
    if [[ "$1" == record ]]; then
      jq '.started=(now|floor) | .authenticatedSmoke=true' "$file" > "$file.tmp"
      mv "$file.tmp" "$file"
      echo "Stage 10 evidence is in run $GITHUB_RUN_ID. Rollback revision: $baseline." >> "$GITHUB_STEP_SUMMARY"

    fi
    ;;
  *) exit 2 ;;
esac
