# Credit runway cost model (feeds ADR-0022)
Owner: architect · Date: 2026-10-23 · Status: draft for ADR-0022 (Proposed). Planning document: no code, infra or proto change.
The measured, living model stays `docs/reviews/cost-model.md` (sre-performance). This file shows the arithmetic behind the
ADR-0022 numbers so the founder can audit it. Every figure is a model estimate: prod has about 0 DAU today.

## 1. Inputs
### 1a. Usage per DAU (from `docs/reviews/cost-model.md` v0.3 and ADR-0021)
| Input | Value | Source |
|---|---|---|
| Firestore reads per DAU/day | 232.3 = 230.0 whole product + 1.1 P8 delta + 1.23 ADR-0021 | cost-model §2 total, header note, ADR-0021 Cost impact |
| Sweep reads per day (DAU-independent) | 288 at `*/5`, 1,440 at `* * * * *` (1 read per empty run) | ADR-0021 |
| Firestore writes per DAU/day | 32.4 = 31.8 + 0.3 + 0.31 | same |
| Firestore deletes per DAU/day | 7.71 (priced as if all were TTL deletes, which have no free quota) | same |
| Cloud Run per DAU-month | 1,104 requests, 110 vCPU-s, 55 GiB-s, 6.6 MB egress to India | cost-model §4 |
| Cloud Run fixed per month | 29,000 requests (uptime + CI) at 0.1 s; sweep 8,760 runs (`*/5`) or 43,800 (`* * * * *`) at 0.2 s | cost-model §4, ADR-0021 |
| GCS per DAU-month | Class A 24, Class B 918, egress 47 MB, storage growth 1.8 MB | cost-model §4 |
| Images per DAU/day | 0.2 | cost-model §1 |
| Vision units per image | **2** (`VISION_SCREEN_THUMB=true`, default and set in prod Terraform) | `config.go` |
| Vision units per DAU-month | 0.2 × 2 × 30.42 = **12.17** | derived |
| Hosting per DAU-month | 4 MB | cost-model §4 |
| Month | 730 h = 2,628,000 s = 30.42 days | |

### 1b. Prices (USD), all retrieved 2026-10-23
| Service | Price used | Page |
|---|---|---|
| Cloud Run, request-based, Tier 1 (asia-south1 is listed under Tier 1) | active $0.000024/vCPU-s; **idle min-instance $0.0000025/vCPU-s**; memory $0.0000025/GiB-s active and idle; $0.40 per 1M requests. Free 180,000 vCPU-s, 360,000 GiB-s, 2M requests per billing account, "applied as a spending based discount using Tier 1 pricing". "Idle instances that are not minimum instances are not charged." "Requests denied by IAM policy are not billed." | https://cloud.google.com/run/pricing |
| Cloud Run egress | Premium Tier internet egress, asia-south1 → Asia (excl. Korea, Indonesia): $0.12/GiB (1 GiB - 1 TiB). The free 1 GiB is "within North America" per the Cloud Run page, so modelled as 0 free | https://cloud.google.com/vpc/network-pricing |
| Firestore, Mumbai (asia-south1) | reads $0.035, writes $0.104, deletes $0.012, TTL deletes $0.012 (no free quota) per 100k; storage $0.104/GiB-month; backup $0.035/GiB-month; restore $0.23/GiB. Free 50k reads, 20k writes, 20k deletes/day, 1 GiB | https://cloud.google.com/firestore/pricing |
| Cloud Vision SafeSearch | first 1,000 units/month free; $1.50 per 1,000 units to 5M | https://cloud.google.com/vision/pricing |
| Cloud Scheduler | 3 jobs free per billing account; then $0.10/job/31 days; "a paused job is counted as a job" | https://cloud.google.com/scheduler/pricing |
| Cloud Logging / Monitoring | $0.50/GiB past 50 GiB/project/month; retention past 30 d $0.01/GiB-month; **alerting charges start "no sooner than September 1, 2027"**; billing, quota and uptime-metric policies are not charged; uptime checks 1M executions free | https://cloud.google.com/stackdriver/pricing |
| Cloud Storage, us-central1 Standard | $0.020/GB-month (0.000027397/GiB-hour); Class A $0.005/1k; Class B $0.0004/1k; egress to Asia $0.12/GiB; Always Free 5 GB-months, 5,000 A, 50,000 B, 100 GB egress from North America (US regions only) | https://cloud.google.com/storage/pricing |
| Artifact Registry | 0.5 GiB free per billing account; then $0.10/GiB-month | https://cloud.google.com/artifact-registry/pricing |
| Secret Manager | 6 active versions free, then $0.06/version-month; 10k accesses free, then $0.03/10k | https://cloud.google.com/secret-manager/pricing |
| Pub/Sub | 10 GiB/month free, then $40/TiB | https://cloud.google.com/pubsub/pricing |
| reCAPTCHA (web App Check) | 10,000 assessments/month free per organization; **$8 flat** for 10,001-100,000; then $1 per 1,000 | https://cloud.google.com/recaptcha/pricing |
| Firebase Hosting | 360 MB/day free, then $0.15/GB; 10 GB storage free, then $0.026/GB | https://firebase.google.com/pricing |
| Fixed-fee examples (not allowed) | LB forwarding rules asia-south1 $21.90/month (first 5); unused static IP $8.76/month | https://cloud.google.com/vpc/network-pricing |

### 1c. Currency and tax
- **FX: INR 95.0 per USD** (assumption; mid-market 94.955 at 15:31 WIB on 2026-10-23, https://pluang.com/en/tools/currency-converter/usd-inr).
  Sensitivity ±5%: INR 90.25 to 99.75. INR billing accounts pay Google's INR SKU prices; the console's *Billing > Pricing*
  is authoritative and can differ.
- **GST: 18%** shown as a separate column; whether it applies to this account and whether the credit covers it is
  **UNVERIFIED** (check the first invoice).

## 2. Monthly cost by service (USD, then INR at 95)
Stage 0 = today's config (min 0, Vision cap 10,000, sweep `*/5`). Credit = ADR-0022 profile (service-level min 1, Vision
cap 20,000 up to 1,300 DAU and 40,000 above, sweep `* * * * *`).

### 2a. Firestore (Mumbai)
| DAU | reads/day (credit) | over 50k → per month | $ | writes/day | over 20k → per month | $ | deletes/month | $ | **Total $** |
|---|---|---|---|---|---|---|---|---|---|
| 300 | 232.3×300 + 1,440 = 71,139 | 21,139 × 30.42 = 643k | 643k × 0.035/100k = 0.23 | 9,723 | 0 | 0 | 70k | 0.008 | **0.23** |
| 1,000 | 233,770 | 183,770 × 30.42 = 5.59M | 1.96 | 32,410 | 12,410 × 30.42 = 377k | 0.39 | 235k | 0.03 | **2.38** |
| 3,000 | 698,430 | 648,430 × 30.42 = 19.72M | 6.90 | 97,230 | 77,230 × 30.42 = 2.35M | 2.44 | 704k | 0.08 | **9.43** |
Stage 0 (`*/5`, 288 sweep reads): 0.22 / 2.36 / 9.42. Storage stays under the free 1 GiB in the window. Weekly backups:
≈ 2 × 0.5 GiB × $0.035 = **$0.04**.

### 2b. Cloud Run
| Line | Arithmetic | $ / month |
|---|---|---|
| Min instance idle (credit only) | CPU 1 × 2,628,000 × 0.0000025 = 6.57; memory 0.5 × 2,628,000 × 0.0000025 = 3.29 | **9.86** upper. If the free-tier discount (180k × 0.000024 + 360k × 0.0000025 = $5.22) also offsets idle SKUs: 4.64 (**UNVERIFIED**; plan on 9.86) |
| Active CPU 300 / 1k DAU | 110 × DAU + 2,900 + sweep ≤ 121,660 vCPU-s < 180,000 free | 0 |
| Active CPU 3k DAU | 341,660 − 180,000 = 161,660 × 0.000024 | 3.88 |
| Requests 3k DAU | 3,384,800 − 2,000,000 = 1,384,800 × 0.40/M | 0.55 |
| GiB-s | ≤ 171k at 3k DAU < 360k free | 0 |
| Egress to India | 6.6 MB × DAU / 1,024 × $0.12: 300 → 1.93 GiB; 1k → 6.45 GiB; 3k → 19.34 GiB | 0.23 / 0.77 / 2.32 |
Stage 0 at 3k DAU: CPU 334,652 − 180,000 = 154,652 × 0.000024 = 3.71, requests 0.54 → 4.25 + egress 2.32.

### 2c. Cloud Storage (us-central1)
| DAU | Class A (−5,000 free) | Class B (−50,000 free) | Egress (−100 GiB free) | Storage after ~2 months (−5 GB free) | **Total $** |
|---|---|---|---|---|---|
| 300 | 7,200 → 2,200 × 0.005/1k = 0.011 | 275,400 → 225,400 × 0.0004/1k = 0.090 | 13.8 GiB → 0 | 1.1 GB → 0 | **0.10** |
| 1,000 | 24,000 → 0.095 | 918,000 → 0.347 | 45.9 GiB → 0 | 3.6 GB → 0 | **0.44** |
| 3,000 | 72,000 → 0.335 | 2,754,000 → 1.082 | 137.7 GiB → 37.7 × 0.12 = 4.52 | 10.8 GB → 5.8 × 0.02 = 0.12 | **6.06** |

### 2d. Cloud Vision SafeSearch
| DAU | Units/month (12.17 × DAU) | Credit (cap 20k / 40k) paid units → $ | Stage 0 (cap 10k) paid units → $ |
|---|---|---|---|
| 300 | 3,650 | 2,650 × 1.50/1k = **3.98** | 2,650 → **3.98** |
| 1,000 | 12,167 | 11,167 → **16.75** | cap: 9,000 → **13.50** (uploads past the cap: unscreened for established accounts, rejected for new ones) |
| 3,000 | 36,500 | cap 40k: 35,500 → **53.25** | cap: 9,000 → **13.50** |
Caps as cost ceilings: 20,000 → 19,000 × 1.50/1k = $28.50 (INR 2,708); 40,000 → $58.50 (INR 5,558). With 1 unit per
image (`VISION_SCREEN_THUMB=false`) every Vision figure roughly halves and the 10,000 cap lasts to about 1,640 DAU.

### 2e. Everything else
| Service | 300 / 1k / 3k DAU | $ / month |
|---|---|---|
| Firebase Hosting | 1.2 / 4.0 / 12.0 GB vs 10.95 GB free (360 MB × 30.42) | 0 / 0 / (12.0 − 10.95) × 0.15 = **0.16** |
| Cloud Scheduler | 1 job today (2 with ADR-0021) ≤ 3 free; 1-min cadence is the same job | 0 |
| Logging | 1.1 MB × DAU ≤ 3.3 GB ≪ 50 GiB per project | 0 |
| Alert policies (prod 4) and the proposed request-count alert | not charged before 2027-09-01 | 0 |
| Artifact Registry | prod keep 3 + dev keep 6, ≈ 25 MB each ≈ 0.23 GB < 0.5 GiB | 0 |
| Secret Manager | 1 version per project; ≤ a few hundred accesses | 0 |
| Pub/Sub | ≈ 80 KB × DAU ≤ 240 MB ≪ 10 GiB | 0 |
| reCAPTCHA | not enabled (would be $8 flat once web passes 10k assessments/month) | 0 (8.00 if enabled) |

## 3. Whole bill per month
| Profile | DAU | Firestore | Cloud Run (min + active + egress) | GCS | Vision | Hosting | Backups | **USD** | **INR (95)** | INR/day | FX −5% / +5% | **INR + 18% GST** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Credit mode | 300 | 0.23 | 9.86 + 0 + 0.23 | 0.10 | 3.98 | 0 | 0.04 | **14.44** | **1,371** | 45 | 1,303 / 1,440 | 1,618 |
| Credit mode | 1,000 | 2.38 | 9.86 + 0 + 0.77 | 0.44 | 16.75 | 0 | 0.04 | **30.24** | **2,873** | 94 | 2,729 / 3,017 | 3,390 |
| Credit mode | 3,000 | 9.43 | 9.86 + 4.43 + 2.32 | 6.06 | 53.25 | 0.16 | 0.04 | **85.54** | **8,127** | 267 | 7,721 / 8,533 | 9,590 |
| Stage 0 as configured | 300 | 0.22 | 0 + 0 + 0.23 | 0.10 | 3.98 | 0 | 0.04 | **4.57** | **434** | 14 | 412 / 456 | 512 |
| Stage 0 as configured | 1,000 | 2.36 | 0 + 0 + 0.77 | 0.44 | 13.50 | 0 | 0.04 | **17.12** | **1,626** | 53 | 1,545 / 1,707 | 1,919 |
| Stage 0 as configured | 3,000 | 9.42 | 0 + 4.25 + 2.32 | 6.06 | 13.50 | 0.16 | 0.04 | **35.74** | **3,396** | 112 | 3,226 / 3,566 | 4,007 |
| Stage 0 strict (Vision cap 1,000) | 300 | 0.22 | 0.23 | 0.10 | 0 | 0 | 0.04 | **0.59** | **56** | 2 | 53 / 59 | 66 |
| Stage 0 strict | 1,000 | 2.36 | 0.77 | 0.44 | 0 | 0 | 0.04 | **3.61** | **343** | 11 | 326 / 360 | 405 |
| Stage 0 strict | 3,000 | 9.42 | 6.57 | 6.06 | 0 | 0.16 | 0.04 | **22.25** | **2,114** | 70 | 2,008 / 2,220 | 2,495 |
"Stage 0 strict" never reaches INR 0 at these DAU: egress to India is billed from the first GiB and reads pass the free
quota at about 215 DAU. INR 0 needs fewer than about 200 DAU and few images.

**Today (≈ 0 DAU):** credit mode ≈ min instance 936 + backups 4 + sweep and uptime noise ≈ **INR 950/month (INR 31/day)**.

## 4. Burn schedule against the cap
Plan line = `credit_spend_cap_inr × day / 62`, day 0 = 2026-10-23, day 62 = 2026-12-24 (pause). Cap 23,000 → **INR 371/day**
(359/day to 12-26; with a cap of 18,000: 290/day). "Expected" assumes the DAU below held from day 0, credit mode until 12-22,
then Stage 0 rates for 2 days.
| Date | Day | Plan line (23k) | Expected at 300 DAU | at 1k DAU | at 3k DAU | Budget threshold due |
|---|---|---|---|---|---|---|
| 2026-10-29 | 6.2 | 2,300 | 280 | 585 | 1,657 | 10% |
| 2026-10-30 | 7 | 2,597 | 316 | 661 | 1,870 | |
| 2026-11-07 | 15.5 | 5,750 | 699 | 1,463 | 4,142 | 25% |
| 2026-11-13 | 21 | 7,790 | 947 | 1,982 | 5,611 | |
| 2026-11-23 | 31 | 11,500 | 1,398 | 2,926 | 8,283 | 50% |
| 2026-11-27 | 35 | 12,984 | 1,579 | 3,304 | 9,352 | |
| 2026-12-08 | 46.5 | 17,250 | 2,097 | 4,390 | 12,425 | 75% |
| 2026-12-15 | 53 | 19,661 | 2,390 | 5,003 | 14,162 | S1 decision |
| 2026-12-17 | 55.8 | 20,700 | 2,517 | 5,268 | 14,910 | 90% |
| 2026-12-22 | 60 | 22,258 | 2,706 | 5,664 | 16,032 | S2 heavy off |
| 2026-12-24 | 62 | 23,000 | 2,735 | 5,771 | 16,255 | S3 pause |
At every DAU tier the expected burn stays below the line; at 3k DAU it reaches about 71% of the cap. Unused credit expires;
that is acceptable and intended.

**Runaway bounds (why the reserve is not a safety net on its own):**
| Event | Arithmetic | INR/day |
|---|---|---|
| 3 instances busy 24/7 (max-instances cap) | 3 × 2,628,000 × (0.000024 + 0.5 × 0.0000025) = $199/month | 622 |
| Request flood 1,000 req/s (requests are not capped) | 86.4M × $0.40/M = $34.56/day | 3,283 |
| Vision upload wave | bounded by the monthly cap: $28.50 (20k) or $58.50 (40k) per calendar month | ≤ 89 / 183 averaged |
| INR 2,000 reserve vs flood + CPU | 2,000 / (3,283 + 622) × 24 h | covers ≈ 12 h |
Billing data lags hours to more than 24 h, so the fast detector is the request-count alert (ADR-0022 D3), and the fast stop
is removing the `allUsers` invoker (IAM-denied requests are not billed).

## 5. Post-expiry monthly sums (INR, ex-GST at 95/USD; with 18% GST in brackets)
| State | 300 DAU | 1,000 DAU | 3,000 DAU | Arithmetic |
|---|---|---|---|---|
| **(a) PAUSED** | 0-15 (0-18) | 0-15 (0-18) | 0-15 (0-18) | Firestore < 1 GiB free; backups ≈ 2 × ≤ 0.5 GiB × $0.035 ≈ $0.04 (INR 4); media ≤ 5 GB free (3k DAU after 2 months: 10.8 GB → 5.8 × $0.02 = $0.12, INR 11); AR, secrets, Pub/Sub, ≤ 3 paused jobs, Auth, Hosting static: 0. API: `allUsers` invoker removed, so no billed requests |
| PAUSED, one-off protection (S1) | 3-15 | 15-50 | 50-180 | managed export billed as document reads (0.15M / 0.5M / 1.5M docs × $0.035/100k ≈ $0.05 / 0.18 / 0.53, **UNVERIFIED** unit) + download egress 1 / 4 / 12 GiB × $0.12 |
| **(b) FREE-TIER, Stage 0 as configured** | **434** (512) | **1,626** (1,919) | **3,396** (4,007) | §3 rows "Stage 0 as configured" |
| (b') FREE-TIER strict (Vision cap 1,000) | 56 (66) | 343 (405) | 2,114 (2,495) | §3 rows "Stage 0 strict" |
| **(c) Credit-mode profile, paid** | **1,371** (1,618) | **2,873** (3,390) | **8,127** (9,590) | §3 rows "Credit mode" |
FX ±5% moves every figure by the same ±5%. FREE-TIER and credit-mode-paid both need a paid (upgraded) billing account; on an
unupgraded Free Trial nothing runs after expiry.

## 6. Not verified (and how each is handled)
| Item | Handling |
|---|---|
| Credit pool (20k vs 25k), remaining amount, type, eligible services, payment method, trial vs paid | ADR-0022 checklist; cap formula `min(23,000, remaining − 2,000)` |
| Whether the Cloud Run free-tier spend discount offsets idle min-instance SKUs | planned at the upper figure ($9.86) |
| Google's INR SKU prices vs USD × 95 | console *Billing > Pricing*; ±5% shown |
| GST applicability and whether the credit covers it | shown with and without 18% |
| Cloud Run free 1 GiB egress for Asia destinations | modelled as 0 free |
| Firestore managed export unit price | small either way; checked at S1 |
| FORECASTED thresholds on a `custom_period` budget | current-spend thresholds suffice |
| Native Cloud Run spend-cap eligibility for this account | ADR-0022 Not decided item 3 |
| Usage inputs (230 reads/DAU, 0.2 images/DAU/day, etc.) | design estimates from cost-model.md; no prod traffic yet |
