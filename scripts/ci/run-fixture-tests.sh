#!/usr/bin/env bash
# Usage: run-fixture-tests.sh
# Runs the three fixture-test suites the promotion-scripts job needs (scripts/promotion/test/run.sh, promote-test.sh and
# scripts/ci/test/run.sh) at the same time instead of one after the other. Each suite is a separate bash process with its
# own mktemp directory and its own log, so none can disturb another; nothing they assert changes. Logs are printed
# one after the other in the fixed order below once all three are done, and the exit status is non-zero if any
# suite failed (every PID is waited for on its own: a bare `wait` would return 0).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT

suites=(scripts/promotion/test/run.sh scripts/promotion/test/promote-test.sh scripts/ci/test/run.sh)
pids=()
for i in "${!suites[@]}"; do
	bash "${suites[$i]}" >"$logs/$i.log" 2>&1 &
	pids[i]=$!
done

failed=0
for i in "${!suites[@]}"; do
	wait "${pids[$i]}"
	rc=$?
	echo "::group::${suites[$i]} (exit $rc)"
	cat "$logs/$i.log"
	echo "::endgroup::"
	if [ "$rc" != 0 ]; then
		echo "::error::${suites[$i]} failed (exit $rc)"
		failed=1
	fi
done
exit "$failed"
