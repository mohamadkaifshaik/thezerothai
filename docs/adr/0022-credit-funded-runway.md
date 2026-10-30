# 0022. Credit-funded runway (time-boxed exception to the $0 rule)
Status: Accepted (founder, 2026-10-23; includes the five founder decisions below and the time-boxed bend of the prime directive; every prod apply and traffic shift still goes through ADR-0019 and the founder's plan-then-OK rule)
Date: 2026-10-23
Deciders: architect (proposal); founder (decisions 1-5 stated 2026-10-23; accepted 2026-10-23; this ADR adds a time-boxed fixed cost and bends the prime directive, so it needs the founder's explicit acceptance)

Related: ADR-0001 (free-tier-first), ADR-0005 (Vision cap), ADR-0006 (abuse controls), ADR-0007 (budgets, regions, alerts),
ADR-0010 (read budget), ADR-0019 (prod gate), ADR-0021 (scheduler sweep). Cost model with the arithmetic:
`docs/plans/credit-runway-cost-model.md`. Command runbook (written by production-deployer, not part of this ADR):
`docs/runbooks/credit-sunset-pause-resume.md`.

## Amendment 1 (2026-10-26): spend cap 25,000

Founder decision, 2026-10-26, after reading the real credit. Firebase console: **INR 28,659.76 remaining** on a Google Cloud Free Trial that is not upgraded (valid until 2026-12-26), a payment method is already attached, no funding is coming. This answers checklist items 1 and 4 below; item 2 (which services the credit covers) is still open.

- `credit_spend_cap_inr` = **min(25,000, remaining credit − 2,000)**. With 28,659.76 remaining that is **25,000**. The ceiling was 23,000, written when the pool was said to be 20,000 or 25,000. The INR 2,000 reserve is unchanged and still holds (28,659.76 − 25,000 = 3,659.76).
- The cap is a **ceiling for the alerts, not a target and not a spending limit**: budgets only alert and the stop is the manual runbook. Real burn is about INR 31-45 a day, so this changes where the alerts fire, not what is spent. Its cost: the straight line is steeper (**INR 403/day** to the 12-24 pause, 391/day to 12-26), so a slow overspend is flagged later.
- Alert thresholds scale, their dates do not: 10% 2,500; 25% 6,250; 50% 12,500; 75% 18,750; 90% 22,500; 100% 25,000.
- Unchanged: the dates, the credit-mode profile, every abuse limit, the "not used" list, no fixed fee, nothing that bills after 2026-12-26, and the pause on 2026-12-24.
- Changed with it, in the same PR: the hard limit in `infra/terraform/envs/prod/variables.tf` (23000 to 25000), `terraform.tfvars.example`, `CLAUDE.md` (credit mode and the Growth-stages row, because the constitution quotes the cap), the sunset runbook, and every 23,000 / 371 in D3 below. The cumulative tables in `docs/plans/credit-runway-cost-model.md` and `docs/reviews/cost-model.md` keep the 23,000 arithmetic and say so.

## Context
**The exception.** The billing account has a GCP credit that **expires 2026-12-26**. We want to spend part of it to buy
what Stage 0 cannot afford, in this order: (1) responsiveness (no cold starts), (2) SafeSearch on **every** image,
(3) capacity. After expiry, charges may go to a payment method. The founder will then **pause** until funded (new money or
subscriptions). If funded, services restart; if not, we revert to Stage 0.

**Founder facts (2026-10-23) and what is not yet known.**
| Fact | Value | Status |
|---|---|---|
| Credit pool | the founder has said both INR 20,000 and INR 25,000 | **AMBIGUOUS**. Plan uses `credit_spend_cap_inr` = **min(25,000, remaining credit on the Credits page − 2,000) (23,000 before Amendment 1)**. The *remaining* figure matters, because usage since about 2026-09-27 has already drawn on the credit |
| Reserve | INR 2,000, never planned | firm |
| Expiry | 2026-12-26 (64 days from 2026-10-23) | founder; verify on the Credits page (date and time zone) |
| Type of credit | unknown. 2026-12-26 is exactly 90 days after the 2026-09-27 bootstrap (ADR-0007), which matches the **GCP Free Trial** ($300, 90 days). Free Trial credits are type `PROMOTION` | **UNVERIFIED**, checklist item 1 |
| Eligible services, payment method attached, account upgraded | not confirmed | **UNVERIFIED**, checklist below |
| Billing currency | INR | firm (`budget_currency_code = "INR"` in both envs) |
| Current prod DAU | about 0 (most prod flags off) | from the repo; not measured |

**Credit verification checklist (founder, Billing console, before any credit-mode apply).**
1. *Billing > Overview:* is this a Free Trial account (banner "Activate full account") or a paid account? If it is a trial
   and is **not** upgraded: at expiry billing is disabled, resources stop, and after a 30-day grace they are
   **permanently deleted** (Free Trial docs). No card is charged, but nothing can run and data is at risk (see Sunset).
2. *Billing > Credits:* name, type, original value, **remaining value**, start and end date (with time zone), and scope
   ("all services" or a list).
3. Eligible services: Cloud Run, Firestore, Cloud Vision, Cloud Storage, Cloud Scheduler, Cloud Logging, Artifact
   Registry, Pub/Sub, and the Firebase charges (Hosting). The Free Trial docs list Firebase as a separate offer, so
   coverage of Firebase lines is **UNVERIFIED**.
4. *Billing > Payment method:* is a card or UPI mandate attached? Who is charged after expiry?
5. Behaviour at expiry: unused credit is lost; usage after expiry is charged to the payment method (paid account) or
   stops (unupgraded trial).
6. Taxes: are GST lines on the invoice, and does the credit cover them? (**UNVERIFIED**)
7. *Billing > Budgets:* is the "spend cap" option offered for Cloud Run on `dzeroth-prod` (account eligibility)?

**If the credit excludes a service**, that service bills the payment method from day 1 (or is unpayable on a trial).
Control: 48 h after each credit-mode step, *Billing > Reports* grouped by service with credits applied must show **net
INR 0** on every line. Any line with net > 0 → that knob goes back to its Stage 0 value the same day.

**Hard limits of the exception.**
| Limit | Value | Who may change it |
|---|---|---|
| Gross spend cap | `credit_spend_cap_inr` = 25,000 (or lower per the formula above; 23,000 before Amendment 1, 2026-10-26) | founder only, by amending this ADR |
| Reserve | INR 2,000 (never planned) | founder only |
| Heavy items off | **2026-12-22** | founder only (earlier is always allowed) |
| Services paused | **2026-12-24** (2 days before expiry: billing data lags up to 24 h or more) | founder only |
| Abuse limits | unchanged (classification below) | not changeable under this ADR |

**Not allowed even with credit** (anything that keeps billing after 2026-12-26, or that we would have to unwind):
| Item | Why | Verified price that would outlive the credit |
|---|---|---|
| External HTTPS LB, Cloud CDN (LB-backed), Cloud Armor | billed per forwarding rule-hour whether used or not | forwarding rules asia-south1 **$21.90/month** for the first 5 (VPC pricing page) ≈ INR 2,080/month; Armor policies extra (not fetched) |
| Cloud SQL, AlloyDB, Memorystore, Spanner, GKE, Filestore | per-hour instances; data gravity: a migration back to Firestore costs reads and writes | not fetched (all hourly) |
| Compute VMs, static IPs, Cloud NAT, VPC connector | per-hour | unused static IP asia-south1 **$8.76/month** (VPC pricing page) |
| Committed use discounts, subscriptions, prepaid plans (incl. a reCAPTCHA volume commitment) | the commitment outlives the credit | n/a |
| Features that create data or traffic that keeps billing: video, larger image limits, log retention > 30 days, realtime listeners | storage and egress continue after the credit | GCS $0.020/GB-month, egress $0.12/GiB |
| Phone/SMS OTP | per-SMS billing and SMS-pumping abuse | billed per SMS (Firebase pricing) |
These also fail CLAUDE.md "Explicitly not used at Stage 0"; that list stays in force.

**Prices used** (all retrieved 2026-10-23; USD; asia-south1 unless stated; full list and URLs in the cost model §1):
Cloud Run Tier 1 request-based (asia-south1 is Tier 1): active $0.000024/vCPU-s, **idle min-instance $0.0000025/vCPU-s**,
memory $0.0000025/GiB-s (active and idle), $0.40/M requests; free 180k vCPU-s, 360k GiB-s, 2M requests per billing account,
"applied as a spending based discount". Firestore Mumbai: **$0.035 / $0.104 / $0.012 per 100k** reads / writes / deletes
(TTL deletes $0.012, no free quota), storage $0.104/GiB-month, backup $0.035/GiB-month. Vision SafeSearch **$1.50 per
1,000 units** past 1,000 free/month. Scheduler $0.10/job/31 days past 3 per billing account (paused jobs count). Logging
$0.50/GiB past 50 GiB/project. **Alerting is not charged before 2027-09-01**; policies on billing, quota or uptime metrics
are never charged. GCS us-central1 $0.020/GB-month, Class A $0.005/1k, Class B $0.0004/1k, egress to Asia $0.12/GiB past
100 GB free. Premium-tier egress from asia-south1 to Asia $0.12/GiB. Artifact Registry $0.10/GiB-month past 0.5 GiB. Secret
Manager $0.06/version-month past 6, $0.03/10k accesses past 10k. Pub/Sub $40/TiB past 10 GiB. reCAPTCHA: free to 10,000
assessments/month, **$8 flat** for 10,001-100,000. Firebase Hosting $0.15/GB past 360 MB/day.
**FX assumption:** INR 95.0 per USD (mid-market 94.955 on 2026-10-23, Pluang). Sensitivity ±5% = INR 90.25 to 99.75.
INR accounts are billed at Google's INR SKU prices, which can differ from USD × market rate: *Billing > Pricing* in the
console is authoritative. **GST:** sums are shown without and with 18% (applicability **UNVERIFIED**).

**Correction found while costing (feeds ADR-0005 and cost-model):** `VISION_SCREEN_THUMB=true` (the default, set in prod
Terraform) bills **2 units per image**. ADR-0005 and `cost-model.md` assume 1. With 2 units, the 10,000 cap is hit at
about **820 DAU**, not 1,600. Thumb screening stays: the client makes the thumbnail, so it can differ from the full image.

## Requirements (credit window only)
- *Functional:* none new. No proto, Firestore model or index change.
- *Non-functional:* p95 first request after idle < 400 ms (no cold start on the first instance); every image screened up to
  the planned DAU; gross spend ≤ `credit_spend_cap_inr`; every credit-mode item off by 2026-12-22 and services paused by
  2026-12-24; abuse bounds unchanged; post-expiry monthly cost known in INR for each state.

## Options
| | A. Status quo (Stage 0, credit only absorbs overage) | **B. Credit-mode profile (recommended)** | C. Spend toward the cap | D. Keep-warm ping instead of min instances |
|---|---|---|---|---|
| What | min 0, Vision cap 10k | prod service-level min instances 1; Vision cap 20k (40k past 1,300 DAU), reject at cap; gross-spend budgets; request-flood alert | min 2-3, 2 vCPU / 2 GiB, Memorystore, LB + CDN, CUDs | Scheduler hits `/internal/cron/*` every minute; Cloud Run "might keep instances idle ... up to 15 minutes" |
| Cold starts | yes (≤ 1.5 s target) | none on the first instance | none | usually none, **not guaranteed** |
| Every image screened | until about 820 DAU | until about 1,640 DAU (3,280 at 40k) | yes | n/a |
| INR/month at 300 / 1k / 3k DAU | 434 / 1,626 / 3,396 | **1,371 / 2,873 / 8,127** | > 10,000 idle | ≈ Stage 0 |
| Outlives the credit | no | no (all reverted 12-22) | **yes** (LB, Memorystore, CUDs) | no |
| Verdict | fails priorities 1 and 2 | **chosen** | rejected: fixed costs outlive the credit; no measured need | rejected for the window (priority 1 asks for a guarantee); **kept as the FREE-TIER fallback** (ADR-0021's sweep already exists) |

## Decision
Adopt option B as **Stage 0C "credit mode"** for prod only, from the founder's acceptance until 2026-12-22, inside a gross
cap of `credit_spend_cap_inr`. Treat the cap as a **ceiling, not a target**: at today's DAU the real burn is about INR
31-45/day, and most of the credit will expire unused unless DAU grows. That is the intended outcome; nothing is bought just
to use the credit. Abuse limits do not change. Budgets are switched to see gross spend, and the kill switch is manual,
backed by free detectors.

### D1. Credit-mode profile (prod; dev stays Stage 0)
INR at 95/USD, before GST; monthly cost of the knob alone (the whole bill is in Cost impact).
| Knob | Current | Credit mode | Why / priority | 300 DAU | 1k DAU | 3k DAU | Change type |
|---|---|---|---|---|---|---|---|
| Cloud Run min instances | 0 | **1, service-level** (`scaling.min_instance_count` on the service). Revision-level stays 0: revision-level minimums start **every tagged revision**, and prod tags revisions (`rc`, `candidate`) | P1 | 936 (idle 1 vCPU + 0.5 GiB × 730 h: $6.57 + $3.29 = $9.86); 441 if the free-tier spend discount also offsets idle SKUs (**UNVERIFIED**, plan on 936) | 936 | 936 | Terraform module: new variable, remove `scaling` from `ignore_changes`, marker `# cost-approved: ADR-0022 until:2026-12-22` |
| CPU / memory | 1 / 512Mi | unchanged | +0.5 GiB idle = INR 312/month with no measured cache-miss problem | 0 | 0 | 0 | none |
| Max instances | prod 3, dev 1 | unchanged | P3: not binding. 3k DAU ≈ 3.4M requests/month ≈ 1.3 req/s average, about 13 req/s at a 10× peak × 0.1 s ≈ 1.3 concurrent against 3 × 80 = 240 slots. Raising it multiplies the per-instance abuse limits | 0 | 0 | 0 | none |
| Concurrency | 80 | unchanged | | 0 | 0 | 0 | none |
| `VISION_MONTHLY_CAP` | 10,000 | **20,000**; **40,000** once DAU > 1,300 for 3 days or Vision > 600 units/day | P2. Demand is 12.2 units per DAU-month (0.2 images/DAU/day × 2 units) | 378 (3,650 units, under the cap) | 1,591 (12,167) | 5,059 (36,500, cap 40k) | tfvars (prod `main.tf` hard-codes "10000": make it a variable) |
| `VISION_EXHAUSTED_POLICY` | `unscreened_established` | **`reject`** (no unscreened image is ever published; uploads fail at the cap) | P2 | 0 | 0 | 0 | tfvars (same) |
| `VISION_SCREEN_THUMB` | true | true | P2 | | | | none |
| Firestore beyond the free daily quota | pay per use | pay per use, no cap change | P3 | 22 | 226 | 896 | none |
| Scheduler `publish-scheduled` (ADR-0021, **not yet in `envs/prod/main.tf`**) | `*/5 * * * *` | `* * * * *` once `FEATURE_SCHEDULED_POSTS` leaves off. Lateness ≤ 1 min. +1,152 reads/day, +35k requests/month, same job (no 4th job) | P1 | 1 | 1 | 1 | tfvars `publish_scheduled_schedule` |
| Scheduler jobs beyond 3 | 1 used (2 with ADR-0021) | a 4th job only with an `until:` marker | | 10 each | | | Terraform |
| Weekly Firestore backups (prod) | on, 14 d | unchanged | data safety | 4 | 4 | 4 | none |
| Logging | 50 GiB/project free; 30 d retention | unchanged. 3k DAU ≈ 3.3 GB/month | | 0 | 0 | 0 | none |
| Artifact Registry | keep 3 (prod) / 6 (dev); 0.5 GiB free per billing account | unchanged | | 0 | 0 | 0 | none |
| GCS (ops, storage, egress) | pay per use | unchanged | | 10 | 42 | 576 | none |
| Cloud Run active CPU, requests, egress to India | pay per use | unchanged | | 22 | 73 | 641 | none |
| App Check web / reCAPTCHA | not used (ADR-0006: $8 flat fee) | **not enabled by this ADR**: it needs an enforce rollout across clients (ADR-0006 amendment), and the $8/month (INR 760) would outlive the credit while web traffic stays above 10k assessments | security | (760 if enabled) | (760) | (760) | separate ADR |
| Pub/Sub | 10 GiB free | unchanged (≈ 240 MB at 3k DAU) | | 0 | 0 | 0 | none |
| Secret Manager | 1 version per project | unchanged. Min instances reduce accesses | | 0 | 0 | 0 | none |
| Alert policies (prod 4) | ADR-0007 R4 "fixed" line | unchanged; **$0** until 2027-09-01 per the pricing page | | 0 | 0 | 0 | none |
| Budgets and alerts | INR 500/project/month, **net of all credits** | see D3 | control | 0 | 0 | 0 | Terraform module |

### D2. Every limit, classified
COST = may be raised in credit mode. ABUSE = must **not** be raised because credit exists (reason given). BOTH = keep,
because the abuse bound is what makes it safe. Names are env vars in `backend/pkg/platform/config/config.go` unless marked
TF (Terraform) or ADR-0021 (specified, not yet in `config.go`).
| Limit (current) | Class | Reason | Credit mode | Change |
|---|---|---|---|---|
| TF `min_instance_count` 0 | COST | cold starts are a cost trade-off | prod 1, service-level | TF module + tfvars |
| `VISION_MONTHLY_CAP` 10,000 | COST | runaway-bill guard (ADR-0005) | 20,000 / 40,000 | tfvars |
| `VISION_EXHAUSTED_POLICY` unscreened_established | ABUSE (safety) | decides whether unscreened bytes go public | tightened to `reject` | tfvars |
| `VISION_SCREEN_THUMB` true | ABUSE (safety) | client-made thumbs can differ from the full image | unchanged | — |
| ADR-0021 `publish_scheduled_schedule` */5 | COST | reads and requests per run | `* * * * *` | tfvars |
| TF Scheduler job count ≤ 3 | COST | $0.10/job past 3 | 4th only with `until:` | TF |
| TF budgets INR 500 net | COST (signal) | blind to credit burn | D3 | TF module |
| TF alert "Firestore reads > 40k/day" | COST (signal) | fires daily above ≈ 170 DAU | 250k/day (≈ 1,070 DAU) until 2026-12-22 | TF monitoring variable |
| TF Firestore PITR off | COST | PITR storage $0.1731/GiB-month | unchanged (not a priority; INR ≈ 16/GiB-month if wanted) | — |
| TF weekly backups, 14 d | COST | backup storage | unchanged | — |
| TF AR keep counts, 30 d tagged retention | COST | 0.5 GiB free | unchanged | — |
| `CACHE_POSTS_ENTRIES` 20,000, `CACHE_AUTHOR_RECENT_ENTRIES` 1,000; TF memory 512Mi | COST (memory) | sized to 512 MiB | unchanged (min instances already keep the cache warm) | — |
| `FEATURE_REMOVED_IDS` off | COST + safety | log reads (≤ 100 per instance per 60 s, window ≤ 107) | eligible (≈ 1.4k-4.3k reads/day, < INR 5/month); its ADR-0016 retest gate decides | — |
| Web App Check provider (ADR-0006 amendment) | COST deferral + security | $8 flat past 10k assessments | not in this ADR | separate ADR |
| TF `max_instance_count` prod 3 / dev 1 | BOTH | cost and blast radius; in-memory limits scale × instances | unchanged | — |
| `READ_BUDGET_PER_UID_PER_DAY` 2,000 | BOTH | ≈ 9× a typical day; bounds one account to ≤ 6,924 reads/day | unchanged | — |
| `READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY` 500 | ABUSE | meter that exposes farms behind one address | unchanged | — |
| `LIST_CALLS_PER_DAY` 100 | BOTH | list scraping (≈ 30.6k reads/day bound) | unchanged | — |
| `GRAPH_MUTATIONS_PER_DAY` 500 | BOTH | replay read loops; follow spam | unchanged | — |
| `CHECK_HANDLE_CALLS_PER_DAY` 100 | ABUSE | handle enumeration | unchanged | — |
| `ACCOUNT_OPS_CALLS_PER_DAY` 20 | BOTH | export job ≈ 700 reads | unchanged | — |
| `NOTIFICATION_DEVICES_CALLS_PER_DAY` 10 | BOTH | token churn, 9 reads + 5 writes per call | unchanged | — |
| `NOTIFICATION_SEEN_CALLS_PER_DAY` 200 | BOTH | write amplification per uid | unchanged | — |
| `NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY` 200 / new 50 | BOTH | notification spam to many users | unchanged | — |
| `NOTIFICATION_PUSHES_PER_RECIPIENT_PER_HOUR` 10 | ABUSE | push harassment (FCM is free) | unchanged | — |
| `RATE_LIMIT_PER_USER_PER_MIN` 60, `_PER_IP_PER_MIN` 120, `_PRE_AUTH_IP_PER_MIN` 120 | ABUSE | flood and scraping backstops | unchanged | — |
| `RATE_LIMIT_TIMELINE_PER_MIN` 6, `_USER_TIMELINE_PER_MIN` 30 | BOTH | each refresh ≥ 4 reads; scraping | unchanged | — |
| `RATE_LIMIT_CHECK_HANDLE_PER_MIN` 20, `_LIKES_PER_MIN` 30, `_POST_CREATE_PER_MIN` 10, `_POST_DELETE_PER_MIN` 20, `_REPORT_PER_MIN` 5, `_GRAPH_FOLLOW/BLOCK/LIST_PER_MIN` 30/20/20 | ABUSE | spam, enumeration, report-bombing | unchanged | — |
| `QUOTA_POSTS_PER_DAY` 100 / new 20 | ABUSE | spam | unchanged | — |
| `QUOTA_FOLLOWS_PER_DAY` 200 / new 50 | ABUSE | follow spam | unchanged | — |
| `QUOTA_MEDIA_PER_DAY` 20 / new 5 | BOTH | upload waves (Vision, GCS) and harmful-image floods | unchanged (the Vision cap carries the cost) | — |
| `QUOTA_LIKES_PER_DAY` 500 / new 100 | BOTH | like spam; likes are 63% of writes | unchanged | — |
| `QUOTA_BLOCKS_PER_DAY` 200 / new 50 | ABUSE | `blockedBy` writes on targets | unchanged | — |
| `QUOTA_REPORTS_PER_DAY` 20 / new 5 | ABUSE | report-bombing | unchanged | — |
| `QUOTA_EXPORTS_PER_DAY` 1 | BOTH | ≈ 700 reads + GCS per export | unchanged | — |
| `QUOTA_SNAPSHOT_EDITS_PER_DAY` 5 | BOTH | each edit rewrites ≤ 100 posts; churns other users' feeds | unchanged (no demand) | — |
| `QUOTA_NEW_ACCOUNT_WINDOW` 24h, `HANDLE_CHANGE_COOLDOWN` 7d | ABUSE | sybils, impersonation | unchanged | — |
| ADR-0021 `QUOTA_SCHEDULES_PER_DAY` 50 / new 10, `SCHEDULED_MAX_PENDING` 25, `SCHEDULED_PER_AUTHOR_PER_RUN` 3 | ABUSE | schedule churn, queue starvation | unchanged | — |
| ADR-0021 `SCHEDULED_SWEEP_LIMIT` 50, `_MAX_PAGES` 2, `_CONCURRENCY` 4, `SCHEDULED_MAX_LATENESS` 6h | BOTH | bounded system reads per run | unchanged | — |
| page size ≤ 50, following ≤ 5,000, body ≤ 256 KiB, request timeout 30 s | BOTH | read and CPU bounds per call | unchanged | — |
| `DEGRADED_MODE` off | switch | used by the runbooks, not a cap | unchanged | — |
| `APP_CHECK_MODE` monitor | ABUSE (security) | ADR-0006 | unchanged | — |
| `CACHE_TTL` ≤ 60 s, `TIMELINE_*`, `ACCOUNT_DELETE_REAUTH_MAX_AGE`, `EXPORT_URL_TTL`, `EXPORT_RETENTION` | correctness / privacy | deletion gate, cursor safety | must not change | — |
| `FEATURE_*` flags | rollout | `flag-rollout` and ADR-0019 decide; credit does not ramp a flag | unchanged | — |
| Phone/SMS OTP | BOTH | per-SMS cost; SMS pumping | stays off | — |
| Search engine (Typesense VM, Vertex AI Search, Cloud SQL FTS); Redis/Memorystore | COST (fixed) | hourly fees outlive the credit | not allowed | — |
| Video (W8) | COST + safety | storage and egress outlive the credit; SafeSearch cannot screen video (priority 2) | not allowed | — |
| GIF provider (Klipy) | legal | terms not verified | unchanged | — |
| Payments, ads shells (W8) | product / legal | | unchanged | — |
| Trends from own counters (W4); DMs realtime/E2E (W7) | COST (design) | must run at Stage 0 cost after the window | unchanged | — |

### D3. Budget plan and alerts
**Spend line.** Gross spend (what we would pay without the promotional credit) is planned against a straight line to the
**pause date**: `plan(day) = credit_spend_cap_inr × day / 62`, day 0 = 2026-10-23, day 62 = 2026-12-24. With 25,000 that
is **INR 403/day** (391/day if drawn to 12-26; 290/day if the cap is 18,000).

**Ramp (what turns on when; each prod step is a Terraform plan shown to the founder first).**
| Step | When | Change | Expected gross INR/day |
|---|---|---|---|
| R0 | on acceptance, dev first | checklist done; `credit_spend_cap_inr` set; gross budgets; request-flood alert; CI `until:` check | 0 |
| R1 | after R0 | prod service-level min instances 1 | +31 |
| R2 | after R1 (bites only once `FEATURE_MEDIA` serves images in prod) | `VISION_MONTHLY_CAP` 20,000, policy `reject` | 0 to +13 at 300 DAU; ceiling +89 (20k units) |
| R3 | when `FEATURE_SCHEDULED_POSTS` leaves off | sweep `* * * * *` | ≈ 0 |
| R4 | DAU > 1,300 for 3 days, or Vision > 600 units/day | cap 40,000 | ceiling +183 |
| S1 | 2026-12-15 | founder funding decision; pause/resume dry run on dev; data export (Sunset) | 0 |
| S2 | **2026-12-22** | heavy items off: min instances 0; Vision back to the post-expiry value; sweep */5; alert threshold back to 40k | back to Stage 0 |
| S3 | **2026-12-24** | PAUSE (unless RESUMED was approved) | ≈ 0 |
Expected whole-bill gross burn: about INR 31-45/day now, 45/day at 300 DAU, 94/day at 1k, 267/day at 3k, all under the 403
line (cost model §4).

**Alert thresholds** on the billing-account-wide credit budget (thresholds on current gross spend; the "due" date is when
the straight line reaches it; percentages and dates hold for any cap, INR scales with it):
| Threshold | INR (of 25,000) | Straight line reaches it | If the alert arrives earlier |
|---|---|---|---|
| 10% | 2,500 | 2026-10-29 | look within 24 h: which service? |
| 25% | 6,250 | 2026-11-07 | ahead of plan: revert the knob driving it |
| 50% | 12,500 | 2026-11-23 | ahead of plan: revert to Stage 0 except min instances |
| 75% | 18,750 | 2026-12-08 | start S2 now |
| 90% | 22,500 | 2026-12-17 | start S3 now |
| 100% | 25,000 | 2026-12-24 | already paused |
Because the expected burn is far below the line, a second, tighter detector is the prod **monthly gross** budget at INR
3,000 (≈ the 1k-DAU profile), thresholds 50/90/100% actual + 100% forecast. Any alert from it means spend above the 1k-DAU
profile: look the same day. Daily habit (founder or sre-performance, 2 minutes): *Billing > Reports*, credits excluded,
cumulative since 2026-10-23, compared with `403 × day`.

**How the Terraform budget module must treat credits.** Today every budget uses the default `INCLUDE_ALL_CREDITS`, so
credit-paid usage shows as **INR 0** and no alert can fire. Changes (proposed, D6):
- Gross view: `credit_types_treatment = "INCLUDE_SPECIFIED_CREDITS"`, `credit_types = ["FREE_TIER"]` (subtract only
  Always Free; promotional credit, which includes the Free Trial, is **not** subtracted). `EXCLUDE_ALL_CREDITS` would count
  Always Free usage as spend and is not used.
- New billing-account-wide budget `credit-runway` (no `projects` filter, so dev and charges not specific to a project are
  included), `custom_period` 2026-10-23 → 2026-12-26, amount `credit_spend_cap_inr`, the thresholds above, Pub/Sub topic
  `billing-alerts`. Whether FORECASTED thresholds work on a `custom_period` is **UNVERIFIED**; current-spend thresholds are
  enough.
- Keep a **net** budget (`INCLUDE_ALL_CREDITS`) per project: it detects charges the credit does not cover and all spend
  after expiry. Prod net amount stays INR 500.

**Kill switch: options.**
| | K1 Manual (alerts → founder runs the runbook) | K2 Automatic: `billing-alerts` → function flips env / scales down | K3 Native Cloud Run spend cap (budget "spend cap", prod, Cloud Run only) |
|---|---|---|---|
| Free-tier cost | $0 | $0 (a few Pub/Sub messages and invocations a day) | $0 (no fee stated) |
| Latency | billing data lags hours to > 24 h + human time | same billing lag; budget messages arrive "multiple times per day" | same lag ("isn't instantaneous"); overage is billed |
| Failure modes | founder asleep or away | prod traffic is **pinned to named revisions**, so an env flip creates a 0% revision unless traffic is shifted, which bypasses the ADR-0019 founder gate; the function's SA can redeploy prod (escalation path); duplicate and out-of-order messages; false trips | full API **outage** at the cap; Cloud Run only (not Vision, Firestore, GCS); "fixed usage associated with persistent resources" is not paused (min instances may keep billing); account eligibility **UNVERIFIED** |
| What it covers | everything | what the function is written for | Cloud Run compute and requests |

**Runaway bounds that matter.** CPU is capped by max instances: 3 busy instances 24/7 = $199/month ≈ **INR 622/day**.
Requests are not capped: a 1,000 req/s flood = 86.4M requests/day × $0.40/M ≈ **INR 3,283/day**, billed even when our
limiters answer 429, because the request reached the container. The INR 2,000 reserve covers about 12 hours of that.
Requests denied by IAM are **not** billed (Cloud Run pricing page), so the fastest cost stop is removing the `allUsers`
invoker.

**Recommendation: K1 manual, with free fast detectors.** Add one prod alert policy on `run.googleapis.com/request_count`
> 50,000 per hour (≈ 14 req/s: 10× the 3k-DAU average and about its peak; raise it as DAU grows), emailed to the founder; alerting is free until 2027-09-01. Its
lag is minutes, not the billing lag. Response (runbook): remove `allUsers` invoker → investigate → `abuse-spike.md`. K2 is
rejected for a 64-day window (code, IAM power, ADR-0019 conflict, same billing lag). K3 is a founder choice (Not decided
item 3): a useful backstop only if eligible, set at INR 6,000/month gross for prod Cloud Run (≈ 6× the 1k-DAU Cloud Run
line), accepting an outage as the price.

### D4. Sunset and resume
```
RUNNING-CREDIT --(12-22 heavy off, 12-24 pause)--> PAUSING --> PAUSED --+--> RESUMED   (funded; new ADR or amendment)
       |                                                                +--> FREE-TIER (not funded; Stage 0)
       +--(funding approved before 12-22)--> RESUMED (skip the pause)
```
| State | What runs | INR/month (ex-GST; ×1.18 with GST) |
|---|---|---|
| RUNNING-CREDIT | D1 profile | 1,371 / 2,873 / 8,127 at 300 / 1k / 3k DAU, paid by credit |
| PAUSING (12-22 → 12-24) | Stage 0 config, then pause steps | Stage 0 rates for 2 days |
| **PAUSED** | Public API closed: `allUsers` invoker removed (IAM-denied requests are not billed); min 0; uptime check and alerts off; `publish-scheduled` paused (still free, ≤ 3 jobs) but `daily-maintenance` **kept running** (1 request/day, free) so the account-deletion backstop works; Pub/Sub push and `/internal/*` keep working (the pubsub-push SA keeps `run.invoker`), so in-flight deletion jobs finish; Firebase Hosting serves the static web app with a "paused" notice | **INR 0-15** (storage only) + one-off export INR 3-50 |
| **FREE-TIER** (Stage 0 as configured) | min 0, Vision cap 10,000, `unscreened_established` | **434 / 1,626 / 3,396** |
| FREE-TIER strict (Vision cap 1,000 + `reject`) | as above, images limited | **56 / 343 / 2,114** (egress to India and Firestore overage are never free) |
| **RESUMED** (credit-mode profile paid by money) | D1 profile | **1,371 / 2,873 / 8,127** (1,618 / 3,390 / 9,589 with GST) |
Today's DAU is about 0, so today any state except RESUMED costs about INR 0-50/month and RESUMED about INR 950-1,000.

**Data kept in PAUSED.**
| Data | Where | Kept? | Cost while paused |
|---|---|---|---|
| Firestore `(default)` | asia-south1, delete protection on | yes | free < 1 GiB; weekly backups INR ≈ 4 (keep the schedule) |
| Media objects | us-central1 public bucket | yes. Still publicly readable, so hotlinks bill Class B + egress: remove `allUsers` objectViewer while paused, or accept the cents | free < 5 GB (10.8 GB at 3k DAU after 2 months ≈ INR 11) |
| Upload / exports buckets | us-central1 | self-empty (2 d / 7 d lifecycle) | 0 |
| Container images | Artifact Registry asia-south1, `v*` tags protected | yes | free < 0.5 GiB |
| `cursor-hmac-key` | Secret Manager, 1 version per project | yes | free |
| Auth users, Pub/Sub topics, Scheduler jobs, Terraform state | | yes | free |
**Right to delete while paused.** The app cannot call DeleteAccount. Before S3: drain `DELETING` and export jobs (Pub/Sub
retains messages 7 days); while paused, deletion requests arrive by email and are run with `opsctl` (the backstop cron keeps
running through `/internal/*`).

**Free-Trial deletion risk (UNVERIFIED).** If the account is an unupgraded Free Trial, at expiry billing is disabled,
resources stop, and after 30 days they are permanently deleted; backups live in the same project and go too. Protection, at
S1 (2026-12-15): (a) a Firestore managed export to a bucket and (b) a copy of the export, the media bucket and the current
release image digest **to the founder's machine**. Cost: export billed as document reads (≈ 0.15M-1.5M docs at 300-3k DAU ≈
INR 3-50, **UNVERIFIED** unit), download egress $0.12/GiB ≈ INR 11/GiB (1-12 GiB ≈ INR 11-130). Alternatively upgrade to a
paid account before 12-26: data is kept, and PAUSED costs INR 0-15/month on the card. FREE-TIER and RESUMED both **require**
a paid (upgraded) account.

**Conditions to leave PAUSED.**
| To | Conditions (all) |
|---|---|
| RESUMED | (1) funding confirmed for ≥ 3 months of the chosen profile at measured DAU, incl. GST; (2) a new ADR or an amendment of this one, accepted by the founder, naming the monthly INR and the revenue or funding milestone (prime directive); (3) budgets re-based (gross = net once the credit is gone); (4) plan-then-OK apply; candidate smoke (ADR-0019); restore the `allUsers` invoker |
| FREE-TIER | (1) founder decides not funded; (2) the account is a paid account; (3) Stage 0 values (or the strict variant) applied and planned; (4) budgets back to INR 500 net per project; (5) restore the invoker |

### D5. Security, abuse, rollout
- **What changes:** service-level min instances, the Vision cap and policy, the sweep cadence, budgets, one alert policy,
  one alert threshold. **No abuse limit, quota, rate limit, read budget or flag changes** (D2).
- **Order:** dev first. (1) Budget module change and the credit budget (billing-account level). (2) On dev, set service-level
  min 1 for one hour and back to 0, to confirm whether it creates a revision and how pinned traffic reacts (the min-instances
  doc contradicts itself on this). (3) Prod, each step a saved `terraform plan` shown to the founder, then `apply tfplan`
  (`gcp-terraform` checklist). Env-var changes (Vision) create a revision at 0% because prod traffic is pinned: they ship
  through the normal release and promote path with the ADR-0019 approvals.
- **Monitoring:** credit budget (gross), prod monthly gross budget, request-count alert, the 48-h net-INR-0 check per
  service, the daily cumulative-vs-line check, `fs_reads` and Vision units in `make cost`.
- **Risks:** (1) a traffic or abuse spike while min instances and higher caps are on → request alert + invoker removal;
  CPU bounded at INR 622/day by max 3; Vision bounded by its cap (INR 2,708 or 5,558 a month). (2) A service the credit
  does not cover → 48-h net check. (3) Forgetting the sunset → dates in this ADR, `until:` markers, a CI check that fails
  after any `until:` date, the credit budget's end date, founder calendar entries 12-15/12-22/12-24. (4) The cap figure is
  wrong (20k pool) → the formula, checklist item 2. (5) Free-Trial deletion → S1 export.
  The `until:` markers sit on committed lines in `envs/prod/main.tf` (D6), not in the gitignored tfvars, so the CI check
  can see them; the Terraform precondition only fires in the founder's local plan.

### Founder decisions (stated and accepted 2026-10-23)
1. **Credit facts.** The founder checked: the account is Firebase Blaze on a Google Cloud trial, the credit expires on 2026-12-26,
   and the credit applies to free-tier-eligible services. Still to read from Billing > Credits before the first paid change:
   the exact remaining amount (pool 20k vs 25k INR was stated both ways), which services the credit covers, and whether a
   payment method is attached. They set `credit_spend_cap_inr` (the lower of INR 25,000 and remaining minus INR 2,000).
2. **Vision at the cap: `VISION_EXHAUSTED_POLICY=reject`** during credit mode (no unscreened image is ever published; uploads
   fail at the cap).
3. **K3 native Cloud Run spend cap on prod as a backstop: yes, if the account is eligible.** What Google documents
   ([spend caps](https://docs.cloud.google.com/billing/docs/how-to/budgets-spend-caps), read 2026-10-23): usage of the
   capped service is paused, **not deleted**; resources and data stay; in-flight requests finish; fixed costs of persistent
   resources continue; enforcement is not instant and overages are billed. **To bring the API back:** Billing > Budgets > edit
   the budget > **Lift spend cap**; services may take up to one hour to fully return; a manually lifted cap does not trigger
   again in the same monthly period unless the target is raised; budget settings cannot be edited while the cap is enforced
   (lift first); the cap lifts automatically at the start of the next monthly period. No Terraform apply or redeploy is needed to
   resume, so there is no revision or traffic-pin conflict, but **do not run `terraform apply` while the cap is on** (it cannot
   change the budget then, and an apply from `envs/prod` also re-adds the public invoker). Caveats: the cap counts gross cost
   excluding credits, so set the target as a gross amount; it covers one project and one service per budget; whether Free Trial
   accounts and whether Terraform can manage a spend-cap budget are UNVERIFIED (the console may be the only way); it is a
   backstop for the monthly period, not a replacement for the manual public-access kill switch.
4. **If no funding arrives at expiry:** run **FREE-TIER as configured for the first month** (about INR 434 at 300 DAU, less at
   fewer users), then **stay PAUSED** until funded or until subscriptions pay. Re-decide earlier if a month of real traffic
   shows a different bill.
5. **Upgrade the account to paid before 2026-12-26**, with minimal usage, so data is kept and PAUSED costs about INR 0-15 a
   month. The card is exposed only to that minimal usage plus whatever runs after expiry, so the sunset must still pause or
   reduce services before expiry.

### D6. Proposed edits (apply only after acceptance; this ADR changes none of them)
**CLAUDE.md**
- *Prime directive*, new last bullet: "- **Time-boxed exception (ADR-0022, credit mode):** until **2026-12-22** (heavy items
  off) and **2026-12-24** (services paused), prod may run the Stage 0C credit-mode profile paid by the GCP credit that
  expires 2026-12-26: service-level min instances 1, a higher `VISION_MONTHLY_CAP` with `reject` at the cap, and per-use
  overage. Gross spend is capped at `credit_spend_cap_inr` (INR 25,000 or lower). Nothing that bills after 2026-12-26 is
  allowed, and abuse limits do not change. After 2026-12-24 this prime directive applies unchanged."
- *Growth stages*, new row after Stage 0: "| **0C — Credit mode** (until 2026-12-24, ADR-0022) | 0 – ~3k DAU | ≤ INR 25,000
  total from GCP credit (≈ INR 45–270/day at 300–3k DAU) | Stage 0 + prod service-level min instances 1, Vision cap
  20k–40k (reject at cap), gross-spend budgets |"
- *Reference architecture*, API compute cell: "... min 0 / max 3 instances (prod: service-level min 1 until 2026-12-22,
  ADR-0022) ..."; Moderation cell: "... capped by `VISION_MONTHLY_CAP` (default 10k; 20k–40k with `reject` in credit mode,
  ADR-0022) ..."; Cost control cell: "Billing budget alerts (net per project + gross credit budget, ADR-0022), ...".
- *Explicitly not used at Stage 0*, append: "Credit mode (ADR-0022) does not lift this list. Also never during credit mode:
  committed use discounts, subscriptions or prepaid plans, or anything else that bills after 2026-12-26."
- *Working conventions, Stop and ask the founder*: "... accepting an ADR, changing `credit_spend_cap_inr` or the ADR-0022
  dates, keeping any credit-mode item on after 2026-12-22, or any `prod` apply/traffic shift."

**`.claude/hooks/cost-guard.sh`** (after `mins=...`): accept a dated marker and block it after the date.
```bash
# ADR-0022: '# cost-approved: ADR-NNNN until:YYYY-MM-DD' is accepted only up to and including that date (UTC).
today=$(date -u +%F)
expired=$(printf '%s\n' "$text" | grep -nE 'cost-approved: ADR-[0-9]{4} until:[0-9]{4}-[0-9]{2}-[0-9]{2}' |
  while IFS= read -r l; do
    d=$(printf '%s' "$l" | sed -E 's/.*until:([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')
    [ "$today" \> "$d" ] && printf '%s\n' "$l"
  done)
```
and change the block condition to `if [ -n "$hits$mins$expired" ]` with the message line
"expired time-boxed approval (until: date passed): revert the line or get a new ADR". The hook sees only edited text, so add
a CI step (production-deployer, `make ci`) that greps `infra/terraform` for `until:YYYY-MM-DD` dates earlier than today and
fails: this is what makes a forgotten sunset visible.

**`infra/terraform/modules/budget`**: new variables `credit_types_treatment` (string, default `"INCLUDE_ALL_CREDITS"`,
validation on the three values), `credit_types` (list, default `[]`), `projects` (list of project numbers; empty = whole
billing account), `custom_period` (object `{start = string, end = string}`, default null); in `budget_filter`:
`credit_types_treatment = var.credit_types_treatment`, `credit_types = var.credit_types`, `projects = var.projects`, a
`dynamic "custom_period"` block, and `calendar_period = var.custom_period == null ? "MONTH" : null`; skip the FORECASTED rule
when `custom_period` is set (UNVERIFIED support). `envs/prod`: a second instance `module "credit_runway_budget"` with
`projects = []`, `INCLUDE_SPECIFIED_CREDITS`, `["FREE_TIER"]`, `custom_period = { start = "2026-10-23", end = "2026-12-26" }`,
`amount = var.credit_spend_cap_inr`, `actual_thresholds = [0.1, 0.25, 0.5, 0.75, 0.9, 1.0]`, line comment
`# ADR-0022 until:2026-12-26`; and a prod monthly gross instance at INR 3,000 (50/90/100% + forecast). The existing net
budgets stay.

**`infra/terraform/modules/cloud-run-api`**: `variable "min_instance_count"` (number, default 0, validation 0..1) and
`variable "credit_mode_until"` (RFC 3339 string, default `"2026-12-22T00:00:00Z"`); a service-level
`scaling { min_instance_count = var.min_instance_count }`; remove `scaling` from `ignore_changes`;
`template.scaling.min_instance_count` stays 0; a `lifecycle { precondition { condition = var.min_instance_count == 0 ||
timecmp(plantimestamp(), var.credit_mode_until) < 0 ... } }`. That precondition is a **local-plan guard only**: CI plans
prod with the `variables.tf` defaults (Stage 0 values, min 0), so it never fires there.
**Where the dated markers go (so CI can see them):** the real `terraform.tfvars` is gitignored, so every credit-mode wiring
line is a committed line in `envs/prod/main.tf` carrying the marker, with the Stage 0 values kept as the `variables.tf`
defaults and the credit values only in the founder's real tfvars. Examples:
`min_instance_count = var.min_instance_count # cost-approved: ADR-0022 until:2026-12-22`,
`{ name = "VISION_MONTHLY_CAP", value = tostring(var.vision_monthly_cap) }, # ADR-0022 until:2026-12-22`,
`module "credit_runway_budget" { # ADR-0022 until:2026-12-26`. The cost-guard regex does not match a `var.` reference, so
these markers exist for the CI `until:` grep (and for humans); the hook itself only sees agent edits.

**`free-tier-budget` skill**
- §1, after "Last verified": "Prices re-verified 2026-10-23 (ADR-0022): Firestore asia-south1 $0.035 / $0.104 / $0.012 per
  100k reads / writes / deletes; Cloud Run asia-south1 is Tier 1; alerting is not charged before 2027-09-01."
- §1 Cloud Vision row, catches: "SafeSearch = 1 unit per screened image; `VISION_SCREEN_THUMB=true` (default) screens 2 per
  upload."
- §4 first bullet, append: "Budgets must not hide promotional credit: a gross view uses `INCLUDE_SPECIFIED_CREDITS` with
  `FREE_TIER` only; keep a net budget too (ADR-0022)."
- New §7 "Credit mode (ADR-0022, until 2026-12-24)": "Profile, cap and sunset in ADR-0022; abuse limits never change for
  credit; everything credit-funded carries `until:` and is off by 2026-12-22."

**`gcp-terraform` skill**: cloud-run-api line "min 0 (prod service-level min 1 only under ADR-0022 until 2026-12-22;
never revision-level: it warms every tagged revision)"; budget line "net per project + gross `credit-runway` custom-period
budget (ADR-0022)"; forbidden list "Cloud Run `min_instance_count > 0`" → "... unless the line carries
`# cost-approved: ADR-NNNN` or `# cost-approved: ADR-NNNN until:YYYY-MM-DD` (blocked after that date)".

**ADR notes** (append, decisions unchanged):
- ADR-0001: "Note (ADR-0022): superseded in part until 2026-12-26. Prod may run service-level min instances 1 until
  2026-12-22, paid by GCP credit. After 2026-12-24 this ADR applies unchanged."
- ADR-0005: "Note (ADR-0022): superseded in part until 2026-12-26: `VISION_MONTHLY_CAP` 20,000 (40,000 above 1,300 DAU) and
  `VISION_EXHAUSTED_POLICY=reject` until 2026-12-22. Correction: with `VISION_SCREEN_THUMB=true` each image costs 2 units, so
  10,000 covers about 820 DAU, not 1,600."
- ADR-0007: "Note (ADR-0022): superseded in part until 2026-12-26: a gross-spend budget view (`INCLUDE_SPECIFIED_CREDITS`
  `FREE_TIER`), a billing-account `credit-runway` budget, a prod monthly gross budget of INR 3,000 and a request-count alert.
  Alerting is not charged before 2027-09-01 (pricing page, 2026-10-23), so the R4 alert line is $0 through the window."
- ADR-0021: "Note (ADR-0022): superseded in part until 2026-12-26: `publish-scheduled` may run every minute until 2026-12-22
  (+1,152 reads/day, +34,560 requests/month, $0 Scheduler), then back to */5."

**`docs/plans/roadmap.md`**: §6 Risks, new row: "| Credit window (ADR-0022, until 2026-12-24) treated as a budget for new
features | the credit lifts no 🔒 gate; anything built in the window must run at Stage 0 cost after 2026-12-24 (no
realtime, video, external search, paid GIF provider, App Check web without its own ADR) |".

## Cost impact
- **Fixed monthly cost added:** prod idle min instance **INR 936/month** ($9.86; INR 441 if the free-tier discount offsets
  idle SKUs, UNVERIFIED), **time-boxed to 2026-12-22**, paid by credit. 1-min sweep: $0 Scheduler. Alert policies: $0 until
  2027-09-01. Nothing fixed remains after 2026-12-22.
- **Per use:** Vision past 1,000 units (2 units/image; bounded by the cap: INR 2,708/month at 20k, 5,558 at 40k), Firestore
  overage (reads past ≈ 215 DAU, writes past ≈ 617 DAU), egress to India (never free), GCS ops and egress.
- **Whole bill, credit mode** (INR/month ex-GST at 95/USD; ±5% FX): **1,371 / 2,873 / 8,127** at 300 / 1k / 3k DAU = INR
  45 / 94 / 267 per day, versus a 403/day line. Over the 62-day window ≈ INR 2.7k / 5.8k / 16.3k if that DAU held from day
  one (cost model §4). Today (≈ 0 DAU) ≈ INR 31-45/day.
- **Free-tier quota consumed:** 1-min sweep +1,152 reads/day (2.3% of 50k), +34,560 requests/month (1.7% of 2M); min
  instance may consume part of the shared Cloud Run free tier.
- **Trigger that justifies it:** founder priorities 1-2 and an expiring, already-granted credit; it is not a stage change
  (no measured DAU trigger from `free-tier-budget` §6). Continuing after 2026-12-26 on money needs a new ADR (D4).

## Consequences
- Positive: no cold start on the first instance; every image screened to ≈ 1,640 DAU (3,280 at 40k); credit burn becomes
  visible; the post-expiry monthly sums are known per state.
- Negative: a fixed line for 60 days; uploads fail once the Vision cap is reached under `reject`; more Terraform surface
  (two budgets, one alert, a module variable); the profile ends abruptly on 12-22 (cold starts return).
- Revisit when: the checklist shows a different cap or expiry; DAU > 1,300 (R4); the credit budget alerts ahead of the
  line; funding is confirmed (RESUMED ADR).

## Handoff
- **production-deployer:** write `docs/runbooks/credit-sunset-pause-resume.md` (R0-R4, S1-S3, PAUSED steps incl. invoker and
  media-bucket IAM, resume both ways, Free-Trial export); the budget and cloud-run-api module changes in D6 (service-level
  min instances; count prod's tagged revisions first); prod `vision_monthly_cap` / `vision_exhausted_policy` variables;
  the request-count alert; the CI `until:` check; the 1-hour dev min-instance test. Every prod step: plan → founder OK →
  apply the saved plan.
- **backend-developer:** none required (every knob is env or Terraform). ADR-0021's `SCHEDULED_*` and
  `QUOTA_*SCHEDULES*` keys are not in `config.go` yet; that is ADR-0021 work.
- **frontend-developer:** when the API answers HTTP 403 from Google's front end (not a Connect error), show a "service
  paused" screen instead of a generic error.
- **sre-performance:** feed the verified prices (Firestore Mumbai, alerting free until 2027-09-01, Vision 2 units/image)
  into `docs/reviews/cost-model.md` §4/§5/§7; track daily gross burn against the line; add Vision units/day to `make cost`.
- **security-auditor:** confirm no abuse limit moved; review invoker removal as the pause and flood lever.
- **tester:** dev dry run of pause → resume (invoker removed: 403 at the front end, `/internal/*` still served).
- **architect (on acceptance):** apply D6 edits in a separate docs PR.
