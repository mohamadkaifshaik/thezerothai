#!/usr/bin/env bash
# Usage: resolve-rollback.sh <service.json> <last-good-revision.json> <images.json> <flag-ceiling.json> <env>
# Resolves the rollback target from the recorded `last-good` traffic tag ONLY (never "previous revision by number",
# which can be a Terraform-made, never-smoke-tested revision). Fails if the tag is missing, the revision JSON is for a
# different revision, the image digest is gone from Artifact Registry, or the revision fails validate-revision.sh.
# <images.json> is `gcloud artifacts docker images list <repo>/<image> --format=json`. Prints the revision name.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
need_tool jq
[ $# -eq 5 ] || { echo "usage: see header" >&2; exit 2; }
svc=$1 rev=$2 images=$3 ceil=$4 env=$5
for f in "$svc" "$rev" "$images" "$ceil"; do need_file "$f"; done

target=$(jqr '[.status.traffic[] | select(.tag == "last-good")] | first | .revisionName // empty' "$svc")
[ -n "$target" ] || { echo "FAIL: no 'last-good' traffic tag; refusing to guess a rollback target" >&2; exit 1; }
[ "$(jqr '.metadata.name // empty' "$rev")" = "$target" ] || { echo "FAIL: revision JSON is not for '$target'" >&2; exit 1; }

serving=$(jqr '[.status.traffic[] | select((.percent // 0) == 100)] | first | .revisionName // empty' "$svc")
[ "$target" != "$serving" ] || { echo "FAIL: last-good is the revision already serving; rolling back would be a no-op" >&2; exit 1; }

image=$(jqr '.spec.containers[0].image // empty' "$rev")
case $image in *@sha256:*) digest=sha256:${image##*@sha256:} ;; *) echo "FAIL: last-good image is not pinned by digest" >&2; exit 1 ;; esac
pkg=${image%@*}
[ "$(jqr --arg d "$digest" --arg p "$pkg" '[.[] | select(.version == $d and .package == $p)] | length' "$images")" -ge 1 ] \
  || { echo "FAIL: image digest of '$target' is no longer in Artifact Registry" >&2; exit 1; }

"$here/validate-revision.sh" "$rev" "$ceil" "$env" >&2 || { echo "FAIL: rollback target '$target' fails validation" >&2; exit 1; }
echo "$target"
