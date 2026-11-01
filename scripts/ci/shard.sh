#!/usr/bin/env bash
# Usage: shard.sh flutter-files <index>/<total>   test files of shard <index> (0-based), one per line, relative to app/
#        shard.sh go-names <index>/<total>        top-level Go test names of shard <index>, one per line
#        shard.sh go-run <index>/<total>          the same names as one `go test -run` regex, ^(A|B|...)$
# Splits CI's two slow suites (flutter test, test-int) into <total> disjoint shards that together hold every test, so
# .github/workflows/ci.yml can run them as parallel jobs. The split is round robin over a byte-sorted list (LC_ALL=C), so
# it depends only on the checkout and every machine computes the same shards. A shard with nothing in it is an error
# (exit 1), never "run everything": `flutter test` with no file arguments runs the whole suite.
#
# flutter-files: every test/**/*_test.dart under APP_DIR (default app), the set a bare `flutter test` runs. The unit is a
#   file: flutter's own --total-shards splits the tests inside each file, so every shard would still compile every file.
# go-run: every top-level Test/Example/Fuzz function name in BACKEND_DIR's (default backend) *_test.go files, whatever their
#   build tags. The unit is the name, not the package: a name is in exactly one shard, so a name two packages share runs
#   in both of them in that one shard, and `go test -run <regex> ./...` keeps go's package parallelism. The scan relies on
#   gofmt (make fmt) starting every top-level declaration at column 0. A name with no test under the current build tags
#   matches nothing, which is harmless.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
usage="usage: shard.sh flutter-files|go-names|go-run <index>/<total>"

mode=${1:-}
spec=${2:-}
case "$mode" in flutter-files | go-names | go-run) ;; *) echo "$usage" >&2; exit 2 ;; esac
[[ $spec =~ ^([0-9]+)/([0-9]+)$ ]] || { echo "$usage (got '$spec')" >&2; exit 2; }
index=$((10#${BASH_REMATCH[1]}))
total=$((10#${BASH_REMATCH[2]}))
if [ "$total" -lt 1 ] || [ "$index" -ge "$total" ]; then
	echo "shard $spec: need 0 <= index < total" >&2
	exit 2
fi

items() {
	cd "$root"
	case "$mode" in
	flutter-files)
		(cd "${APP_DIR:-app}" && find test -type f -name '*_test.dart') ;;
	go-names | go-run)
		# go ignores testdata directories, so their files are not tests. No match (grep exit 1) leaves the shard empty.
		{ grep -rhoE --include='*_test.go' --exclude-dir=testdata '^func (Test|Example|Fuzz)[[:alnum:]_]*\(' "${BACKEND_DIR:-backend}" || [ $? = 1 ]; } |
			sed -E 's/^func //; s/\($//; /^TestMain$/d' ;;
	esac | LC_ALL=C sort -u
}

mine=$(items | awk -v i="$index" -v n="$total" '(NR - 1) % n == i')
if [ -z "$mine" ]; then
	echo "shard $spec of $mode is empty: lower the shard count" >&2
	exit 1
fi

case "$mode" in
flutter-files | go-names) printf '%s\n' "$mine" ;;
go-run)
	run="^($(printf '%s\n' "$mine" | paste -sd '|' -))\$"
	# One argv string; Linux caps a single argument at 128 KiB (MAX_ARG_STRLEN).
	if [ "${#run}" -gt 100000 ]; then
		echo "shard $spec: -run regex is ${#run} bytes, over 100000: raise the test-int shard count in ci.yml" >&2
		exit 1
	fi
	printf '%s\n' "$run" ;;
esac
