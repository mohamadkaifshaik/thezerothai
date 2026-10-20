#!/usr/bin/env bash
# scripts/mint-app-token.sh mints a short-lived (1 hour) GitHub App installation access token and prints
# it to stdout, and nothing else, so callers can do `GH_TOKEN=$(bash scripts/mint-app-token.sh)`.
#
# Flow: sign a 10-minute RS256 JWT with the App's private key, then exchange it for an installation token
# via POST /app/installations/{id}/access_tokens.
#
# APP_ID / INSTALLATION_ID / APP_KEY come from the environment, defaulting to this repo's agent App.
# Needs only bash, openssl and curl (no jq/python), so it runs under Git Bash on Windows too.
#
# The key and the token are secrets: neither is ever echoed, logged or written to disk. Diagnostics go to
# stderr and never include the token or the API response body on success.
set -euo pipefail

APP_ID="${APP_ID:-5396134}"
INSTALLATION_ID="${INSTALLATION_ID:-173396003}"
APP_KEY="${APP_KEY:-$HOME/.dzeroth-agent/app.pem}"
API_URL="${GITHUB_API_URL:-https://api.github.com}"

[[ -r "$APP_KEY" ]] || { echo "mint-app-token: cannot read private key at $APP_KEY" >&2; exit 1; }
command -v cygpath >/dev/null && APP_KEY=$(cygpath -m "$APP_KEY")

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
# iat is backdated 60s to tolerate clock drift; GitHub caps exp - iat at 10 minutes.
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$APP_KEY" | b64url)
jwt="$header.$payload.$signature"

response=$(curl -sS -w '\n%{http_code}' -X POST \
	-H "Authorization: Bearer $jwt" \
	-H "Accept: application/vnd.github+json" \
	-H "X-GitHub-Api-Version: 2022-11-28" \
	"$API_URL/app/installations/$INSTALLATION_ID/access_tokens")

status=${response##*$'\n'}
body=${response%$'\n'*}

if [[ "$status" != "201" ]]; then
	echo "mint-app-token: GitHub returned HTTP $status: $body" >&2
	exit 1
fi

token=$(printf '%s' "$body" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[[ -n "$token" ]] || { echo "mint-app-token: no token in response" >&2; exit 1; }

printf '%s\n' "$token"
