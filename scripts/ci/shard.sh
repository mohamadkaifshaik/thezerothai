#!/usr/bin/env bash
# Usage: shard.sh flutter-files <index>/<total>   test files of shard <index> (0-based), one per line, relative to app/
#        shard.sh go-names <index>/<total>        top-level Go test names of shard <index>, one per line
#        shard.sh go-run <index>/<total>          the same names as one `go test -run` regex, ^(A|B|...)$
#        shard.sh go-packages <index>/<total>     Go packages with tests of shard <index>, one ./dir per line
# Splits CI's slow suites (flutter test, test-int, go unit tests) into <total> disjoint shards that together hold every
# test, so .github/workflows/ci.yml can run them as parallel jobs. The split depends only on the checkout, so every
# machine computes the same shards. A shard with nothing in it is an error (exit 1), never "run everything": `flutter
# test` with no file arguments runs the whole suite.
#
# flutter-files: every test/**/*_test.dart under APP_DIR (default app), the set a bare `flutter test` runs. The unit is a
#   file: flutter's own --total-shards splits the tests inside each file, so every shard would still compile every file.
#   Files are bin-packed by size, a stand-in for run time: greedy, largest first (ties by byte-sorted name, LC_ALL=C),
#   each into the shard with the fewest bytes so far (ties to the lowest index). The size counts every byte except CR,
#   so a CRLF checkout (Windows, core.autocrlf=true: .dart has no eol attribute) computes the same shards as Linux CI.
# go-names / go-run: every top-level Test/Example/Fuzz function name in BACKEND_DIR's (default backend) *_test.go files,
#   whatever their build tags, round robin over the byte-sorted list. The unit is the name, not the package: a name is
#   in exactly one shard, so a name two packages share runs in both of them in that one shard, and `go test -run <regex>
#   ./...` keeps go's package parallelism. The scan relies on gofmt (make fmt) starting every top-level declaration at
#   column 0. A name with no test under the current build tags matches nothing, which is harmless. test-int uses these.
# go-packages: every directory under BACKEND_DIR holding a unit test file (a *_test.go without the exact line
#   `//go:build integration`), as `go test` would see it from BACKEND_DIR (./... skips testdata and directories starting with . or _),
#   bin-packed like flutter-files by the size of those unit test files. Packages with only integration tests are left
#   out: named without the tag, go fails them ("build constraints exclude all Go files"). The go unit tests use
#   packages, not names: their time is mostly compiling and linking race test binaries, which a name split would repeat
#   in every shard, and their slowest package (internal/identity) is one slow test that no split can divide.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
usage="usage: shard.sh flutter-files|go-names|go-run|go-packages <index>/<total>"

mode=${1:-}
spec=${2:-}
case "$mode" in flutter-files | go-names | go-run | go-packages) ;; *) echo "$usage" >&2; exit 2 ;; esac
[[ $spec =~ ^([0-9]+)/([0-9]+)$ ]] || { echo "$usage (got '$spec')" >&2; exit 2; }
index=$((10#${BASH_REMATCH[1]}))
total=$((10#${BASH_REMATCH[2]}))
if [ "$total" -lt 1 ] || [ "$index" -ge "$total" ]; then
	echo "shard $spec: need 0 <= index < total" >&2
	exit 2
fi

# <bytes>\t<file> for every flutter test file, CRs not counted; a file awk cannot read fails the whole run.
flutter_sizes() {
	cd "$root" && cd "${APP_DIR:-app}"
	find test -type f -name '*_test.dart' | LC_ALL=C sort -u | LC_ALL=C awk '
		{
			f = $0; b = 0
			while ((r = (getline line < f)) > 0) { gsub(/\r/, "", line); b += length(line) + 1 }
			if (r < 0) { print "shard.sh: cannot read " f > "/dev/stderr"; exit 1 }
			close(f)
			print b "\t" f
		}'
}

# <bytes>\t<dir> for every Go package with a unit test file; CRs and integration-tagged files do not count.
go_package_sizes() {
	cd "$root" && cd "${BACKEND_DIR:-backend}"
	find . -mindepth 1 -type d \( -name testdata -o -name '.*' -o -name '_*' \) -prune -o -type f -name '*_test.go' -print |
		LC_ALL=C sort -u | LC_ALL=C awk '
		{
			f = $0; b = 0; tagged = 0
			while ((r = (getline line < f)) > 0) {
				gsub(/\r/, "", line); b += length(line) + 1
				# Exactly the repo form. Any other constraint (!integration, a && b) counts as a unit file: if go then
				# cannot build the package without the tag, the shard fails loudly instead of the package running nowhere.
				if (line == "//go:build integration") tagged = 1
			}
			if (r < 0) { print "shard.sh: cannot read " f > "/dev/stderr"; exit 1 }
			close(f)
			d = f; sub(/\/[^\/]*$/, "", d)
			if (!tagged) size[d] += b
		}
		END { for (d in size) print size[d] "\t" d }'
}

# Reads <bytes>\t<item> lines; prints the items greedy bin packing puts in shard <index>, byte-sorted.
pack() {
	LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 | LC_ALL=C awk -F '\t' -v i="$index" -v n="$total" '
		BEGIN { for (s = 0; s < n; s++) load[s] = 0 }
		{
			best = 0
			for (s = 1; s < n; s++) if (load[s] < load[best]) best = s
			load[best] += $1
			if (best == i) print $2
		}' | LC_ALL=C sort
}

go_names() {
	cd "$root"
	# go ignores testdata directories, so their files are not tests. No match (grep exit 1) leaves the shard empty.
	{ grep -rhoE --include='*_test.go' --exclude-dir=testdata '^func (Test|Example|Fuzz)[[:alnum:]_]*\(' "${BACKEND_DIR:-backend}" || [ $? = 1 ]; } |
		sed -E 's/^func //; s/\($//; /^TestMain$/d' | LC_ALL=C sort -u
}

case "$mode" in
flutter-files)
	sizes=$(flutter_sizes)
	mine=$(if [ -n "$sizes" ]; then printf '%s\n' "$sizes" | pack; fi) ;;
go-packages)
	sizes=$(go_package_sizes)
	mine=$(if [ -n "$sizes" ]; then printf '%s
' "$sizes" | pack; fi) ;;
go-names | go-run)
	mine=$(go_names | awk -v i="$index" -v n="$total" '(NR - 1) % n == i') ;;
esac
if [ -z "$mine" ]; then
	echo "shard $spec of $mode is empty: lower the shard count" >&2
	exit 1
fi

case "$mode" in
flutter-files | go-names | go-packages) printf '%s\n' "$mine" ;;
go-run)
	run="^($(printf '%s\n' "$mine" | paste -sd '|' -))\$"
	# One argv string; Linux caps a single argument at 128 KiB (MAX_ARG_STRLEN).
	if [ "${#run}" -gt 100000 ]; then
		echo "shard $spec: -run regex is ${#run} bytes, over 100000: raise this suite's shard count in ci.yml" >&2
		exit 1
	fi
	printf '%s\n' "$run" ;;
esac
