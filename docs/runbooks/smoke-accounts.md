# Runbook (PROPOSAL): dev smoke accounts, credentials lifecycle and environment restriction
Status: **Implemented.** The two dev accounts and the `dev` Environment secrets (`SMOKE_A_EMAIL`, `SMOKE_A_PASSWORD`, `SMOKE_B_EMAIL`, `SMOKE_B_PASSWORD`) exist since 2026-10-19, with the environment limited to branch `main`. The dev deploy workflow now uses account A for the authenticated smoke (step `4b/8` of `promote-dev.sh`, fail closed on main; see `docs/runbooks/authenticated-smoke.md`, "Dev (CI)"). The text below is the original design proposal.
Owner and incident responder: the founder (confirmed 2026-10-19). Store: GitHub Actions **`dev` Environment secrets** (confirmed).
Note (2026-10-30): the CI smoke accounts were deleted from dev Auth outside the API and recreated as handles `smoke_a2` / `smoke_b2`. Gotcha: Git Bash `openssl rand` output ends with a CR, so generate passwords with `openssl rand -hex 24 | tr -d '\r\n'`.

## Purpose and limits
Two dev-only Firebase Auth identities let the dev deploy workflow smoke authenticated paths against a 0% candidate before promotion.
- Dev project `dzeroth-dev` only. No admin claims, no custom claims, no production access, no prod credentials.
- Never added to a feature allowlist unless a specific test is explicitly authorized by the founder. The dev-only bookmarks smoke (`bookmarks-smoke.sh`, W2-16) relies on it: it asserts that account A is refused by the `FEATURE_BOOKMARKS` cohort gate, so allowlisting A for bookmarks would fail every deploy-dev smoke until the entry is removed.
- The API refuses unverified emails on every RPC (`authn` requires `email_verified`), so the accounts must be created verified, with
  addresses the founder controls (or non-deliverable addresses; no mailbox is needed because they are created by an admin call).
- Feature-branch validation stays credential-free: branch/PR workflows never receive these secrets (see the environment restriction).

## Credentials and where they live
| Secret (dev Environment) | Content |
|---|---|
| `SMOKE_A_EMAIL`, `SMOKE_A_PASSWORD` | account A |
| `SMOKE_B_EMAIL`, `SMOKE_B_PASSWORD` | account B (second account for cross-user checks, e.g. graph/report negative cases) |
The Firebase Web API key is public app configuration, not a secret. Passwords are random, 32+ characters, unique per account, never
reused anywhere, never in the repo, shell history, logs, workflow outputs or artifacts. The workflow signs in fresh each run (Identity
Toolkit `accounts:signInWithPassword`); **refresh tokens are never stored**. The resulting ID token is passed through `::add-mask::`
before first use, is used only inside the step, and is never written to `$GITHUB_OUTPUT`, a file, or an artifact. The repo is public,
so every log line is public: the smoke steps print only step names, HTTP status codes, the smoke account's profile handle, for the bookmarks smoke also a Connect error code, the ErrorDetail reason and feature name (fixed alphabets) and a row count, and pass/fail (never a body, token, email, uid or Connect message).

## Token lifetime (important for revocation)
Firebase ID tokens live about 1 hour. The backend verifies them with `VerifyIDToken` (`backend/pkg/platform/authn/firebase.go`), which
does **not** check revocation. Therefore disabling an account or revoking its refresh tokens stops new sign-ins immediately but a token
already issued stays accepted by the API until it expires, **up to about 1 hour**. Dev only; accepted unless the founder wants
`VerifyIDTokenAndCheckRevoked` (one extra Auth lookup per request; would be an ADR-level cost/latency change, not proposed here).

## Lifecycle
1. **Create (one time, founder, local machine, nothing in CI).** Create each user with the Identity Toolkit admin API using the
   founder's ADC (`email`, random `password`, `emailVerified: true`), generating the password locally (`openssl rand -base64 36`),
   never echoing it. Then create the profile with the app's `CreateProfile` RPC (handle `smoke_a` / `smoke_b`). The exact admin call
   will be validated on dev before use (the REST shape is not yet exercised from this repo). Record the creation date in the secret
   description or the issue tracker, not the password.
2. **Store.** `gh secret set SMOKE_A_PASSWORD --env dev < file` (stdin, never as an argument), then delete the local file. Set all four.
3. **Use.** Only the `deploy-dev` workflow on `main`, in the validate step after the candidate smoke, never on forks or branches.
4. **Rotate every 90 days, or immediately on any suspicion:** generate a new password; set it with the admin `accounts:update`;
   `gh secret set ... --env dev`; run a dry-run dispatch to prove sign-in; delete the local file. Old password stops working at once.
5. **Revoke (compromise, offboarding, or retiring the accounts):** (a) disable the user (`disableUser: true`); (b) revoke refresh tokens
   (`validSince` update); (c) delete the four secrets (`gh secret delete NAME --env dev`); (d) accept the up-to-1-hour residual
   window for already-issued ID tokens; (e) check Cloud Logging for calls by those uids in that window (hash/uid kept out of public
   logs and issues; look in the Cloud Console, not in the repo).
6. **Recover:** delete the Auth users (and their dev data through the normal account deletion path), then repeat Create with new
   addresses and new passwords. The accounts hold test data only, so recovery loses nothing of value.
7. **Retire:** revoke as above, then delete the Auth users.

## Incident response (owner: founder)
Suspected leak of a smoke credential, or unexpected activity by a smoke uid: revoke immediately (step 5), rotate after the cause is
understood, and record what happened under `docs/reviews/` without credentials or uids. A leak cannot reach prod: the accounts exist
only in `dzeroth-dev`, the dev WIF identity cannot touch prod, and neither account has admin rights or allowlist entries.

## Environment restriction (to be applied only after the founder reviews this; before any secret is added)
Current state (read-only check 2026-10-19): `dev` has no protection rules and `deployment_branch_policy: null`, i.e. any branch's
workflow may reference it. Only `deploy-dev.yml` uses `environment: dev` (prod uses `prod`). The dev GCP identity is already pinned
to `deploy-dev.yml@refs/heads/main` for environment `dev` (`envs/dev/main.tf`), so GCP access from other refs already fails; this adds
the same limit for secrets.
```bash
# 1. restrict the environment to custom branch policies (wait_timer/reviewers are already empty, so nothing is removed)
gh api -X PUT repos/mohamadkaifshaik/thezerothai/environments/dev --input - <<'JSON'
{"wait_timer":0,"reviewers":null,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
# 2. allow only the main branch
gh api -X POST repos/mohamadkaifshaik/thezerothai/environments/dev/deployment-branch-policies -f name=main -f type=branch
# 3. verify
gh api repos/mohamadkaifshaik/thezerothai/environments/dev --jq .deployment_branch_policy
gh api repos/mohamadkaifshaik/thezerothai/environments/dev/deployment-branch-policies --jq '.branch_policies[]|[.name,.type]|@tsv'
# rollback of the setting itself
gh api -X PUT repos/mohamadkaifshaik/thezerothai/environments/dev --input - <<'JSON'
{"wait_timer":0,"reviewers":null,"deployment_branch_policy":null}
JSON
```
Effect: a run of `deploy-dev.yml` from any ref other than `main` is rejected at the environment gate (including manual dispatch from a
feature branch). **The new workflow therefore cannot be exercised from a branch at all: its first run is a dry run after merge**, which
is safe because promotion is off unless `DEV_PROMOTE` is `true` or a manual run sets `promote=true`. Tags are not allowed (the dev
workflow does not run on tags). Other workflows are unaffected.

## Open items before executing
- Validate the exact admin REST calls on dev (create, update password, disable, revoke) and record them here.
- Decide whether the smoke step also needs the accounts' ID token to cover write RPCs (a quota/read-budget decision: each smoke run
  costs a handful of reads; counts must be added to `docs/reviews/cost-model.md` at that time).
- Confirm the 90-day rotation reminder mechanism (the founder's calendar, or a scheduled workflow that only warns).

## Dev test accounts for development (w7smoke1..3), since 2026-10-30
The founder asked (2026-10-30) for three more dev-only accounts that agents and sessions use to verify **any** dev change end to end without the founder: `w7smoke1`, `w7smoke2`, `w7smoke3` (uid hash prefixes `29f33a`, `ce512b`, `cb1409`). They are **separate** from the CI smoke accounts above (SMOKE_A / SMOKE_B stay non-allowlisted; the bookmarks smoke still relies on that).
- **Created** with the admin call this runbook left open, now validated on dev: `POST https://identitytoolkit.googleapis.com/v1/projects/dzeroth-dev/accounts` with the founder's gcloud token, header `x-goog-user-project: dzeroth-dev`, body `{email, password, emailVerified: true}`. Addresses are non-deliverable (`@example.com`). Profiles were then made with `CreateProfile`.
- **Sign-in from a terminal:** `accounts:signInWithPassword?key=<web apiKey>` needs `returnSecureToken: true` (without it Identity Toolkit returns a legacy token the API refuses as `unauthenticated`) and `Referer: https://dzeroth-dev.web.app/` (the key is referrer-restricted).
- **Where the credentials live:** only on the founder's machine, outside the repo, in `%USERPROFILE%/.dzeroth/dev-test-accounts/` (`acct<N>.json` plus a `devacct.sh` helper with `signin N` and `rpc N <Service/Method> <json>`). Never in the repo, a PR, a log line or a GitHub secret. Never print a password, token or uid; logs are read by `uid_hash`.
- **Allowlists:** all 17 `feature_*_allowlist` lines of the dev tfvars hold the three testers plus these three (6 uids); the dev `max_allowlist` ceiling is 6 for every allowlist flag (`scripts/promotion/flag-ceiling.json`). A flag that is still unset in dev (`content_disclosure`, `reply_audience`, `scheduled_posts`, `shells`) gets the six uids when it is first rolled out. Prod is unchanged: these accounts do not exist there.
- **Limits:** dev project only, no admin or custom claims. Revoke, rotate and retire exactly as in "Lifecycle" above (`accounts:update` with `disableUser`, a new password, or delete). On a leak: disable all three, then follow "Incident response".
