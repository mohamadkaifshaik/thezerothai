# Runbook: `ui_shell` (new app shell)

| Flag | Env / Terraform | Gates | Default |
| --- | --- | --- | --- |
| `ui_shell` | `FEATURE_UI_SHELL[_ALLOWLIST\|_PERCENT]` / `feature_ui_shell*` | client navigation chrome only (no RPC): bottom bar + avatar drawer + account chip + X-style rail | off |

- **Off:** legacy chrome (Settings is the 4th destination, no drawer or account chip, compose button wherever posting is offered).
  Colours and typography (ADR-0020) are not gated by the flag.
- **Cost:** 0 reads/writes; the flag already travels in `GetMe.enabled_features`.
- **Ramp:** dev allowlist -> percent -> on, per the `flag-rollout` skill. Ceiling in `scripts/promotion/flag-ceiling.json` (founder review).
- **Rollback:** set `FEATURE_UI_SHELL=off` (or lower the percent) and deploy; clients pick it up on the next `GetMe`.
- **Failure modes:** a user stuck without Settings access means the flag is on but the drawer/chip failed to render; roll back as above.
