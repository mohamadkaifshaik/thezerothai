# 0006. Authentication, App Check and abuse controls
Status: Accepted
Date: 2026-09-26
Deciders: architect, founder

## Context
Stage 0 has no Cloud Armor, no LB, no WAF (fixed cost). A scripted signup/spam/scrape wave is simultaneously a
safety problem and a **cost** problem: every abusive request burns Firestore reads/writes from a 50k/20k daily quota
and Cloud Run requests from a billing-account-wide 2M/month. The Cloud Run service must stay `allUsers`-invokable
(no IAP/LB), so all authentication happens in Go. Phone/SMS auth is billed per SMS and is forbidden (CLAUDE.md).

## Options
### A. Firebase Auth (email/password, Google, Apple) + App Check + layered in-app limits (chosen)
- Pros: $0 at our scale; ID tokens verified locally in Go against cached Google public keys (no per-request call);
  App Check (Play Integrity / App Attest / reCAPTCHA v3 on web) blocks most scripted clients for free; limits are
  code/config (rule 11).
- Cons: App Check on web (reCAPTCHA v3) is weaker than device attestation; Play Integrity has a daily call quota
  (tokens are cached client-side for their TTL, ~1 h); in-memory rate limits are per instance (×3 at max scale).
- Cost: $0 fixed; ~1 Firestore read + 1 write per quota'd mutation (included in RPC budgets).

### B. Self-hosted auth (Go + password hashes in Firestore, own OAuth)
- Cons: we'd store PII and password hashes, implement MFA/reset flows, and still need bot defence. More risk, no saving.
- Cost: $0 infra; high engineering and security cost.

### C. Cloud Armor / reCAPTCHA Enterprise on an external LB
- Pros: edge rate limiting, bot scores.
- Cons: LB forwarding rule + Armor policy = fixed monthly fee (~$18+/month LB, Armor per policy/rule).
- Cost: ≈ $25–40/month idle. Deferred to Stage 3 (CLAUDE.md).

## Cost impact
- Fixed monthly cost added: **$0**.
- Free-tier quota consumed: `quotas/{uid}` = +1 read, +1 write on CreatePost/Follow/CreateUpload/RequestAccountExport
  (≈ 1.7 reads + 1.7 writes per DAU/day); token verification and App Check verification are local JWT checks (0 reads).
- Trigger: sustained abuse that in-app limits can't absorb (e.g. > 20% of requests rejected for 7 days, or a budget
  alert caused by abuse twice in a month) → ADR for LB + Cloud Armor or reCAPTCHA Enterprise.

## Decision
1. **Identity providers:** Firebase Auth Email/Password (email verification required before posting, following,
   uploading), Google, Apple (required on iOS when Google is offered). Phone provider stays **disabled**.
2. **Per request (Connect interceptors, in order):** recover → trace/log → **App Check** (`X-Firebase-AppCheck`, JWT
   verified against the App Check JWKS, audience = project number; missing/invalid → UNAUTHENTICATED +
   `ERROR_REASON_APP_CHECK_REQUIRED`) → **Firebase ID token** (`Authorization: Bearer`, issuer/audience = project,
   expiry, signature; uid from token only) → **rate limit** → **degraded mode** → account status
   (SUSPENDED/DELETING → PERMISSION_DENIED; no profile → PROFILE_REQUIRED) → error mapping → validation.
   *Amended 2026-09-27 (Phase 0 review M1):* the free in-memory checks (rate limit, degraded mode) run before account
   status, the only interceptor that can read Firestore, so profile-less callers cannot burn reads unthrottled; a
   "no profile" result is negatively cached for ~10 s per instance (cleared by `CreateProfile`).
   Public (no ID token, App Check still required) RPCs: none at Stage 0. Allowed before a profile exists:
   `CreateProfile` and `CheckHandleAvailability` (the sign-up form needs it); all others get `ERROR_REASON_PROFILE_REQUIRED`.
   Enforcement flag `APP_CHECK_MODE=enforce|monitor` (monitor in dev and for the first prod week to measure false
   rejects; then enforce).
3. **In-memory token buckets** (per instance; effective limit ≤ 3× at max instances): per uid 60 req/min overall,
   home timeline 6/min, CheckHandleAvailability 10/min, likes 30/min; per client IP 120 req/min (IP = the `X-Forwarded-For` entry appended by Google's
   front end / Firebase Hosting, counted from the right; never the client-supplied leftmost entries). Over limit → RESOURCE_EXHAUSTED + `RATE_LIMITED` + retry_after.
4. **Daily quotas** (`quotas/{uid}`, day boundary IST, config `QUOTA_*`): posts 100, follows 200, media 20, exports 1;
   likes 500 enforced in memory. **New accounts (< 24 h):** posts 20, follows 50, media 5.
5. **Internal endpoints** `/internal/*` (Pub/Sub push, Scheduler) verify Google-signed OIDC tokens: audience = service
   URL, email = the dedicated push/scheduler SA; not reachable via Connect handlers.
6. **Authorization** is enforced in the module service layer, not handlers: ownership for deletes/updates/media;
   blocks and privacy on every read (NOT_FOUND for blocked-by to avoid leaking existence).
7. **Blast-radius caps:** Cloud Run max 3 instances × concurrency 80, request timeout 30 s, per-RPC deadline ≤ 10 s,
   page_size ≤ 50, following ≤ 5,000 — all in Terraform/config and reviewed like code.
8. **Tokens and secrets:** no service-account keys; cursor HMAC key in Secret Manager (1 version, read once per
   instance start).

## Consequences
- Positive: $0; most scripted abuse stopped before any Firestore read (App Check + ID token checks are local).
- Negative: per-instance limits are approximate; a determined attacker with many real devices can still create
  accounts (mitigated by email verification, new-account quotas, report flow, and degraded mode).
- Follow-up: runbook `docs/runbooks/abuse-spike.md` (flip `DEGRADED_MODE`, tighten `QUOTA_*`, disable signups via
  `admin/config.signupsEnabled`); security-auditor threat model before prod.
- Revisit when: the trigger above fires, or we add DMs (separate E2E ADR).

## Amendment 2026-09-27: web App Check deferred (founder decision)
reCAPTCHA Classic (v3) keys can no longer be created. Web App Check now needs reCAPTCHA Enterprise, sold as Google
Cloud Fraud Defense: 10,000 assessments per calendar month free per organization (pooled across projects), then a
**flat $8/month** from 10,001 to 100,000, then $0.001 per assessment (source: Fraud Defense billing docs). App Check
re-attests about twice per token TTL (default 1 h), so a few hundred daily web users would cross 10k/month. That is a
step to a fixed fee, which the prime directive forbids without an ADR and a revenue milestone.

Decision for Stage 0:
- **Web: no App Check.** The app skips activation when `RECAPTCHA_SITE_KEY` is empty (it is).
- **Mobile: Play Integrity (Android) / App Attest (iOS)**, both free. Register them in the App Check console when
  the store builds exist.
- **API: `APP_CHECK_MODE=monitor` for all clients.** The API can't reliably tell web requests from mobile ones, so it
  can't enforce App Check for mobile only. Until web has a provider, App Check is telemetry, not a gate. Abuse
  protection at Stage 0 is Firebase Auth, per-uid/per-IP rate limits, daily per-user quotas, the max-3-instances cap,
  degraded mode and the budget alerts.
- **Revisit** (new ADR) when abusive web sign-ups or requests show up in logs, or when revenue comfortably covers
  $8/month. The planned shape then: a `google_recaptcha_enterprise_key` (web, score-based, no localhost on prod) and
  `google_firebase_app_check_recaptcha_enterprise_config` in Terraform with a 1-day token TTL. The app switches to
  `ReCaptchaEnterpriseProvider` (already wired) by setting the `*_RECAPTCHA_SITE_KEY` repo variables. Then enforce.

## Amendment 2026-09-28: pre-auth IP limit and client IP resolution (security audit M1/M2)
- A **pre-auth per-IP token bucket** (`ratelimit.PreAuthIPMiddleware`, `RATE_LIMIT_PRE_AUTH_IP_PER_MIN`, default 120)
  now wraps the whole mux as net/http middleware, ahead of the §2 Connect chain. Unauthenticated floods are
  throttled before any JWT verification. `/health` is exempt. The §2 interceptor order itself is unchanged.
- **Client IP:** the rightmost `X-Forwarded-For` entry (appended by Google's front end) is trusted. When that entry is a
  Google-operated egress address (goog.json minus the customer-rentable cloud.json ranges, so it can't be spoofed
  from a rented VM), the request came through Firebase Hosting and the next entry left is the client. Verified on dev,
  2026-09-28: direct requests log `xff_hops=1 via_hosting=false`, Hosting requests `xff_hops=2 via_hosting=true`.
- `CreateProfile` requires `email_verified` for password-provider accounts (audit H1). Google and Apple are exempt.
- Request bodies are capped at 256 KiB (`connect.WithReadMaxBytes` + `http.MaxBytesHandler`).

## Handoff
- backend-developer: `pkg/platform/authn` (ID token + App Check verifiers with cached JWKS, emulator mode via
  `FIREBASE_AUTH_EMULATOR_HOST`), `pkg/platform/ratelimit` (token buckets keyed by uid/IP, LRU-bounded),
  `pkg/platform/quota`, `pkg/platform/degraded`; interceptor chain as in §2; `/internal` OIDC verifier.
- frontend-developer: Firebase Auth UI for email (with verification gate), Google, Apple; App Check providers per
  platform (debug provider in dev only); attach both headers on every call; handle PROFILE_REQUIRED,
  EMAIL_NOT_VERIFIED, RATE_LIMITED, QUOTA_EXCEEDED, DEGRADED_MODE distinctly.
- production-deployer: enable Email/Password, Google, Apple providers only; App Check apps registered
  (Play Integrity, App Attest/DeviceCheck; web deferred, see the 2026-09-27 amendment); push/scheduler SA with OIDC; cursor HMAC secret.
- tester: tokens with wrong audience/issuer/expired, missing App Check, suspended account, per-uid bucket exhaustion,
  quota rollover, new-account quotas, forged `/internal` calls.

## Note 2026-09-28: see ADR-0008
Cross-reference only; no decision above changes. ADR-0008 D7 adds graph abuse limits as a follow-up to §3–§4: a
`blocks` daily quota (Block + Mute, 200/day, 50 for new accounts), per-procedure buckets for graph RPCs, an in-memory
daily cap on list RPCs, and CheckHandleAvailability at 20/min. ADR-0008 D9 is the block-semantics table that
implements §6 ("NOT_FOUND for blocked-by"), and D6 defines the env-var feature-flag pattern.
