#!/usr/bin/env bash
# Usage: changed-groups.sh < <changed paths, one per line>     (repo-relative; `git diff --name-only --no-renames`)
#        changed-groups.sh --all                               (every group on: not a pull request, or the diff failed)
# Prints which of ci.yml's job groups a change needs, as `name=true|false` lines for $GITHUB_OUTPUT:
#   go_checks  gofmt/vet/lint/buf/govulncheck/osv-scanner   backend, app (osv-scanner reads pubspec.lock)
#   go_unit    go unit shards + their coverage gate          backend, infra (Go tests read infra/terraform/modules/*)
#   int        test-int shards + their coverage gate         backend
#   flutter    flutter analyze + test shards                 app
#   promotion  promotion scripts (shellcheck, actionlint, fixture tests, flag registry, until-dates)
#                                                            backend (config.go), infra (flag registry, until-dates)
#   crypto     MLS core (Rust): the crypto job (in make-ci)  crypto, app/rust, app/lib/core/crypto, app/integration_test,
#                                                            app/web
#                                                            (testdata/mls and scripts/crypto are shared paths: everything runs)
#   crypto_web the advisory web integration job (not in make-ci)  whenever crypto is on, and app/lib/core/vault,
#                                                            app/lib/features/keys (Dart only: no Rust job for them)
#   android    Android debug build on Linux (Rust via cargo-ndk)  crypto, app/rust, app/rust_builder, app/android,
#                                                            app/pubspec.yaml, app/pubspec.lock (not other app code; .github is shared: everything runs)
# Every path is classified by its first match; anything that is not clearly one of the kinds below, anything shared
# (proto, testdata, scripts, Makefile, .github, firebase, root files, loadtest, ...) turns every group on. Fail open:
# an empty list or an unreadable one is "everything", never "nothing". A path in the docs kind (docs/, .claude/,
# scratchpad/, README.md, releases/*.md) needs no job at all.
set -uo pipefail

groups="go_checks go_unit int flutter promotion crypto crypto_web android"

emit_all() {
	local g
	for g in $groups; do echo "$g=true"; done
}

if [ "${1:-}" = "--all" ]; then
	emit_all
	exit 0
fi

backend=0 app=0 infra=0 crypto=0 crypto_web=0 android=0 other=0 seen=0
while IFS= read -r p || [ -n "$p" ]; do
	p=${p%$'\r'}
	[ -n "$p" ] || continue
	seen=1
	case "$p" in
	docs/* | .claude/* | scratchpad/* | README.md | releases/*.md) ;;
	backend/*) backend=1 ;;
	crypto/*) crypto=1 android=1 ;;
	app/rust/*) app=1 crypto=1 android=1 ;;
	app/lib/core/crypto/* | app/integration_test/* | app/web/*) app=1 crypto=1 ;;
	app/lib/core/vault/* | app/lib/features/keys/*) app=1 crypto_web=1 ;;
	app/rust_builder/* | app/android/* | app/pubspec.yaml | app/pubspec.lock) app=1 android=1 ;;
	app/*) app=1 ;;
	infra/terraform/*) infra=1 ;;
	*) other=1 ;;
	esac
done

if [ "$seen" = 0 ] || [ "$other" = 1 ]; then
	emit_all
	exit 0
fi

flag() { [ "$1" = 1 ] && echo true || echo false; }
echo "go_checks=$(flag $((backend | app)))"
echo "go_unit=$(flag $((backend | infra)))"
echo "int=$(flag "$backend")"
echo "flutter=$(flag "$app")"
echo "promotion=$(flag $((backend | infra)))"
echo "crypto=$(flag "$crypto")"
echo "crypto_web=$(flag $((crypto | crypto_web)))"
echo "android=$(flag "$android")"
