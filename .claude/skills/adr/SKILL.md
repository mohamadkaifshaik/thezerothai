---
name: adr
description: Template and rules for writing Architecture Decision Records, including the mandatory cost section. Use whenever making or changing an architectural decision.
---

# ADR template — `docs/adr/NNNN-kebab-title.md`

```
# NNNN. <Title>
Status: Proposed | Accepted | Superseded by NNNN
Date: YYYY-MM-DD
Deciders: architect, <human>

## Context
Problem, constraints, current stage (CLAUDE.md), measured numbers (DAU, reads/day, p95, bill).

## Options
### A. <option>  — pros / cons / cost: idle $/month, $/month at current DAU, at 10× DAU
### B. <option>  — pros / cons / cost: ...

## Cost impact
- Fixed monthly cost added: $X (0 if pay-per-use)
- Free-tier quota consumed: reads/writes/day, requests, GB
- Trigger that justifies it (from free-tier-budget §6)

## Decision
What and why, in one paragraph.

## Consequences
Positive, negative, follow-up work, what would make us revisit.

## Handoff
- backend-developer: ...
- frontend-developer: ...
- production-deployer: ...
- tester: ...
```

Rules: number sequentially, never edit an Accepted ADR's decision — supersede it. An ADR adding a fixed monthly cost needs
the human founder's explicit approval recorded in Deciders.

Seed ADRs: 0001 Free-tier-first architecture (exists) · 0002 Firestore data model · 0003 Pull timeline with incremental refresh ·
0004 Client-side media processing · 0005 Search via Firestore prefix/hashtags · 0006 ID generation · 0007 Auth & App Check.
