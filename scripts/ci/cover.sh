#!/usr/bin/env bash
# Usage: cover.sh gate <profile> <threshold> <label>      fail when the profile's total coverage is under <threshold>%
#        cover.sh merge <out> <shard profile>...          merge one run's shard profiles (*-shard-<i>-of-<n>.out) into <out>
# The coverage gates of `make test` (pkg/platform) and `make test-int` / `make test-int-cover` (internal/, testing-strategy
# skill: 70%). gate runs `go tool cover` from the profile's directory, which must be the Go module (backend/), because the
# tool reads the source files to find functions.
# merge refuses an incomplete or mixed set (every index 0..n-1 exactly once, one n, one mode line), so a missing shard
# can never be gated as if it were the whole run. It writes the first mode line once, then every profile's blocks;
# `go tool cover` adds up blocks that appear more than once (each test binary reports every -coverpkg package).
set -euo pipefail
fail() { echo "cover.sh: $*" >&2; exit 1; }

gate() {
	local profile=$1 threshold=$2 label=$3 total pct
	[ -f "$profile" ] || fail "no profile at $profile"
	total=$(cd "$(dirname "$profile")" && go tool cover -func="$(basename "$profile")" | tail -1)
	echo "$total"
	pct=$(awk '{print $NF}' <<<"$total" | tr -d '%')
	awk -v p="$pct" -v t="$threshold" 'BEGIN { exit !(p != "" && p + 0 >= t + 0) }' ||
		fail "$label coverage ${pct}% < ${threshold}% threshold"
}

merge() {
	local out=$1 f n="" mode
	shift
	[ "$#" -gt 0 ] || fail "merge: no shard profiles given"
	local -A seen=()
	for f in "$@"; do
		[ -f "$f" ] || fail "merge: no profile at $f"
		[[ $(basename "$f") =~ -shard-([0-9]+)-of-([0-9]+)\.out$ ]] || fail "merge: $f is not named *-shard-<i>-of-<n>.out"
		n=${n:-${BASH_REMATCH[2]}}
		[ "${BASH_REMATCH[2]}" = "$n" ] || fail "merge: profiles from different shard counts ($n and ${BASH_REMATCH[2]})"
		[ -z "${seen[${BASH_REMATCH[1]}]:-}" ] || fail "merge: shard ${BASH_REMATCH[1]} given twice"
		seen[${BASH_REMATCH[1]}]=$f
	done
	local i
	for ((i = 0; i < n; i++)); do
		[ -n "${seen[$i]:-}" ] || fail "merge: shard $i of $n is missing"
	done
	[ "$#" = "$n" ] || fail "merge: $# profiles for $n shards"
	mode=$(head -1 "$1")
	[[ $mode == "mode: "?* ]] || fail "merge: $1 does not start with a mode line"
	for f in "$@"; do
		[ "$(head -1 "$f")" = "$mode" ] || fail "merge: $f has '$(head -1 "$f")', want '$mode'"
	done
	{
		echo "$mode"
		for f in "$@"; do tail -n +2 "$f"; done
	} >"$out"
	echo "merged $n shard profiles into $out"
}

case "${1:-}" in
gate) [ "$#" = 4 ] || fail "usage: cover.sh gate <profile> <threshold> <label>"; gate "$2" "$3" "$4" ;;
merge) [ "$#" -ge 2 ] || fail "usage: cover.sh merge <out> <shard profile>..."; shift; merge "$@" ;;
*) fail "usage: cover.sh gate|merge ..." ;;
esac
