#!/usr/bin/env bash
# scripts/e2ee-smoke.sh: the encrypted-messaging smoke test (Plan 5a Task 16). Two users, three devices, the real
# API on the Firebase emulators that `make e2ee-smoke` (root Makefile) has already started through `emulators:exec`;
# the client side is app/test/e2e_emulator/e2ee_smoke_test.dart (the real pipeline with the fake MLS engine).
#
# Like scripts/dev.sh, this runs as `bash scripts/e2ee-smoke.sh`, the single cmd.exe-safe line `emulators:exec` gets on
# Windows; everything else (trap, background job, loops) lives here, under a real bash.
#
# The API is built ONCE into a private temp dir and that binary is started in the background, so the pid remembered
# below is the server's own (`go run` would leave a child process holding the port). The trap stops only that pid.
# The script exits with the test's status.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=8081
export PORT

# Feature flags, emulator-only values (backend/pkg/platform/config/config.go):
# - messaging and e2ee_dm on for everyone: the scenario sends, registers devices and starts encryption;
# - graph on (the follows the scenario starts from; already the local default);
# - reports on (step 9 reports a decrypted message);
# - device_sign_out off: step 7's REMOTE removal must not cut the account's other sessions, or the removed device
#   would see SESSION_ENDED instead of finding out that it was removed (the scenario's removed-elsewhere check);
# - public_ids for an allowlist of the second pair only (users c and d of this run), so step 9a sees the flag on
#   (c, d) and off (a, b) against one API.
smoke_run="r$(date +%s)"
export FEATURE_MESSAGING=on
export FEATURE_E2EE_DM=on
export FEATURE_GRAPH=on
export FEATURE_REPORTS=on
export FEATURE_DEVICE_SIGN_OUT=off
export FEATURE_PUBLIC_IDS=allowlist
export FEATURE_PUBLIC_IDS_ALLOWLIST="e2eesmoke-${smoke_run}-c,e2eesmoke-${smoke_run}-d"
# Every device of the test calls from the same loopback address; the per-IP limits (120 a minute by default) would
# count four users' devices as one client. The per-user limits stay at their defaults.
export RATE_LIMIT_PER_IP_PER_MIN=100000
export RATE_LIMIT_PRE_AUTH_IP_PER_MIN=100000

auth_host="${FIREBASE_AUTH_EMULATOR_HOST:-127.0.0.1:9099}"
project="${FIREBASE_PROJECT_ID:-demo-dzeroth-local}"

tmp="$(mktemp -d)"
api_pid=""
cleanup() {
	if [ -n "$api_pid" ]; then
		kill "$api_pid" 2>/dev/null || true
		wait "$api_pid" 2>/dev/null || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

api_bin="$tmp/dzeroth-api$(cd "$root/backend" && go env GOEXE)"
(cd "$root/backend" && go build -o "$api_bin" ./cmd/api)
"$api_bin" >"$tmp/api.log" 2>&1 &
api_pid=$!

ready=0
for _ in $(seq 1 60); do
	if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
		ready=1
		break
	fi
	if ! kill -0 "$api_pid" 2>/dev/null; then
		break
	fi
	sleep 1
done
if [ "$ready" != 1 ]; then
	echo "e2ee-smoke: the API did not answer /health on port $PORT; its last log lines:" >&2
	tail -n 40 "$tmp/api.log" >&2 || true
	exit 1
fi

status=0
(cd "$root/app" && flutter test test/e2e_emulator/e2ee_smoke_test.dart \
	--dart-define=E2EE_SMOKE_API="http://127.0.0.1:$PORT" \
	--dart-define=E2EE_SMOKE_AUTH="$auth_host" \
	--dart-define=E2EE_SMOKE_PROJECT="$project" \
	--dart-define=E2EE_SMOKE_RUN="$smoke_run") || status=$?
if [ "$status" != 0 ]; then
	echo "e2ee-smoke: the test failed ($status); the API's last log lines:" >&2
	tail -n 60 "$tmp/api.log" >&2 || true
fi
exit "$status"
