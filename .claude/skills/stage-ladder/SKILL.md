---
name: stage-ladder
description: For every hot concern of an X-style platform (timeline, real-time, counters, IDs, cache, rate limits, DDoS), the Stage 0 implementation, the seam to protect now, the Stage 2/3 target and the measured trigger that moves between them. Use when designing, building, reviewing or load-testing any feed, event, counter, cache or abuse control, and before proposing any new infrastructure.
---

# Stage ladder: design for Stage 0, keep the door open to Stage 3

`CLAUDE.md` forbids fixed-cost infrastructure (Memorystore, Cloud SQL, Spanner, GKE, load balancers, Cloud Armor) at
Stage 0 and names the growth stages. This skill is the one place that says, per hot concern, what we run now, what the
hyper-scale version looks like, and what measured number moves us from one to the other.

**Rule:** a Stage 0 choice is acceptable only if the Stage 2/3 replacement changes no caller. Name the seam in the ADR
and the ticket (`Seam:` line); `code-reviewer` checks it; `sre-performance` alerts on the trigger; moving a rung needs an
ADR with measured numbers (`free-tier-budget` §6) accepted by the founder. The credit window (ADR-0022) lifts no rung.

| Concern | Stage 0 (now) | Seam to protect now | Stage 2/3 target (ADR) | Trigger |
|---|---|---|---|---|
| Home timeline | Pull-on-read: followees chunked by 30 (`in`), `since` cursor, instance LRU + client cache (`timeline` skill, ADR-0004). Home is chronological Following only | `timeline` module interface; opaque, versioned cursor; merge logic behind the interface, never in the handler | Hybrid fan-out: write fan-out for authors under N followers, pull-merge for celebrities, materialised in Memorystore | Firestore reads > 1.5M/day or bill > $30/month sustained 7 days (`free-tier-budget` §6). Latency alone (p95 warm > 800 ms) moves min-instances first, not the timeline design |
| Real-time (notifications, DMs, live counts) | FCM nudge + incremental pull. No WebSocket/SSE | Every engagement and notification event goes through the module's `Events` seam and `notifications.Emitter` on Pub/Sub, never a direct call | Firestore client listeners on owner-only docs (needs a rules ADR), then SSE on an instance-billed service. DMs v1 = pull + push, no E2E (roadmap W7) | A latency requirement under ~5 s with measured demand |
| Counters (likes, reposts, followers) | `FieldValue.Increment` on the parent doc, ≤ 1 sustained write/s (rule 3) | One counter helper so the backend can be swapped; `ABORTED` rate surfaced as a metric | Pub/Sub-batched increments or sharded counters | Sustained `ABORTED` on a doc; any post above 1 like/s. This is traffic shape, not DAU: a viral post breaks rule 3 at tiny DAU |
| IDs and collections | 64-bit Snowflake, time-ordered, string doc IDs (rule 1) | IDs opaque to clients | Hash-prefixed IDs or a collection split | Any collection nearing ~500 writes/s |
| Cache | In-process LRU per instance (max 3 instances, so 3 cold caches) + client drift/IndexedDB | A cache interface; every cached read states its staleness bound; keys scoped to the viewer where block/mute matter | Memorystore | Hit rate below the budget's assumption, or max-instances above 3 |
| Rate limiting | In-memory per instance (`pkg/platform/ratelimit`) + per-user Firestore quotas + max-instances | Limits as config, reviewed like logic (rule 11) | Shared limiter (Memorystore) or edge (Cloud Armor) | Abuse that spreads across instances |
| DDoS and cost attacks | max-instances is a **cost circuit breaker, not a defence**; request-flood alert; degraded mode; Vision cap with `reject` | Degraded-mode switch reachable without a deploy | Cloud Armor and CDN at Stage 3 | Sustained flood past the cap |

## Locked features (shell only)
These features exist at Stage 0 only as client-only "coming soon" pages (W8, `docs/plans/ui-w8-shells.md`, ADR-0026):
0 RPCs, 0 Firestore operations, behind `shells` + `ui_shell`. Each real feature needs its own ADR, numbered when written
(the highest existing plus one). The shell keeps its route and its `shellEntries` entry; the real feature moves the entry's
gate to its own flag, swaps the route's builder and deletes the shell, so no caller changes.

| Concern | Stage 0 (shell) | Seam to protect now | Stage 2/3 target (future ADR) | Trigger |
|---|---|---|---|---|
| Paid tier (Premium) | Tap-only coming-soon pop-up with Plus ₹235/month and Premium ₹850/month incl. GST (ADR-0026 D3), no purchase path | `AppRouter.premiumPath`, `ShellKind.premium`; prices only in `kPremiumPlans`; no client code reads an entitlement | **Payments ADR:** store billing in the apps (Google Play Billing; Apple In-App Purchase after the Apple launch), a web payment provider (not GCP: a stack exception the ADR justifies), server-side receipt verification and store notifications through Pub/Sub, an entitlements doc owned by `identity`, GST and invoicing, refunds and cancellation, consumer-protection disclosures, Indian recurring-payment mandate rules, what may be paywalled (never safety or privacy features); `kPremiumPlans` becomes server plan data | The founder's decision to charge **plus** a measured need: the Stage 0 bill (`cost-model.md` §5) above INR 3,000/month for 2 consecutive months (about 3,000 DAU), or no funding after the credit expires (`pending.md` 1.14) with more than 1,000 DAU |
| Creator insights (beyond profile counts) | Followers, following, posts and join month from the `GetMe` profile in memory (0 reads); every other row "Coming soon" | `ShellKind.creatorStudio` route; `CreatorInsightsGroup` is one widget, so real rows replace it without touching the page frame | **Insights plan** (an ADR only if it adds a collection): an `InsightsService` summarising the counters already on the caller's recent posts (bounded reads, instance-cached). **Impressions** need a write per view: the Counters row above and its own ADR | At least 50 accounts with more than 1,000 followers, or the founder's request; impressions only once the Counters row's ADR exists |
| Creator monetisation (earnings, creator subscriptions) | `CreatorProgramsGroup` rows read "Coming soon"; no control | Same route; `CreatorProgramsGroup` is a separate widget | **Creator payouts ADR** (after Payments): revenue share, a payouts provider, KYC, tax withholding, eligibility, fraud and chargebacks | Payments live in prod **and** the founder's decision |
| Advertising | Coming-soon page; `mailto:` off until the mailbox exists (ADR-0026 D8) | `AppRouter.advertisePath`, `ShellKind.advertise`; the `timeline` interface stays the only place a feed is merged (an ad slot goes behind it, never in a handler or widget) | **Ads ADR:** direct-sold promoted posts or an ad-network SDK, consent and privacy (DPDP Act, iOS App Tracking Transparency, Play Data safety), ad labelling, advertiser verification and review, payments (needs Payments), brand safety, the Privacy Policy change | DAU above 20,000 sustained for 30 days (the Stage 2 boundary; below it ad revenue does not cover review and legal cost), or a signed advertiser budget the founder accepts |
| Calls (1:1 voice and video) | Coming-soon page; no permission, no calling or WebRTC package | `AppRouter.callsPath`, `ShellKind.calls`; a call action later goes in W7's conversation header, never on a new public surface | **Calls ADR**, which **depends on the Real-time row above** having moved (calls need a signalling channel; Stage 0 has none): WebRTC, signalling, STUN, a TURN relay (egress billed per GB; a TURN VM or SFU is a **fixed cost** and the matching services are on `CLAUDE.md`'s not-used list), call push (high-priority FCM; PushKit and CallKit after the Apple launch), block and spam rules, call metadata in export and erasure, an emergency-calls disclaimer | W7 messaging live with messaging DAU above 30 % of DAU for 30 days, **and** the Real-time row's trigger met, **and** the founder's decision to accept the fixed or per-GB relay cost |

## Facts behind the rows
- Cloud Run bills request time: a held WebSocket/SSE connection keeps an instance warm, which is a fixed cost in disguise.
  Cloud Run routing is not sticky, so a broadcast needs a shared bus (Memorystore or Pub/Sub), another fixed cost.
- Firestore `in` takes up to 30 values; followee counts above 30 cost one query per chunk.
- Firestore hot-spots on monotonically increasing document IDs at high write rates (the 500/50/5 ramp rule: start at
  500 writes/s per collection, grow 50% every 5 minutes).
- Firestore and Storage rules are deny-all to clients today; any client listener is a rules change and therefore an ADR.
- A per-instance rate limit is multiplied by the number of instances; the effective limit is per-instance × max-instances.
- Scraping vectors at Stage 0: handle prefix search, hashtag `array-contains`, author `in` queries, public-read GCS
  objects, guessable time-ordered IDs. Every public read needs a `Limit`, a per-user quota and a rate limit.

## How each agent uses this
- `architect` and `planner`: every Stage 0 choice is written with its Stage 2/3 target and trigger; the ticket carries a `Seam:` line.
- `backend-developer` and `frontend-developer`: build behind the seam; never pre-build the later rung.
- `code-reviewer`: a change that bypasses a seam is a Blocker.
- `tester` and `sre-performance`: load shapes include the trigger scenarios (600 followees, 50 likes/s on one post, fan-out burst).
- `security-auditor`: abuse controls are checked against the rate-limit multiplication and the scraping vectors.
- `production-reviewer`: asks "if one post goes viral tonight, what breaks and what does it cost?"
- Everyone: a locked feature moves only by its own accepted ADR; its shell is the placeholder.
