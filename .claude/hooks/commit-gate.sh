#!/usr/bin/env bash
# PreToolUse(Bash): before `git commit`, run the fast subset of `make ci` (gofmt, go vet, flutter analyze
# when the matching files are staged). CLAUDE.md: "No agent marks work done while make ci fails."
# Full `make ci` still runs in GitHub Actions. Exit 2 = block with the tool output as the reason.
. "${0%/*}/lib.sh" || exit 2
require_jq
cmd=$(jq -r '.tool_input.command // empty')
if ! printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))*[[:space:]]+commit([[:space:]]|$)'; then exit 0; fi
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
staged=$(git diff --cached --name-only 2>/dev/null)
fail=0
if printf '%s\n' "$staged" | grep -q '^backend/.*\.go$' && command -v go >/dev/null; then
  out=$(make fmt vet 2>&1) || { printf '%s\n' "$out" | tail -30 >&2; fail=1; }
fi
if printf '%s\n' "$staged" | grep -q '^app/.*\.dart$' && command -v flutter >/dev/null; then
  out=$(cd app && flutter analyze 2>&1) || { printf '%s\n' "$out" | tail -30 >&2; fail=1; }
fi
[ $fail -ne 0 ] && { echo "commit-gate: fast CI checks failed; fix them before committing (see output above)." >&2; exit 2; }
exit 0
