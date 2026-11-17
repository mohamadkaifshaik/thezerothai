#!/usr/bin/env bash
# Usage: refresh-timings.sh flutter <job log>...       -> scripts/ci/timings/flutter.tsv     (ms per test file)
#        refresh-timings.sh go-names <job log>...      -> scripts/ci/timings/go-names.tsv   (ms per top-level Go test name)
#        refresh-timings.sh go-packages <job log>...   -> scripts/ci/timings/go-packages.tsv (ms per package with unit tests)
# Regenerates the timing files scripts/ci/shard.sh packs shards by (greedy, longest first). Each file is "<ms>\t<item>".
# shard.sh treats an item missing from a file as unmeasured and estimates it, so a stale file is slower, never wrong;
# refresh it now and then (after a big test is added or a suite doubles), from the logs of ONE recent green ci.yml run:
#   gh run list --workflow ci.yml --status success --limit 5
#   gh run view <run-id> --json jobs --jq '.jobs[] | [.databaseId, .name] | @tsv'
#   gh api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/<job-id>/logs > shard-<i>.log     (one per shard job)
#   bash scripts/ci/refresh-timings.sh flutter flutter-shard-*.log        # "flutter test (shard i of n)" jobs
#   bash scripts/ci/refresh-timings.sh go-names int-shard-*.log           # "make test-int (shard i of n)" jobs
#   bash scripts/ci/refresh-timings.sh go-packages unit-shard-*.log       # "go unit tests (shard i of n)" jobs
# How the numbers are derived (all of them estimates; CI logs carry no per-item clock):
#   flutter: flutter's github reporter prints one timestamped line per test; the time between a line and the one before
#     it in the same log is charged to the file of the later line (files run concurrently, so this is a rough share).
#   go-names: `go test` prints one `ok <pkg> <seconds>` line per package, not per test. For each shard log, a package's
#     seconds (less 1 s of startup) are split evenly over the package's test names that ran in that shard, so heavy
#     tests show up as heavy only through the shard they happened to share with their neighbours; a name two packages
#     share gets both shares. The names of a shard come from `shard.sh go-names <i>/<n>` as it is now: run this on the
#     logs of a run made at this checkout's test set and with the timings (or SHARD_TIMINGS_DIR=<none>) that run used.
#     Run test-int with -v and extend this script if that is not accurate enough.
#   go-packages: the package's `ok` seconds plus 1.5 s for compiling and linking its race test binary.
# Needs bash, awk, grep, sed. BACKEND_DIR (default backend) names the Go module for go-names.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$root/scripts/ci/timings
usage="usage: refresh-timings.sh flutter|go-names|go-packages <job log>..."
mode=${1:-}
[ "$#" -ge 2 ] || { echo "$usage" >&2; exit 2; }
shift
for f in "$@"; do [ -f "$f" ] || { echo "refresh-timings.sh: no log at $f" >&2; exit 2; }; done
tab=$(printf '\t')

# clean <log>...: ANSI colour and CRs out, the logs one after the other with a marker line after each.
clean() {
	local f
	for f in "$@"; do
		sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' "$f"
		echo "@@LOG-END"
	done
}

# ok_lines <log>...: "<package relative to backend>\t<ms>" for every passing package, "@@LOG-END" after each log.
ok_lines() {
	clean "$@" | awk -F '\t' '
		/^@@LOG-END/ { print; next }
		/Z ok[ \t]/ {
			pkg = $2; sec = $3
			sub(/.*\/backend\//, "", pkg); sub(/s$/, "", sec)
			if (sec ~ /^[0-9.]+$/) printf "%s\t%d\n", pkg, sec * 1000 + 0.5
		}'
}

case "$mode" in
flutter)
	clean "$@" | awk '
		/^@@LOG-END/ { prev = 0; next }
		/^[0-9-]+T[0-9:.]+Z / && /\/app\/test\/[^ ]*_test\.dart: / {
			split($1, a, "T"); split(a[2], t, ":"); s = t[1] * 3600 + t[2] * 60 + t[3]
			i = index($0, "/app/test/"); p = substr($0, i + 5); j = index(p, "_test.dart: "); p = substr(p, 1, j + 9)
			ms[p] += prev ? (s - prev) * 1000 : 0
			seen[p] = 1; prev = s
		}
		END { for (p in seen) printf "%d\t%s\n", (ms[p] < 100 ? 100 : ms[p] + 0.5), p }' |
		LC_ALL=C sort -t "$tab" -k2,2 >"$out/flutter.tsv" ;;
go-names)
	# <package>\t<name> for every top-level test name, the set shard.sh go-names finds.
	(cd "$root/${BACKEND_DIR:-backend}" && { grep -rE --include='*_test.go' --exclude-dir=testdata '^func (Test|Example|Fuzz)[[:alnum:]_]*\(' . || true; }) |
		sed -E 's#^\./(.*)/[^/]*_test\.go:func ([[:alnum:]_]+)\(.*#\1\t\2#' |
		LC_ALL=C sort -u | awk -F '\t' '$2 != "TestMain"' >"$out/.pkgnames.tmp"
	: >"$out/.weights.tmp"
	for f in "$@"; do
		# Which shard this log is: the job prints "==> go test, test-int shard <i>/<n> (...)".
		spec=$(clean "$f" | sed -n 's/.*==> go test, test-int shard \([0-9][0-9]*\/[0-9][0-9]*\).*/\1/p' | head -n 1)
		[ -n "$spec" ] || { echo "refresh-timings.sh: $f has no '==> go test, test-int shard i/n' line" >&2; exit 2; }
		bash "$root/scripts/ci/shard.sh" go-names "$spec" >"$out/.shardnames.tmp"
		ok_lines "$f" >"$out/.ok.tmp"
		# Per package of this log: its seconds (less 1 s startup) are split over the package's names that ran in this shard.
		awk -F '\t' '
			FILENAME ~ /\.ok\.tmp$/ { if ($1 != "@@LOG-END") t[$1] = $2; next }
			FILENAME ~ /\.shardnames\.tmp$/ { inshard[$1] = 1; next }
			{ if ($2 in inshard) { n[$1]++; pk[++m] = $1; nm[m] = $2 } }
			END {
				for (i = 1; i <= m; i++) {
					v = t[pk[i]] - 1000
					printf "%d\t%s\n", (v < 0 ? 0 : v) / n[pk[i]], nm[i]
				}
			}' "$out/.ok.tmp" "$out/.shardnames.tmp" "$out/.pkgnames.tmp" >>"$out/.weights.tmp"
	done
	awk -F '\t' '{ w[$2] += $1 } END { for (x in w) printf "%d\t%s\n", (w[x] < 10 ? 10 : w[x]), x }' "$out/.weights.tmp" |
		LC_ALL=C sort -t "$tab" -k2,2 >"$out/go-names.tsv"
	rm -f "$out"/.pkgnames.tmp "$out"/.weights.tmp "$out"/.shardnames.tmp "$out"/.ok.tmp ;;
go-packages)
	ok_lines "$@" | awk -F '\t' '!/^@@LOG-END/ { printf "%d\t./%s\n", $2 + 1500, $1 }' |
		LC_ALL=C sort -t "$tab" -k2,2 >"$out/go-packages.tsv" ;;
*) echo "$usage" >&2; exit 2 ;;
esac
echo "wrote $(wc -l <"$out/$mode.tsv" | tr -d ' ') rows to scripts/ci/timings/$mode.tsv"
