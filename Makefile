# Root Makefile (works with GNU Make 3.81+ on Windows Git Bash and on Linux CI/ubuntu).
# Every recipe line runs in `bash` so the same syntax works on both platforms.
SHELL := bash
# .SHELLFLAGS needs GNU Make 3.82+; on 3.81 it's silently ignored (recipes still run, just without
# -eu -o pipefail strictness) so this stays compatible with both the 3.81 and 3.82+ requirement.
.SHELLFLAGS := -eu -o pipefail -c

BACKEND_DIR := backend
PROTO_DIR   := proto
APP_DIR     := app
# scripts/dev.sh (N8) reads these via the environment, not Make substitution, since it's invoked as its
# own process by `emulators:exec` rather than interpolated into a Make recipe line.
export BACKEND_DIR
export APP_DIR

# buf 1.73 may not be on PATH; fall back to the Go-installed location noted in the task brief.
BUF := $(shell command -v buf 2>/dev/null || echo "$$HOME/go/bin/buf")

# N9: -race requires cgo (a real C compiler on PATH). CI's Linux images have one, so CGO_ENABLED=1 there by
# default and -race stays on; plenty of local dev machines (this Windows box included) have CGO_ENABLED=0,
# where passing -race would simply fail to build instead of testing anything. Computed once, used by the
# `test` and `test-int` targets below so `make ci`/`make test`/`make test-int` all work out of the box on
# either platform without a flag callers have to remember.
RACE_FLAG := $(shell go env CGO_ENABLED 2>/dev/null | grep -qx 1 && echo -race || true)

# firebase-tools is not installed globally in this environment (and CI installs it fresh each run);
# use npx so `make emulators`/`make test-int`/`make dev` work the same locally and in CI without
# requiring `npm install -g firebase-tools`. -y avoids the interactive "ok to install" prompt.
FIREBASE := $(shell command -v firebase 2>/dev/null || echo "npx -y firebase-tools@latest")

# Fixed demo-* project for every emulator run ("demo-* projects are offline").
# Without an explicit --project, firebase-tools falls back to .firebaserc's "default" alias
# (dzeroth-dev) — a real-looking, non-demo project name; every emulator (Auth in particular, which is
# locked to one project by firebase.json's singleProjectMode) would then be pinned to that name instead
# of an obviously-fake one. Matches config.Config's own local-mode default project ID (config.go), so
# tests/e2e need no extra env var to agree with the running emulators on a project ID.
EMULATOR_PROJECT := demo-dzeroth-local

# Every recipe below that starts the Firebase Emulator Suite runs behind scripts/with-private-tmp.sh: a private,
# per-run TEMP/TMP/TMPDIR for the emulator process (and what it starts), removed afterwards. The Storage emulator
# keeps its blobs in os.tmpdir()/firebase/storage/blobs, shared by every suite on the machine whatever the ports and
# project ids, so two concurrent suites wiped each other's blobs and the first one crashed mid-upload (ENOENT, then
# the Auth emulator refused connections; test-report-w3 D-2). Run any raw `firebase emulators:*` the same way, and see
# `bash scripts/...` is a single cmd.exe-safe command line (see dev below).
EMULATOR_TMP := bash scripts/with-private-tmp.sh

.PHONY: proto ci emulators test-int test-int-shard test-int-cover dev cost loadtest fmt vet test buf-check lint flutter-analyze flutter-test help

help:
	@echo "Targets: proto ci emulators test-int dev cost loadtest fmt vet test"
	@echo "  ci = fmt vet test buf-check lint flutter-analyze flutter-test (CI runs them as parallel jobs)"
	@echo "  make flutter-test SHARD=0/3 | make test-int-shard SHARD=0/3 + make test-int-cover   # CI shards (scripts/ci/shard.sh)"
	@echo "  make loadtest SCENARIO=identity_getme   # runs loadtest/<scenario>.js with k6 (see loadtest/README.md)"
	@echo "  make cost PROJECT_ID=dzeroth-dev        # also queries live Cloud Logging usage"

## proto: buf lint + buf breaking (tolerant of a missing 'main' baseline, e.g. first commit) + generate.
proto:
	@echo "==> buf lint"
	"$(BUF)" lint $(PROTO_DIR)
	@echo "==> buf breaking (against local 'main', tolerant of a missing baseline)"
	@if git rev-parse --verify --quiet main >/dev/null 2>&1; then \
		"$(BUF)" breaking $(PROTO_DIR) --against '.git#branch=main,subdir=proto'; \
	else \
		echo "no local 'main' branch found (first commit / shallow clone) - skipping buf breaking"; \
	fi
	@echo "==> buf generate"
	cd $(PROTO_DIR) && "$(BUF)" generate

## fmt: gofmt check only (never rewrites files in CI). Generated code under backend/gen is never linted.
fmt:
	@echo "==> gofmt check"
	@bad=0; \
	for f in $$(find $(BACKEND_DIR) -name '*.go' -not -path '*/gen/*'); do \
		out=$$(gofmt -l "$$f"); \
		if [ -n "$$out" ]; then echo "not gofmt'd: $$out"; bad=1; fi; \
	done; \
	if [ $$bad -ne 0 ]; then exit 1; fi

## vet: go vet across the backend module.
vet:
	cd $(BACKEND_DIR) && go vet ./...

## test: unit tests only (no emulator needed) with the race detector. Coverage
## is gated here at 70% but only over pkg/platform (-coverpkg): internal/<module>'s repo_firestore.go paths
## need the Firestore emulator to exercise at all, so a unit-only run can never reach 70% honestly on
## internal/ — that combined (unit + integration) number is gated in test-int instead (testing-strategy
## skill: "coverage gate 70% on internal/"). pkg/platform has no such gap (fakes/emulator-free by design),
## so it can hold the line in every plain `go test` run, local or CI.
COVERAGE_THRESHOLD := 70
test:
	cd $(BACKEND_DIR) && go test $(RACE_FLAG) -shuffle=on -coverprofile=cover.out -coverpkg=./pkg/platform/... ./...
	@echo "==> pkg/platform coverage gate ($(COVERAGE_THRESHOLD)%)"
	@bash scripts/ci/cover.sh gate $(BACKEND_DIR)/cover.out $(COVERAGE_THRESHOLD) pkg/platform

## ci: everything make ci must pass before any agent declares work done. Prerequisites run left to right.
## .github/workflows/ci.yml runs the same targets as parallel jobs (flutter-test in shards) and reports them together
## under the required check "make ci (...)".
ci: fmt vet test buf-check lint flutter-analyze flutter-test

## buf-check: buf lint + buf breaking against origin/main (needs full git history for the baseline).
buf-check:
	@echo "==> buf lint"
	"$(BUF)" lint $(PROTO_DIR)
	@echo "==> buf breaking (against origin/main, tolerant of a missing ref/baseline e.g. first commit / no remote / proto not pushed yet)"
	@if git rev-parse --verify --quiet origin/main >/dev/null 2>&1 && git cat-file -e origin/main:$(PROTO_DIR) 2>/dev/null; then \
		"$(BUF)" breaking $(PROTO_DIR) --against '.git#branch=origin/main,subdir=proto'; \
	else \
		echo "no $(PROTO_DIR)/ found at origin/main - skipping buf breaking"; \
	fi

## lint: golangci-lint when it is installed (CI runs it through golangci-lint-action instead).
lint:
	@echo "==> golangci-lint"
	@if command -v golangci-lint >/dev/null 2>&1; then \
		cd $(BACKEND_DIR) && golangci-lint run ./...; \
	else \
		echo "golangci-lint not installed locally; skipping (CI installs and runs it)"; \
	fi

## flutter-analyze: flutter analyze, then the check that the CSP script-src carries the FlutterFire loader hashes.
flutter-analyze:
	@echo "==> flutter analyze"
	cd $(APP_DIR) && flutter analyze
	@echo "==> CSP script-src carries the FlutterFire loader hashes"
	bash scripts/csp/check-firebase-loader-hashes.sh firebase.json $(APP_DIR)

## flutter-test: flutter test. SHARD=<index>/<total> (0-based) runs only that shard's test files (scripts/ci/shard.sh),
## as CI does with one job per shard. An empty or invalid shard fails; it never falls back to the whole suite.
flutter-test:
	@echo "==> flutter test$(if $(SHARD), (shard $(SHARD)))"
	@if [ -z "$(SHARD)" ]; then \
		cd $(APP_DIR) && flutter test; \
	else \
		files=$$(bash scripts/ci/shard.sh flutter-files "$(SHARD)") || exit 1; \
		echo "$$(echo "$$files" | wc -l | tr -d ' ') test files"; \
		cd $(APP_DIR) && flutter test $$files; \
	fi

## emulators: Firebase Emulator Suite only (Firestore, Auth, Pub/Sub, Storage). $0, local dev/test.
emulators:
	$(EMULATOR_TMP) $(FIREBASE) emulators:start --project $(EMULATOR_PROJECT) --only firestore,auth,pubsub,storage

## test-int: emulator integration tests, backend/**/*_integration_test.go (//go:build integration), plus
## the combined (unit + integration) 70% coverage gate on internal/<module> that
## `make test`/`make ci` can't honestly enforce alone (repo_firestore.go paths need the emulator to be
## exercised at all — see the `test` target's comment). The coverage/threshold step runs as a normal Make
## recipe line *after* emulators:exec finishes, not inside its quoted script: that script runs through the
## OS default shell (cmd.exe on Windows, per the FIREBASE_PROJECT_ID note below), where the awk/tr pipeline
## below wouldn't parse; every line in this Makefile itself, by contrast, always runs under bash
## (SHELL := bash, top of file) regardless of platform, and cover-internal.out survives on disk once the
## emulators have shut down.
## FIREBASE_PROJECT_ID is exported here (make's own recipe shell, always bash per SHELL:=bash above), not
## inside the quoted script string passed to `emulators:exec` — firebase-tools runs that string via the
## OS default shell (cmd.exe on Windows), which doesn't understand `VAR=val cmd` inline-env syntax. Env
## vars set before a child process always propagate to it regardless of which shell the child itself uses.
export FIREBASE_PROJECT_ID := $(EMULATOR_PROJECT)
test-int:
	$(EMULATOR_TMP) $(FIREBASE) emulators:exec --project $(EMULATOR_PROJECT) --only firestore,auth,pubsub,storage \
		'cd $(BACKEND_DIR) && go test -tags=integration $(RACE_FLAG) -coverprofile=cover-internal.out -coverpkg=./internal/... ./...'
	@echo "==> internal/ coverage gate (combined unit + integration, $(COVERAGE_THRESHOLD)%)"
	@bash scripts/ci/cover.sh gate $(BACKEND_DIR)/cover-internal.out $(COVERAGE_THRESHOLD) internal/

## test-int-shard: one CI shard of test-int, SHARD=<index>/<total> (0-based): the tests scripts/ci/shard.sh puts in that
## shard, against this shard's own emulators, writing backend/cover-internal-shard-<index>-of-<total>.out. No gate here:
## test-int-cover gates the merged profiles of all shards. The script runs as `bash ...`, cmd.exe-safe like dev below.
test-int-shard:
	@[ -n "$(SHARD)" ] || { echo "usage: make test-int-shard SHARD=<index>/<total>"; exit 2; }
	$(EMULATOR_TMP) $(FIREBASE) emulators:exec --project $(EMULATOR_PROJECT) --only firestore,auth,pubsub,storage \
		'bash scripts/ci/test-int-shard.sh $(SHARD) $(RACE_FLAG)'

## test-int-cover: merges every test-int-shard profile of one run (all <total> of them, or it fails) into
## backend/cover-internal.out and applies test-int's internal/ coverage gate to it.
test-int-cover:
	bash scripts/ci/cover.sh merge $(BACKEND_DIR)/cover-internal.out $(BACKEND_DIR)/cover-internal-shard-*-of-*.out
	@echo "==> internal/ coverage gate (combined unit + integration, all shards, $(COVERAGE_THRESHOLD)%)"
	@bash scripts/ci/cover.sh gate $(BACKEND_DIR)/cover-internal.out $(COVERAGE_THRESHOLD) internal/

## dev: emulators + API + Flutter web, all torn down together (Ctrl+C in the flutter run session).
## Same reasoning as test-int for FIREBASE_PROJECT_ID; FIRESTORE_EMULATOR_HOST etc. are read by the
## Firebase/Firestore client libraries themselves without needing to be set at all when they're already in
## this process's environment (emulators:exec sets them on itself before spawning the script), and setting
## them again inline here for `go run` would hit the same Windows cmd.exe problem, so they're dropped.
## PORT is exported at 8081 here (matching config.Config's own local-dev default, config.go) so it never
## collides with the Firestore emulator's fixed port 8080 (firebase.json). loadtest/identity_getme.js and
## its README default to this same port; scripts/dev.sh reads it from the environment (see below).
## N8: the actual backend+flutter startup logic lives in scripts/dev.sh, not inlined here. It used to be a
## single-quoted bash script string (`trap ... ; (cmd) & ; cmd`) passed straight to `emulators:exec`, but
## firebase-tools runs that string through the *OS default shell* — cmd.exe on Windows — which doesn't
## understand `trap`, background `&` jobs or subshells, so `make dev` silently failed to start the API on
## Windows. `bash scripts/dev.sh` is itself just a single, cmd.exe-safe command line (Git Bash's bash.exe is
## on PATH on Windows), and the script it runs is always interpreted by a real bash on every platform.
export PORT ?= 8081
dev:
	$(EMULATOR_TMP) $(FIREBASE) emulators:exec --project $(EMULATOR_PROJECT) --only firestore,auth,pubsub,storage \
		'bash scripts/dev.sh'

## cost: if PROJECT_ID is set, print the last 24h of
## request logs (fs_reads/fs_writes) from Cloud Logging for a quick live sanity check.
cost:
	@echo "=== Last 24h usage ==="
	@if [ -z "$${PROJECT_ID:-}" ]; then \
		echo "Set PROJECT_ID=<gcp-project> (and run 'gcloud auth login' first) to query live usage, e.g.:"; \
		echo "  make cost PROJECT_ID=dzeroth-dev"; \
	else \
		echo "Firestore reads = sum(fs_reads) + sum(removal_log_reads) + sum(protected_set_reads). removal_log_reads is the detached shared removal-log"; 		echo "refresh and protected_set_reads the detached protected-set refresh (ADR-0025 D3); neither is in fs_reads. fanout_fs_reads equals fs_reads on its own line: do not add it again."; 		gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="api"' \
			--project="$$PROJECT_ID" --freshness=1d --limit=50 \
			--format='table(timestamp, jsonPayload.rpc, jsonPayload.fs_reads, jsonPayload.fs_writes, jsonPayload.removal_log_reads, jsonPayload.protected_set_reads, jsonPayload.fanout_fs_reads, jsonPayload.code)' \
		|| echo "gcloud query failed - check 'gcloud auth login' and PROJECT_ID=$$PROJECT_ID"; \
	fi
	@echo ""
	@echo "=== Cloud Vision units (ADR-0022) ==="
	@bash scripts/cost-vision.sh "$${PROJECT_ID:-}"

## loadtest: k6 against the emulators by default. make loadtest SCENARIO=identity_getme (loadtest/README.md)
loadtest:
	@if [ -z "$${SCENARIO:-}" ]; then echo "usage: make loadtest SCENARIO=<name>  (runs loadtest/<name>.js)"; exit 1; fi
	@if [ ! -f "loadtest/$(SCENARIO).js" ]; then echo "loadtest/$(SCENARIO).js not found"; exit 1; fi
	k6 run "loadtest/$(SCENARIO).js"
