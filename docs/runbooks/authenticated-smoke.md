# Runbook: authenticated smoke (prod candidate and live)

Owner: the founder. Scripts: `scripts/promotion/authenticated-smoke.sh` (the check) and `scripts/promotion/prod-smoke.sh` (the
founder's terminal wrapper). Fixture tests: `scripts/promotion/test/smoke-test.sh`, run by the required CI check "promotion scripts".
Cost: $0 (a handful of Firestore reads per run).

## Purpose: the x509/TLS lesson
`/health` is a static handler: no Firestore, no JWKS, no outbound TLS. When v0.4.1 (Go 1.26.10, GO-2026-6809 in `crypto/x509`) was
promoted, the readiness review (H5/H6) said only a real signed ID token exercises the changed paths: the Google key (JWKS) fetch and the
Firestore reads, both over outbound TLS. There was no tooling, so that gate (P2.6) was skipped. This script is that tooling.

It signs in as a smoke account (Identity Toolkit `accounts:signInWithPassword`) and then:
1. calls GetMe **without** a token and requires **401** (proves auth is enforced);
2. calls GetMe with the token: **200** and a non-empty profile handle;
3. calls GetProfile with that handle: **200** and the same handle.
Transient answers (502, 503, 504, connection errors: a cold start) are retried up to 3 times; anything else fails at once.

## What it proves, and what it does not
- Proves: a signed ID token is accepted (JWKS fetch and signature verification work on this build), Firestore reads over TLS work
  (`GetMe` and `GetProfile` read the profile), and an unauthenticated call is still refused.
- Does **not** prove: App Check (it is in monitor mode, so it is neither required nor exercised); any write path; any feature behind a
  flag; behavior under load. It only calls read-only RPCs.

## Output contract (public logs)
Only step names, HTTP status codes and the handle are printed, ending with exactly `authenticated smoke: PASS` (exit 0) or
`authenticated smoke: FAIL at <step>` (exit 1; steps: `sign-in`, `unauthenticated-getme`, `getme`, `getprofile`). Exit 2 means a usage or
environment error (a missing variable, a non-https URL). It never prints the password, the token, response bodies, the email or any uid.

## Usage (prod): from your OWN terminal
Never through the assistant's `!` prefix and never in CI for prod. Before `promote-prod` with `stage=10`, against the candidate:
```bash
bash scripts/promotion/prod-smoke.sh https://candidate---api-jgr3aiensq-el.a.run.app 1
```
and after a release against the live service URL (the candidate URL without the `candidate---` prefix):
```bash
bash scripts/promotion/prod-smoke.sh <live-service-url> 1
```
The second argument picks smoke account 1 or 2 (default 1). `prod-smoke.sh` reads `~/.dzeroth-smoke/prod.env` (override with
`SMOKE_ENV_FILE`), which defines `SMOKE_EMAIL_1`, `SMOKE_PASSWORD_1`, `SMOKE_EMAIL_2` and `SMOKE_PASSWORD_2`, and takes the Firebase web
API key from `FIREBASE_API_KEY` or, if unset, from the web block of `app/lib/firebase_options_prod.dart` (public client config). It
refuses an env file that group or others can read (Linux and macOS; on Windows `stat` cannot see the ACL, so check it yourself with
`icacls`). It works in Git Bash on Windows and on Linux.

**What to record** in the readiness or post-release note: just the `authenticated smoke: PASS` line and the date. Nothing else from the output.

## API key restrictions (the sign-in Referer)
The Firebase **web** (browser) API key is restricted by HTTP referrer to the app's own origins (prod: `https://dzeroth.com/*`,
`https://www.dzeroth.com/*`, `https://dzeroth-prod.web.app/*`, `https://dzeroth-prod.firebaseapp.com/*`). A terminal sends no `Referer`,
so Identity Toolkit refuses the sign-in call. The script therefore sends `Referer: $SMOKE_REFERER` on the **sign-in request only** (never on
GetMe or GetProfile). `SMOKE_REFERER` is optional for `authenticated-smoke.sh` (unset: no Referer) and must be an https URL without spaces
or `@`; `prod-smoke.sh` defaults it to `https://dzeroth.com/` (override by setting it). It is not a secret.
- **Recognize the failure:** `FAIL at sign-in` with `HTTP 403`. The response (not printed by the script) carries
  `error.message "Requests from referer <empty> are blocked."` and `reason API_KEY_HTTP_REFERRER_BLOCKED`. With a Referer for an allowed
  origin, fake credentials reach credential checking instead (400 `INVALID_LOGIN_CREDENTIALS`).
- **Dev:** needs the dev web origin as `SMOKE_REFERER`. Check the dev browser key's allowed referrers with
  `gcloud services api-keys list --project=dzeroth-dev`, and do not print key values (do not use `--format` fields that include `keyString`).
- **The Android key** currently has no application restriction, but do not rely on that: a future package or certificate restriction would
  break it. Use the web key and the Referer.

## The two prod smoke accounts and their credentials
- They are the two `FEATURE_GRAPH_ALLOWLIST` smoke accounts: throwaway identities, **no admin or custom claims**, never used for real
  people, and **never add real users** to them or to the allowlist because of this script.
- Credentials live in `~/.dzeroth-smoke/prod.env`, outside the repo, readable by your user only (`chmod 600`, or `icacls` with inheritance
  removed on Windows). Passwords are random, 32+ characters, unique, never reused, never in the repo, shell history, logs or chat.
- **Rotate** every 90 days or on any suspicion: reset the password with the Identity Toolkit admin `accounts:update` call (your ADC),
  update `prod.env`, run the smoke once to prove sign-in. The old password stops working at once.
- **Revoke** (suspected leak, or retiring the accounts): disable the user and revoke its refresh tokens (the same admin `accounts:update`
  call), then remove the entries from `prod.env`. The API verifies tokens without a revocation check, so an ID token already issued
  stays accepted for up to about 1 hour: accept that residual window.
- **Recover:** reset the password again (rotate). The accounts hold test data only.

## Resetting and verifying the prod smoke passwords (Git Bash on Windows)
**Why this section exists.** Sign-in rejections (`INVALID_LOGIN_CREDENTIALS`) appeared after a new password was passed as a command-line
argument to Windows programs (`jq --arg`, `curl -d @-` from Git Bash), although the server-side reset had applied, and disappeared when the
password was passed through the environment and stdin instead. The exact mechanism was not isolated. On Windows never pass a secret as an
argument: put it in the environment (`export PW=...`, then `jq -n '{...password:$ENV.PW...}'`), send it to curl with `--data-binary @-` from
stdin, and never print it.

**Rules.**
1. **Always verify a credential** by signing in right after setting it, and write it to `~/.dzeroth-smoke/prod.env` only after a verified OK:
   build the file under a temp name and rename it over `prod.env` at the end, and only if every account verified.
2. Run it from **Git Bash**, not PowerShell (PowerShell cannot parse the bash syntax and runs nothing).
3. The two keys are public client config in `app/lib/firebase_options_prod.dart`: the `web` block (used with `Referer: https://dzeroth.com/`,
   see "API key restrictions") and the `android` block (checked too, without a Referer).

The block holds no secrets. It prints only `account <n>: reset HTTP <code> | web key+referer: OK|<message> | android key: OK|<message>`.
The gcloud access token is short-lived and is the founder's own.
```bash
(
cd "$(git rev-parse --show-toplevel)" || exit 1
P=dzeroth-prod
IDT=https://identitytoolkit.googleapis.com
OPTS=app/lib/firebase_options_prod.dart
# The apiKey of one block (web or android) of the options file: public client config.
opt_key() {
  tr -d '\r' <"$OPTS" | awk -v blk="$1" '
    $0 ~ "static const FirebaseOptions " blk "[[:space:]]*=" { inb = 1 }
    inb && /apiKey:/ { print; exit }
    inb && /\);/ { exit }' | sed -n "s/.*apiKey:[[:space:]]*'\([^']*\)'.*/\1/p"
}
WEBKEY=$(opt_key web); ANDROIDKEY=$(opt_key android)
[ -n "$WEBKEY" ] && [ -n "$ANDROIDKEY" ] || { echo "missing a key in $OPTS"; exit 1; }
TOKEN=$(gcloud auth print-access-token)
# sign_in <key> [referer]: prints OK, or the error message (never a token or a body).
sign_in() {
  local ref=()
  [ -z "${2:-}" ] || ref=(-H "Referer: $2")
  jq -n '{email: $ENV.EM, password: $ENV.PW, returnSecureToken: true}' |
    curl -s --max-time 20 -X POST -H 'content-type: application/json' "${ref[@]}" --data-binary @- \
      "$IDT/v1/accounts:signInWithPassword?key=$1" |
    jq -r 'if .idToken then "OK" else (.error.message // "no answer") end'
}

# The two FEATURE_GRAPH_ALLOWLIST uids (comma separated) from the Cloud Run service env.
UIDS=$(gcloud run services describe api --project="$P" --region=asia-south1 --format=json |
  jq -r '.spec.template.spec.containers[0].env[] | select(.name=="FEATURE_GRAPH_ALLOWLIST") | .value')
mkdir -p ~/.dzeroth-smoke
NEW=~/.dzeroth-smoke/prod.env.new
( umask 077; : >"$NEW" )
all_ok=1; n=0
for UID_ in ${UIDS//,/ }; do
  n=$((n + 1))
  # Look up the email (project-scoped v1 endpoint).
  EM=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $P" -H 'content-type: application/json' \
    -d "{\"localId\":[\"$UID_\"]}" "$IDT/v1/projects/$P/accounts:lookup" | jq -r '.users[0].email // empty')
  export EM
  # New password: generated into an exported variable, never an argument, never printed.
  PW=$(openssl rand -base64 36 | tr -d '\r\n'); export PW
  # Set it (the body travels on stdin).
  code=$(jq -n --arg u "$UID_" '{localId: $u, password: $ENV.PW, emailVerified: true, disableUser: false}' |
    curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $P" \
      -H 'content-type: application/json' --data-binary @- "$IDT/v1/projects/$P/accounts:update")
  # Verify with the web key (+ Referer) and with the Android key.
  web=$(sign_in "$WEBKEY" https://dzeroth.com/); droid=$(sign_in "$ANDROIDKEY")
  echo "account $n: reset HTTP $code | web key+referer: $web | android key: $droid"
  if [ "$code" = 200 ] && [ "$web" = OK ] && [ "$droid" = OK ] && [ -n "$EM" ]; then
    printf "SMOKE_EMAIL_%s='%s'\nSMOKE_PASSWORD_%s='%s'\n" "$n" "$EM" "$n" "$PW" >>"$NEW"
  else
    all_ok=0
  fi
  unset PW EM
done
# Only a fully verified set replaces prod.env.
if [ "$all_ok" = 1 ] && [ "$n" = 2 ]; then
  mv -f "$NEW" ~/.dzeroth-smoke/prod.env && echo "prod.env updated"
else
  rm -f "$NEW"; echo "NOT updated: not every account verified OK"
fi
)
```
After the rename on Windows, check that `prod.env` is still readable by your user only (`icacls`). Then run `prod-smoke.sh` once against the live
service URL as the final proof.

## Why prod credentials are NOT in GitHub yet
The bot GitHub App can push `v*` tags, and the `prod` environment accepts `v*` tags. Secrets placed in the `prod` environment would
therefore be reachable by a workflow modified on a branch and run at a tag. Revisit after the public-repo ADR (required reviewers on the
`prod` environment) and a `v*` tag ruleset. Until then the prod smoke is run by hand, by the founder; a dev equivalent in CI is a separate,
later change (see `docs/runbooks/smoke-accounts.md` for the dev accounts' design).
