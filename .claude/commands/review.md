---
description: Run code review + security review + tests on the current changes in parallel
---
In parallel, run the `code-reviewer`, `security-auditor` and `tester` subagents on the current diff (`git diff main...HEAD`).
Merge their findings into one prioritized list (Blocker → Nit) with owners.
