#!/usr/bin/env bash
# SessionStart: make cloud sessions able to run the guard hooks and `make ci`. Cloud sessions only;
# idempotent; never fails the session.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
if ! command -v jq >/dev/null 2>&1; then
  (apt-get install -y -q jq || sudo apt-get install -y -q jq) >/dev/null 2>&1
fi
[ -f backend/go.mod ] && (cd backend && go mod download >/dev/null 2>&1)
exit 0
