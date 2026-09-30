# Security audit — Phase 0, before the v0.1.0 prod release (2026-09-27)

Auditor: security-auditor agent. The audit was read-only, against the repo at `main@8dac396` and the live dev/prod GCP,
Firebase and GitHub config. Rubric: the `security-checklist` skill and ADR-0006. Prod was pre-release at the time
(placeholder image, no prod rules or web deployed).

**Summary: 0 Critical, 1 High, 6 Medium, 10 Low.** Verified live: no auth bypass, Firestore deny-all enforced (dev and
prod), no public buckets beyond the intended media bucket, no service-account keys anywhere, `/internal/*` OIDC fails
closed, and the Terraform state bucket is private.

## Findings

| ID | Sev | Title | Evidence | Scenario | Fix |
|---|---|---|---|---|---|
| H1 | High | CreateProfile has no email-verified gate or per-IP creation cap, and App Check doesn't block it | `identity/service.go:60-81`, `server.go:41-51` never check `claims.EmailVerified`; CreateProfile is profile-exempt (`apiserver.go:74-79`); the per-IP limit is 120/min; `identitytoolkit` App Check is UNENFORCED (live) | Scripted email/password sign-ups with the public web API key: Firebase allows about 100 sign-ups per hour per IP, so about 2,400 profiles and about 7,200 writes per day from one IP. That's handle squatting plus about 36% of the 20k/day free write quota, and ~3 IPs exhaust it | Password-provider accounts need `email_verified` to CreateProfile (return `EMAIL_NOT_VERIFIED`); add a per-IP profile-creation cap; restrict API keys (M3) |
| M1 | Med | The per-IP rate limit runs after ID-token verification, so it can't throttle unauthenticated floods | `apiserver.go:97-114`; `IDTokenInterceptor` returns before `ratelimit`; live ingress ALL plus `allUsers` invoker | Floods of garbage tokens burn Cloud Run requests and JWT-verify CPU with no per-IP throttle, bounded only by max-instances=3 | Add a pre-auth per-IP token bucket as net/http middleware before the Connect chain |
| M2 | Med | `TRUSTED_PROXY_HOPS` is unmeasured (default 1), and its calibration log is Debug, below the Info logger level | `config.go:211`, `ratelimit/interceptor.go:48-53`, `logger.go:23`; 0 hop-count log lines in 30 days; Hosting-path requests arrive from shared Google egress IPs | Every web user behind Hosting may share one per-IP bucket (a single abuser trips it for everyone), or the limit keys on the wrong IP | Log hop counts at Info, measure in dev, set `TRUSTED_PROXY_HOPS`, add a Hosting-chain `ClientIP` test |
| M3 | Med | Firebase API keys are unrestricted (browser: no referrers; Android: no SHA) and allow a broad set of APIs | Live, both projects | The public web key can drive `identitytoolkit` sign-ups from any origin (feeds H1) | Restrict the browser key to our HTTP referrers; Android key SHA-256 and iOS bundle-id once store builds exist; trim the API list |
| M4 | Med | `tf-plan` has `roles/viewer` (reads all Firestore and Auth users); its WIF pool is pinned to the repo only; TF state holds the cursor HMAC key and is readable by tf-plan | Live IAM, WIF condition, state bucket IAM | Any repo workflow assuming tf-plan can read PII and the HMAC key. Not an escalation beyond the owner today; becomes one with a second collaborator | A custom read role without `datastore.entities.*` / `firebaseauth.users.*`; pin the plan pool to `terraform.yml` |
| M5 | Med | No account deletion or export, and no privacy policy | `identity/server.go:127-137` returns Unimplemented; no UI or policy | App Store / Play require in-app deletion (a store blocker); GDPR/DPDP erasure rights | For web launch: publish a privacy policy and a manual deletion runbook. For stores: ship DeleteAccount first (Phase 1) |
| M6 | Med | App Check doesn't enforce anywhere, and can't until web has a provider | Live: API `monitor`; App Check services UNENFORCED; web has no provider (ADR-0006 amendment, PR #12) | App Check is telemetry only, which multiplies H1/M1/M3 | Accepted by design (ADR-0006 amendment). Own the residual risk: H1/M1/M2/M3 are the compensating controls |
| L1 | Low | The default Compute Engine SA has `roles/editor` (dev and prod) | Live IAM | A latent broad identity (unused today) | Remove the Editor grant or disable the SA |
| L2 | Low | `ci-deploy` has `roles/firebase.viewer` (reads Firestore, Auth users and GCS objects) | Live IAM, `modules/iam/main.tf:126-131` | Over-broad read for a deploy identity | A narrow custom role for web-app config |
| L3 | Low | The CSP is Report-Only and has no `report-to`, so it's inert; no Permissions-Policy | `firebase.json`, live headers | It gathers no data and blocks nothing (XSS surface is low with Flutter) | Add reporting, then enforce; add a Permissions-Policy |
| L4 | Low | Prod `authorizedDomains` includes `localhost` | Live identitytoolkit config | A local app can complete OAuth against the prod project | Remove `localhost` from prod |
| L5 | Low | `storage.rules` is never deployed; `promote-prod` deploys Firestore rules/indexes after the 100% traffic shift | `deploy-dev.yml:78`, `release-prod.yml:114`, `promote-prod.yml:205-249` | Storage rules are inert (IAM and PAP protect the buckets). Rules and indexes after traffic will bite once there are indexed queries | Add `storage` to `--only`; deploy rules and indexes before shifting traffic |
| L6 | Low | Dependabot and vulnerability alerts are off; `govulncheck@latest` is unpinned; no osv-scanner | Live GitHub settings, `ci.yml:75` | No dependency alerting (the current tree is clean; two OSV hits are unreachable) | Enable Dependabot and alerts, pin tool versions, add osv-scanner |
| L7 | Low | Actions are pinned by tag, not SHA, in prod-credentialed workflows | release/promote/deploy-dev/terraform workflows | A tag hijack would run with prod WIF credentials (bounded by the WIF pin and a single collaborator) | SHA-pin actions, enable `sha_pinning_required`, add the Dependabot github-actions ecosystem |
| L8 | Low | No password policy; MFA off; founder GitHub 2FA unconfirmed; the VERDICT gate is honor-system | Live identitytoolkit, `gh api user` | Weak passwords; GitHub account takeover would mean prod deploys | Firebase password policy; enforce GitHub 2FA |
| L9 | Low | The `isPrivate` toggle isn't enforced server-side | `identity/service.go:124-149,180-182` | A misleading privacy control | Enforce it or hide it until the graph module lands |
| L10 | Low | The Unimplemented error leaks the internal roadmap | `identity/server.go:139-145` | Minor disclosure | Return a generic message |

**Informational:** Connect has no `WithReadMaxBytes`, so gzip bodies inflate before unmarshal. This sits behind auth,
so the risk is low at Stage 0. Add `connect.WithReadMaxBytes` (256 KiB) and `http.MaxBytesHandler` when posts and media land.

## Blocks v0.1.0?
- **H1: yes.** A small, free fix.
- **M5: conditional.** A web launch needs a privacy policy and a manual deletion process. A hard blocker for store submission.
- **M1, M2, M3, M6:** need a written risk acceptance in the readiness report. Do M2 and M3 before launch; they're cheap.
- **L1–L10:** hardening, to schedule.

## Verified OK
Auth (live 401s, Admin-SDK token verification, uid only from the token), interceptor order per the ADR-0006 amendment,
generic internal errors, `/internal/*` OIDC fail-closed (live), CORS off outside local, rate limiting working (live),
Firestore deny-all (live, both envs), private upload and state buckets, least-privilege runtime SA, ci-deploy
`run.developer` only, no SA keys, WIF conditions match Terraform (live), prod environment tag policy, env-indirected
workflows, input validation, max-instances=3, distroless nonroot image, graceful shutdown, degraded mode, phone and
anonymous auth off, Firestore delete protection, prod backups, PII-free request logs, govulncheck clean.

Sources: [Fraud Defense billing](https://docs.cloud.google.com/recaptcha/docs/billing-information),
[Firebase Auth limits](https://firebase.google.com/docs/auth/limits),
[DPDP Rules 2025 (EY)](https://www.ey.com/en_in/insights/cybersecurity/transforming-data-privacy-digital-personal-data-protection-rules-2025).

## Resolution (2026-09-28)
Founder-approved scope: the blockers plus the cheap fixes.
| ID | Status | Where |
|---|---|---|
| H1 | **Fixed.** CreateProfile requires `email_verified` for password accounts. Mass creation is also bounded by the pre-auth per-IP limiter (M1) and Firebase's own ~100 sign-ups/hour/IP | PR #14 |
| M1 | **Fixed.** A pre-auth per-IP token bucket runs as net/http middleware before auth | PR #14 |
| M2 | **Fixed and verified on dev.** A Hosting-aware ClientIP (Google egress allowlist, not spoofable); logs show direct `xff_hops=1/via_hosting=false` and Hosting `2/true` | PR #14 |
| M3 | **Fixed, dev and prod.** API keys imported into Terraform; browser keys restricted to our origins (an unknown Referer gets 403 `API_KEY_HTTP_REFERRER_BLOCKED`); API targets trimmed | PR #13 |
| M5 | **Web launch unblocked.** Privacy policy at `/privacy.html`, links in the app, privacy@dzeroth.com (ImprovMX to Gmail), manual deletion runbook `docs/runbooks/account-deletion.md`. Store submission is still blocked until in-app DeleteAccount (Phase 1) | PR #15, docs |
| L4 | **Fixed.** `localhost` removed from prod authorizedDomains (Identity Toolkit admin API) | live config |
| L5 | **Fixed.** Firestore rules and indexes deploy before any prod traffic shift; storage.rules documented as emulator-only (buckets are protected by IAM and PAP) | PR #13 |
| L10 | **Fixed.** Generic Unimplemented message | PR #14 |
| — | **Hardening.** 256 KiB request cap | PR #14 |
| L6 | **Closed for Dependabot** (`.github/dependabot.yml`: gomod, pub, github-actions, terraform). Still open: `govulncheck@latest` and other run-time tool versions are unpinned, and there's no osv-scanner (listed in `docs/runbooks/dependency-updates.md`) | PR #45 |
| L7 | **Closed.** All 36 third-party `uses:` in `.github/workflows/*.yml` (16 distinct actions) are SHA-pinned with version comments; Dependabot github-actions keeps them current. Enabling the `sha_pinning_required` repo setting is a follow-up | PR #45 |

**Accepted for v0.1.0 (written risk acceptance goes in the readiness report):** M4 (tf-plan has `roles/viewer`, and its WIF
is pinned to the repo only; single collaborator), M6 (App Check is monitor-only by design, ADR-0006 amendment), and
L1–L3, L6–L9 (hardening backlog).
**Follow-up:** log `xff_hops`/`via_hosting` for requests rejected before auth as well (today they log 0/false).
