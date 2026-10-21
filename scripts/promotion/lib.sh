#!/usr/bin/env bash
# Shared helpers for the promotion scripts. Source it; do not run it.
# Rules: never `set -x`, never print env values or revision JSON (allowlists hold uids) -- only names and counts.

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
note() { echo "ok: $*"; }
finish() {
  if [ "$fail_count" -gt 0 ]; then
    echo "RESULT: $fail_count check(s) failed" >&2
    exit 1
  fi
  echo "RESULT: all checks passed"
}

# jq without the CRLF that the Windows jq build can emit.
jqr() { jq -r "$@" | tr -d '\r'; }

need_file() { [ -r "$1" ] || { echo "FAIL: cannot read $1" >&2; exit 2; }; }
need_tool() { command -v "$1" >/dev/null 2>&1 || { echo "FAIL: $1 is required" >&2; exit 2; }; }

# firebase_web_api_key <options.dart>: prints the apiKey inside `static const FirebaseOptions web = FirebaseOptions(` (the file also holds
# android and ios keys). Public client config. Prints nothing when the block or key is missing; the caller decides what that means.
firebase_web_api_key() {
  tr -d '\r' <"$1" | awk '
    /static const FirebaseOptions web[[:space:]]*=/ { inweb = 1 }
    inweb && /apiKey:/ { print; exit }
    inweb && /\);/ { exit }' | sed -n "s/.*apiKey:[[:space:]]*'\([^']*\)'.*/\1/p"
}
