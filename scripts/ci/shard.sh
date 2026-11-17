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
# Timings: when scripts/ci/timings/<flutter|go-names|go-packages>.tsv (or $SHARD_TIMINGS_DIR/...) holds measured times, the
#   greedy packing above weighs items by those milliseconds instead of bytes (go-names: instead of round robin), and an
#   item with no measurement is estimated in ms from its size (go-names: the mean measured weight). Without such a file
#   nothing changes. scripts/ci/refresh-timings.sh regenerates the files from CI logs.
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

# Measured times: <SHARD_TIMINGS_DIR, default scripts/ci/timings>/<kind>.tsv holds "<ms>\t<item>" rows (refresh-timings.sh
# writes them from CI logs). A missing file, or one that matches nothing in this checkout, means "no timings": the
# packing below is then exactly the by-size packing (flutter, go-packages) or the round robin (go-names) described above.
timing_file() { printf '%s/%s.tsv' "${SHARD_TIMINGS_DIR:-$root/scripts/ci/timings}" "$1"; }

# weigh <kind>: reads <bytes>\t<item> lines, prints <weight>\t<item>. An item with a measured time weighs that many ms. An
# unmeasured one is estimated in the same unit, bytes * (measured ms / bytes of the measured items), so measured and
# estimated items stay comparable. With no measured item at all the weight is the byte count, as before. Rows of the
# timing file for items that are not in the input (stale) are ignored; CRs in the file are ignored (no eol attribute).
weigh() {
	local tf
	tf=$(timing_file "$1")
	[ -f "$tf" ] || tf=/dev/null
	LC_ALL=C awk -F '\t' -v tf="$tf" '
		BEGIN {
			while ((getline l < tf) > 0) {
				gsub(/\r/, "", l)
				if (split(l, a, "\t") == 2 && a[1] ~ /^[0-9]+$/ && a[2] != "") t[a[2]] = a[1] + 0
			}
		}
		{ n++; bytes[n] = $1 + 0; item[n] = $2; if ($2 in t) { ms += t[$2]; kb += $1 } }
		END {
			ratio = (kb > 0) ? ms / kb : 1
			for (i = 1; i <= n; i++) printf "%d\t%s\n", (item[i] in t) ? t[item[i]] : bytes[i] * ratio, item[i]
		}'
}

# weigh_names: reads names, prints <weight>\t<name> when at least one has a measured time (an unmeasured name weighs the
# mean of the measured ones), prints nothing when none has.
weigh_names() {
	local tf
	tf=$(timing_file go-names)
	[ -f "$tf" ] || { cat >/dev/null; return 0; } # drain stdin: a writer that gets SIGPIPE fails the pipeline (pipefail)
	LC_ALL=C awk -F '\t' -v tf="$tf" '
		BEGIN {
			while ((getline l < tf) > 0) {
				gsub(/\r/, "", l)
				if (split(l, a, "\t") == 2 && a[1] ~ /^[0-9]+$/ && a[2] != "") t[a[2]] = a[1] + 0
			}
		}
		{ n++; item[n] = $1; if ($1 in t) { known++; sum += t[$1] } }
		END {
			if (!known) exit
			mean = sum / known
			for (i = 1; i <= n; i++) printf "%d\t%s\n", (item[i] in t) ? t[item[i]] : mean, item[i]
		}'
}

case "$mode" in
flutter-files)
	sizes=$(flutter_sizes)
	mine=$(if [ -n "$sizes" ]; then printf '%s\n' "$sizes" | weigh flutter | pack; fi) ;;
go-packages)
	sizes=$(go_package_sizes)
	mine=$(if [ -n "$sizes" ]; then printf '%s\n' "$sizes" | weigh go-packages | pack; fi) ;;
go-names | go-run)
	names=$(go_names)
	weighted=$(printf '%s\n' "$names" | weigh_names)
	if [ -n "$weighted" ]; then
		mine=$(printf '%s\n' "$weighted" | pack)
	else
		mine=$(printf '%s\n' "$names" | awk -v i="$index" -v n="$total" 'NF && (++k - 1) % n == i')
	fi ;;
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
