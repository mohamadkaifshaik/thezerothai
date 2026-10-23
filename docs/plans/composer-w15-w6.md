# Composer: W1.5 conformance + W6 reply audience, content disclosure, scheduled posts
Plan owner: planner · Stage 0 ($0) · **DRAFT, not accepted.** Part 1 is client-only. Part 2 needs an architect ADR + proto change before any code, and a founder OK (new proto fields; possibly a scheduler job).
Source: `docs/x_research/screens/composer.md` (captured 2026-10-23, local, git-ignored), `docs/plans/roadmap.md` (W1.5, W6, B-29), existing `app/lib/features/posts/presentation/composer_screen.dart`.
Branches: `feat/composer-<id>-<slug>`; one ticket per PR; merge `origin/main` into the branch. Every user-facing Part 2 feature ships behind its own `FEATURE_*` flag (see `flag-rollout`).

## Scope
In: composer modal conformance, reply audience, content disclosure, scheduled posts (create, list, cancel).
Out (separate plans): polls, GIF, drafts beyond a local list, Communities audience, user-pinned timelines, edit-scheduled-post, Verified-only replies (needs a verification feature we do not have).

## What we have vs what X shows
| Area | Ours today | X (observed 2026-10-23) |
| --- | --- | --- |
| Composer | `/compose` screen: text 280 (NFC code points), images, signed upload, SafeSearch | modal with Close, Drafts, audience pill, reply link, 7-icon toolbar, ring counter |
| Reply control | none (no `reply_policy`, grep of `proto/` finds nothing) | 5-way policy |
| Disclosure | none | two booleans (paid partnership, made with AI) |
| Scheduling | none; one existing cron `/internal/cron/daily-maintenance` | date/time dialog, tz row, Scheduled list |

## Part 1: W1.5 composer conformance (client-only, 0 RPCs, 0 reads/writes)

| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| CMP-0 | Founder-driven capture of the remaining composer states, REA only: with text, near-limit ring, with media + alt text, discard-draft prompt, composer at 400 dp (mobile), light theme, reply-policy selection result, Post-button label after a schedule is set, Scheduled list with one row. Add measurements (`tools/pix.py`) and update `screens/composer.md`. Tab must be the active tab. | founder + planner | S | **Partly done 2026-10-23:** with text, over-limit (red highlight, "-N", disabled Post) and the "Save post?" discard prompt (Save / Discard) are captured in `screens/composer.md` §1a. Also captured: Confirm in the Schedule dialog (the primary button becomes "Schedule", a "Will send on ..." line appears above the audience pill, reply control and poll become disabled; §1b) and mobile Home at 375 px (inline composer, 5-icon toolbar without poll or schedule; §1c). **Left:** counter ring under the 280 limit and its warning colours, with media + alt text, light theme, reply-policy selection result, what the Schedule button does, Scheduled list with a row, pixel measurements |
| CMP-1 | Composer layout conformance from what is observed: header (Close left, Drafts right), audience slot, text area, "who can reply" link slot, one shared `ComposerToolbar` widget (media, GIF, poll, emoji, schedule, location, disclosure) used by both the Home inline row and `/compose`; icons present only for features whose flag is on; Post pill disabled while empty or over limit | frontend-developer | M | Blocked on CMP-0 for measurements; layout ordering can start now |
| CMP-2 | Counter ring (colours, over-limit state) and discard-draft prompt, per CMP-0. Observed already: over limit = red highlight on the excess, red negative number, disabled Post; closing with text asks "Save post?" with Save / Discard. Do **not** copy the "Upgrade to Plus" banner. Ring under the limit stays blocked on CMP-0 | frontend-developer | S | Partly unblocked (over-limit and discard prompt); ring blocked on CMP-0 |
| CMP-3 | Widget tests light/dark x 360/600/1200 dp x text scale 1.0/1.3/2.0 via `test/support/theme_harness.dart`; `docs/ui-catalog.md` updated | tester | S | After CMP-1/2 |

Do not fill unobserved states with guesses (roadmap risk "Building P0 surfaces from guesses").
Cost line: 0 reads/writes.

## Part 2: W6 backend-backed features

### Gate ticket
| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| CMP-A1 | **ADR-00NN "Composer extras: reply audience, disclosure, scheduled posts"** with proto diff, Firestore model, index list, reads/writes table, flag names, and the scheduling decision below. Founder accepts before CMP-B/C/D start. | architect | M | **Done 2026-10-23:** `docs/adr/0021-composer-extras-reply-audience-disclosure-scheduling.md` **Accepted** by the founder (security review: `docs/reviews/security-review-adr-0021.md`). Tickets B, C and D are unblocked; proto and backend work follows the ADR, not this plan, wherever they differ. |

Scheduling decision the ADR must make (options, recommendation first):
1. **Sweep job** (roadmap default: "scheduling stays on one sweep job"). One Cloud Scheduler job every 5 minutes hits `/internal/cron/publish-scheduled`. Publish lateness up to 5 min. **Free-tier check required:** Cloud Scheduler allows 3 free jobs per *billing account* and dev + prod share it; `daily-maintenance` already uses one. The ADR must count existing jobs in `infra/terraform` for both envs before adding one, and either fold the sweep into an existing job or get founder approval for a paid job (a fixed cost, so it needs ADR + milestone per CLAUDE.md).
2. **Cloud Tasks** one task per scheduled post (`scheduleTime`), push to `/internal/*` with OIDC. Exact timing, no polling, no scheduler job slot. Free quota (first 1M operations / month) must be verified in `free-tier-budget`; max schedule horizon 30 days. Adds a new GCP service, so the ADR must justify it.
3. Reject: a long-running in-process timer (does not survive scale to zero).

### Reply audience
| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| CMP-B1 | Proto: enum `ReplyPolicy { UNSPECIFIED=0 (= EVERYONE), EVERYONE, FOLLOWING, MENTIONED_ONLY }` as a new field on `CreatePostRequest` and `Post` (new field numbers, `buf breaking` clean). Reserve names for `FOLLOWING_OF_FOLLOWING` and `VERIFIED` but do not implement | architect | S | Not started |
| CMP-B2 | `posts`: store `reply_policy` on the post doc and in the denormalised snapshots; enforce in the reply create path through the `graph` interface. `FOLLOWING`: 1 read (does the author follow the replier). `MENTIONED_ONLY`: 0 extra reads (mentions are already on the parent post). Returns a typed error `REPLY_NOT_ALLOWED`; idempotency key unchanged. ADR-0021 (M-1): an unusable root (missing, hidden, non-public, author not ACTIVE, blocked either way, overflow) is NOT_FOUND before the policy runs; deep replies cost up to +3 (MENTIONED_ONLY) / +4 (FOLLOWING) cold reads | backend-developer | M | Not started |
| CMP-B3 | Flutter: "Who can reply?" sheet (3 options for now), link text reflects the choice, disabled reply button with an explanation on posts where the viewer may not reply; after CreatePost compare the echoed `reply_policy` with what was sent and warn on mismatch (ADR-0021 L-1) | frontend-developer | M | Needs CMP-0 (selection behaviour) |
| CMP-B4 | Tests: emulator integration for each policy x (author, follower, non-follower, mentioned, blocked), plus mentioned + blocked by root author -> NOT_FOUND and root hidden/suspended -> NOT_FOUND (ADR-0021 M-1); Flutter widget tests | tester | M | After B2/B3 |

Budget: create +0 reads (field on the doc); reply under `FOLLOWING` +1 read (Get on one doc); `MENTIONED_ONLY` +0. Flag `FEATURE_REPLY_AUDIENCE`.

### Content disclosure
| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| CMP-C1 | Proto: `bool paid_partnership`, `bool made_with_ai` on `CreatePostRequest` and `Post` (new field numbers) | architect | S | Not started |
| CMP-C2 | `posts`: persist both flags and copy them into the denormalised author/post snapshots so timelines add no reads; reject nothing (labels only); moderation reports may reference them | backend-developer | S | Not started |
| CMP-C3 | Flutter: disclosure dialog (two switches, Done), badge/label on `PostCard`. **How X renders the label is UNKNOWN**; capture it (CMP-0) before specifying the visual. Warn when the echoed labels differ from what was sent (ADR-0021 L-1) | frontend-developer | M | Needs CMP-0 |
| CMP-C4 | Tests | tester | S | After C2/C3 |

Budget: +0 reads, +0 writes (fields on existing docs). Flag `FEATURE_CONTENT_DISCLOSURE`. Copy must avoid implying legal compliance advice.

### Scheduled posts
| ID | Ticket | Owner | Size | Status |
| --- | --- | --- | --- | --- |
| CMP-D1 | Proto: `ScheduledPost` message; RPCs `SchedulePost` (reuses `CreatePostRequest` body + `publish_at` + `idempotency_key`), `ListScheduledPosts` (opaque cursor, limit 20, max 50), `CancelScheduledPost`. IANA zone is a client display concern; the wire carries UTC `publish_at` only | architect | M | Not started |
| CMP-D2 | Firestore: `users/{uid}/scheduled/{snowflakeId}` {body snapshot, media ids, `publish_at`, `status` pending / published / cancelled / failed, `reply_policy`, disclosure flags}. Under `users/{uid}` so the right-to-delete path covers it. Collection-group or per-sweep query index on `status + publish_at` (listed in `firestore.indexes.json`) | architect | S | Not started |
| CMP-D3 | `posts`/`scheduling` module: validate at schedule time (text rules, owned media, account active), enforce a per-user cap on pending items (proposal: 25) and a horizon (proposal: 60 days), 1 write per schedule and 1 per cancel. ADR-0021: replay lookup before the time and cap checks (L-6); <= 3 pending within +-4 min; `QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY` (10) (L-3/L-4) | backend-developer | M | Not started |
| CMP-D4 | Publisher: `/internal/cron/publish-scheduled` (or Tasks handler per CMP-A1), OIDC-protected like the other `/internal/*` routes. Query `status==pending && publish_at<=now`, `Limit 50`, publish through the normal create-post path so snowflake ids, snapshots and SafeSearch on media are unchanged; re-check account state and media at publish time; mark `failed` with a reason instead of retrying forever; idempotent on retry (deterministic post id from the scheduled id); structured logs + Error Reporting path. ADR-0021 replaces the deterministic id with a PENDING guard and adds: recover per item and inside the txn (M-2), status read inside the publish txn, `LastUpdateTime` preconditions never `Set`, path-shape filter (L-7), <= 3 items per author per run, run one after another (L-3), `ScrubErr` on every error (L-8) | backend-developer | L | Not started |
| CMP-D5 | Terraform: one `publish-scheduled` job (every 5 min) in `envs/prod` only; dev jobs stay empty. No `# cost-approved:` marker is needed because it stays inside the free tier (2 of 3 jobs); update the job-count comment in both env files. Dev only: time-bound (30 d) `roles/iam.serviceAccountOpenIdTokenCreator` on the dev pubsub-push SA for the manual curl, never in prod (ADR-0021 L-5) | production-deployer | S | Not started |
| CMP-D6 | Flutter: Schedule dialog (Month/Day/Year, Hour/Minute/AM-PM, read-only zone, "Will send on ..." summary, Confirm; Confirm disabled for past times), Scheduled list inside Drafts (tabs Unsent posts / Scheduled; cancel). Observed: after Confirm the primary button reads "Schedule", a tappable "Will send on ..." line sits above the audience pill, and the reply-policy control and poll are disabled while a schedule is set (so the backend must define how `reply_policy` and polls interact with `publish_at`; for now reply policy is allowed with a schedule in our design unless the ADR decides otherwise: **open question for CMP-A1**). Mobile web uses native-style date and time spinbuttons with date/time picker buttons (day-month-year, hours:minutes) instead of desktop comboboxes, so use the platform pickers in Flutter (§1c of the research note). What the Schedule button does and the Scheduled list rows remain UNKNOWN. Dialog copy must say images are uploaded now and reachable by link before publish (ADR-0021 L-9) | frontend-developer | L | Partly unblocked; list and submit result need CMP-0 |
| CMP-D7 | Tests: unit (time validation, caps), emulator integration (schedule, list, cancel, publish due, skip cancelled, account deleted before publish, retry idempotency), clock-injected tests (no sleeping), Flutter widget tests; failure-mode runbook entry; a panicking item -> FAILED INTERNAL with the process alive (M-2) and a two-uid `ScrubErr` test (L-8) per ADR-0021 | tester | M | After D3/D4 |
| CMP-D8 | Cost report | sre-performance | S | After D4 |

Reads/writes (sweep option, per the ADR to confirm):
| Operation | Reads | Writes |
| --- | --- | --- |
| SchedulePost | 1 (cap count, `Count` aggregation = 1 read per 1000 index entries) | 1 |
| ListScheduledPosts (page of 20) | up to 20 | 0 |
| CancelScheduledPost | 1 | 1 |
| Sweep run, nothing due | 1 query (min 1 read) | 0 |
| Publish one due post | 1 (scheduled doc, already in the query) + normal create-post reads | create-post writes + 1 (mark published) |
At a 5-minute sweep that is 288 reads per day when idle (about 0.6 % of the 50k/day free read quota) per environment. `make cost` and `free-tier-budget` must still hold at Stage 0 targets.
Flag `FEATURE_SCHEDULED_POSTS` (off, then allowlist; the sweep is a no-op while the flag is off).

## Sequencing
1. CMP-0 (founder capture) and CMP-A1 (ADR) in parallel; CMP-1 layout ordering can start immediately.
2. C (disclosure) first: smallest, 0 extra reads. Then B (reply audience). Then D (scheduling) once the mechanism and the scheduler-job count are settled.
3. D5 deploys to dev first; prod only through the normal tagged zero-traffic revision and founder gate.

## Answers to the open questions (proposed 2026-10-23 at the founder's request; become binding only when the CMP-A1 ADR is Accepted)
| # | Question | Answer | Why |
| --- | --- | --- | --- |
| 1 | Scheduling mechanism | **Sweep job**, one Cloud Scheduler job `publish-scheduled` every 5 minutes, **prod only**; dev has none and is exercised with `gcloud scheduler jobs run`. Cloud Tasks is rejected for now. | Checked `infra/terraform/envs/*/main.tf`: dev has 0 jobs, prod has 1 (`daily-maintenance`), so the billing account uses 1 of 3 free jobs and this makes 2 of 3: **no fixed cost, no new GCP service**, and the roadmap already says scheduling stays on one sweep job. Cloud Tasks would add a service and its free quota and the 30-day horizon are unverified. Lateness up to 5 min is acceptable for a first release; the cadence is a config value (1 minute would be 1,440 empty-sweep reads/day, about 2.9 % of the 50k/day quota, so it is available later). Keep the third job slot free as headroom; do not add a dev job. |
| 2 | Reply audience at launch | **Three tiers**: Everyone, Accounts you follow, Only accounts you mention. Defer "follow and who they follow" and "Verified". | The two deferred tiers need a 2-hop graph read and a verification feature we do not have. The proto enum reserves their names so adding them later is not breaking. |
| 3 | Disclosure labels | **User-asserted only**, no automatic detection. | Detection needs a model or classifier (cost and error risk), and the labels are self-declarations by design. Reports may reference them. |
| 4 | Scheduled-post limits | **Accepted**: at most 25 pending per user, horizon 60 days. Both live in config (not hard-coded) per the rule that cost caps are code. | Bounds the per-user write and sweep-query volume. |
| 5 | Wave placement | **Stay in W6** behind `FEATURE_REPLY_AUDIENCE`, `FEATURE_CONTENT_DISCLOSURE`, `FEATURE_SCHEDULED_POSTS`, all off by default. Order inside W6: disclosure, then reply audience, then scheduling. | Matches the roadmap (W2 and W4 first) and keeps the cheapest, lowest-risk feature first. |

Two follow-ons for the ADR: (a) the observed X behaviour that **reply control and polls are disabled while a schedule is set**: decide whether we mirror it (proposal: yes, reject `reply_policy != EVERYONE` together with `publish_at` only if it cannot be enforced at publish time; otherwise allow it); (b) the publisher must be idempotent so a retried sweep never double-publishes (deterministic post id from the scheduled id).

## Definition of done (per ticket)
Acceptance criteria met and tested; Go coverage >= 70 % on `internal/`; Flutter widget tests for every new screen (light/dark, 360/600/1200 dp); `buf breaking` clean; worst-case reads/writes documented per RPC; `make ci` green; runbook updated for scheduler failure modes; this table's Status updated in the merging PR.
