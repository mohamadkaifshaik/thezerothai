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
- Fixed monthly cost added: INR X (0 if pay-per-use; the credit window of ADR-0022 lifts nothing after 2026-12-26)
- Free-tier quota consumed: reads/writes/day, requests, GB, Vision units, egress to India
- Trigger that justifies it (from free-tier-budget §6)

## Stage ladder (stage-ladder skill)
- Stage 0 choice made here, and the seam (interface, cursor, event envelope) that keeps it swappable
- Stage 2/3 target for the same concern, and the measured trigger that would move to it

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

Rules: the next number is the highest existing plus one (0012–0015 are intentionally unused); never edit an Accepted ADR's
decision — supersede it, or add a dated amendment note. Only the founder accepts an ADR (the merge of the ADR PR is the
acceptance). An ADR adding a fixed monthly cost needs the founder's explicit approval recorded in Deciders.

Existing ADRs: the directory `docs/adr/` is the list; read the ones the plan names before writing a new one.
