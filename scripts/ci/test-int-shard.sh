#!/usr/bin/env bash
# Usage: test-int-shard.sh <index>/<total> [go test flags...]      (run by `make test-int-shard`, inside emulators:exec)
# One CI shard of `make test-int`: the same go test run (integration tag, -coverpkg=./internal/..., every package),
# limited to the top-level tests that shard.sh puts in shard <index>. Writes
# $BACKEND_DIR/cover-internal-shard-<index>-of-<total>.out. There is no coverage gate here, because one shard's coverage
# means nothing on its own: `make test-int-cover` merges every shard's profile and gates the result.
# A script and not an inline emulators:exec string: firebase-tools runs that string through the OS default shell
# (cmd.exe on Windows), and the -run regex is too long, and too full of metacharacters, to quote for both shells.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
spec=${1:?usage: test-int-shard.sh <index>/<total> [go test flags...]}
shift
run=$(bash "$here/shard.sh" go-run "$spec")
cd "$here/../../${BACKEND_DIR:-backend}"
echo "==> go test, test-int shard $spec ($(tr -cd '|' <<<"$run" | wc -c | awk '{print $1 + 1}') test names)"
go test -tags=integration "$@" -coverprofile="cover-internal-shard-${spec%/*}-of-${spec#*/}.out" -coverpkg=./internal/... \
	-run "$run" ./...
