#!/usr/bin/env bash
# Usage: resolve-rollback.sh <service.json> <last-good-revision.json> <images.json> <flag-ceiling.json> <env>
# Resolves the rollback target from the recorded `last-good` traffic tag ONLY (never "previous revision by number",
# which can be a Terraform-made, never-smoke-tested revision). Fails if the tag is missing, the revision JSON is for a
# different revision, the image digest is gone from Artifact Registry, the image is older than a `rollback_floors` commit in
# <flag-ceiling.json> while that flag is not `off` (or has no commit tag), or the revision fails validate-revision.sh.
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
# PREFLIGHT=1 (set by promote-dev.sh before it moves traffic) proves the target would be usable later, so it may still be serving.
if [ "${PREFLIGHT:-0}" != "1" ] && [ "$target" = "$serving" ]; then
  echo "FAIL: last-good is the revision already serving; rolling back would be a no-op" >&2
  exit 1
fi

image=$(jqr '.spec.containers[0].image // empty' "$rev")
case $image in *@sha256:*) digest=sha256:${image##*@sha256:} ;; *) echo "FAIL: last-good image is not pinned by digest" >&2; exit 1 ;; esac
pkg=${image%@*}
[ "$(jqr --arg d "$digest" --arg p "$pkg" '[.[] | select(.version == $d and .package == $p)] | length' "$images")" -ge 1 ] \
  || { echo "FAIL: image digest of '$target' is no longer in Artifact Registry" >&2; exit 1; }

# Rollback floors (W3-42, W3-36 M-1(b)): a flag with a floor in <flag-ceiling.json> may only be rolled back to an image built
# from the floor commit or later, unless the flag is `off` on the rollback target. The revision pins only @sha256:, so the image's
# commit is its 40-hex Artifact Registry tag (the github.sha IMAGE_TAG). Everything unreadable or unproven REFUSES.
# ROLLBACK_REPO (default: the repo holding this script) is where `git merge-base --is-ancestor` runs; it needs full history.
repo=${ROLLBACK_REPO:-$(cd "$here/../.." && pwd)}
for flag in $(jqr '.rollback_floors // {} | keys[] | select(startswith("_") | not)' "$ceil"); do
  mode=$(jqr --arg f "FEATURE_$flag" '[.spec.containers[0].env // [] | .[] | select(.name == $f)] | first | .value // empty' "$rev")
  mode=${mode:-$(jqr --arg e "$env" --arg f "$flag" '.unset_default[$e][$f] // "off"' "$ceil")}
  [ "$mode" != "off" ] || { echo "ok: $flag is off on '$target'; its rollback floor is not enforced" >&2; continue; }
  floor=$(jqr --arg f "$flag" '.rollback_floors[$f].commit // empty' "$ceil")
  [[ $floor =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL: rollback floor for $flag is not a 40-hex commit; refusing" >&2; exit 1; }
  git -C "$repo" cat-file -e "$floor^{commit}" 2>/dev/null \
    || { echo "FAIL: rollback floor ${floor:0:8} for $flag is not in the checkout (shallow clone? the job needs full history); refusing" >&2; exit 1; }
  commits=$(jqr --arg d "$digest" --arg p "$pkg" '[.[] | select(.version == $d and .package == $p) | .tags[]? | select(test("^[0-9a-f]{40}$"))] | unique | .[]' "$images")
  [ -n "$commits" ] || { echo "FAIL: image of '$target' has no commit tag, so it cannot be shown to be at or after the $flag rollback floor ${floor:0:8}; refusing (flag is $mode)" >&2; exit 1; }
  for c in $commits; do
    git -C "$repo" merge-base --is-ancestor "$floor" "$c" 2>/dev/null \
      || { echo "FAIL: image of '$target' (commit ${c:0:8}) is older than, or not provably after, the $flag rollback floor ${floor:0:8} (flag is $mode); roll forward with a fix instead (docs/runbooks/rollback.md)" >&2; exit 1; }
  done
done

"$here/validate-revision.sh" "$rev" "$ceil" "$env" >&2 || { echo "FAIL: rollback target '$target' fails validation" >&2; exit 1; }
echo "$target"
