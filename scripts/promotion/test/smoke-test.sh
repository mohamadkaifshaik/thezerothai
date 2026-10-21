#!/usr/bin/env bash
# Fixture tests for authenticated-smoke.sh and prod-smoke.sh against a fake curl (test/fakebin-smoke). No network, no credentials:
# every value below is a made-up string chosen to be easy to grep for. The key assertion is that NONE of the secrets ever shows up
# in the scripts' output or in the arguments curl was started with.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
p=$(dirname "$here")
fx=$here/fixtures
export PATH="$here/fakebin-smoke:$here/fakebin:$PATH"
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
S=$p/authenticated-smoke.sh
P=$p/prod-smoke.sh

check() { # check <name> <condition...>
  local name=$1
  shift
  if "$@"; then pass=$((pass + 1)); else echo "FAIL $name"; failed=$((failed + 1)); fi
}
eq() { [ "$1" = "$2" ]; }
has() { grep -qF -- "$1" "$tmp/out"; }
hasnt() { ! grep -qF -- "$1" "$tmp/out"; }
calls() { cat "$FAKE/calls" 2>/dev/null || echo 0; }
# in_file <needle> <file>: the file contains the needle (as a fixed string)
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

# run [args...]: runs the smoke with the fake credentials; sets rc, out.
run() {
  SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY IDENTITY_TOOLKIT_URL=http://127.0.0.1:1 \
    bash "$S" http://127.0.0.1:2 "$@" >"$tmp/out" 2>&1
  rc=$?
}

# secrecy <name>: nothing secret in the output, and curl never received one in its arguments (the API key is public, so it may).
secrecy() {
  local name=$1 s
  for s in "$TOKEN" "$PASSWORD" "$EMAIL"; do
    check "$name: output has no $s" hasnt "$s"
    check "$name: curl argv has no $s" not_in_file "$s" "$FAKE/argv.log"
  done
  check "$name: output has no response body" hasnt '"idToken"'
}

# --- success path
setup; run
check "success exits 0" eq "$rc" 0
check "success: PASS line" has 'authenticated smoke: PASS'
check "success: ends with the PASS line" eq "$(tail -n 1 "$tmp/out")" 'authenticated smoke: PASS'
check "success: prints the handle" has 'handle: smoke_a'
check "success: 4 calls (sign-in, unauthenticated GetMe, GetMe, GetProfile)" eq "$(calls)" 4
secrecy "success"
# the secrets did reach curl, on stdin (so the secrecy checks above are not vacuous)
check "token reached curl on stdin" in_file "Authorization: Bearer $TOKEN" "$FAKE/stdin.3"
check "password reached curl on stdin" in_file "$PASSWORD" "$FAKE/stdin.1"
check "the API key (public) is in the sign-in URL" in_file "key=$APIKEY" "$FAKE/argv.log"

# --- handle handling
setup; run --handle smoke_a
check "--handle matching GetMe passes" eq "$rc" 0
setup; echo '{"profile":{"handle":"Smoke_A"}}' >"$FAKE/getprofile-body"; run
check "handle comparison is case-insensitive" eq "$rc" 0

# --- sign-in failure
setup; echo 400 >"$FAKE/signin-code"; echo '{"error":{"message":"INVALID_PASSWORD"}}' >"$FAKE/signin-body"; run
check "sign-in 400 fails" eq "$rc" 1
check "sign-in 400: FAIL at sign-in" has 'authenticated smoke: FAIL at sign-in'
check "sign-in 400: no further call" eq "$(calls)" 1
secrecy "sign-in 400"
check "sign-in 400: the error body is not printed" hasnt INVALID_PASSWORD
setup; echo '{"noToken":true}' >"$FAKE/signin-body"; run
check "sign-in 200 without a token fails" eq "$rc" 1
check "sign-in without token: FAIL at sign-in" has 'authenticated smoke: FAIL at sign-in'

# --- usage and environment errors exit 2
setup
for v in SMOKE_EMAIL SMOKE_PASSWORD FIREBASE_API_KEY; do
  (
    export SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY
    unset "$v"
    bash "$S" http://127.0.0.1:2
  ) >"$tmp/out" 2>&1
  rc=$?
  check "missing $v exits 2" eq "$rc" 2
  check "missing $v: names the variable" has "$v is required"
done
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY bash "$S" >"$tmp/out" 2>&1
check "no arguments exits 2" eq "$?" 2
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY bash "$S" http://127.0.0.1:2 --bogus >"$tmp/out" 2>&1
check "unknown option exits 2" eq "$?" 2
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY bash "$S" http://example.com >"$tmp/out" 2>&1
check "plain http to a real host exits 2" eq "$?" 2
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY bash "$S" https://user:pw@example.com >"$tmp/out" 2>&1
check "credentials in the URL exit 2" eq "$?" 2
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY IDENTITY_TOOLKIT_URL=http://example.com bash "$S" http://127.0.0.1:2 >"$tmp/out" 2>&1
check "the password is never sent over plain http to a real host" eq "$?" 2
check "no call for any usage error" eq "$(calls)" 0
secrecy "usage errors"

# --- auth must be enforced
setup; echo 200 >"$FAKE/getme-unauth-code"; run
check "unauthenticated GetMe 200 fails" eq "$rc" 1
check "unauthenticated 200: FAIL at unauthenticated-getme" has 'authenticated smoke: FAIL at unauthenticated-getme'
check "unauthenticated 200: stops before the authenticated calls" eq "$(calls)" 2
secrecy "auth open"
setup; echo 403 >"$FAKE/getme-unauth-code"; run
check "unauthenticated GetMe 403 fails (only 401 proves enforcement)" eq "$rc" 1

# --- authenticated GetMe
setup; echo 401 >"$FAKE/getme-codes"; run
check "authenticated GetMe 401 fails" eq "$rc" 1
check "GetMe 401: FAIL at getme" has 'authenticated smoke: FAIL at getme'
check "GetMe 401: no retry on a 401" eq "$(calls)" 3
setup; echo '{"profile":{}}' >"$FAKE/getme-body"; run
check "GetMe without a handle fails" eq "$rc" 1
check "GetMe without a handle: FAIL at getme" has 'authenticated smoke: FAIL at getme'
secrecy "getme failures"

# --- cold start: retry only transient answers
setup; printf '503\n503\n200\n' >"$FAKE/getme-codes"; run
check "GetMe 503 twice then 200 passes" eq "$rc" 0
check "503 twice: PASS" has 'authenticated smoke: PASS'
check "503 twice: 3 GetMe attempts (6 calls in all)" eq "$(calls)" 6
secrecy "retry"
setup; printf '503\n503\n503\n503\n503\n' >"$FAKE/getme-codes"; run
check "GetMe 503 always fails" eq "$rc" 1
check "503 always: FAIL at getme" has 'authenticated smoke: FAIL at getme'
check "503 always: gives up after 3 attempts" eq "$(calls)" 5
setup; printf 'conn\n200\n' >"$FAKE/getme-codes"; run
check "a connection error is retried" eq "$rc" 0
setup; printf '502\n504\n200\n' >"$FAKE/getme-codes"; run
check "502 and 504 are retried" eq "$rc" 0
setup; printf '500\n200\n' >"$FAKE/getme-codes"; run
check "500 is NOT retried" eq "$rc" 1

# --- GetProfile
setup; echo '{"profile":{"handle":"someone_else"}}' >"$FAKE/getprofile-body"; run
check "GetProfile handle mismatch fails" eq "$rc" 1
check "mismatch: FAIL at getprofile" has 'authenticated smoke: FAIL at getprofile'
setup; echo 404 >"$FAKE/getprofile-code"; run
check "GetProfile 404 fails" eq "$rc" 1
check "GetProfile 404: FAIL at getprofile" has 'authenticated smoke: FAIL at getprofile'
setup; run --handle other_handle
check "--handle is what GetProfile asks for (mismatch with the fake answer fails)" eq "$rc" 1
check "--handle: the requested handle is in the request" in_file other_handle "$FAKE/argv.log"
secrecy "getprofile failures"

# --- GitHub Actions: the token is masked before any other use, and that line is the only place it appears
setup
SMOKE_EMAIL=$EMAIL SMOKE_PASSWORD=$PASSWORD FIREBASE_API_KEY=$APIKEY IDENTITY_TOOLKIT_URL=http://127.0.0.1:1 GITHUB_ACTIONS=true \
  bash "$S" http://127.0.0.1:2 >"$tmp/out" 2>&1
rc=$?
check "Actions run passes" eq "$rc" 0
check "Actions: exactly one ::add-mask:: line" eq "$(grep -c '^::add-mask::' "$tmp/out")" 1
check "Actions: the mask line carries the token" has "::add-mask::$TOKEN"
check "Actions: nothing else in the output carries the token" eq "$(grep -F -- "$TOKEN" "$tmp/out" | grep -vc '^::add-mask::')" 0
mask_line=$(grep -n '^::add-mask::' "$tmp/out" | head -1 | cut -d: -f1)
next_line=$(grep -n 'unauthenticated GetMe' "$tmp/out" | head -1 | cut -d: -f1)
check "Actions: the mask comes before the next step" [ "$mask_line" -lt "$next_line" ]
check "Actions: password absent" hasnt "$PASSWORD"
check "Actions: email absent" hasnt "$EMAIL"
setup; run
check "outside Actions no mask line is printed" hasnt '::add-mask::'

# --- prod-smoke.sh
envfile=$tmp/prod.env
{
  echo "SMOKE_EMAIL_1=$EMAIL"
  echo "SMOKE_PASSWORD_1=$PASSWORD"
  echo "SMOKE_EMAIL_2=second.person@example.invalid"
  echo "SMOKE_PASSWORD_2=FAKE-PW-2-xyz"
} >"$envfile"
chmod 600 "$envfile" 2>/dev/null || true
OPTS=$fx/firebase-options-prod.dart.txt
prod() { # prod <args...>
  SMOKE_ENV_FILE=${ENVF:-$envfile} FIREBASE_OPTIONS_FILE=$OPTS IDENTITY_TOOLKIT_URL=http://127.0.0.1:1 bash "$P" "$@" >"$tmp/out" 2>&1
  rc=$?
}
unset FIREBASE_API_KEY
setup; prod http://127.0.0.1:2
check "prod-smoke passes with account 1 by default" eq "$rc" 0
check "prod-smoke takes the WEB key from the options file" in_file "key=FAKE-WEB-KEY" "$FAKE/argv.log"
check "prod-smoke does not take the android key" not_in_file FAKE-ANDROID-KEY "$FAKE/argv.log"
check "prod-smoke does not take the ios key" not_in_file FAKE-IOS-KEY "$FAKE/argv.log"
check "prod-smoke signs in as account 1" in_file "$EMAIL" "$FAKE/stdin.1"
secrecy "prod-smoke"
check "prod-smoke does not echo the env file (account 2 email)" hasnt second.person
check "prod-smoke does not echo the env file (account 2 password)" hasnt FAKE-PW-2-xyz
setup; prod http://127.0.0.1:2 2
check "prod-smoke account 2 passes" eq "$rc" 0
check "prod-smoke signs in as account 2" in_file "second.person@example.invalid" "$FAKE/stdin.1"
check "prod-smoke account 2: account 1 password not used" not_in_file "$PASSWORD" "$FAKE/stdin.1"
# the real options file has CRLF in a Windows working copy
sed 's/$/\r/' "$fx/firebase-options-prod.dart.txt" >"$tmp/options-crlf.dart"
setup; OPTS=$tmp/options-crlf.dart prod http://127.0.0.1:2
check "prod-smoke reads a CRLF options file" eq "$rc" 0
check "prod-smoke CRLF: the web key, without a stray CR" in_file "key=FAKE-WEB-KEY" "$FAKE/argv.log"
OPTS=$fx/firebase-options-prod.dart.txt
setup; FIREBASE_API_KEY=FROM-ENV-KEY prod http://127.0.0.1:2
check "FIREBASE_API_KEY from the environment wins" in_file "key=FROM-ENV-KEY" "$FAKE/argv.log"
unset FIREBASE_API_KEY
setup; OPTS=$tmp/does-not-exist prod http://127.0.0.1:2
check "no api key anywhere exits 2" eq "$rc" 2
check "no api key: a clear message" has 'FIREBASE_API_KEY is unset'
echo 'class X {}' >"$tmp/no-key.dart"
setup; OPTS=$tmp/no-key.dart prod http://127.0.0.1:2
check "options file without a web key exits 2" eq "$rc" 2
OPTS=$fx/firebase-options-prod.dart.txt
setup; prod
check "prod-smoke without a URL exits 2" eq "$rc" 2
setup; prod http://127.0.0.1:2 3
check "prod-smoke account 3 exits 2" eq "$rc" 2
setup; ENVF=$tmp/missing.env prod http://127.0.0.1:2
check "missing env file exits 2" eq "$rc" 2
echo "SMOKE_EMAIL_1=$EMAIL" >"$tmp/partial.env"
chmod 600 "$tmp/partial.env" 2>/dev/null || true
setup; ENVF=$tmp/partial.env prod http://127.0.0.1:2
check "env file without the password exits 2" eq "$rc" 2
check "incomplete env file: names the variable, not a value" has 'SMOKE_PASSWORD_1 is not set'
secrecy "prod-smoke errors"
case $(uname -s) in
  MINGW* | MSYS* | CYGWIN*) echo "note: the group/world-readable env file test is skipped on Windows (stat cannot see the ACL)" ;;
  *)
    chmod 644 "$envfile"
    setup; prod http://127.0.0.1:2
    check "a group/world-readable env file is refused" eq "$rc" 2
    check "refusal says how to fix it" has 'chmod 600'
    check "refusal makes no call" eq "$(calls)" 0
    chmod 600 "$envfile"
    ;;
esac

echo "authenticated smoke tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
