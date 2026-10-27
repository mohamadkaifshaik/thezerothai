#!/usr/bin/env bash
# Fixture tests for bookmarks-smoke.sh against a fake curl (test/fakebin-smoke). No network, no credentials: every value below is a
# made-up string chosen to be easy to grep for. The key assertions: the leg is STRICT (List must be 200 with 0 rows, Add must be 400
# failed_precondition with the FEATURE_DISABLED ErrorDetail and feature=bookmarks, anything else fails), it makes exactly three calls
# and never writes, and NONE of the secrets, bodies or Connect messages ever shows up in the output or in the arguments curl was
# started with.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
p=$(dirname "$here")
export PATH="$here/fakebin-smoke:$here/fakebin:$PATH"
# CI sets GITHUB_ACTIONS=true, which makes the script print its ::add-mask:: line. Only the dedicated Actions test below turns it on.
unset GITHUB_ACTIONS
# SMOKE_REFERER is opt-in; an inherited value would change what the tests below see.
unset SMOKE_REFERER
# The fakes must be executable (git on Windows can drop the bit); otherwise PATH would skip them and the REAL curl would run.
for f in "$here/fakebin-smoke/curl" "$here/fakebin/sleep"; do
  [ -x "$f" ] || { echo "FAIL: $f is not executable; refusing to run against real tools" >&2; exit 2; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0

TOKEN='FAKE-ID-TOKEN-xyz'
PASSWORD='FAKE-PW-xyz'
EMAIL='fake.person@example.invalid'
APIKEY='FAKE-API-KEY-123'
B=$p/bookmarks-smoke.sh

# The wire shape of the answers (verified against connect-go v1.21.1: a detail's message is rendered as protojson under `debug`).
# FD is what the bookmarks gate answers; the others are the near misses the smoke must refuse.
FD='{"code":"failed_precondition","message":"FAKE-MSG-xyz","details":[{"type":"dzeroth.common.v1.ErrorDetail","value":"RkFLRQ","debug":{"reason":"ERROR_REASON_FEATURE_DISABLED","message":"FAKE-MSG-xyz","metadata":{"feature":"bookmarks"}}}]}'
LIMIT='{"code":"failed_precondition","message":"FAKE-MSG-xyz","details":[{"type":"dzeroth.common.v1.ErrorDetail","value":"RkFLRQ","debug":{"reason":"ERROR_REASON_LIMIT_REACHED","message":"FAKE-MSG-xyz","metadata":{"limit":"bookmarks"}}}]}'
POSTS_GATE='{"code":"failed_precondition","message":"FAKE-MSG-xyz","details":[{"type":"dzeroth.common.v1.ErrorDetail","value":"RkFLRQ","debug":{"reason":"ERROR_REASON_FEATURE_DISABLED","message":"FAKE-MSG-xyz"}}]}'
OTHER_FEATURE='{"code":"failed_precondition","message":"FAKE-MSG-xyz","details":[{"type":"dzeroth.common.v1.ErrorDetail","value":"RkFLRQ","debug":{"reason":"ERROR_REASON_FEATURE_DISABLED","message":"FAKE-MSG-xyz","metadata":{"feature":"posts"}}}]}'
NO_DEBUG='{"code":"failed_precondition","message":"FAKE-MSG-xyz","details":[{"type":"dzeroth.common.v1.ErrorDetail","value":"RkFLRQ"}]}'
NO_DETAILS='{"code":"failed_precondition","message":"FAKE-MSG-xyz"}'
WRONG_TYPE='{"code":"failed_precondition","message":"FAKE-MSG-xyz","details":[{"type":"google.rpc.ErrorInfo","value":"RkFLRQ","debug":{"reason":"ERROR_REASON_FEATURE_DISABLED","metadata":{"feature":"bookmarks"}}}]}'
INVALID='{"code":"invalid_argument","message":"FAKE-MSG-xyz","details":[{"type":"dzeroth.common.v1.ErrorDetail","value":"RkFLRQ","debug":{"reason":"ERROR_REASON_FEATURE_DISABLED","message":"FAKE-MSG-xyz","metadata":{"feature":"bookmarks"}}}]}'
NOT_FOUND='{"code":"not_found","message":"FAKE-MSG-xyz","details":[{"type":"dzeroth.common.v1.ErrorDetail","value":"RkFLRQ","debug":{"reason":"ERROR_REASON_NOT_FOUND","message":"FAKE-MSG-xyz"}}]}'

check() { # check <name> <condition...>
  local name=$1
  shift
  if "$@"; then pass=$((pass + 1)); else echo "FAIL $name"; failed=$((failed + 1)); fi
}
eq() { [ "$1" = "$2" ]; }
has() { grep -qF -- "$1" "$tmp/out"; }
hasnt() { ! grep -qF -- "$1" "$tmp/out"; }
calls() { cat "$FAKE/calls" 2>/dev/null || echo 0; }
in_file() { grep -qF -- "$1" "$2"; }
not_in_file() { ! grep -qF -- "$1" "$2"; }

# A fresh fake state; sets FAKE.
setup() {
  FAKE=$tmp/state
  export FAKE
  rm -rf "$FAKE"
  mkdir -p "$FAKE"
  : >"$FAKE/argv.log"
}

# run: runs the smoke with the fake credentials; sets rc, out.
run() {
  SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY IDENTITY_TOOLKIT_URL=http://127.0.0.1:1 \
    bash "$B" http://127.0.0.1:2 >"$tmp/out" 2>&1
  rc=$?
}

# secrecy <name>: nothing secret, no body, no Connect message in the output, and curl never received a secret in its arguments (the API
# key is public, so it may).
secrecy() {
  local name=$1 s
  for s in "$TOKEN" "$PASSWORD" "$EMAIL"; do
    check "$name: output has no $s" hasnt "$s"
    check "$name: curl argv has no $s" not_in_file "$s" "$FAKE/argv.log"
  done
  check "$name: output has no response body" hasnt '"idToken"'
  check "$name: output has no detail value" hasnt RkFLRQ
  check "$name: the Connect message is not printed" hasnt FAKE-MSG-xyz
}

# expect_fail <name> <step> <calls>: the run failed at <step> after <calls> curl calls; nothing secret printed.
expect_fail() {
  check "$1: exits 1" eq "$rc" 1
  check "$1: FAIL at $2 is the last line" eq "$(tail -n 1 "$tmp/out")" "bookmarks smoke: FAIL at $2"
  check "$1: $3 calls" eq "$(calls)" "$3"
  secrecy "$1"
}

# --- The pass path: sign-in, List 200 with 0 rows, Add 400 failed_precondition FEATURE_DISABLED feature=bookmarks. Three calls, no write.
setup; run
check "pass path: exits 0" eq "$rc" 0
check "pass path: PASS is the last line" eq "$(tail -n 1 "$tmp/out")" 'bookmarks smoke: PASS'
check "pass path: List {} is 0 rows" has 'HTTP 200 rows=0'
check "pass path: Add prints status, Connect code, reason and feature" has 'HTTP 400 failed_precondition reason=FEATURE_DISABLED feature=bookmarks'
check "pass path: exactly 3 calls (sign-in, ListBookmarks, AddBookmark)" eq "$(calls)" 3
check "pass path: List asks for pageSize 20" in_file '"pageSize":20' "$FAKE/argv.2"
check "pass path: List goes to the EngagementService" in_file '/dzeroth.engagement.v1.EngagementService/ListBookmarks' "$FAKE/argv.2"
check "pass path: Add goes to the EngagementService" in_file '/dzeroth.engagement.v1.EngagementService/AddBookmark' "$FAKE/argv.3"
check "pass path: Add key looks like smoke-<epoch>-bm-<4 digits>" grep -Eq 'smoke-[0-9]+-bm-[0-9]{4}"' "$FAKE/argv.3"
check "pass path: Add names the fixed dummy post" in_file '"postId":"1"' "$FAKE/argv.3"
for n in 2 3; do check "pass path: call $n carries the bearer token on stdin" in_file "Authorization: Bearer $TOKEN" "$FAKE/stdin.$n"; done
check "pass path: no timeline call" not_in_file GetHomeTimeline "$FAKE/argv.log"
check "pass path: no RemoveBookmark call (the leg never writes)" not_in_file RemoveBookmark "$FAKE/argv.log"
secrecy "pass path"
# the secrets did reach curl, on stdin (so the secrecy checks above are not vacuous)
check "password reached curl on stdin" in_file "$PASSWORD" "$FAKE/stdin.1"
check "the API key (public) is in the sign-in URL" in_file "key=$APIKEY" "$FAKE/argv.log"

# --- sign-in failure
setup; echo 400 >"$FAKE/signin-code"; echo '{"error":{"message":"INVALID_PASSWORD"}}' >"$FAKE/signin-body"; run
expect_fail "sign-in 400" sign-in 1
check "sign-in 400: the error body is not printed" hasnt INVALID_PASSWORD
setup; echo '{"noToken":true}' >"$FAKE/signin-body"; run
expect_fail "sign-in 200 without a token" sign-in 1

# --- usage and environment errors exit 2
setup
for v in SMOKE_EMAIL SMOKE_PASSWORD FIREBASE_API_KEY; do
  (
    export SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY
    unset "$v"
    bash "$B" http://127.0.0.1:2
  ) >"$tmp/out" 2>&1
  rc=$?
  check "missing $v exits 2" eq "$rc" 2
  check "missing $v: names the variable" has "$v is required"
done
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY bash "$B" >"$tmp/out" 2>&1
check "no arguments exits 2" eq "$?" 2
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY bash "$B" http://127.0.0.1:2 --bogus >"$tmp/out" 2>&1
check "an extra argument exits 2" eq "$?" 2
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY bash "$B" http://example.com >"$tmp/out" 2>&1
check "plain http to a real host exits 2" eq "$?" 2
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY bash "$B" https://user:pw@example.com >"$tmp/out" 2>&1
check "credentials in the URL exit 2" eq "$?" 2
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY IDENTITY_TOOLKIT_URL=http://example.com bash "$B" http://127.0.0.1:2 >"$tmp/out" 2>&1
check "the password is never sent over plain http to a real host" eq "$?" 2
check "no call for any usage error" eq "$(calls)" 0
secrecy "usage errors"

# --- ListBookmarks: only 200 with 0 rows passes (a missing key or an explicit empty array)
setup; echo '{"bookmarks":[]}' >"$FAKE/listbm-body"; run
check "List with an explicit empty array: passes" eq "$rc" 0
check "List with an explicit empty array: rows=0" has 'HTTP 200 rows=0'
setup; echo '{"bookmarks":[{"post":{"text":"FAKE-POST-TEXT-xyz"}},{},{}]}' >"$FAKE/listbm-body"; run
expect_fail "List with 3 rows" list-bookmarks 2
check "List with 3 rows: rows=3 is printed" has 'HTTP 200 rows=3'
check "List with 3 rows: the post text is not printed" hasnt FAKE-POST-TEXT-xyz
setup; echo '{"bookmarks":"nope"}' >"$FAKE/listbm-body"; run
expect_fail "List 200 with a non-array bookmarks" list-bookmarks 2
setup; echo '<html>FAKE-MSG-xyz</html>' >"$FAKE/listbm-body"; run
expect_fail "List 200 with a non-JSON body" list-bookmarks 2
setup; echo 'null' >"$FAKE/listbm-body"; run
expect_fail "List 200 with a null body" list-bookmarks 2
# the flag is globally off: List answers 400 FEATURE_DISABLED. The leg is strict, so this fails (and says why)
setup; echo 400 >"$FAKE/listbm-code"; echo "$FD" >"$FAKE/listbm-body"; run
expect_fail "List 400 FEATURE_DISABLED (flag globally off)" list-bookmarks 2
check "List 400 FEATURE_DISABLED: the status and the reason are printed" has 'HTTP 400 failed_precondition reason=FEATURE_DISABLED'
for bad in 500 401 404 429 403; do
  setup; echo "$bad" >"$FAKE/listbm-code"; echo "$NOT_FOUND" >"$FAKE/listbm-body"; run
  expect_fail "List $bad" list-bookmarks 2
done
setup; echo 503 >"$FAKE/listbm-code"; run
expect_fail "List 503 always (retried 3 times)" list-bookmarks 4
setup; echo conn >"$FAKE/listbm-code"; run
expect_fail "List connection error always (retried 3 times)" list-bookmarks 4
check "List connection error: HTTP 000 is printed" has 'HTTP 000'
setup; echo 429 >"$FAKE/listbm-code"; run
check "List 429 is not retried (2 calls)" eq "$(calls)" 2

# --- AddBookmark: only 400 failed_precondition + the FEATURE_DISABLED ErrorDetail + feature=bookmarks passes
setup; echo 200 >"$FAKE/addbm-code"; echo '{"state":{"postId":"1","bookmarked":true}}' >"$FAKE/addbm-body"; run
expect_fail "Add 200 (a write went through)" add-bookmark 3
check "Add 200: no undo call is made (the leg has no write path)" not_in_file RemoveBookmark "$FAKE/argv.log"
setup; echo 200 >"$FAKE/addbm-code"; run
expect_fail "Add 200 even with the FEATURE_DISABLED body (only the 400 passes)" add-bookmark 3
setup; echo "$LIMIT" >"$FAKE/addbm-body"; run
expect_fail "Add 400 failed_precondition LIMIT_REACHED (a cap, not the gate)" add-bookmark 3
check "Add LIMIT_REACHED: the reason is printed" has 'reason=LIMIT_REACHED'
setup; echo "$NO_DETAILS" >"$FAKE/addbm-body"; run
expect_fail "Add 400 failed_precondition without details" add-bookmark 3
setup; echo "$NO_DEBUG" >"$FAKE/addbm-body"; run
expect_fail "Add 400 with an ErrorDetail but no debug field" add-bookmark 3
setup; echo "$POSTS_GATE" >"$FAKE/addbm-body"; run
expect_fail "Add 400 FEATURE_DISABLED without feature metadata (the FEATURE_POSTS gate)" add-bookmark 3
setup; echo "$OTHER_FEATURE" >"$FAKE/addbm-body"; run
expect_fail "Add 400 FEATURE_DISABLED with feature=posts" add-bookmark 3
check "Add feature=posts: the feature is printed" has 'feature=posts'
setup; echo "$WRONG_TYPE" >"$FAKE/addbm-body"; run
expect_fail "Add 400 with a detail of another type" add-bookmark 3
setup; echo "$INVALID" >"$FAKE/addbm-body"; run
expect_fail "Add 400 invalid_argument (not failed_precondition)" add-bookmark 3
setup; echo '<html>FAKE-MSG-xyz</html>' >"$FAKE/addbm-body"; run
expect_fail "Add 400 with a non-JSON body" add-bookmark 3
setup; echo 404 >"$FAKE/addbm-code"; echo "$NOT_FOUND" >"$FAKE/addbm-body"; run
expect_fail "Add 404 not_found (the account would be in the cohort; the dummy post does not exist)" add-bookmark 3
for bad in 500 401 403 429; do
  setup; echo "$bad" >"$FAKE/addbm-code"; run
  expect_fail "Add $bad (with the FEATURE_DISABLED body: only the 400 passes)" add-bookmark 3
done
setup; echo 503 >"$FAKE/addbm-code"; run
expect_fail "Add 503 always (retried 3 times: 2 + 3 calls)" add-bookmark 5
setup; echo 429 >"$FAKE/addbm-code"; run
check "Add 429 is not retried (3 calls)" eq "$(calls)" 3
# hostile reason and feature values are reduced to a fixed alphabet before they are printed
setup; echo '{"code":"fail<b>ed_precondition","details":[{"type":"dzeroth.common.v1.ErrorDetail","debug":{"reason":"ERROR_REASON_BAD$(id)<script>FAKE-REASON-xyz","metadata":{"feature":"book<b>marks-SECRET-QQ"}}}]}' >"$FAKE/addbm-body"; run
expect_fail "Add with hostile detail values" add-bookmark 3
check "hostile values: no angle bracket is printed" hasnt '<'
check "hostile values: no dollar sign is printed" hasnt '$('
check "hostile values: the reason keeps only A-Z and _" has 'reason=BADFAKEREASON'
check "hostile values: the feature keeps only a-z, 0-9 and _" has 'feature=bookbmarks'
check "hostile values: lowercase marker text is removed" hasnt xyz

# --- SMOKE_REFERER: on the sign-in request ONLY
REF=https://dzeroth.com/
setup; SMOKE_REFERER=$REF run
check "SMOKE_REFERER set: passes" eq "$rc" 0
check "SMOKE_REFERER: sign-in carries exactly that Referer" eq "$(grep -c '^Referer: ' "$FAKE/argv.1")" 1
check "SMOKE_REFERER: sign-in Referer value" in_file "Referer: $REF" "$FAKE/argv.1"
for n in 2 3; do check "SMOKE_REFERER: call $n has no Referer" not_in_file "Referer" "$FAKE/argv.$n"; done
setup; run
check "SMOKE_REFERER unset: no Referer on any call" not_in_file "Referer" "$FAKE/argv.log"
for bad in http://dzeroth.com/ "https://dzeroth.com/ x" https://user@dzeroth.com/ dzeroth.com; do
  setup; SMOKE_REFERER=$bad run
  check "invalid SMOKE_REFERER '$bad' exits 2" eq "$rc" 2
  check "invalid SMOKE_REFERER '$bad': no call is made" eq "$(calls)" 0
done

# --- GitHub Actions: the token is masked before any other use, and that line is the only place it appears
setup
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY IDENTITY_TOOLKIT_URL=http://127.0.0.1:1 GITHUB_ACTIONS=true \
  bash "$B" http://127.0.0.1:2 >"$tmp/out" 2>&1
rc=$?
check "Actions run passes" eq "$rc" 0
check "Actions: exactly one ::add-mask:: line" eq "$(grep -c '^::add-mask::' "$tmp/out")" 1
check "Actions: the mask line carries the token" has "::add-mask::$TOKEN"
check "Actions: nothing else in the output carries the token" eq "$(grep -F -- "$TOKEN" "$tmp/out" | grep -vc '^::add-mask::')" 0
check "Actions: password absent" hasnt "$PASSWORD"
check "Actions: email absent" hasnt "$EMAIL"
setup; run
check "outside Actions no mask line is printed" hasnt '::add-mask::'

echo "bookmarks smoke tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
