#!/usr/bin/env bash
# Fixture tests for the CI shard scripts (scripts/ci). No network, no toolchains: shard.sh runs against a throwaway
# app/backend tree and against this checkout, cover.sh merge against made-up profiles. cover.sh gate needs Go and the
# real sources, so `make test` and `make test-int-cover` exercise it in CI instead.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ci=$(dirname "$here")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0

# expect <name> <want-exit> <command...>   (stdout goes to $tmp/out, stderr to $tmp/err)
expect() {
	local name=$1 want=$2
	shift 2
	"$@" >"$tmp/out" 2>"$tmp/err"
	local rc=$?
	if [ "$rc" = "$want" ]; then
		pass=$((pass + 1))
	else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/    /' "$tmp/out" "$tmp/err"
		failed=$((failed + 1))
	fi
}
# expect_out <name> <want stdout> <command...>: exit 0 and exactly that stdout
expect_out() {
	local name=$1 want=$2
	shift 2
	expect "$name" 0 "$@"
	if [ "$(cat "$tmp/out")" != "$want" ]; then
		echo "FAIL $name: stdout differs"
		diff <(printf '%s\n' "$want") "$tmp/out" | sed 's/^/    /'
		failed=$((failed + 1))
	fi
}
# expect_err <name> <pattern> <command...>: exit 1 and stderr containing the pattern
expect_err() {
	local name=$1 pat=$2
	shift 2
	expect "$name" 1 "$@"
	if ! grep -q -- "$pat" "$tmp/err"; then
		echo "FAIL $name: stderr lacks '$pat'"
		sed 's/^/    /' "$tmp/err"
		failed=$((failed + 1))
	fi
}

shard() { bash "$ci/shard.sh" "$@"; }

# --- usage ---
expect usage-none 2 shard
expect usage-mode 2 shard unit-files 0/1
expect usage-spec 2 shard go-run 1
expect usage-nan 2 shard go-run a/b
expect usage-zero-total 2 shard go-run 0/0
expect usage-index-too-big 2 shard flutter-files 3/3

# --- fixture tree ---
fx=$tmp/fx
mkdir -p "$fx/app/test/b" "$fx/app/test/support" "$fx/app/lib" "$fx/backend/p1/testdata" "$fx/backend/p2"
touch "$fx/app/test/a_test.dart" "$fx/app/test/b/c_test.dart" "$fx/app/test/z_test.dart" "$fx/app/test/b/a_test.dart" \
	"$fx/app/test/support/helpers.dart" "$fx/app/lib/not_test.dart.txt"
cat >"$fx/backend/p1/a_test.go" <<'EOF'
package p1

func TestMain(m *testing.M) {}
func TestB(t *testing.T) {}
func TestA(t *testing.T) {}
func ExampleA() {}
func FuzzParse(f *testing.F) {}
func helper() {}
	func TestIndentedIsNotTopLevel(t *testing.T) {}
EOF
cat >"$fx/backend/p2/b_test.go" <<'EOF'
//go:build integration

package p2

func TestA(t *testing.T) {}
func TestC_sub(t *testing.T) {}
EOF
echo 'func TestInTestdata(t *testing.T) {}' >"$fx/backend/p1/testdata/x_test.go"
echo 'func TestNotATestFile(t *testing.T) {}' >"$fx/backend/p1/a.go"
fxenv=(env APP_DIR="$fx/app" BACKEND_DIR="$fx/backend")

# Sorted (LC_ALL=C): test/a_test.dart test/b/a_test.dart test/b/c_test.dart test/z_test.dart
expect_out flutter-all "$(printf '%s\n' test/a_test.dart test/b/a_test.dart test/b/c_test.dart test/z_test.dart)" \
	"${fxenv[@]}" bash "$ci/shard.sh" flutter-files 0/1
expect_out flutter-0of2 "$(printf '%s\n' test/a_test.dart test/b/c_test.dart)" "${fxenv[@]}" bash "$ci/shard.sh" flutter-files 0/2
expect_out flutter-1of2 "$(printf '%s\n' test/b/a_test.dart test/z_test.dart)" "${fxenv[@]}" bash "$ci/shard.sh" flutter-files 1/2
expect_err flutter-empty "is empty" "${fxenv[@]}" bash "$ci/shard.sh" flutter-files 4/5

# Names, sorted and unique (TestA is in both packages; TestMain, testdata/, non-_test.go and indented decls are out):
# ExampleA FuzzParse TestA TestB TestC_sub
expect_out go-all '^(ExampleA|FuzzParse|TestA|TestB|TestC_sub)$' "${fxenv[@]}" bash "$ci/shard.sh" go-run 0/1
expect_out go-0of2 '^(ExampleA|TestA|TestC_sub)$' "${fxenv[@]}" bash "$ci/shard.sh" go-run 0/2
expect_out go-1of2 '^(FuzzParse|TestB)$' "${fxenv[@]}" bash "$ci/shard.sh" go-run 1/2
expect_out go-leading-zero '^(FuzzParse|TestB)$' "${fxenv[@]}" bash "$ci/shard.sh" go-run 01/02
expect_err go-empty "is empty" "${fxenv[@]}" bash "$ci/shard.sh" go-run 5/6
mkdir -p "$tmp/nobackend"
expect_err go-no-tests "is empty" env BACKEND_DIR="$tmp/nobackend" bash "$ci/shard.sh" go-run 0/1

expect_out go-names-1of2 "$(printf '%s\n' FuzzParse TestB)" "${fxenv[@]}" bash "$ci/shard.sh" go-names 1/2

# --- this checkout: for several shard counts the shards are disjoint and together are exactly the whole suite ---
# go-names is the whole list (one regex for every name is over go-run's size limit); go-run must hold the same names.
items_of() { # <mode> <spec>: one item per line (go-run regexes are unpacked into names)
	if [ "$1" = go-run ]; then shard go-run "$2" | sed -E 's/^\^\(//; s/\)\$$//' | tr '|' '\n'; else shard "$1" "$2"; fi
}
for mode in flutter-files go-run; do
	full=$mode
	[ "$mode" = go-run ] && full=go-names
	shard "$full" 0/1 >"$tmp/all" || { echo "FAIL repo-$mode: shard.sh $full 0/1 failed"; failed=$((failed + 1)); continue; }
	[ -s "$tmp/all" ] || { echo "FAIL repo-$mode: no items in this checkout"; failed=$((failed + 1)); continue; }
	for n in 2 3 4 7; do
		: >"$tmp/union"
		for ((i = 0; i < n; i++)); do items_of "$mode" "$i/$n" >>"$tmp/union"; done
		if [ "$(LC_ALL=C sort "$tmp/union")" = "$(LC_ALL=C sort "$tmp/all")" ]; then
			pass=$((pass + 1))
		else
			echo "FAIL repo-$mode-$n: the $n shards are not a partition of the suite"
			diff <(LC_ALL=C sort "$tmp/all") <(LC_ALL=C sort "$tmp/union") | head -10 | sed 's/^/    /'
			failed=$((failed + 1))
		fi
	done
done

# --- cover.sh merge ---
cov=$tmp/cov
mkdir -p "$cov"
for i in 0 1 2; do printf 'mode: atomic\npkg/f.go:1.1,2.2 1 %s\npkg/g.go:3.1,4.2 2 0\n' "$i" >"$cov/c-shard-$i-of-3.out"; done
expect merge-ok 0 bash "$ci/cover.sh" merge "$cov/m.out" "$cov/c-shard-0-of-3.out" "$cov/c-shard-1-of-3.out" "$cov/c-shard-2-of-3.out"
if [ "$(grep -c '^mode: ' "$cov/m.out")" = 1 ] && [ "$(head -1 "$cov/m.out")" = "mode: atomic" ] && [ "$(wc -l <"$cov/m.out" | tr -d ' ')" = 7 ]; then
	pass=$((pass + 1))
else
	echo "FAIL merge-ok-content: want one leading mode line and the 6 blocks"
	sed 's/^/    /' "$cov/m.out"
	failed=$((failed + 1))
fi
expect_err merge-missing "shard 1 of 3 is missing" bash "$ci/cover.sh" merge "$cov/m.out" "$cov/c-shard-0-of-3.out" "$cov/c-shard-2-of-3.out"
expect_err merge-twice "given twice" bash "$ci/cover.sh" merge "$cov/m.out" "$cov/c-shard-0-of-3.out" "$cov/c-shard-0-of-3.out" "$cov/c-shard-2-of-3.out"
printf 'mode: atomic\n' >"$cov/c-shard-1-of-2.out"
expect_err merge-mixed "different shard counts" bash "$ci/cover.sh" merge "$cov/m.out" "$cov/c-shard-0-of-3.out" "$cov/c-shard-1-of-2.out"
printf 'mode: set\npkg/f.go:1.1,2.2 1 1\n' >"$cov/s-shard-1-of-2.out"
printf 'mode: atomic\n' >"$cov/s-shard-0-of-2.out"
expect_err merge-mode "want 'mode: atomic'" bash "$ci/cover.sh" merge "$cov/m.out" "$cov/s-shard-0-of-2.out" "$cov/s-shard-1-of-2.out"
printf 'pkg/f.go:1.1,2.2 1 1\n' >"$cov/n-shard-0-of-1.out"
expect_err merge-no-mode "mode line" bash "$ci/cover.sh" merge "$cov/m.out" "$cov/n-shard-0-of-1.out"
expect_err merge-name "not named" bash "$ci/cover.sh" merge "$cov/m.out" "$cov/m.out"
expect_err merge-unexpanded-glob "no profile at" bash "$ci/cover.sh" merge "$cov/m.out" "$cov/none-shard-*-of-*.out"
expect_err merge-none "no shard profiles" bash "$ci/cover.sh" merge "$cov/m.out"
expect_err gate-no-profile "no profile at" bash "$ci/cover.sh" gate "$cov/absent.out" 70 internal/
expect usage-cover 1 bash "$ci/cover.sh" frobnicate

echo "scripts/ci fixture tests: $pass passed, $failed failed"
[ "$failed" = 0 ]
