# Runbook: `shells` (W8 coming-soon pages)

| Flag | Env / Terraform | Gates | Default |
| --- | --- | --- | --- |
| `shells` | `FEATURE_SHELLS[_ALLOWLIST\|_PERCENT]` / `feature_shells*` | client only (no RPC): the Creator tools, Premium, Advertise and Calls pages, their drawer rows (under 600 dp) and the rail "More" menu (600 dp and up). Plan: `docs/plans/ui-w8-shells.md` | off |

- **Entries need `shells` and `ui_shell`.** With `ui_shell` off there is no entry in the legacy layout (founder decision F6, 2026-10-28). The routes need `shells` only; with it off, a typed `/creator-studio`, `/premium`, `/advertise` or `/calls` lands on Home.
- **Which pages exist** is the client constant `kVisibleShells`, not the flag: one flag turns all of them on or off for a caller.
- **Cost:** 0 reads/writes and 0 RPCs; the flag already travels in `GetMe.enabled_features`. The only cost is the web bundle (plan, Cost section).
- **Ramp:** dev allowlist (3 uids that also have `ui_shell`), ceiling in `scripts/promotion/flag-ceiling.json` (founder review). Prod: the founder accepted a prod raise up to `on` on all platforms (2026-10-28): allowlist, then `on`, each step a Terraform change plus a `v*` tag, a production-reviewer GO and `promote-prod` (ADR-0019). It reaches users only once `ui_shell` is on in prod. `flag-ceiling.json` has no `prod` block for any flag yet, so that decision lives here and in the plan, not in the file.
- **Rollback:** set `FEATURE_SHELLS=off` (or shrink the allowlist) and deploy; clients drop the entries and routes on their next `GetMe`. One page only: remove its kind from `kVisibleShells` by PR (web on the next deploy, mobile on the next store build).
- **Failure modes:**
  - **A page is visible to a user outside the allowlist:** roll back as above, then check `GetMe.enabled_features` for that uid.
  - **A store rejects a build over the pages** (placeholder content, or shown Premium prices without store billing; risk accepted by the founder): drop the cited kind from `kVisibleShells` for the store build and resubmit, or set `shells` off. Web is unaffected.
  - **The Premium pop-up opens without a tap,** or a page reads as something you can buy today: roll back as above and file a bug; the plan's tap-only and copy-guard tests should have caught it.
