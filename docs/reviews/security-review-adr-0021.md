# Security review: ADR-0021 composer extras (reply audience, content disclosure, scheduled posts)

- **Date:** 2026-10-23
- **Scope:** `docs/adr/0021-composer-extras-reply-audience-disclosure-scheduling.md` (Status: Proposed) on branch `docs/composer-w15-w6-plan`, checked against the current code: `backend/internal/posts`, `graph`, `identity` lifecycle, `apiserver`, `pkg/platform/{pubsubpush,quota,ratelimit,config}`, `firebase/firestore.rules`, `infra/terraform/modules/{iam,scheduler}`, `envs/{dev,prod}/main.tf`, `proto/`. Plan input: `docs/plans/composer-w15-w6.md`.
- **Reviewer:** `security-auditor` agent. Design review only; no code exists yet for the new RPCs or the sweep.
- **Provenance:** the auditor had no file-write tool, so the parent session saved its report here verbatim in substance. The parent re-verified M-2's library claim (`golang.org/x/sync@v0.24.0/errgroup/errgroup.go` does not propagate goroutine panics, and `identity/lifecycle_jobs.go:474-496` has no recover in the worker). The other citations were not independently re-checked.
- **Labels:** **[code]** = confirmed in the current code. **[ADR]** = inferred from the ADR text about code not yet written.
- **Verdict:** **APPROVE WITH CHANGES.** 0 Critical, 0 High, 2 Medium, 9 Low, 7 Info. Before the ADR is Accepted its text must change as listed in "Required before acceptance".

## STRIDE summary

| Threat | Controls in the ADR / code | Residual |
|---|---|---|
| Spoofing | Firebase ID token plus the verified-identity and account-status interceptors on the 3 new RPCs. The sweep route uses `protectInternal`: `idtoken.Validate` with audience = run.app URL, then an email allowlist (`pubsubpush.go:40,46`). Config refuses to start without these outside `ENV=local` (`apiserver.go:401-407`). | App Check is monitor-only (I-2). The verifier allowlist is not per route (I-1, L-5). |
| Tampering | Scheduled docs live at `users/{caller}/scheduled/{id}`, a path built from the token uid. Publish is one transaction that requires PENDING. Media is re-validated at publish (owner, READY, unattached). Reply policy is server-set and inherited. | Sweep state writes must not use `Set` (L-7). |
| Repudiation | One `scheduled_sweep` log line per run, and Error Reporting on INTERNAL. | Fine for Stage 0. |
| Information disclosure | Visibility is checked before policy. The FOLLOWING answer matches public `ListFollowing`. Draft text is never logged. | Root-author block oracle (M-1). Drafts retained (L-2). Pre-publish images public (L-9). |
| Denial of service / cost | Limits of 25 pending, 50 per day, 10/min. The sweep handles at most 100 items per run, with 0 reads when off or degraded. The posts quota is charged at publish. | Worker panics (M-2). Fairness (L-3). Reads outside the read budget (L-4). |
| Elevation | No new admin path. Firestore rules stay deny-all with `{document=**}`, which covers the subcollection **[code]**. | none |

## Confirmed sound (no finding)

- **IDOR:** Cancel and List can only reach `users/{caller}/scheduled`. A foreign or guessed 32-hex id is simply a missing doc, so NOT_FOUND. The id hash `SHA-256(uid|"SchedulePost"|key)` cannot collide across users or be confused by separators: a uid matches `^[A-Za-z0-9-]+$` and the key `[A-Za-z0-9_-]`.
- **Read budget:** the per-user read budget covers new procedures automatically, and its exemption lists must stay empty (`ratelimit_config.go`, enforced by `guard_test.go`) **[code]**.
- **Exactly-once publish:** re-reading the scheduled doc inside the transaction, requiring PENDING, and committing PUBLISHED in the same commit is serializable. Cancel and publish race safely.
- **No user-doc recreation:** `AddPostsCount` is a field `Update` with an implicit Exists precondition (`identity/repo_firestore.go:441-443`) **[code]**. A publish for a purged account fails instead of recreating `users/{uid}`.
- **Indexes:** the new indexes and TTL entry are server-only. Rules stay deny-all.
- **Scheduler identity:** the job reuses the pubsub-push SA, which holds only `run.invoker` (`iam/main.tf:102-111`, `cloud-run-api/main.tf:150`) **[code]**.

## Findings

### Medium

**M-1. A deep reply in a restricted conversation can reveal that the root author blocked you.** [code + ADR]
- **Where:** ADR section D2 "Enforcement" and "Who may reply". Code: `posts/service_delete.go:157-216` (`viewable`) and `posts/service_engagement.go:51-69` (`resolveTarget`).
- **What the code does:** `viewable` checks only whether the *parent's* author (and an embedded author) blocks the caller. It never checks the conversation root's author.
- **What the ADR claims:** "A blocked caller never sees REPLY_NOT_ALLOWED". That holds only for direct replies to the root.
- **Scenario:**
  - Alice posts root R as MENTIONED_ONLY and mentions Mallory. Later she blocks Mallory.
  - Mallory replies to Bob's reply inside R's conversation. Bob's reply is visible to her, so the visibility check passes.
  - The new rule (`snapshot.BlockedBy[R.AuthorID]`) refuses her with PERMISSION_DENIED / REPLY_NOT_ALLOWED and `metadata["policy"]`.
  - Mallory knows she is mentioned (the post text, or her notification). A mentioned caller is otherwise always allowed, so this answer means "Alice blocked me".
  - The ADR does not say what code "R is gone" returns. If it is NOT_FOUND, the two cases are told apart directly. That breaks ADR-0008 D4.
- **Fix (ADR text):** define "R usable" with the same predicate as `threadContext` (`service_thread.go:204-225`): R exists, is public and not hidden, and its author is ACTIVE; R's author does not block the caller, and the caller does not block R's author; a `blockedByOverflow` counts as not usable. When R is not usable, return the single NOT_FOUND "post not found" answer (the same thing GetThread already shows as `root_unavailable`, so it reveals nothing new). Evaluate the policy and return REPLY_NOT_ALLOWED only once R is usable. Add "mentioned + blocked by root author -> NOT_FOUND" and "R hidden/suspended -> NOT_FOUND" to the policy test matrix.

**M-2. A panic in a sweep worker crashes the whole instance, and the poison item never retires.** [code for the pattern, ADR for the new code]
- **Where:** ADR "Sweep" step 2 ("an errgroup ... as the backstop does") and step 3 "Errors". ADR D1 "panic recovery".
- **What the code does:**
  - The backstop runs `errgroup.Group.Go` with no recover inside the goroutine (`identity/lifecycle_jobs.go:474-496`).
  - Route-level `recoverPanic` (`lifecycle_jobs.go:95-106`) only covers the handler's own goroutine.
  - The pinned `golang.org/x/sync` v0.24.0 errgroup deliberately does **not** pass a goroutine panic on to `Wait()` (`errgroup.go:81-91`). An unrecovered panic in a worker ends the process. (Re-verified by the parent session.)
- **Scenario:**
  - One scheduled doc makes the CreatePost draft builder panic, for example an unexpected shape in `draft.media`, or a parser edge case on text that passed an older rule set.
  - Every 5 minutes the sweep crashes the Cloud Run instance. That also kills up to 80 unrelated user requests in flight on it.
  - `attempts` is never incremented, so the 3-attempt limit never fires.
  - The item stays PENDING until the 6 h EXPIRED rule, but only if expiry is checked before the panicking step. That is roughly 72 crashes.
  - The ADR's claim "a poison item cannot block the head of the queue for more than 3 runs" is false for panics.
- **Fix (ADR text):**
  - Every per-item goroutine runs `defer recover()`. A recovered panic marks the item FAILED `INTERNAL` in a transaction that requires PENDING, and calls `mw.ReportError` with the panic type only.
  - Each item gets its own context, so one failure does not cancel the others. Do not use `errgroup.WithContext` cancellation.
  - Bookkeeping writes (`attempts++`, FAILED) use a short context detached from the run deadline (`context.WithoutCancel` plus about 3 s), so an item that times out at the 25 s limit can still be counted.
  - Add a test that a panicking item becomes FAILED `INTERNAL` and the process survives.

### Low

**L-1. A pre-ADR revision serving canary traffic silently drops `reply_policy` and the disclosure labels.** [ADR + proto3 behaviour]
- **Where:** ADR "Rollout". Consequences covers rollback, but not a traffic split.
- **Scenario:** during a 10%/90% split, GetMe (new revision, flag on) lists `reply_audience`; the user's CreatePost lands on the old revision, which drops field 7 as unknown; the user believes they limited replies, but the post is open to everyone. That is a harassment control failing silently.
- **Fix:** flip `FEATURE_REPLY_AUDIENCE` and `FEATURE_CONTENT_DISCLOSURE` only after 100% of traffic is on a revision that enforces them. Client: compare the echoed `Post.reply_policy` and labels with what was sent, and warn on a mismatch.

**L-2. Draft text is kept in PUBLISHED/CANCELLED docs for 7 days, and is not exported.** [ADR]
- **Where:** ADR "Firestore model" (`draft`, `expireAt`) and "Right to delete" item 3.
- **Scenario:** a user publishes through the sweep and then deletes the post. The text and media refs stay in `users/{uid}/scheduled/{id}.draft` for 7 days, and the export leaves them out. The ADR's "PUBLISHED items are already exported under posts" stops being true once the post is deleted. CANCELLED drafts are also user content that the export leaves out.
- **Fix:** clear `draft` in the transaction that enters PUBLISHED or CANCELLED. Keep only status, `postId`, `requestHash` and timestamps, which is enough for replay and for "too late". Only FAILED keeps the draft, because reschedule is offered only from FAILED. The export section then covers every doc that still holds a draft.

**L-3. The sweep has no per-author limit, so posts arrive in bursts and one author can fill the queue.** [ADR]
- **Where:** ADR "Sweep" step 2, "Lateness", abuse table row 2.
- **Scenarios:** (a) a user schedules 25 posts for the same minute; all 25 land at once and sidestep the 10/min CreatePost bucket, which is never applied at publish. (b) About 70 verified sock-puppet accounts x 25 items at one minute is about 1,750 items, which takes about 18 runs; other users' posts that minute are delayed by about 1.5 h, and around 290 accounts would push legitimate items past the 6 h EXPIRED limit. (c) The 4 workers can publish for the same author at once and contend on `quotas/{uid}` and `users/{uid}`.
- **Fix:** at most `SCHEDULED_PER_AUTHOR_PER_RUN` (for example 3) items per author per run, the rest wait for the next tick; never run two items of the same author at once; optionally cap the pending items due in any single minute per user.

**L-4. Publish reads fall outside the per-user read budget, checks are ordered expensive-first, and there is no new-account schedule cap.** [code + ADR]
- **Where:** ADR D1 (`budget.WithCounter`, "never charged to a user's ADR-0010 D5 budget"), D4 Limits, Sweep "Checks that re-run at publish".
- **Scenario:** the per-user read budget defaults to 2,000 per day (`config.go:141-148,579`) [code]. Each account can push 50 x up to 17 = 850 reads per day through the sweep, outside that budget. New accounts get 50 schedules per day but only 20 posts per day. Items bound to fail QUOTA_EXCEEDED still pay for up to 10 handle reads and 4 media reads first, because the ADR orders the checks text, mentions, quota. In money terms this is small (about $0.05 per 100 accounts per day) but it is a lever outside the per-user budget.
- **Fix:** per item, run cheapest and most decisive first: expiry, then account status, then quota (1 read), then media, then mention resolution. Add `SCHEDULED_PER_DAY_NEW_ACCOUNT` (for example 10) to match the other new-account quotas. Log `fs_reads` per author when it exceeds a threshold.

**L-5. The dev `serviceAccountTokenCreator` grant on the shared pubsub-push SA is broader than needed.** [code]
- **Where:** ADR D1 "Testing in dev" and Handoff production-deployer.
- **Why it matters:** the verifier allowlist is not per route (`pubsubpush.go:46`, `apiserver.go:408-416`). A token minted for `publish-scheduled` is also accepted by `/internal/pubsub/jobs` and `/internal/pubsub/notifications-fanout`. The fan-out handler takes `actorId` and `recipientIds` from the message body (`notifications/fanout.go:30-60`) [code], so stolen founder gcloud credentials could forge notifications and real FCM pushes to dev testers. `TokenCreator` also grants `getAccessToken`, `signBlob` and `signJwt`, which this curl does not need.
- **Fix:** grant `roles/iam.serviceAccountOpenIdTokenCreator` instead (only `getOpenIdToken`), on the dev SA only, with an IAM condition `request.time < <date>` (for example 30 days). Never grant it in prod. Longer term (see I-1): a separate `cron-invoker` SA, allowlisted only on `/internal/cron/*`.

**L-6. SchedulePost replay must be checked before the time and cap checks, and `requestHash` must hash normalised values.** [ADR]
- **Where:** ADR D4 "Idempotency", "Time" and "Limits", and "CreatePost requestHash".
- **Scenario:** a client retries a lost SchedulePost response 3 minutes later. The `now + 2 min` lead check, the pending cap or the daily cap now rejects it, and the client gets VALIDATION or LIMIT_REACHED instead of the stored item. The user re-schedules with a new key, and a duplicate post publishes, which is what rule 4 exists to prevent. Separately: if `EVERYONE` (1) is not normalised to `UNSPECIFIED` before hashing, a retry that sends 0 and then 1 gets IDEMPOTENCY_KEY_REUSED. If `publish_at` is hashed before truncation, retries can differ too.
- **Fix:** order: key format, then read the scheduled doc, then a matching hash returns the stored item, and only then the lead/horizon checks, the count, and the quota. Hash the *effective* values: the truncated `publish_at`, the policy with EVERYONE stored as absent, and never the policy a reply inherits. Treat the CancelScheduledPost `idempotency_key` as unused but still format-validated.

**L-7. Sweep writes need preconditions, the status re-check timing must be stated, and the collection-group path must be checked.** [code + ADR]
- **Where:** ADR Sweep step 3 (author status, "missing -> CANCELLED", Errors) and "Firestore model" (collection group `scheduled`).
- **Risks:** (a) if "DELETING or missing -> CANCELLED" is written with `Set`/merge after the `scheduled` eraser has run, it recreates a doc under a purged user, residue outside ADR-0011 Q10. (b) The settle and start-gate argument only holds while each item reads status immediately before its own 5 s transaction. Code: `repo_create.go:36`; `opsctl/moderation.go:37` settle wait = 60 s cache + 15 s = 75 s; start gate 120 s. If status were read once per run, a commit up to 25 s later could land after the 75 s settle pass, and a suspended user's post would stay visible. (c) A collection-group query matches any collection named `scheduled` at any depth.
- **Fix:** every sweep state change is a transaction that reads the doc and requires it to exist and be PENDING; never `Set`. Read account status per item, immediately before its transaction. Better: read `users/{uid}.status` inside the publish transaction (+1 read per publish, about 0.05 reads per DAU), so a concurrent suspension or deletion conflicts and the guarantee is exact. Accept only refs shaped `users/{uid}/scheduled/{id}` with a valid uid, take the uid from the path, and skip and log anything else.

**L-8. Sweep errors must go through `ScrubErr`.** [code]
- **Where:** ADR Sweep "Errors" (`mw.ReportError` on INTERNAL) and the "Logging" item.
- **Risk:** Firestore errors carry `documents/users/<uid>/scheduled/<id>`. One sweep request touches many users, so `RedactErr(err, uid)` for a single uid is not enough. Same class as M-2 in `security-review-account-lifecycle.md`.
- **Fix:** route every error that leaves the sweep through `logger.ScrubErr`. Log panic types only. Add a test with two uids in a Firestore-shaped error.

**L-9. Scheduled images are publicly reachable for up to 60 days before publish.** [code + ADR]
- **Where:** ADR "Firestore model" "Media". The public object path is `m/<mediaId>.<ext>` (`lifecycle_collections_guard_test.go:107`) [code].
- **Risk:** an image for an announcement scheduled 60 days ahead is publicly fetchable before release by anyone holding or guessing the Snowflake-named URL. It also cannot be reported, because no post exists yet.
- **Fix:** state in the ADR and the client copy that images in a scheduled post are uploaded now and reachable by link. Revisit the private-until-attach option in an ADR-0005 amendment if embargoes matter.

### Info

- **I-1. OIDC verifier hardening.** [code] `idtoken.Validate` (`google.golang.org/api` v0.304.0 `idtoken/validate.go:142-161`) checks the signature against Google's keys, the audience and the expiry, but not `iss`. `pubsubpush.go` checks neither `iss` nor `email_verified`. Not exploitable today: only Google can sign, and IAP-style audiences cannot equal the run.app URL. Suggest checking `iss` in {accounts.google.com, https://accounts.google.com} and `email_verified == true`, and a per-route allowlist (cron routes accept only a scheduler SA). Tokens last 1 h and are not tied to a route; replay is harmless here because of the PENDING guard.
- **I-2. App Check is in monitor mode** in both envs (`envs/dev/main.tf:261`, `envs/prod/main.tf:253`) [code]. The ADR's Authz bullet and abuse table should not list it as an enforcing control.
- **I-3. The soft pending cap's real bound.** [code] The CreatePost bucket is a per-instance in-memory limiter (`ratelimit_config.go`), so the overshoot bound is bursts across up to 3 instances, still capped by 50 per day. Acceptable. `quota.CheckAndReserveN` `Set`s the whole record (`quota.go:172-178`): any revision without the new `Schedules` field (canary or rollback) resets `schedules` on its next quota'd call. That is bounded by the pending cap; state it.
- **I-4. FOLLOWING refusals.** "Equivalent to public `ListFollowing`" holds only while following lists stay public. The private-accounts ADR must revisit both the refusal and `viewer_reply_permission`.
- **I-5. Mentions resolved at publish.** If a mentioned user renames and someone else claims the old handle before publish, the claimant gets the mention notification and MENTIONED_ONLY reply rights. Accept as on X, or warn in the Scheduled list. Do not store uids in the draft (the ADR rightly avoids that residue).
- **I-6. REPOST rows and disclosure labels.** A REPOST row is a root post without its own policy. The timeline hint must use `embedded.replyPolicy`, or return UNKNOWN; otherwise ALLOWED is shown and the server refuses. `EmbeddedPost` has no mentions, so MENTIONED_ONLY repost rows are UNKNOWN. The client must render disclosure labels on the content they belong to (the quoter's vs the quoted post's).
- **I-7. Pin the scoping with tests.** The ADR says this already; make it tests. Cancel and List build the path from the token uid and never look up an id through the collection-group index. The List cursor is HMAC-bound to `scheduled|<uid>`, the same way as `threadBinding`.

## Required before acceptance (ADR text changes)

1. **M-1:** define "R usable" with the `threadContext` predicate. Every unusable R, including a block by R's author or a `blockedByOverflow`, returns the single NOT_FOUND. REPLY_NOT_ALLOWED comes only after that. Fix the "never sees REPLY_NOT_ALLOWED" claim and extend the test matrix.
2. **M-2:** per-item `recover` leading to FAILED `INTERNAL` with a PENDING precondition; per-item contexts with no group cancellation; bookkeeping writes on a detached short context; correct the "3 runs" claim; add a panic test.
3. **L-1:** rollout rule: enable the reply-audience and disclosure flags only once 100% of traffic is on an enforcing revision. Client checks the echoed fields.
4. **L-2:** clear `draft` on PUBLISHED and CANCELLED; the export covers every doc that still holds a draft.
5. **L-3 / L-4:** a per-author cap per run, with one author's items never processed concurrently; per-item check order expiry, status, quota, media, mentions; `SCHEDULED_PER_DAY_NEW_ACCOUNT`.
6. **L-5:** replace the dev grant with `roles/iam.serviceAccountOpenIdTokenCreator`, time-bound by an IAM condition, dev only.
7. **L-6:** replay lookup before the time and cap checks; hash the effective values (truncated `publish_at`, EVERYONE normalised to absent).
8. **L-7 / L-8:** all sweep writes are precondition transactions, never `Set`; status read per item (preferably inside the transaction); path-shape check on collection-group results; `ScrubErr` on every sweep error.

The other Lows and Infos can be noted in the ADR and handled in implementation and review.
