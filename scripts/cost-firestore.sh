#!/usr/bin/env bash
# Prints project-wide Firestore document reads, writes and deletes for the last 24 h, for `make cost`.
# Source: Cloud Monitoring metrics firestore.googleapis.com/document/{read,write,delete}_count, summed over every
# series (all databases, all callers). The API's request logs no longer carry per-request Firestore counts.
# Usage: scripts/cost-firestore.sh <gcp-project>   (needs gcloud auth; read-only; 3 Monitoring API calls)
# Never fails the caller: without credentials it prints a fallback line and exits 0.
set -u
project="${1:-${PROJECT_ID:-}}"
if [ -z "$project" ]; then
  echo "Firestore usage: needs PROJECT_ID plus gcloud credentials (make cost PROJECT_ID=dzeroth-dev)"
  exit 0
fi
token="$(gcloud auth print-access-token 2>/dev/null || true)"
if [ -z "$token" ]; then
  echo "Firestore usage (last 24 h): unavailable, needs gcloud credentials (run 'gcloud auth login')"
  exit 0
fi
end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
if [ -z "$start" ]; then
  echo "Firestore usage (last 24 h): unavailable, this shell's date cannot do 24-hour arithmetic"
  exit 0
fi
url="https://monitoring.googleapis.com/v3/projects/${project}/timeSeries"
echo "Firestore document operations, last 24 h (${start} to ${end}), whole project:"
for kind in read write delete; do
  # The token goes in on stdin, so it never shows in the process list.
  resp="$(printf 'Authorization: Bearer %s\n' "$token" | curl -s -w '\n%{http_code}' -G -H @- "$url" \
    --data-urlencode "filter=metric.type=\"firestore.googleapis.com/document/${kind}_count\"" \
    --data-urlencode "interval.startTime=${start}" \
    --data-urlencode "interval.endTime=${end}" \
    --data-urlencode "aggregation.alignmentPeriod=86400s" \
    --data-urlencode "aggregation.perSeriesAligner=ALIGN_SUM" \
    --data-urlencode "aggregation.crossSeriesReducer=REDUCE_SUM" 2>/dev/null || true)"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  if [ "$code" != "200" ]; then
    echo "  ${kind}s: unavailable (Monitoring HTTP ${code:-none}); needs monitoring.timeSeries.list on ${project}"
    continue
  fi
  # No series at all means no operations in the window. Points come newest first, and the newest one ends at endTime
  # and spans the 24 h alignment period, which is exactly the window; an older point would reach before it.
  total="$(printf '%s' "$body" | grep -o '"int64Value": *"[0-9]*"' | head -n1 | sed 's/.*"\([0-9]*\)"$/\1/')"
  total="${total:-0}"
  echo "  ${kind}s: ${total}"
done
