#!/usr/bin/env bash
# Usage: test-shard.sh <index>/<total> [go test flags...]      (run by `make test-shard`)
# One CI shard of `make test`: the same go test run (-shuffle=on, -coverpkg=./pkg/platform/...), limited to the packages
# shard.sh go-packages puts in shard <index>. Writes $BACKEND_DIR/cover-platform-shard-<index>-of-<total>.out. There is
# no coverage gate here, because one shard's coverage means nothing on its own: `make test-cover` merges every shard's
# profile and gates the result. Every package profiles every pkg/platform block (-coverpkg), so the merged profile has
# the same blocks as one `make test` run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
spec=${1:?usage: test-shard.sh <index>/<total> [go test flags...]}
shift
pkgs=()
while IFS= read -r p; do pkgs+=("$p"); done < <(bash "$here/shard.sh" go-packages "$spec")
# A failed shard.sh leaves pkgs empty; never fall back to ./... (the whole suite).
[ "${#pkgs[@]}" -gt 0 ] || { echo "test-shard.sh: no packages for shard $spec" >&2; exit 1; }
cd "$here/../../${BACKEND_DIR:-backend}"
echo "==> go test, unit shard $spec (${#pkgs[@]} packages)"
go test "$@" -shuffle=on -coverprofile="cover-platform-shard-${spec%/*}-of-${spec#*/}.out" -coverpkg=./pkg/platform/... \
	"${pkgs[@]}"
