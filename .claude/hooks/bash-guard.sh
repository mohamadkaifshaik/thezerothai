#!/usr/bin/env bash
# PreToolUse(Bash): stop shell commands from writing generated code or secret files, which guard.sh
# only catches for Write/Edit. Heuristic (obvious redirects / sed -i / tee / cp / mv); exit 2 = block.
. "${0%/*}/lib.sh" || exit 2
require_jq
cmd=$(jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0
target='(/gen/|\.pb\.go|\.connect\.go|\.pb\.dart|\.pbgrpc\.dart|\.g\.dart|\.freezed\.dart|\.env([. ]|$)|\.pem|credentials[^ ]*\.json|sa-key[^ ]*\.json)'
writer='(>|>>|sed[[:space:]]+-i|tee[[:space:]]|[[:space:]]cp[[:space:]]|[[:space:]]mv[[:space:]]|rm[[:space:]])'
if printf '%s' "$cmd" | grep -Eq "${writer}[^|;&]*${target}"; then
  echo "bash-guard: refusing a shell write to generated code or a secret file. Edit the .proto / annotated source and run 'make proto' / build_runner; secrets live in Secret Manager." >&2
  exit 2
fi
exit 0
