---
name: production-readiness
description: The GO/NO-GO production readiness checklist used by the production-reviewer, sized for a free-tier Stage 0 startup. Use before any production release.
---

# Production readiness checklist (Stage 0)
**Evidence required for every item — link the file, CI run, or console screenshot/export.**

### Quality
- [ ] CI green on release commit (lint, unit, emulator integration, buf breaking, flutter analyze/test); promotion validators green (`scripts/promotion`)
- [ ] Test report `VERDICT: PASS`; coverage gates met; budget assertions present
- [ ] Code review `APPROVE`; no open Blockers
### Security
- [ ] Security review `SECURITY: CLEAR`: 0 Critical / 0 High open
- [ ] Every new public read or write has a `Limit`, a per-user quota and a rate limit (effective limit = per-instance × max-instances)
- [ ] `govulncheck` + `osv-scanner` clean of Critical/High; image built by CI from a tagged commit (digest recorded)
- [ ] Firestore/Storage rules deny-all to clients (except public-read media bucket); App Check enforced
### Cost
- [ ] Cost report `BUDGET: HOLDS`: new/changed RPCs have read/write budgets; totals ≤ 80% of free quota at current DAU target
- [ ] No new fixed-cost resource, or an Accepted ADR covers it (`cost-guard` hook clean); credit-mode items carry `until:` dates and nothing bills after 2026-12-26 (ADR-0022)
- [ ] Budget alerts active; max-instances and per-user quotas unchanged or justified; degraded-mode switch tested on dev
- [ ] "If one post goes viral tonight, what breaks and what does it cost?" answered from the cost report (`stage-ladder` counter and rate-limit rows)
### Reliability
- [ ] Tagged `candidate` revision smoke-tested; previous revision identified for rollback
- [ ] Firestore indexes deployed and **READY** before traffic shift
- [ ] Pub/Sub handlers idempotent; DLQ configured
- [ ] Data changes are expand/contract
### Operability
- [ ] Error Reporting clean for the `candidate` revision; uptime check on `/health` green
- [ ] Runbooks updated; release notes written
- [ ] Feature flags default OFF; rollout plan (10% → 100%) with explicit rollback triggers (5xx > 2%, p95 > 2× baseline)
### Clients
- [ ] Mobile builds on TestFlight / Play internal tested on real devices (a low-end Android included)
- [ ] Crashlytics on; forced-upgrade path works; web initial bundle < 3 MB
### Approvals (ADR-0019)
- [ ] Founder approvals recorded for this release, **3 expected**: `release-prod` `build-and-stage`, `promote-prod` `stage=10`, `promote-prod` `stage=100`. Link each run; the first was approved only after comparing the tag's commit with the commit this review covers (a release is not complete with fewer)
### Compliance
- [ ] Privacy review for new PII; delete/export covers new collections (DPDP Act / GDPR)
- [ ] Store policies: UGC report + block present; privacy policy + account deletion in-app (required by App Store/Play)

`VERDICT: GO` only if every box is ✅ or an explicit, human-approved risk acceptance is recorded.
