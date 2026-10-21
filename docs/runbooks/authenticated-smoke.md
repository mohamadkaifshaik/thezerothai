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

## Why prod credentials are NOT in GitHub yet
The bot GitHub App can push `v*` tags, and the `prod` environment accepts `v*` tags. Secrets placed in the `prod` environment would
therefore be reachable by a workflow modified on a branch and run at a tag. Revisit after the public-repo ADR (required reviewers on the
`prod` environment) and a `v*` tag ruleset. Until then the prod smoke is run by hand, by the founder; a dev equivalent in CI is a separate,
later change (see `docs/runbooks/smoke-accounts.md` for the dev accounts' design).
