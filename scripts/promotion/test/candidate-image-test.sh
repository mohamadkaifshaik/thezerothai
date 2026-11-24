#!/usr/bin/env bash
set -euo pipefail
check="$(dirname "$0")/../check-candidate-image.sh"
repo=registry.example/project/repo/api
sha=$(printf 'a%.0s' {1..40})
digest=sha256:$(printf '1%.0s' {1..64})
other=sha256:$(printf '2%.0s' {1..64})
release_digest=$digest
source_digest=$digest
export repo sha release_digest source_digest
gcloud() {
  case "$5" in
    "$repo:v1.0.0") printf '%s\n' "$release_digest" ;;
    "$repo:v1.0.0-$sha") [[ -n $source_digest ]] && printf '%s\n' "$source_digest" ;;
    *) return 1 ;;
  esac
}
export -f gcloud
verify() { bash "$check" "$1" v1.0.0 "$sha"; }
[[ $(verify "$repo@$digest") == "$digest" ]]
if verify "$repo:v1.0.0"; then exit 1; fi
if release_digest=$other verify "$repo@$digest"; then exit 1; fi
if source_digest=$other verify "$repo@$digest"; then exit 1; fi
if source_digest='' verify "$repo@$digest"; then exit 1; fi
echo "5 candidate image cases passed"
