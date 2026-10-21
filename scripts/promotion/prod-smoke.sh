#!/usr/bin/env bash
# The founder's terminal wrapper around authenticated-smoke.sh for PROD. Run it from your OWN terminal: never through the assistant's
# `!` prefix, never in CI. See docs/runbooks/authenticated-smoke.md.
#
# Usage: prod-smoke.sh <base_url> [1|2]        (account 1 by default)
# Env file (default ~/.dzeroth-smoke/prod.env, override with SMOKE_ENV_FILE) defines SMOKE_EMAIL_1, SMOKE_PASSWORD_1, SMOKE_EMAIL_2,
# SMOKE_PASSWORD_2. It lives outside the repo with a user-only ACL, and its contents are never echoed.
# FIREBASE_API_KEY comes from the environment or, if unset, from the web block of app/lib/firebase_options_prod.dart (public client
# config; override the path with FIREBASE_OPTIONS_FILE).
# SMOKE_REFERER (default https://dzeroth.com/, override allowed) is exported: the web API key is restricted by HTTP referrer and the
# sign-in call must carry the app's own origin as Referer (see the runbook, "API key restrictions").
# Exit codes: those of authenticated-smoke.sh (0 pass, 1 smoke failure), or 2 for a usage or environment error here.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

die() { echo "FAIL: $*" >&2; exit 2; }

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then die "usage: prod-smoke.sh <base_url> [1|2]"; fi
base=$1
account=${2:-1}
case $account in 1 | 2) ;; *) die "account must be 1 or 2" ;; esac

env_file=${SMOKE_ENV_FILE:-$HOME/.dzeroth-smoke/prod.env}
[ -f "$env_file" ] || die "env file not found: $env_file (see docs/runbooks/authenticated-smoke.md)"

# Refuse a group- or world-accessible env file where the mode means something. On Windows (Git Bash) stat cannot tell the real ACL,
# so the check is skipped there: make sure the file is readable by your user only (icacls).
case $(uname -s) in
  MINGW* | MSYS* | CYGWIN*)
    echo "note: file permissions are not checked on Windows; the env file must be readable by your user only (icacls)" >&2
    ;;
  *)
    mode=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null || true)
    if [ -n "$mode" ]; then
      case $mode in
        *00 | 0) ;; # user-only (rwx for the owner, nothing for group or others)
        *) die "$env_file is accessible by group or others (mode $mode); run: chmod 600 \"$env_file\"" ;;
      esac
    fi
    ;;
esac

# shellcheck source=/dev/null
. "$env_file"

email_var=SMOKE_EMAIL_$account
password_var=SMOKE_PASSWORD_$account
[ -n "${!email_var:-}" ] || die "$email_var is not set in the env file"
[ -n "${!password_var:-}" ] || die "$password_var is not set in the env file"
SMOKE_EMAIL=${!email_var}
SMOKE_PASSWORD=${!password_var}
export SMOKE_EMAIL SMOKE_PASSWORD

if [ -z "${FIREBASE_API_KEY:-}" ]; then
  opts=${FIREBASE_OPTIONS_FILE:-$here/../../app/lib/firebase_options_prod.dart}
  [ -r "$opts" ] || die "FIREBASE_API_KEY is unset and $opts is not readable"
  # The apiKey inside `static const FirebaseOptions web = FirebaseOptions(` (the file also holds android and ios keys).
  FIREBASE_API_KEY=$(tr -d '\r' <"$opts" | awk '
    /static const FirebaseOptions web[[:space:]]*=/ { inweb = 1 }
    inweb && /apiKey:/ { print; exit }
    inweb && /\);/ { exit }' | sed -n "s/.*apiKey:[[:space:]]*'\([^']*\)'.*/\1/p")
  [ -n "$FIREBASE_API_KEY" ] || die "could not find the web apiKey in $opts; set FIREBASE_API_KEY"
fi
export FIREBASE_API_KEY
SMOKE_REFERER=${SMOKE_REFERER:-https://dzeroth.com/}
export SMOKE_REFERER

exec bash "$here/authenticated-smoke.sh" "$base"
