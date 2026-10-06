---
name: security-checklist
description: Security review checklist for features, APIs, infra and releases using free/no-cost controls. Use for any security review or when touching auth, input handling, media or IAM.
---

# Security checklist (free-tier controls)
- [ ] Every RPC authenticated (Firebase ID token: issuer, audience = project, expiry, signature via cached Google keys) except an explicit public list.
- [ ] Authz: ownership and visibility checks (private accounts, blocked/muted) on every read and write path.
- [ ] Input validated in the Connect interceptor and again in the module (length, charset, NFC normalization, max 280 chars).
- [ ] Rate limits: per-user daily quotas (Firestore counters on docs already written) + per-instance token buckets per uid and per IP.
      Cloud Run `max-instances` caps blast radius and cost. (No Cloud Armor at Stage 0.)
- [ ] Firebase App Check enforced on the API (verify App Check token in Go) — blocks most scripted abuse for free.
- [ ] Signup friction: email verification or Google/Apple sign-in required before posting; new accounts get lower quotas for 24 h.
- [ ] Idempotency keys scoped per user; no IDOR — IDs never trusted without an ownership check.
- [ ] `/internal/*` endpoints verify Pub/Sub/Scheduler OIDC tokens (audience + service account email).
- [ ] Web client: no raw HTML rendering of user content; CSP + security headers set in `firebase.json` hosting config.
- [ ] Link previews (when added): isolated fetcher, deny private IP ranges and metadata server, re-check redirects, size/time caps.
- [ ] Media: signed URL TTL ≤ 10 min, bound to object + content-type + size range; magic-byte check; moderation before public copy.
- [ ] Firestore rules deny-all for clients; Storage upload bucket private; only the approved-media bucket is public.
- [ ] Secrets in Secret Manager or GitHub Actions OIDC — no service-account keys anywhere; Workload Identity Federation for CI.
- [ ] IAM least privilege per service account; no Owner/Editor on runtime SAs.
- [ ] `govulncheck ./...`, `osv-scanner` for Go and pub deps; GitHub Actions pinned by SHA; Dependabot on.
- [ ] Admin Activity audit logs (on by default, free). Data Access logs only for IAM/Secret Manager (volume = cost).
- [ ] PII: minimal (email lives in Firebase Auth); Google-managed encryption at rest; deletion and export paths tested.
- [ ] Budget alerts + degraded mode are part of the abuse response (a scraping/spam spike is also a cost spike).

## Known-public files (don't flag)
- `app/android/app/google-services.json` and `app/lib/firebase_options*.dart` hold Firebase **client** config, not secrets. They are protected by App Check enforcement and the API-key restrictions in `infra/terraform/modules/apikeys`. Flag them only if a service-account key or private key appears.
