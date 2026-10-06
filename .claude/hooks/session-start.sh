#!/usr/bin/env bash
# SessionStart: make cloud sessions able to run the guard hooks and `make ci`. Cloud sessions only;
# idempotent; never fails the session.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
if ! command -v jq >/dev/null 2>&1; then
  (apt-get update -qq && apt-get install -y -q jq) >/dev/null 2>&1 ||
    (sudo apt-get update -qq && sudo apt-get install -y -q jq) >/dev/null 2>&1
  command -v jq >/dev/null 2>&1 ||
    echo "session-start: could not install jq; the guard hooks fail closed and will block edits and Bash until it is installed." >&2
fi
[ -f backend/go.mod ] && (cd backend && go mod download >/dev/null 2>&1)
exit 0
