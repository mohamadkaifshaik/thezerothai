#!/usr/bin/env bash
# Shared by guard.sh / cost-guard.sh. Guard hooks must fail CLOSED: without jq they cannot read the
# tool input, so silently exiting 0 would disable the protection.
require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "hook: 'jq' is not installed, so the guard hooks cannot inspect this edit. Install jq (apt install jq / brew install jq) and retry." >&2
  exit 2
}
