#!/usr/bin/env bash
# Prints Cloud Vision SafeSearch units used this month and today (UTC), for `make cost` (ADR-0022).
# Month: Firestore doc admin/vision-YYYYMM field "units" (backend/internal/media AddVisionUnits/VisionUsed).
# Today: sum of the vision_units field on FinalizeUpload request lines in Cloud Logging since 00:00 UTC.
# Usage: scripts/cost-vision.sh <gcp-project>   (needs gcloud auth; read-only; ~1 Firestore read + 1 log query)
# Never fails the caller: without credentials it prints a fallback line and exits 0.
set -u
project="${1:-${PROJECT_ID:-}}"
cap="${VISION_MONTHLY_CAP:-10000}"
if [ -z "$project" ]; then
  echo "Vision units: needs PROJECT_ID plus gcloud/Firestore credentials (make cost PROJECT_ID=dzeroth-prod)"
  exit 0
fi
month="$(date -u +%Y%m)"
today="$(date -u +%Y-%m-%d)"
token="$(gcloud auth print-access-token 2>/dev/null || true)"
if [ -z "$token" ]; then
  echo "Vision units this month / today: unavailable, needs gcloud/Firestore credentials (run 'gcloud auth login')"
  exit 0
fi
url="https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents/admin/vision-${month}"
resp="$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer ${token}" "$url" 2>/dev/null || true)"
code="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
case "$code" in
  200) units="$(printf '%s' "$body" | tr -d '\n ' | sed -n 's/.*"units":{"integerValue":"\([0-9-]*\)".*/\1/p')"; units="${units:-0}" ;;
  404) units=0 ;;
  *)   units="" ;;
esac
if [ -z "$units" ]; then
  echo "Vision units this month: unavailable (Firestore HTTP ${code:-none}); needs gcloud/Firestore credentials with datastore.viewer on ${project}"
else
  echo "Vision units this month (${month}, UTC): ${units} of cap ${cap}; 1,000 free, then \$1.50 per 1,000 units (2 units per image while VISION_SCREEN_THUMB=true)"
fi
logs="$(gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"api\" AND jsonPayload.vision_units>0 AND timestamp>=\"${today}T00:00:00Z\"" \
  --project="$project" --limit=1000 --format='value(jsonPayload.vision_units)' 2>/dev/null)" || logs="__fail__"
if [ "$logs" = "__fail__" ]; then
  echo "Vision units today (${today}, UTC): unavailable, needs gcloud logging credentials on ${project}"
else
  sum="$(printf '%s\n' "$logs" | awk 'NF{s+=$1} END{printf "%d", s}')"
  echo "Vision units today (${today}, UTC): ${sum} (sum of vision_units on request lines; capped at 1000 log lines)"
fi
