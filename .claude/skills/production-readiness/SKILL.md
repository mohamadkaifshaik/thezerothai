---
name: production-readiness
description: The GO/NO-GO production readiness checklist used by the production-reviewer, sized for a free-tier Stage 0 startup. Use before any production release.
---

# Production readiness checklist (Stage 0)
**Evidence required for every item — link the file, CI run, or console screenshot/export.**

### Quality
- [ ] CI green on release commit (lint, unit, emulator integration, buf breaking, flutter analyze/test)
- [ ] Test report PASS; coverage gates met
- [ ] Code review APPROVE; no open Blockers
### Security
- [ ] Security review: 0 Critical / 0 High open
- [ ] `govulncheck` + `osv-scanner` clean of Critical/High; image built by CI from a tagged commit (digest recorded)
- [ ] Firestore/Storage rules deny-all to clients (except public-read media bucket); App Check enforced
### Cost
- [ ] Cost report: new/changed RPCs have read/write budgets; totals ≤ 80% of free quota at current DAU target
- [ ] No new fixed-cost resource, or an Accepted ADR covers it (`cost-guard` hook clean)
- [ ] Budget alerts active; max-instances and per-user quotas unchanged or justified; degraded-mode switch tested on dev
### Reliability
- [ ] Tagged `rc` revision smoke-tested; previous revision identified for rollback
- [ ] Firestore indexes deployed and **READY** before traffic shift
- [ ] Pub/Sub handlers idempotent; DLQ configured
- [ ] Data changes are expand/contract
### Operability
- [ ] Error Reporting clean for the rc revision; uptime check green
- [ ] Runbooks updated; release notes written
- [ ] Feature flags default OFF; rollout plan (10% → 100%) with explicit rollback triggers (5xx > 2%, p95 > 2× baseline)
### Clients
- [ ] Mobile builds on TestFlight / Play internal tested on real devices (a low-end Android included)
- [ ] Crashlytics on; forced-upgrade path works; web initial bundle < 3 MB
### Compliance
- [ ] Privacy review for new PII; delete/export covers new collections (DPDP Act / GDPR)
- [ ] Store policies: UGC report + block present; privacy policy + account deletion in-app (required by App Store/Play)

`VERDICT: GO` only if every box is ✅ or an explicit, human-approved risk acceptance is recorded.
