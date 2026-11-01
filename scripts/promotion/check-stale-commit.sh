#!/usr/bin/env bash
# Usage: check-stale-commit.sh <run-sha> <main-head-sha> [compare.json]
#        check-stale-commit.sh --print-patterns
# deploy-dev.yml must not promote an older commit after main has moved on: the newer push starts its own run. The exception is a
# push that changes only paths in deploy-dev.yml's `paths-ignore` list; it starts no run, so refusing here would leave dev on the
# commit before this one (seen 2026-11-01: run 517 refused after a docs-only merge and nothing deployed). With the net diff
# <run-sha>...<head> limited to ignored paths, this run's deployable content equals head's and it may promote.
# compare.json is `gh api repos/<owner>/<repo>/compare/<run-sha>...<head>`. Fails closed unless head is strictly ahead and every
# changed path (and every rename's old path) is ignored. The API lists at most 300 files, so 300 or more fails closed too.
# Exit 0: promote. Exit 1: refuse. Exit 2: usage.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

# Must equal deploy-dev.yml's on.push.paths-ignore, in GitHub glob syntax; test/run.sh compares the two.
PATTERNS=("docs/**" "**/*.md" ".claude/**")

if [ "${1:-}" = "--print-patterns" ]; then
  printf '%s\n' "${PATTERNS[@]}"
  exit 0
fi
[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: $0 <run-sha> <main-head-sha> [compare.json]" >&2; exit 2; }
sha=$1
head=$2
hex40='^[0-9a-f]{40}$'
[[ $sha =~ $hex40 ]] && [[ $head =~ $hex40 ]] || { echo "FAIL: both commits must be 40-hex SHAs" >&2; exit 2; }

if [ "$sha" = "$head" ]; then
  echo "ok: this run is main's head (${sha:0:7})"
  exit 0
fi
refuse() {
  echo "::error::main has moved on (head ${head:0:7}, this run ${sha:0:7}): $*. Not promoting a stale commit; the newer run will." >&2
  exit 1
}
[ $# -eq 3 ] || refuse "no compare data"
need_tool jq
need_file "$3"

# GitHub globs to bash patterns: `**/` and `**` become `*`, which in [[ == ]] also matches `/`.
ignored() {
  local f=$1 pat p
  for pat in "${PATTERNS[@]}"; do
    p=${pat//\*\*\//*}
    p=${p//\*\*/*}
    # shellcheck disable=SC2053 # $p is a pattern on purpose
    [[ $f == $p ]] && return 0
  done
  return 1
}

status=$(jqr '.status // "missing"' "$3" 2>/dev/null) || refuse "unreadable compare data"
[ "$status" = "ahead" ] || refuse "head is not strictly ahead of this commit (compare status: $status)"
count=$(jqr 'if (.files | type) == "array" then .files | length else "missing" end' "$3")
[ "$count" != "missing" ] || refuse "the compare data has no file list"
[ "$count" -lt 300 ] || refuse "$count changed files; the compare API lists at most 300, so the change set cannot be checked"

code=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  ignored "$f" || code=$((code + 1))
done < <(jqr '.files[] | .filename, (.previous_filename // empty)' "$3")
[ "$code" -eq 0 ] || refuse "$code changed path(s) outside paths-ignore"

commits=$(jqr '.total_commits // "?"' "$3")
echo "::notice title=Stale check::main moved ${commits} commit(s) past this run (head ${head:0:7}) changing only paths-ignore files (${count}); those pushes start no run, so this run promotes."
