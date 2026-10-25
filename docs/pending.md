# Pending jobs and tasks

The founder's single list of everything still open. Claude updates it in the PR that changes the state of an item (done, new, blocked), so it should always match `main`. Dates are 2026; today when this file was created was 2026-10-23.

Status: **TODO** not started · **DOING** in progress · **BLOCKED** needs something first · **WAIT** waiting on a date or an event · **DONE** (kept in the history section, not here).
Owner: **Founder** only you can do it (credentials, billing, console, decisions) · **Claude** agents do it, you review and approve the PR · **Both**.

Rules that apply to every item: prod applies and traffic shifts need your plan-then-OK (ADR-0019); every feature flag stays **off** until 100% of traffic is on a revision that enforces it; merge one PR at a time and wait for the dev deploy to finish between merges (the deploy refuses a stale commit).

---

## 1. Credit runway (ADR-0022, GCP credit expires 2026-12-26)

Decisions already made: Vision at the cap = `reject`; use Cloud Run's native spend cap on prod as a backstop if the account is eligible; if no funding arrives, run Stage 0 as configured for the first month after expiry (about INR 434 a month at 300 daily users) and then stay paused; upgrade the account to paid before expiry so paused costs about INR 0 to 15 a month. Spend cap: `credit_spend_cap_inr` = the lower of INR 23,000 and (remaining credit minus INR 2,000).

### Dated steps (do them in this order)

| # | When | Owner | Status | Task |
|---|---|---|---|---|
| 1.1 | **Now** | Founder | TODO | Open Billing > Credits. Write down the remaining amount, which services the credit covers, and whether a payment method is attached. (The ADR says 20k or 25k pool: the real figure is needed to set the cap.) Tell Claude the numbers. |
| 1.2 | After 1.1 | Both | TODO | **R0 apply (prod, no behaviour change):** in your gitignored prod `terraform.tfvars` set `enable_credit_budgets = true`, `credit_spend_cap_inr = <min(23000, remaining - 2000)>`, `enable_request_flood_alert = true`, optionally `firestore_reads_alert_per_day = 250000`. From `infra/terraform/envs/prod` run `terraform plan -out=tfplan`, paste the plan to Claude, expect only: 2 budgets created, 1 flood alert created, the reads threshold changed, plus the known noise (the `moved` notice for the budget topic, `template[0].revision -> null`, the `FEATURE_GRAPH` artifact: never apply that). Then your OK and `terraform apply tfplan`. **CI does not run a Terraform plan, so this local plan is the only real check.** |
| 1.3 | By **2026-11-15** | Both | TODO | **Dev rehearsal** of the pause and resume runbook (`docs/runbooks/credit-sunset-pause-resume.md`) and the one-hour dev test "service-level min instance" (no merges to `main` meanwhile). Write the results back into the runbook. |
| 1.4 | After 1.2 and 1.3 | Both | TODO | **R1:** set `min_instance_count = 1` in the prod tfvars (a warm instance, about INR 936 a month, paid by the credit), plan, review, OK, apply. Expect a 0%-traffic revision in the plan. |
| 1.5 | When `FEATURE_MEDIA` serves images in prod | Both | WAIT | **R2:** `vision_monthly_cap = 20000` and `vision_exhausted_policy = "reject"`. Goes through the normal release path (three ADR-0019 approvals). |
| 1.6 | When `FEATURE_SCHEDULED_POSTS` leaves off | Claude | WAIT | **R3:** scheduled-post sweep runs every minute instead of every 5 minutes (free). |
| 1.7 | Daily users above 1,300 for 3 days, or Vision above 600 units a day | Both | WAIT | **R4:** Vision cap 40,000. |
| 1.8 | Before launch traffic | Founder | TODO | Set up the **Cloud Run native spend cap** on prod in the console if the account is eligible (Billing > Budgets). To bring the API back after it trips: Lift spend cap, wait up to an hour; do not run `terraform apply` while capped. Unverified for Free Trial accounts. |
| 1.9 | **2026-12-22** | Both | WAIT | **Heavy items off:** revert the tfvars to the Stage 0 values (min 0, Vision cap 10000, `unscreened_established`, reads threshold 40000), plan, OK, apply. Then merge a PR removing every `until:2026-12-22` line in `infra/terraform/envs/prod/main.tf` and the tfvars example. **From 2026-12-23 CI goes red on every PR until this is done** (deliberate). |
| 1.10 | **2026-12-24** | Both | WAIT | **Pause** both projects per the runbook (remove the public invoker, disable the deploy workflows, **keep `daily-maintenance` running**). The mandatory data export (Firestore, media bucket, auth users, tfvars, stored outside GCP) comes first. |
| 1.11 | **Before 2026-12-26** | Founder | TODO | **Upgrade the account to paid** so data is kept. Confirm a payment method is attached and that nothing is left running that bills after expiry. |
| 1.12 | **2026-12-26** | Founder | WAIT | Credit expires. Check Billing reports that spend has stopped. |
| 1.13 | From 2026-12-27 | Both | WAIT | Remove the two credit budget modules and the flood alert (their `until:2026-12-26` markers). Destroying a budget needs your confirmation. |
| 1.14 | After expiry | Founder | WAIT | If funded: resume per the runbook. If not: Stage 0 as configured for the first month, then stay paused. |

### Credit follow-ups (no date yet)

| # | Owner | Status | Task |
|---|---|---|---|
| 1.15 | Claude | TODO | Replace remaining "Stage 0 ($0)" wording: plan headers (`docs/plans/*.md` line 2), `docs/plans/roadmap.md:2,9`, `.claude/agents/production-deployer.md:11`, `.claude/skills/free-tier-budget/SKILL.md:41`, `docs/plans/phase1.md:398`, `docs/runbooks/cloud-bootstrap.md:235` ("$5 budget"). |
| 1.16 | Claude | TODO | Terraform comments that still say "min must stay 0" or "~$5" (`modules/cloud-run-api/main.tf`, `modules/budget/main.tf`, `envs/*/variables.tf`). |
| 1.17 | Claude | TODO | Runbook follow-ups F1 to F6: a `service_paused` Terraform variable, tested `pause.sh` and `resume.sh`, a budget-triggered automatic pause (level 1 only), a gross-spend budget, a maintenance page and a way to mute the uptime alert while paused, and the dev rehearsal results. |
| 1.18 | Claude | TODO | `publish-scheduled` Cloud Scheduler job is not in `envs/prod/main.tf` yet (ADR-0021, part of composer item 2.7). |
| 1.19 | Claude | TODO | Make CI able to run a real `terraform plan` (the plan service-account secrets do not exist yet; `plan (dev)` and `plan (prod)` only run fmt and tflint). Needs your bootstrap per `docs/runbooks/cloud-bootstrap.md`. |
| 1.20 | Founder | TODO | Decide whether to give dev the OpenID Token Creator role (30-day condition) so the scheduled-post sweep can be tested with `curl` (ADR-0021 review L-5). |

---

## 2. Composer extras (ADR-0021: reply audience, content disclosure, scheduled posts)

Done and merged: ADR accepted, proto contract, scheduled TTL policy, content disclosure backend (`FEATURE_CONTENT_DISCLOSURE`), reply audience backend (`FEATURE_REPLY_AUDIENCE`). Both flags are **off everywhere**.

| # | Ticket | Owner | Status | Task |
|---|---|---|---|---|
| 2.1 | CMP-B3 | Claude | DONE (#256, merged) | Flutter reply-audience UI: "Who can reply?" sheet (3 options), link text, disabled reply state from `viewer_reply_permission`, echo check. Needs a dev check once `FEATURE_REPLY_AUDIENCE` is allowlisted for a test user (see 2.13). |
| 2.2 | CMP-D2/D3 foundation | Claude | DONE (PR #258 open) | Scheduled posts PR 1: config and quotas, the `users/{uid}/scheduled` model and repository, deletion eraser, export section, collection-guard row, `FEATURE_SCHEDULED_POSTS` (off), rate-limit mapping. Founder decisions 2026-10-24: failed items are not rescheduled (draft cleared on FAILED); Cancel accepts FAILED as well as PENDING; `SCHEDULED_MAX_PENDING` max 50 and `SCHEDULED_SWEEP_CONCURRENCY` max 4; flaky lifecycle test is issue #259. |
| 2.3 | CMP-D3 | Claude | TODO | Scheduled posts PR 2: `SchedulePost`, `ListScheduledPosts`, `CancelScheduledPost` service and handlers (replay check before limits, window cap, quotas, per-item rules from the security review). |
| 2.4 | CMP-D4 | Claude | TODO | Scheduled posts PR 3: the publish sweep and its `/internal/cron/publish-scheduled` route (per-item recover, per-author cap, precondition writes, error scrubbing, exactly-once publish). |
| 2.5 | CMP-D5 | Claude | TODO | Scheduled posts PR 4: Terraform for the `publish-scheduled` job (prod only, every 5 minutes; 2 of 3 free Scheduler jobs). |
| 2.6 | CMP-D6 | Claude | TODO | Scheduled posts PR 5: Flutter schedule dialog (native date and time pickers on mobile) and the Scheduled list. |
| 2.7 | CMP-D7/D8 | Claude | TODO | Scheduled posts PR 6: tests, runbook entry, cost report (sre-performance). |
| 2.8 | CMP-C3 | Claude | TODO (on hold: founder said do not start yet) | Flutter disclosure UI. Unblocked: the two-switch dialog, the label rows under the composer text (sparkle "Made with AI", then "Paid partnership", grey `#71767b`, about 22 dp pitch), the filled flag icon while a label is set, and the same two rows on a posted post (between the text and the action row) are all captured and measured. Add the label text to the post's accessibility summary (X leaves it out). Still unknown: label placement with media or a quote, mobile, light theme. |
| 2.9 | CMP-0 captures | Both | DOING | Captured so far (local notes `docs/x_research/screens/composer.md` sections 1a to 1g): over-limit state, discard prompt, mobile composer, schedule dialog, disclosure labels in the composer and on a posted post, counter ring (blue progress arc, number only near the limit, yellow ring at 4 remaining, red negative over). **Still to capture:** the exact remaining-count where the number appears and the ring colour at 15 and 20 remaining; media with alt text; light theme; labelled post with media or a quote, in the post detail and on mobile; what the Schedule button does; a Scheduled list with a row. Needs a Chrome tab in the foreground. |
| 2.10 | Follow-up | Claude | TODO | De-duplicate the who-may-reply decision (`policyAllows`, `Post.Mentions`); remove the proto import from the posts domain layer; add a log field for degraded hints; the CreatePost response hint. |
| 2.11 | Follow-up | Claude | DONE (#259) | Ticket opened for the flaky `TestAccountLifecycle_RichAccountCrashAtEverySideEffect` (failed in a few local runs, green in CI every time). |
| 2.12 | Follow-up | Claude | TODO | Name the first reply-audience-enforcing release tag in `docs/runbooks/rollback.md` when it is cut (the "forward-only floor"). |
| 2.13 | Rollout | Both | WAIT | Ramp the three flags (`content_disclosure`, `reply_audience`, `scheduled_posts`): dev allowlist first (max 3 users), then prod through the normal release path. Only after the UI exists and 100% of traffic is on an enforcing revision. |
| 2.14 | Cleanup | Founder | TODO | Close the browser tab(s) that still hold test text or an open dialog (choose **Discard**, never Save), and delete the test post you published with both labels on `x.com/fan_of_ur_s` if you do not want it on your profile. |

---

## 3. Older work still open (from earlier sessions; status not re-verified in this session)

These come from the memory notes of earlier sessions. Claude should confirm each against `main` and update or delete it.

| # | Owner | Status | Task |
|---|---|---|---|
| 3.1 | Both | TODO | ADR-0020 accent-colour amendment (agenda of 2026-10-24). |
| 3.2 | Both | TODO | UI wave W1.5 capture session (post detail, composer modal states, another user's profile, light-theme gaps), then the W1.5 client plan. |
| 3.3 | Claude | TODO | W2 plan (bookmarks, share, alt text, quote UI, hashtag tap-through, push opt-in), with the bookmarks ADR from the architect. |
| 3.4 | Claude | TODO | UI W0 leftovers: the W0-10 flag and pixel goldens (deferred). |
| 3.5 | Both | TODO | Authenticated smoke path for prod releases (work packages WP1 to WP3; prod credentials were lost and need a reset). |
| 3.6 | Both | WAIT | v0.4.1 prod hotfix watch window to 2026-10-28. |
| 3.7 | Claude | TODO | Pending docs PRs from the ADR-0019 rollout (Accepted status, R4). |
| 3.8 | Claude | TODO | Plan items per `docs/plans/roadmap.md`: W3 (profiles), W4 (search and Explore), W5 (Lists and Communities), W6 remainder (polls, drafts, GIF), W7 (DMs), W8 (UI shells). Spaces are dropped. |
| 3.9 | Founder | TODO | Terms of Service: `docs/plans/phase1.md` says a draft is at `docs/legal/terms-of-service-DRAFT.md`, but that file does not exist. A ToS (with legal review) is needed before real users; decide who drafts it. |

---

## 4. Reference

- Credit facts: expires 2026-12-26; spend cap INR 23,000 (reserve INR 2,000), about INR 359 a day to 26 Dec or INR 371 a day to the 24 Dec pause; Firebase Blaze on a Google Cloud trial, free-tier-eligible services.
- Monthly cost after the credit (INR, before GST): paused 0 to 15; Stage 0 as configured 434 / 1,626 / 3,396 at 300 / 1,000 / 3,000 daily users; credit mode 1,371 / 2,873 / 8,127. Source: `docs/plans/credit-runway-cost-model.md`.
- Emergency levers, mildest first: `DEGRADED_MODE` (readonly or nomedia), remove the public `allUsers` invoker, last resort unlink billing. See `docs/runbooks/credit-sunset-pause-resume.md` and `docs/runbooks/cost-spike.md`.
- Key documents: `docs/adr/0021-*.md`, `docs/adr/0022-credit-funded-runway.md`, `docs/plans/composer-w15-w6.md`, `docs/plans/roadmap.md`, `docs/reviews/cost-model.md`, `docs/reviews/security-review-adr-0021.md`.

## 5. Recently done

- 2026-10-23: reply audience UI CMP-B3 merged (#256).
- 2026-10-23: `docs/pending.md` added (#255); 
- 2026-10-23: ADR-0021 accepted and merged (#242); proto contract (#243); scheduled TTL policy (#244); disclosure backend (#247); reply audience backend (#248); ADR-0022 accepted (#249); cost model re-priced (#250); `CLAUDE.md` credit mode and dated cost-hook marker (#251); Flutter service-paused screen (#252); credit-mode Terraform and the until-date CI check (#253); `CLAUDE.md` Stage 0 wording (#254).
