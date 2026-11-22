#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 || -z ${1:-} ]]; then
  echo "usage: $0 PROJECT_ID" >&2
  exit 2
fi
project=$1
for ((attempt = 1; attempt <= 40; attempt++)); do
  indexes=$(gcloud firestore indexes composite list --project="$project" --format=json)
  if jq -e 'type == "array" and all(.[]; .state == "READY")' <<<"$indexes" >/dev/null; then
    exit 0
  fi
  if ((attempt < 40)); then sleep 15; fi
done
echo "::error::Firestore composite indexes are still building; promotion stopped (indexes already deployed are additive and stay)"
exit 1
