#!/usr/bin/env bash
# scripts/dev.sh runs the backend API and the Flutter web dev server together, against the Firebase
# Emulator Suite that `make dev` (root Makefile) has already started via `emulators:exec`.
#
# N8: this used to be inlined as a single-quoted bash script string
# (`trap "kill 0" EXIT INT TERM; (cd backend && go run ./cmd/api) & cd app && flutter run ...`) passed
# straight to `emulators:exec`. firebase-tools runs that string through the *OS default shell* — cmd.exe
# on Windows — which has no idea what `trap`, a backgrounded `&` job or a `(subshell)` are, so `make dev`
# would silently never start the API on Windows. Moving the logic into its own file and having Make invoke
# `bash scripts/dev.sh` keeps the command line handed to cmd.exe trivially simple (find bash.exe on PATH,
# run a script), while this script itself is always interpreted by a real bash, on every platform, since it
# names its own interpreter explicitly.
#
# BACKEND_DIR / APP_DIR / PORT come from the environment (exported by the Makefile) rather than being
# substituted by Make into this file's text, since this runs as its own process, not a Make recipe line.
set -euo pipefail

BACKEND_DIR="${BACKEND_DIR:-backend}"
APP_DIR="${APP_DIR:-app}"
PORT="${PORT:-8081}"

# Kill every process in this script's own process group (the backgrounded API included) when this script
# exits for any reason - normal exit, Ctrl+C, or emulators:exec tearing everything down.
trap 'kill 0' EXIT INT TERM

(cd "$BACKEND_DIR" && go run ./cmd/api) &

cd "$APP_DIR" && flutter run -d chrome \
	--dart-define=API_BASE_URL="http://localhost:$PORT" \
	--dart-define=USE_EMULATORS=true
