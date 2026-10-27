#!/usr/bin/env bash
# Dev-only bookmarks smoke of an API URL (W2-16): signs in as a smoke account that is NOT in the FEATURE_BOOKMARKS cohort and checks that
# the bookmark RPCs are routed, authenticated and gated on the candidate. Run by promote-dev.sh (step 4b) right after
# authenticated-smoke.sh, against the same 0% candidate and with the same credentials. It is NOT run against prod: prod-smoke.sh only
# runs authenticated-smoke.sh, which stays read-only and knows no bookmark RPC (live prod does not carry them yet).
# See docs/runbooks/authenticated-smoke.md, "The dev-only bookmarks smoke".
#
# Usage: bookmarks-smoke.sh <base_url>
# Env (never arguments): SMOKE_EMAIL, SMOKE_PASSWORD, FIREBASE_API_KEY (public client config, not a secret), the same contract as
#   authenticated-smoke.sh. Optional IDENTITY_TOOLKIT_URL (default https://identitytoolkit.googleapis.com, so the tests can point at a
#   fake) and SMOKE_REFERER (an https URL, sent as `Referer:` on the SIGN-IN request only; the web API key is referrer-restricted).
# Steps (strict, fail-closed: ANY mismatch fails, like the authenticated smoke):
#   1. Sign in.
#   2. ListBookmarks {"pageSize":20} must be 200 with 0 rows (protojson omits an empty array, so a missing `bookmarks` key is 0 rows).
#      ListBookmarks only needs FEATURE_BOOKMARKS "not globally off", and smoke account A has no bookmarks. Anything else, including a
#      400 FEATURE_DISABLED (the flag is globally off) or any row, fails at list-bookmarks.
#   3. AddBookmark with a fresh key smoke-<epoch>-bm-<4 digits> and a FIXED dummy post id must be 400 failed_precondition carrying the
#      ErrorDetail reason FEATURE_DISABLED with metadata feature=bookmarks (the bookmarks gate, not the FEATURE_POSTS one, which has no
#      feature metadata). Account A is never allowlisted (docs/runbooks/smoke-accounts.md), and the gate runs before ANY Firestore
#      access or input check (backend/internal/engagement/server_bookmarks.go, guardBookmarks), so the answer does not depend on the post.
#      That is also why no real post is needed and nothing is ever written: if A were allowlisted by mistake, the dummy id is
#      not_found, which fails here with 0 writes. Anything else (a 200, LIMIT_REACHED, another code, no ErrorDetail) fails at add-bookmark.
# Transient answers (502/503/504, connection errors: a cold start) are retried up to 3 times with a short backoff, on every call; a
# retry resends the same key, so it is a replay. 429 is NOT retried.
# Exit codes: 0 pass, 1 smoke failure, 2 usage or environment error.
#
# The repository is PUBLIC and CI logs are public. Output is ONLY step names, HTTP status codes, the Connect error code (a-z and _
# only), the ErrorDetail reason (A-Z and _ only), the feature name (a-z, 0-9 and _ only) and a bookmark row count, ending with exactly
# `bookmarks smoke: PASS` or `bookmarks smoke: FAIL at <step>` (steps: sign-in, list-bookmarks, add-bookmark). Never printed: the
# password, the token, any response body or Connect message, the email, any uid. No tracing, no temp files: secrets live in shell
# variables and pipes only, and never in a command line (the sign-in body and the Authorization header reach curl on stdin).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

usage() {
  echo "usage: bookmarks-smoke.sh <base_url>  (env: SMOKE_EMAIL SMOKE_PASSWORD FIREBASE_API_KEY)" >&2
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

[ "$#" -eq 1 ] || usage
base=${1%/}

need_tool jq
need_tool curl
for v in SMOKE_EMAIL SMOKE_PASSWORD FIREBASE_API_KEY; do
  [ -n "${!v:-}" ] || { echo "FAIL: $v is required (environment)" >&2; exit 2; }
done
idt=${IDENTITY_TOOLKIT_URL:-https://identitytoolkit.googleapis.com}
idt=${idt%/}
check_url "$base" "base_url"
check_url "$idt" "IDENTITY_TOOLKIT_URL"
if [ -n "${SMOKE_REFERER:-}" ]; then check_url "$SMOKE_REFERER" "SMOKE_REFERER"; fi

code=""
body=""
# call <url> <json-body> [bearer-token]: sets $code and $body (never printed). Retries only transient answers.
# A non-empty $referer_hdr (set by the sign-in step alone) is sent as an extra header.
referer_hdr=""
call() {
  local url=$1 payload=$2 token=${3:-} attempt resp extra=()
  [ -z "$referer_hdr" ] || extra=(-H "$referer_hdr")
  for attempt in 1 2 3; do
    if [ -n "$token" ]; then
      resp=$(printf 'Authorization: Bearer %s\n' "$token" |
        curl -s --max-time 15 -w '\n%{http_code}' -X POST -H 'content-type: application/json' "${extra[@]}" -H @- --data-binary "$payload" "$url") || resp=$'\n000'
    else
      resp=$(printf '%s' "$payload" |
        curl -s --max-time 15 -w '\n%{http_code}' -X POST -H 'content-type: application/json' "${extra[@]}" --data-binary @- "$url") || resp=$'\n000'
    fi
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}
    case $code in 000 | 502 | 503 | 504) [ "$attempt" -lt 3 ] && { sleep $((attempt * 2)); continue; } ;; esac
    break
  done
}

fail_at() {
  echo "bookmarks smoke: FAIL at $1"
  exit 1
}

# error_parts: sets $ccode (the Connect error code of $body), $reason (the reason of its first dzeroth.common.v1.ErrorDetail, without the
# ERROR_REASON_ prefix) and $feature (that detail's metadata "feature"); each is "" when absent or when $body is not the expected JSON.
# connect-go renders a detail's message as protojson under `debug`, so the enum arrives as its NAME. Every value is sanitized to a
# fixed alphabet and length before it can be printed; the Connect message and everything else in the body are never read.
ccode=""
reason=""
feature=""
error_parts() {
  local pair
  ccode=$(printf '%s' "$body" | jqr 'if type == "object" then (.code // empty | tostring) else empty end' 2>/dev/null | tr -cd 'a-z_' | head -c 40) || ccode=""
  pair=$(printf '%s' "$body" | jqr 'if type == "object" then ([.details[]? | select(.type == "dzeroth.common.v1.ErrorDetail") | .debug | select(type == "object") | "\(.reason // "")|\(.metadata.feature? // "")"] | first // empty) else empty end' 2>/dev/null) || pair=""
  reason=$(printf '%s' "${pair%%|*}" | tr -cd 'A-Z_' | head -c 48) || reason=""
  reason=${reason#ERROR_REASON_}
  feature=$(printf '%s' "${pair#*|}" | tr -cd 'a-z0-9_' | head -c 24) || feature=""
}
# describe: the one status line printed after a call that is not a plain 200.
describe() {
  echo "   HTTP $code${ccode:+ $ccode}${reason:+ reason=$reason}${feature:+ feature=$feature}"
}

echo "== sign-in"
# $ENV keeps the credentials out of jq's command line.
payload=$(jq -n '{email: $ENV.SMOKE_EMAIL, password: $ENV.SMOKE_PASSWORD, returnSecureToken: true}')
if [ -n "${SMOKE_REFERER:-}" ]; then referer_hdr="Referer: $SMOKE_REFERER"; fi
call "$idt/v1/accounts:signInWithPassword?key=$FIREBASE_API_KEY" "$payload"
referer_hdr=""
unset payload
echo "   HTTP $code"
[ "$code" = "200" ] || fail_at sign-in
token=$(printf '%s' "$body" | jqr '.idToken // empty') || token=""
body=""
[ -n "$token" ] || fail_at sign-in
# Mask BEFORE any further use of the token (a no-op outside GitHub Actions).
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::add-mask::$token"; fi

eng="$base/dzeroth.engagement.v1.EngagementService"

echo "== ListBookmarks (must be 200 with 0 rows: the smoke account is outside the cohort and has no bookmarks)"
call "$eng/ListBookmarks" '{"pageSize":20}' "$token"
if [ "$code" = "200" ]; then
  # protojson omits an empty repeated field, so a missing key is 0 rows; a present key must be an array.
  rows=$(printf '%s' "$body" | jqr 'if type == "object" and ((.bookmarks // []) | type) == "array" then (.bookmarks // []) | length else empty end' 2>/dev/null) || rows=""
  case $rows in '' | *[!0-9]*) rows="" ;; esac
  body=""
  echo "   HTTP $code rows=${rows:-?}"
  [ "$rows" = "0" ] || fail_at list-bookmarks
else
  error_parts
  body=""
  describe
  fail_at list-bookmarks
fi

# A fixed, well-formed but nonexistent post id: the cohort gate answers before the post is looked at (see the header).
add_key="smoke-$(date +%s)-bm-$(printf '%04d' $((RANDOM % 10000)))"
echo "== AddBookmark (must be 400 failed_precondition FEATURE_DISABLED feature=bookmarks: the smoke account is outside the cohort)"
call "$eng/AddBookmark" "$(jq -nc --arg k "$add_key" '{idempotencyKey: $k, postId: "1"}')" "$token"
error_parts
body=""
describe
{ [ "$code" = "400" ] && [ "$ccode" = "failed_precondition" ] && [ "$reason" = "FEATURE_DISABLED" ] && [ "$feature" = "bookmarks" ]; } || fail_at add-bookmark

echo "bookmarks smoke: PASS"
