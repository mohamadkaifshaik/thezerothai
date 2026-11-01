# Runbooks index

One runbook per failure mode or operation, grouped by situation. Something is broken right now: start with **Incidents**.
Binding rules are in `/CLAUDE.md`; decisions in `docs/adr/` win over a runbook. Adding a runbook: add its row to the right
group here in the same PR.

## Incidents: broken or costing money now

| When | Read |
|---|---|
| A deploy went bad: move traffic back to the previous revision | [rollback.md](rollback.md) |
| The bill or a free-tier quota is climbing: degraded mode, caps, budgets | [cost-spike.md](cost-spike.md) |
| Mass sign-ups, scraping or a request flood | [abuse-spike.md](abuse-spike.md) |
| The GCP credit ends (ADR-0022): pause everything, resume later, or fall back to the free tier | [credit-sunset-pause-resume.md](credit-sunset-pause-resume.md) |

## Features: failure modes, flags and rollback per module

| Feature | Read |
|---|---|
| Posts: create, delete, get, purge, timelines (ADR-0010) | [posts.md](posts.md) |
| Likes, reposts, quotes and the `post_delete` job (ADR-0018) | [engagement.md](engagement.md) |
| Bookmarks (ADR-0023) | [bookmarks.md](bookmarks.md) |
| Follows, blocks and mutes (ADR-0008) | [graph.md](graph.md) |
| Profile fields and the pinned post (ADR-0024) | [identity.md](identity.md) |
| Private accounts and the protected set (ADR-0025) | [private-accounts.md](private-accounts.md) |
| Images, avatars, banners and SafeSearch (ADR-0005) | [media.md](media.md) |
| Reports, takedowns and suspensions (ADR-0016) | [moderation.md](moderation.md) |
| Notifications and push (ADR-0017) | [notifications.md](notifications.md) |
| Search and trends (ADR-0028) | [search.md](search.md) |
| Lists and custom Home tabs (ADR-0030) | [lists.md](lists.md) |
| Direct messages (ADR-0027) | [messaging.md](messaging.md) |
| Communities (skeleton until the write path lands) | [communities.md](communities.md) |
| Client crash reporting and usage analytics (ADR-0032) | [client-telemetry.md](client-telemetry.md) |
| The new app shell, flag `ui_shell` | [ui-shell.md](ui-shell.md) |
| Coming-soon pages (Creator tools, Premium, Advertise, Calls), flag `shells` | [shells.md](shells.md) |

## User requests

| When | Read |
|---|---|
| Someone emails to delete their account or export their data; section 6 runs the in-app flow | [account-deletion.md](account-deletion.md) |

## Release, CI and dependencies

| When | Read |
|---|---|
| Required checks, code-owner review, the assistant's GitHub App identity, the `v*` tag ruleset | [ci-enforcement.md](ci-enforcement.md) |
| Signed-in smoke test of a prod candidate and of live prod | [authenticated-smoke.md](authenticated-smoke.md) |
| Dev smoke accounts: credentials, rotation, environment limits | [smoke-accounts.md](smoke-accounts.md) |
| Updating dependencies and SHA-pinned GitHub Actions | [dependency-updates.md](dependency-updates.md) |

## Setup and local tooling

| When | Read |
|---|---|
| First-time GCP and GitHub setup (human-run, once) | [cloud-bootstrap.md](cloud-bootstrap.md) |
| Claude Code commands, guardrails and hooks | [claude-setup.md](claude-setup.md) |
| Two emulator suites on one machine break each other's Storage files | [emulator-collisions.md](emulator-collisions.md) |

## One-off rollouts and applies (done, kept as a record)

| What | Read |
|---|---|
| W3 Part A dev rollout (ADR-0024, W3-24) | [w3-part-a-rollout.md](w3-part-a-rollout.md) |
| W3 Part B dev rollout (ADR-0025, W3-38) | [w3-part-b-rollout.md](w3-part-b-rollout.md) |
| W7 messaging dev rollout (ADR-0027, W7-24) | [w7-messaging-dev-rollout.md](w7-messaging-dev-rollout.md) |
| Artifact Registry retention applied to prod without unrelated changes (2026-10-19) | [prod-ar-retention-apply.md](prod-ar-retention-apply.md) |
