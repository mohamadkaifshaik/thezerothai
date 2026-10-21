#!/usr/bin/env bash
# Authenticated smoke of an API URL: signs in as a smoke account and calls GetMe and GetProfile with the signed Firebase ID token.
#
# Why: /health is a static handler, so only a real signed token exercises the paths a toolchain or dependency change can break
# (the JWKS key fetch and the Firestore reads, both over outbound TLS). See docs/runbooks/authenticated-smoke.md.
#
# Usage: authenticated-smoke.sh <base_url> [--handle <handle>]
# Env (never arguments): SMOKE_EMAIL, SMOKE_PASSWORD, FIREBASE_API_KEY (public client config, not a secret).
#   Optional IDENTITY_TOOLKIT_URL (default https://identitytoolkit.googleapis.com) so the tests can point at a fake.
# Steps: sign in -> unauthenticated GetMe must be 401 (auth is enforced) -> GetMe 200 with a profile handle -> GetProfile 200, same handle.
# Transient answers (502/503/504, connection errors: a cold start) are retried up to 3 times with a short backoff, on every call.
# Exit codes: 0 pass, 1 smoke failure, 2 usage or environment error.
#
# The repository is PUBLIC and CI logs are public. Output is ONLY step names, HTTP status codes and the handle, ending with exactly
# `authenticated smoke: PASS` or `authenticated smoke: FAIL at <step>`. Never printed: the password, the token, any response body,
# the email, any uid. No tracing, no temp files: secrets live in shell variables and pipes only, and never in a command line
# (the sign-in body and the Authorization header reach curl on stdin).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

usage() {
  echo "usage: authenticated-smoke.sh <base_url> [--handle <handle>]  (env: SMOKE_EMAIL SMOKE_PASSWORD FIREBASE_API_KEY)" >&2
  exit 2
}

# https only; plain http is allowed for a loopback address so the fixture tests can use a local fake.
check_url() {
  case $1 in
    https://*) ;;
    http://127.0.0.1 | http://127.0.0.1:* | http://127.0.0.1/* | http://localhost | http://localhost:* | http://localhost/*) ;;
    *) echo "FAIL: $2 must be an https URL (http only for 127.0.0.1 or localhost)" >&2; exit 2 ;;
  esac
  case $1 in *[[:space:]@]*) echo "FAIL: $2 must not contain spaces or credentials" >&2; exit 2 ;; esac
}

[ "$#" -ge 1 ] || usage
base=${1%/}
shift
handle_arg=""
while [ "$#" -gt 0 ]; do
  case $1 in
    --handle) [ "$#" -ge 2 ] || usage; handle_arg=$2; shift 2 ;;
    *) usage ;;
  esac
done

need_tool jq
need_tool curl
for v in SMOKE_EMAIL SMOKE_PASSWORD FIREBASE_API_KEY; do
  [ -n "${!v:-}" ] || { echo "FAIL: $v is required (environment)" >&2; exit 2; }
done
idt=${IDENTITY_TOOLKIT_URL:-https://identitytoolkit.googleapis.com}
idt=${idt%/}
check_url "$base" "base_url"
check_url "$idt" "IDENTITY_TOOLKIT_URL"

code=""
body=""
# call <url> <json-body> [bearer-token]: sets $code and $body (never printed). Retries only transient answers.
call() {
  local url=$1 payload=$2 token=${3:-} attempt resp
  for attempt in 1 2 3; do
    if [ -n "$token" ]; then
      resp=$(printf 'Authorization: Bearer %s\n' "$token" |
        curl -s --max-time 15 -w '\n%{http_code}' -X POST -H 'content-type: application/json' -H @- --data-binary "$payload" "$url") || resp=$'\n000'
    else
      resp=$(printf '%s' "$payload" |
        curl -s --max-time 15 -w '\n%{http_code}' -X POST -H 'content-type: application/json' --data-binary @- "$url") || resp=$'\n000'
    fi
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}
    case $code in 000 | 502 | 503 | 504) [ "$attempt" -lt 3 ] && { sleep $((attempt * 2)); continue; } ;; esac
    break
  done
}

fail_at() {
  echo "authenticated smoke: FAIL at $1"
  exit 1
}

echo "== sign-in"
# $ENV keeps the credentials out of jq's command line.
payload=$(jq -n '{email: $ENV.SMOKE_EMAIL, password: $ENV.SMOKE_PASSWORD, returnSecureToken: true}')
call "$idt/v1/accounts:signInWithPassword?key=$FIREBASE_API_KEY" "$payload"
unset payload
echo "   HTTP $code"
[ "$code" = "200" ] || fail_at sign-in
token=$(printf '%s' "$body" | jqr '.idToken // empty') || token=""
body=""
[ -n "$token" ] || fail_at sign-in
# Mask BEFORE any further use of the token (a no-op outside GitHub Actions).
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::add-mask::$token"; fi

rpc="$base/dzeroth.identity.v1.IdentityService"

echo "== unauthenticated GetMe (must be refused)"
call "$rpc/GetMe" '{}'
echo "   HTTP $code"
[ "$code" = "401" ] || fail_at unauthenticated-getme

echo "== GetMe"
call "$rpc/GetMe" '{}' "$token"
echo "   HTTP $code"
[ "$code" = "200" ] || fail_at getme
me_handle=$(printf '%s' "$body" | jqr '.profile.handle // empty') || me_handle=""
body=""
[ -n "$me_handle" ] || fail_at getme
echo "   handle: $me_handle"

want=${handle_arg:-$me_handle}
echo "== GetProfile (handle: $want)"
call "$rpc/GetProfile" "$(jq -n --arg h "$want" '{handle: $h}')" "$token"
echo "   HTTP $code"
[ "$code" = "200" ] || fail_at getprofile
got=$(printf '%s' "$body" | jqr '.profile.handle // empty') || got=""
body=""
[ -n "$got" ] || fail_at getprofile
# The lookup is case-insensitive, so compare case-insensitively.
[ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" ] || fail_at getprofile
echo "   handle: $got"

echo "authenticated smoke: PASS"
