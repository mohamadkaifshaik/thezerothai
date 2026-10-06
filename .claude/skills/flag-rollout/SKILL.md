---
name: flag-rollout
description: How server feature flags work (off/allowlist/percent/on), how to add one, ramp it, kill it and retire it. Use when shipping or rolling out any user-facing feature, or changing FEATURE_* config.
---

# Feature-flag rollout

Source of truth: `backend/pkg/platform/flags/flags.go` and ADR-0008 D6. Flags are env vars on the `api` Cloud Run
service: **0 Firestore reads**, mirrored to clients via `IdentityService.GetMe.enabled_features`.

## Modes
`FEATURE_<NAME>` = `off` (default) | `allowlist` | `percent` | `on`. Any other value fails startup.
- `FEATURE_<NAME>_ALLOWLIST` = comma-separated uids (a Terraform variable, not a secret); applies in allowlist and percent modes.
- `FEATURE_<NAME>_PERCENT` = 0-100, bucket = `fnv32a(name:uid) % 100`.

## Adding a flag
1. Register it in `flags.NewRegistry` and `config.Config` (follow `FEATURE_POSTS`).
2. Guard every RPC in the *service layer* with the shared helper (`flags.DisabledError`: FAILED_PRECONDITION `FEATURE_DISABLED`, before any Firestore access).
3. Gate the client on `enabled_features`; the server stays authoritative.
4. Add the env vars to Terraform (`cloud-run-api`), default `off` in prod.

## Ramp (prod)
allowlist (founder + testers) → percent 5 → 25 → 100 → `on`. Check `docs/reviews/cost-model.md` headroom and the
error rate before each step; each step is a Terraform change plus a `release-rollout` tagged revision.
Prerequisites for going beyond allowlist come from the plan (e.g. posts needs the P0 read budget deployed to prod).

## Kill switch
Set the flag to `off` (or lower the percent) and deploy; no data migration is needed. Document the trigger in the plan's rollout section.

## Retire
Once `on` and the minimum supported client no longer reads it, remove the env vars but keep reporting the name
(`NewRetired`). Never reuse a retired name.
