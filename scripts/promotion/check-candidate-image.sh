#!/usr/bin/env bash
# Print the verified digest for subsequent canary steps.
set -euo pipefail
image=$1
tag=$2
sha=$3
if [[ ! $image =~ ^([^@]+)@(sha256:[a-f0-9]{64})$ ]]; then
  echo "Candidate revision must reference an image by digest." >&2
  exit 1
fi
repository=${BASH_REMATCH[1]}
digest=${BASH_REMATCH[2]}
for expected in "$tag" "$tag-$sha"; do
  actual=$(gcloud artifacts docker images describe "$repository:$expected" --format='value(image_summary.digest)')
  if [[ $actual != "$digest" ]]; then
    echo "Candidate digest differs from the image tagged $expected." >&2
    exit 1
  fi
done
printf '%s\n' "$digest"
