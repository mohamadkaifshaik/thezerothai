# Security review: W6-40, the Vision attempt cap revision (PR #554)

**Ticket:** W6-42, part 1 (part 2, the review of #555 / W6-36, comes later) · **Date:** 2026-10-31 · **Reviewer:** security-auditor (read only; committed by the orchestrating session) · **Branch:** `fix/media-w6-40-attempt-cap` (006c73e4, 5f119cfb, 0706da68, ed1d6083), CI green (`make ci`, `make test-int`, the plans, the promotion scripts).

**Inputs:** ADR-0029 Amendment 1 A5 (accepted in principle 2026-10-31); H-3 in `docs/reviews/security-w6-composer-extras.md`; plan row W6-42 in `docs/plans/ui-w6-composer-extras.md`. The tester's results do not exist yet (W6-41 is open); this review reads the developer's tests in `attempt_cap_w640_test.go`. **Method:** read only: the diff, the code paths around it on the branch, the Terraform and the client. No cloud calls.

## Scope and the founder's binding points

| Founder point (Amendment 1 header) | Result |
|---|---|
| Vision outages, timeouts and busy responses do not consume attempts | **Holds.** Each takes at most one retry (`screenAttempts` +1, `screenAssessed` +0); a busy GIF slot takes nothing |
| The busy-GIF defect is fixed and tested; the busy path writes nothing | **Holds.** The slot wait is before the claim (`finalize.go:221-235`); `TestW640_BusyGIFSlotNeverConsumesAnAttemptAndWritesNothing` asserts 0 claims, 0 releases, 0 resolves, 0 Vision calls and 0 per-uid units after 10 busy calls, then READY |

## STRIDE (the changed surface only)

| Threat | Where | Control | Finding |
|---|---|---|---|
| **S**poofing | FinalizeUpload caller | Firebase ID token, App Check, ownership check in `FinalizeUpload` (unchanged) | none |
| **T**ampering (object swap on the retry path) | retry of the same media id for up to 48 h | create-only signed PUT (W6-25); `verify` re-runs on every attempt; GIF read and `Publish` pinned to the verified generation | none (verified below) |
| **R**epudiation | request log | `screen_outcome`, `screen_claims`, `screen_assessed`, `attempts_exhausted`, `units_daily_refused`, `gif_busy` | none |
| **I**nformation disclosure | logs, error text | enum and count fields only; errors through `RedactErr(err, uid)`; one uniform `reasonAttempts` for both counters | Info I-6 |
| **D**enial of service / **cost** | Vision spend, GIF slot, per-uid cap | per-doc claims ceiling of 8, the per-uid units `DailyCap`, the finalize bucket, `VISION_MONTHLY_CAP` with `reject`, the Vision project quota of 30 req/min | **H-1**, L-3 |
| **E**levation | none | — | none |

## Findings

| ID | Severity | Title | Blocks merge |
|---|---|---|---|
| H-1 | **High** (cost) | `VISION_MONTHLY_CAP` misses spend a client can trigger by hanging up | **yes: fixed in 9490702a** |
| L-1 | Low | Refunds cover every non-context error, not only Google's 429 and 5xx answers | no |
| L-2 | Low | The cost statement gives only the in-memory bound (INR 780), not the durable one (INR 1,390) | **yes: fixed in 9490702a** |
| L-3 | Low | The GIF slot wait still counts against the 20 s `finalizeDeadline` | no |
| L-4 | Low | A zero `createdAt` is "established" for the upload quota but "new" for the units cap | no |
| L-5 | Low | The new caps are env-only and do not show in a Terraform plan (rule 11) | no |
| I-1 | Info | `finalizeOne` never checks `expireAt` | no |
| I-2 | Info | A refund landing after IST midnight is subtracted from the new day's count | no |
| I-3 | Info | An account leaving the new-account window mid-day gets 12 + 60 units that day | no |
| I-4 | Info | The units cap is checked after `verify`, so a refused call still costs 1 read and 4 Class B operations | no |
| I-5 | Info | Test gaps (no cancellation case; one subtest name says more than it tests) | no (W6-41) |
| I-6 | Info | The client recognises a screening UNAVAILABLE by a heuristic | no |

### H-1 (High, cost): `VISION_MONTHLY_CAP` misses spend a client can trigger by hanging up

**Where:**
- `backend/internal/media/finalize.go:69`: `s.Repo.AddVisionUnits(ctx, …)` runs on the request context, which carries the handler's 20 s `finalizeDeadline` (`server.go:117`) and ends when the client disconnects. If it has ended, the write fails and is only logged (`vision_counter_write_failed`); `visionBudget.used` is reloaded from Firestore every 60 s (`vision_budget.go`), so the answered units are lost from the monthly counter for good.
- `finalize.go:278`: `s.vision.release(units - res.answered)` returns every unanswered call to the monthly counter, including `context.Canceled` and `context.DeadlineExceeded`, calls that may have been billed (the N1 behaviour inherited from #535).
- `screencap.go:105-107`: `neverSent` already treats context errors as possibly billed, but only for the per-uid cap. The two counters use different definitions of "billed".

**Exploit:** an account uploads an image (1 of its 20 daily uploads), calls FinalizeUpload and closes the connection about 1 s later while the Vision call is in flight. Go's `net/http` cancels the request context, the Vision call returns `context.Canceled`, Google probably bills the received call, the monthly counter gets the 2 units back, the per-uid cap keeps them (correct), the claim is released on a detached context, and the doc takes 1 retry. Variant: hang up after Vision answered, during the publish copies; `AddVisionUnits` fails on the cancelled context. Both repeat up to the claims ceiling of 8 per doc, over 20 docs a day.

**Bound per account:** the per-uid cap still holds, so this is not the unbounded H-3: 180 units/day while instances live, 320 units/day durable (20 uploads × 16) across instance restarts.

**Why this PR widens the gap:** under #535 a cancellation consumed one of 3 attempts (at most 6 uncounted units per doc, 120 per account-day); now it consumes a retry (up to 16 per doc, 180–320 per account-day). A5.7's "the service-wide `VISION_MONTHLY_CAP` with `reject` still caps the total" is therefore **not true for this class**; the real service-wide ceiling is the Vision project quota of 30 req/min.

**Cost scenario** (INR 0.1425 per unit; every uncounted unit assumed billed):

| Ring | INR/day | INR 25,000 credit gone in |
|---|---|---|
| 10 accounts | 257 (durable 456) | 97 days (55) |
| 50 accounts | 1,283 (2,280) | 19.5 days (11) |
| 100 accounts | 2,565 (4,560) | 9.7 days (5.5) |
| ≥ 240 accounts (≥ 135 durable): the project quota binds | 6,156 | **4.1 days** |

Accounts cost nothing (Google sign-in); web App Check is still an open ADR; the only signal is the gross-spend budget alert, which lags billing. **With the fix**, total Vision spend is capped by `VISION_MONTHLY_CAP` again (20,000–40,000 units, about INR 2,850–5,700 a month in credit mode); a ring can then only exhaust the cap and deny uploads to everyone, which A5.7 already accepts.

**Fix (required before merge):**
1. Write `AddVisionUnits` on `context.WithoutCancel(ctx)` with a short timeout (the `releaseClaim` / `claimReleaseTimeout` pattern).
2. One definition of "possibly billed" for both counters: (a) `spent = units - res.refundable` and `s.vision.release(res.refundable)`, so timeouts and cancellations count in the monthly cap; or (b) run the Vision calls on `context.WithoutCancel(ctx)` with their own 10 s deadline so a hang-up cannot abort a billed call (deadlines still need (a)). Option (a) over-counts by at most 2 units per honest timeout, the safe direction.
3. Tests: a context cancelled after the moderator answered still adds the units to the monthly counter; a context cancelled mid-call is counted in the monthly counter (or, under (b), does not cancel the call) and is not refunded to the per-uid cap.
4. Architect: a one-line implementation note on A5.7/N1 that timeouts and cancellations are counted.

**Unverified:** whether Cloud Run's front end passes a client disconnect to the container (Go cancels on a closed connection; rated likely); whether Google bills an abandoned request. Rated High because the ADR's total-spend argument rests on the monthly counter and the fix is a few lines; not Critical because the per-account bound holds; not a founder stop because every repo signal says `FEATURE_MEDIA` is off in prod and the widened code is not merged.

### L-1 (Low): refunds cover every non-context error

`finalize.go:612-615`, `screencap.go:105`: every error that is not a `VisionAnsweredError` and not a context error is refunded. An error after the request was written (connection reset, unexpected EOF) is as ambiguous as a timeout. Not attacker-triggerable (server-to-Google path) and bounded by the 16-unit per-doc ceiling. **Fix:** refund only a `*googleapi.Error` with HTTP 429 or ≥ 500, errors before any request was sent (building the service, a dial failure) and the existing pre-call paths; treat other transport errors like timeouts.

### L-2 (Low, required doc fix): the cost statement gives only the in-memory bound

`docs/runbooks/media.md` ("about INR 780 per account-month"), the PR text and ADR-0029 A5.7. The units cap lives in memory per instance and resets on a new instance (scale to zero, a deploy, an idled service); the durable bound is the claims ceiling times the uploads quota. **Fix:** state both: established accounts about INR 780 nominal / about INR 1,390 durable; new accounts about INR 156 nominal / about INR 347 durable.

### L-3 (Low): the GIF slot wait still counts against the 20 s `finalizeDeadline`

`finalize.go:221-235`, `server.go:117`; the comment at `finalize.go:136-139` ("about 17 s") leaves out the 5 s wait. Worst case (5 s wait, 5 s read, 2 s decode, verify and claim round trips) leaves Vision about 8 s; under GIF load an honest GIF can hit `DeadlineExceeded` mid-call, costing a retry and 2 units on the per-uid cap (and, until H-1, uncounted monthly units). Pre-existing (W6-10). **Fix:** the cheaper of shortening `GifQueueWait` to 2–3 s, giving the Vision calls the remaining time and refusing to start them below about 3 s left, or correcting the comment.

### L-4 (Low): a zero `createdAt` gets different tiers for uploads and for units

`service.go:378` treats it as established (20 uploads); `screencap.go:91` as new (12 units). A usability inconsistency, not a hole; the stricter units tier is the safe side (deviation 2). **Fix:** treat zero as new in `CreateUpload` too, or confirm no `users` doc lacks `createdAt`.

**Fixed in #565 (W6-50).** Zero `createdAt` is now NEW in both places: `CreateUpload` and the units cap call one predicate, `isNewAccountAt` (`screencap.go`), so the 5-image upload quota and the 12-unit cap always apply together. The first option was taken because signup always sets `createdAt` (so only a hand-written or imported doc can lack it, which the repo cannot enumerate), an unknown age proves nothing about the account, and the other two readers of the age already fail closed (an unreadable age is new for the units cap; zero is not established for the unscreened publish). `CreateUpload` still fails when the age cannot be read. Tests: `TestW650_UploadQuotaAndUnitsCapUseTheSameTier`, `TestW650_UnreadableAgeBehaviourIsUnchanged`, `TestW650_ZeroCreatedAtIsNotEstablishedWhenTheMonthlyCapIsSpent`.

### L-5 (Low): the new caps are env-only (rule 11)

`MEDIA_VISION_UNITS_PER_DAY`, `MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT` and `MEDIA_MAX_SCREEN_RETRIES` exist only as code defaults (`config/composer.go`, validated to 2..200, 2..60, 0..10), following `MEDIA_MAX_SCREEN_ATTEMPTS`. The defaults are reviewed code, so rule 11 is met, but the values in force never show in a Terraform plan. At their limits: 20 claims (40 units per doc), 600 effective units per uid per day. **Fix (follow-up, production-deployer):** add the three keys with their defaults to `infra/terraform/envs/{dev,prod}/main.tf` next to `RATE_LIMIT_MEDIA_FINALIZE_PER_MIN`.

### Info

- **I-1:** `finalizeOne` does not check `expireAt`; Firestore TTL and the bucket's `age = 2` rule run late, so a PENDING doc can sometimes be screened after 48 h. The per-doc bound and moderation are unaffected (`verify` re-runs; `Publish` is generation-pinned). Optional: treat `now ≥ expireAt` as NOT_FOUND.
- **I-2:** a refund crossing IST midnight is subtracted from the new day (floored at 0): at most 2 units. Negligible.
- **I-3:** the two tiers are separate `DailyCap`s; an account leaving the new-account window mid-day can use 12 + 60 that day. Negligible.
- **I-4:** the units check is after `verify`, so a refused call costs 1 read and 4 Class B operations (at most about INR 3 a day per looping account at the 30/min bucket). Optional: peek at the cap before `verify`.
- **I-5 (W6-41):** no test cancels the context (H-1's tests above); the subtest "a lost claim race and a Vision-counter error refund" only exercises the counter error; add a claim conflict (`ErrConflict` from `ClaimScreening`) asserting a full refund.
- **I-6:** `connect_error_mapper.dart` maps any UNAVAILABLE with reason UNSPECIFIED and a `retry_after` to `ScreeningUnavailableException`. Correct today (only FinalizeUpload sends that combination). Optional: a dedicated metadata key.
- **Combined bucket:** the split doubles the combined CreateUpload + FinalizeUpload rate from 10 to 20 per minute per instance (60 effective), bounded by `quotas.uploads` and the units cap. Accepted.

## Rulings on the developer's seven deviations

1. **5xx/429 refunded to the per-uid cap: ACCEPTED, narrowed as L-1.** The monthly counter already treats these as unbilled (since #535); each refunded call still takes one of the doc's 8 claims, so even if Google bills them the durable per-doc 16 units and per-account 320 units/day hold (the refund only moves an account from nominal 180 toward durable 320). A 429 can be caused by a ring saturating the 30 req/min project quota, but the saturating calls are themselves billed and capped and the effect is a denial of honest uploads (REJECTED `claims` after 8), which A5.7 accepts; a 5xx cannot realistically be steered. Billing of 5xx/429 is unverified. A refinement of A5.5, not one of the founder's binding points; the architect records it as an A5.5 implementation note.
2. **Unknown or zero age gets the new-account tier: ACCEPTED** (fails closed; see L-4).
3. **Units charge before the GIF slot wait, refunded when busy: ACCEPTED.** The deferred `Refund(uid, refundUnits)` with `refundUnits = units` covers the busy path, the claim conflict, the claim and reserve errors and the cap-exhausted branch; `TestW640_BusyGIFSlotDoesNotSpendTheUnitsCap` pins it. The charge is held up to 5 s, which can briefly refuse the same uid's concurrent finalizes near its cap (affects only the caller).
4. **`reasonAttempts` text: ACCEPTED** ("We couldn't check this image. Remove it and choose another." matches A5.6; the same for both counters).
5. **Log field `attempts_exhausted` (`assessed` / `claims`): ACCEPTED** (enum; no metric, alert or Terraform resource used the old `screen_attempts_exhausted`; runbook updated).
6. **Only `RATE_LIMIT_MEDIA_FINALIZE_PER_MIN` in Terraform (not applied): ACCEPTED** (its value equals the code default, 10; the rest is follow-up L-5).
7. **16 billed units per doc, about INR 780 per abusive account-month: ACCEPTED for the number, corrected by L-2.** 16 = 8 claims × 2 units, pinned by `TestW640_PerDocBillableUnitsAreAtMost16` (the 9th call bills nothing). INR 780 is the bound while instances live; the durable INR 1,390 must appear next to it.

## The H-3 bound, verified

| Question | Answer |
|---|---|
| Can a path bill Vision without counting against the **per-uid** cap? | **No.** The charge comes before the claim (`finalize.go:212`); the refund returns only `res.refundable`, the calls that never went out (`finalize.go:279`); timeouts, cancellations and answers stay charged |
| … against **`VISION_MONTHLY_CAP`**? | **Yes, until H-1 is fixed:** a cancellation or deadline during a Vision call, and an answered call whose request context ends before `AddVisionUnits`. Bounded per account by the per-uid cap and the per-doc ceiling; service-wide only by the 30 req/min project quota |
| Crash between a Vision answer and the release write | `screenAttempts` was incremented in the claim write before any call, so the 8-claim ceiling applies; the lost `screenAssessed` increment counts as a retry (still bounded, A5.4); the per-uid charge is lost with the instance (fails open, bounded durably); the monthly units are lost (same gap as H-1; crashes are not attacker-triggerable) |
| Can `screenAttempts` / `screenAssessed` be reset or bypassed? | Not on one doc: only `ClaimScreening` and `ReleaseScreening` write them, with `UpdateTime` preconditions. A **new doc** starts at 0 but costs an upload: `quotas.uploads` is charged per doc in `CreateUploads` (`repo_firestore.go:239`), 20 a day (5 new), durable. A CreateUpload replay re-signs the **same** media ids and doc, so the counters carry over |
| Per-doc bound | 8 claims × 2 = **16 units** (ceilings: 20 claims, 40 units) |
| Per account per day | Established: 180 nominal, 320 durable. New: 36 nominal, 80 durable |

## Other checks (all hold)

- **Busy path:** no claim, release, resolve, Vision call, monthly reservation or per-uid units; it costs 1 doc read and 4 Class B operations for `verify` plus up to 5 s. The slot is per instance and each holder is bounded by the per-doc claims and the uploads quota, so it cannot amplify anything.
- **`DailyCap.Refund`:** one deferred refund per `finalizeOne`, `refundUnits` assigned once after the call (no double refund); `res.refundable` ≤ the number of calls = `units` (1 or 2; a GIF has `screensThumb` true, so `units` = 2 matches its `refundable: 2`, `gifscreen.go:147`); refunded to the same tier object that charged; under the per-key mutex, floored at 0; single-flight followers neither charge nor refund; each instance refunds only its own charge; LRU of 100,000 keys.
- **Effective limits at max 3 instances:** FinalizeUpload bucket 10/min → 30/min; CreateUpload bucket 10/min → 30/min; units cap established 60/day → 180/day; new 12/day → 36/day. Restarts lift the units caps up to the durable bounds.
- **Retry without re-upload:** `verify` re-runs before every claim and pins the generations (W6-25); the GIF read and both `Publish` copies use them, so a replaced object answers `ErrGenerationChanged` and REJECTS with nothing published (`rejectChanged`). Vision's gs:// read is not generation-pinned, but the PUT is create-only and a changed object fails the pinned `Publish`, so unscreened bytes are never published. The 48 h doc and 2-day object lifetime give no swap window.
- **Client retry:** 3 automatic retries after `retry_after` (5 s, or 2/4/8 s when missing), capped at 30 s plus jitter; the loop counter is shared with the GIF-busy retries (at most 7 calls per `upload()`); the manual Retry flips the tile to `uploading` at once, so a double tap cannot loop. A modified client is bounded only by the server (30/min bucket, units cap, claims ceiling).
- **Logs:** enums, counts and booleans; errors via `RedactErr(err, uid)`; no Vision verdict or likelihood logged. Pre-existing: a `googleapi.Error` message for a gs:// call could name the object path (uid redacted, media id not), the existing convention.

## Cost math

Unit price INR 0.1425 ($1.50 per 1,000 at INR 95/USD).

| Account | Bound | Units/day | INR/day | INR/month |
|---|---|---|---|---|
| Established | nominal (60 × 3) | 180 | 25.7 | **≈ 780** |
| Established | durable (20 × 16) | 320 | 45.6 | **≈ 1,390** |
| New | nominal (12 × 3) | 36 | 5.1 | ≈ 156 |
| New | durable (5 × 16) | 80 | 11.4 | ≈ 347 |
| For comparison: #535 | — | 120 | 17.1 | ≈ 520 |

Firestore: about 2 writes per claim, at most 320 writes a day per account (negligible). **After the H-1 fix**, Vision spend is capped by `VISION_MONTHLY_CAP` (INR 1,425 at 10,000 units; INR 2,850–5,700 at 20,000–40,000 in credit mode), so Vision alone cannot burn the INR 25,000 credit; the remaining harm is denial of uploads once the cap trips (about 222 account-days at 180/day, or about 125 at 320, for 40,000 units). **Before the fix:** see the H-1 table (at most INR 6,156 a day at the project quota, the credit gone in about 4.1 days with at least about 240 accounts).

## Verdict on #554: MERGE AFTER FIXES

Required before merge:
1. **H-1:** `AddVisionUnits` on a detached context with a timeout; one "possibly billed" definition for both counters (count timeouts and cancellations in the monthly cap, or detached Vision calls plus counting deadlines); the two context-cancellation tests.
2. **L-2:** state the durable INR 1,390 (new accounts INR 347) next to INR 780 in `docs/runbooks/media.md` and the PR text; the architect adds the matching A5.7 note with the H-1 note.

Follow-ups, not blocking: L-1 (narrow refunds), L-3 (slot wait vs deadline), L-4 (age-tier alignment): backend-developer. L-5 (Terraform env entries): production-deployer. I-5 (tests): tester, W6-41. The A5.5 refund note (deviation 1): architect.

## What could not be verified

- Whether Google bills Vision calls that answer HTTP 429 or 5xx, or that the caller abandoned mid-flight.
- Whether Cloud Run passes a client disconnect to the container's request context (Go's `net/http` cancels on a closed connection).
- The live prod value of `FEATURE_MEDIA` (prod tfvars are gitignored; every repo signal says off).
- Whether `google.golang.org/api` v0.307.0 retries `images:annotate` internally.
- No tests were run by the reviewer; it relied on the PR's green CI.

SECURITY: CLEAR (H-1 and L-2 fixed in 9490702a, checked against the recommended fix by the orchestrating session 2026-10-31; L-1, L-3, L-4, L-5 are follow-ups W6-49, W6-50, W6-51)
