# Reports, takedown and suspension (P7)
Plan owner: P7 slice agent · Date: 2026-10-10 · Target release: v0.3.0 (UGC store requirement) · Stage 0 ($0)
Inputs: CLAUDE.md, `docs/plans/phase1.md` P7, ADR-0008 (block), ADR-0010 D10, ADR-0011 Q1/Q10,
`docs/adr/0016-reports-and-moderation-actions.md` (Proposed), `proto/dzeroth/moderation/v1/moderation.proto`.

## Goal
Users can report a post or an account and block from where they see content. The founder can list and resolve
reports, take a post down and suspend a user, with suspended content leaving every feed within 60 s. No admin console.

## Decisions (delegated 2026-10-10)
| # | Decision | Why |
|---|---|---|
| D1 | Report evidence retention: 90 days after resolution, then Firestore TTL (`reports.expireAt`). Open reports kept until resolved. | Long enough for an appeal or a store inquiry, short enough for privacy; TTL is free, no job code |
| D2 | Response SLA (published in `docs/runbooks/moderation.md`): acknowledge and triage within 48 hours; clearly illegal content removed as soon as seen. | Realistic for one founder; matches store guidance |
| D3 | Reporter identity is never shown to the reported user (no RPC returns it). Reporting your own content is rejected. | Protects reporters |
| D4 | Dedupe by deterministic report id (reporter, target type, target). A repeat is a free no-op returning `already_reported`. | 0 quota burn, 0 writes, no extra idempotency doc |
| D5 | Takedown and suspension are a `moderation` field on the post doc, filtered on read; reversible; no counter change. | 0 extra reads (ADR-0016 D3) |
| D6 | Hidden means hidden for the author too (NOT_FOUND). | No oracle, no ghost post |
| D7 | Reports as reporter are anonymised (not deleted) on account deletion; reports about a user are retained until resolved + 90 d. Needs a privacy-policy line. | Third-party safety evidence; Q10 allowlist entry |
| D8 | Moderator actions are opsctl commands, not RPCs. | Stage 0 rule: no admin console, smaller attack surface |
| D9 | Quota 20 reports/day (5 for accounts < 24 h), env `QUOTA_REPORTS_PER_DAY`. | Abuse cap, far above honest use (~0.02 calls/DAU) |

## Cost line
| Item | Reads | Writes | Notes |
|---|---|---|---|
| ReportContent POST, cold | 6 | 2 | interceptor user 1, post 1, author 1, graph 1, report doc 1, quotas 1 |
| ReportContent warm / planning | 2 / 3 | 2 | |
| ReportContent duplicate | <= 6 | 0 | report doc exists; no quota charge |
| GetPost / timelines with filter | +0 | 0 | filter on documents already read |
| `opsctl reports list` | 1 per report shown (<= 50) | 0 | |
| `opsctl takedown-post` | 1-2 | 1-2 | post, report |
| `opsctl suspend-user` | P + 1 | P + 2 | P = the user's posts, once, batches of 500 |
| Reports Eraser (reporter) | R + 1 | R | R = reports filed by the account (<= 20/day) |

Storage: ~1 KB/report. **$0** at Stage 0: at 300 DAU about 6 reports/day against 20k writes/day free.

## Tickets
| # | Ticket | Owner | PR | Status |
|---|---|---|---|---|
| T1 | `moderation.v1` proto, ADR-0016, this plan, generated code | architect | proto+ADR | Done (this PR) |
| T2 | `FEATURE_REPORTS` flag, `reports` quota kind + `QUOTA_REPORTS_PER_DAY`, Terraform var (default off), TTL field, index | backend | backend | Done (backend PR) |
| T3 | `internal/moderation`: ReportContent service, repo, server, wiring | backend | backend | Done (backend PR) |
| T4 | posts: `moderation` field, `Hidden()`, GetPost + timeline filters, `Moderator` (hide/restore, HideAuthor/RestoreAuthor) | backend | backend | Done (backend PR) |
| T5 | identity: `SetAccountStatus` (ACTIVE <-> SUSPENDED) | backend | backend | Done (backend PR) |
| T6 | opsctl: `reports list/show/resolve`, `takedown-post`, `restore-post`, `suspend-user`, `unsuspend-user` | backend | backend | Done (backend PR) |
| T7 | reports Eraser + export section, T11 guard rows, residue allowlist, `account-deletion.md` retained-data lists | backend | backend | Done (backend PR; privacy.html line is a founder action) |
| T8 | Go unit + emulator integration tests with budget assertions | tester | backend | Done (backend PR) |
| T9 | `docs/runbooks/moderation.md` (SLA, procedures, cost) | backend | backend | Done (backend PR) |
| T10 | Flutter: report sheet, PostCard overflow Report/Block, profile menu Report, widget tests | frontend | client | Todo |
| T11 | Docs: ui-catalog, code-map, phase1 status, cost-model line | docs | docs | Todo |
| T12 | Follow-up (after P4 merges): copy `Post` media ids into `evidence.mediaIds`; P3/P5/P6 consumers drop `Hidden()` posts | backend | later | Blocked on P4 |
| T13 | Security-auditor review of report abuse, oracle checks, opsctl | security | review | Todo |

## Acceptance criteria
1. `ReportContent` validates, enforces the quota, dedupes, copies evidence and writes `reports/{id}` within one
   transaction; a report is visible to `opsctl reports list` immediately.
2. A reporter cannot distinguish hidden, blocked, suspended and missing targets (one NOT_FOUND).
3. `takedown-post` hides the post from GetPost, GetUserTimeline and Home within CACHE_TTL (60 s).
4. `suspend-user` hides every post of the user within 60 s from followers' Home; `unsuspend-user` restores exactly
   those; a TAKEN_DOWN post stays hidden throughout.
5. Reads/writes per RPC and per opsctl command match the cost line (asserted in emulator tests).
6. Eraser + exporter + T11 guard + runbook lists updated; `make ci` green; `buf breaking` clean.
7. Flag off: RPC returns FEATURE_DISABLED with 0 reads and the client shows no Report entry.

## Open items for the founder
- Accept ADR-0016.
- Privacy policy: add "reports about an account are retained until 90 days after resolution" (D7).
- Decide the flag ramp (`FEATURE_REPORTS` allowlist then on) with `FEATURE_POSTS`.
