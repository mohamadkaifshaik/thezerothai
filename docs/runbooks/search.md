# Runbook: search and trends (ADR-0028)

Owner module: `backend/internal/search`. Plan: `docs/plans/ui-w4-discovery-search.md` (W4-9 refresh, W4-9b cron host, W4-10
GetTrends; the People and Posts sections arrive with W4-5 and W4-7). This file covers the **trends** half today.

Data: one document, `trends/current` = `{schemaVersion 1, items [{tag, posts, authors}] (at most 100, rank order), windowStart,
watermark {at, id}, computedAt, postsScanned, backlog}`. Tags and counts only: **no uid** is stored (distinct authors are
counted in memory), so the collection has no eraser step and is not exported (`lifecycle_collections_guard_test.go` row
`trends`, `notPersonal`). `trends.items` is exempt from single-field indexing (fieldOverride, acknowledged in
`firebase/field-overrides.ack`). Client rules stay deny-all.

## 1. How it runs
| Where | Route | Who calls it | Status |
|---|---|---|---|
| Prod (F1 = B) | `POST /internal/cron/daily-maintenance` | Cloud Scheduler, 03:00 UTC (the ADR-0011 job, unchanged) | the **backstop's** status only: 204, or 500 so Scheduler retries the backstop |
| Dev, or an hourly job later (F1 = A) | `POST /internal/cron/trends-refresh` | a direct OIDC call (dev has no Scheduler jobs) | 204; 500 only when nothing could be written (the document read, the first page or the protected set failed) |

`daily-maintenance` is the wrapper in `apiserver/daily_maintenance.go`: the backstop runs first under its own 25 s deadline,
then the trends step gets `min(10 s, 28 s - elapsed)` and is **skipped** (`trends_skipped reason=deadline`) when under 3 s are
left. Scheduler's attempt deadline is 30 s (the module default, equal to Cloud Run's request timeout), so 28 s leaves 2 s of
margin. A trends error, panic or skip is logged and reported to Error Reporting and **never** changes the status: Scheduler
retries the backstop, not the sweep. A Scheduler retry minutes after a good run skips trends as `fresh`.

## 2. Reads and writes
| Case | Reads | Writes |
|---|---|---|
| Run, flag globally off or `DEGRADED_MODE=readonly` | 0 | 0 |
| Run inside `TRENDS_MIN_INTERVAL` (12 h) of the last list (`fresh`) | 1 (the document) | 0 |
| Run, nothing new | 1 + 1 (the empty page is billed as 1) | 1 |
| Run, N new posts (N <= `TRENDS_MAX_POSTS_PER_RUN` 2,000) | 1 + N (one projected read per post) | 1 |
| Worst run | 2,001 | 1 |
| `GetTrends` cold / warm (instance copy, 10 min) | 2 / 0-1 (the interceptor's profile read counts in both; the document is read once per instance per 10 min, at most 432 a day at 3 instances) | 0 |

The protected set is read by the identity loader on its detached `protected_set_reads` counter, never charged to the run.
Budget assertions: `search/trends_integration_test.go` (run 1 + N reads, 1 write; GetTrends 1 cold, 0 warm; fresh skip 1 read;
kill switch 0) and the `fs_reads` / `fs_writes` fields of the `trends_refresh` line.

## 3. Log lines (no uid, no tag text beyond counts)
- `trends_refresh` (INFO): `trends_posts_scanned`, `trends_tags` (counted), `tags_kept`, `backlog`, `fs_reads`, `fs_writes`, `duration_ms`, `outcome=ok`.
- `trends_skipped` (INFO): `reason` = `flag_off` | `readonly` | `fresh` | `deadline`, plus `fs_reads` / `fs_writes` (except `deadline`, which never started).
- `trends_backlog` (WARN): the cap was reached with posts left; the next run resumes. `trends_backlog_skipped` (WARN): a watermark older than 48 h was dropped.
- Error Reporting entries: operation `cron/trends-refresh` (the refresher; a failure that wrote nothing, or a later-page failure that wrote a partial list) and `cron/daily-maintenance/trends` (a panic in the step).
- `GetTrends` request line: `results`, `cache_hit`, `computed_age_s` (-1 when there is no list), `fs_reads`.

## 4. Failure modes
### 4.1 The list is stale or missing ("Trending today" never changes)
1. `FEATURE_TRENDS` is `off` on the revision: the step logs `trends_skipped reason=flag_off` every night. Only `off` stops the sweep; percent 0 or an empty allowlist is a rollout and the sweep still runs. GetTrends itself is per caller, so it answers FEATURE_DISABLED to callers outside the rollout.
2. `DEGRADED_MODE=readonly`: `reason=readonly`. The list freezes and GetTrends keeps serving the last one.
3. Scheduler did not call the route (job paused, OIDC audience wrong): no `trends_refresh` or `trends_skipped` line at all that night. Check the `daily-maintenance` job and the `account_job backstop` line first; trends rides on it.
4. The backstop takes more than 25 s (`reason=deadline`): trends is skipped that night and resumes from its watermark the next. Repeated deadline skips mean the backstop is doing real work (stuck deletions): fix that first (`docs/runbooks/account-deletion.md`). Optional follow-up: give the job `attempt_deadline_seconds = 60` (prod Terraform, plan-then-OK).
5. Volume is low: fewer than 3 distinct authors on any tag in a day is an **empty list by design**, not a failure. `trends_tags` > 0 with `tags_kept` = 0 shows it.
6. A tag shows up to one sweep interval plus 10 min late (daily + the instance copy).

### 4.2 Stuck watermark
Symptoms: `trends_backlog` for 7 runs in a row, or `trends_skipped reason=fresh` on a night the list should have refreshed, or a `computedAt` that never moves.
- **Backlog** (more than 2,000 posts a day, about 2,000 DAU): each run reads at most 2,000 posts and resumes the next night from the watermark, so the list only ever reflects the latest chunk and the sweep falls behind. A backlog run is never skipped as `fresh`, so calling the standalone route repeatedly (dev, or an operator with an OIDC token) drains it. Stage-ladder trigger: go hourly (F1 A: a third Scheduler job, `TRENDS_MIN_INTERVAL` 50 min, Terraform only) or raise `TRENDS_MAX_POSTS_PER_RUN` (reads are 1 per post, so it is a cost decision).
- **Too old** (watermark older than 48 h, a sweep that was down): the next run drops it to `now - 24h` and logs `trends_backlog_skipped`. The posts in between are not counted on purpose, so a week-old list is never shown as "today". Nothing to repair.
- **Force a fresh window**: delete `trends/current` (console or an operator script). The next run starts at `now - 24h`. Safe: the document holds no user data and GetTrends answers an empty list until the next run (and for up to 10 min after the delete on a warm instance).
- **A wrong `computedAt`** (clock skew, a manual edit) makes `fresh` skip nights: delete the document as above.

### 4.3 Denylist (an offensive or spam tag trends)
1. Add the tag body, without `#`, to `TRENDS_DENYLIST` (comma-separated; trimmed, lower-cased, a leading `#` tolerated) in the `cloud-run-api` Terraform variables and deploy. It applies at the next run.
2. To remove it **now**, also delete `trends/current` (or wait for the next run); a warm instance serves its copy for up to 10 min.
3. Sockpuppet rings of 3 or more accounts can still push a tag until it is denylisted (ADR-0028, accepted residual). Raising `TRENDS_MIN_AUTHORS` is the blunt lever.
4. Posts hidden by a moderator, REPOSTs and posts by protected authors are never counted; a protect after a run is reflected at the next run.

### 4.4 Protected set unavailable
The step needs `identity.ProtectedAuthors`. When the loader cannot produce a trusted set (`PROTECTED_SET_MAX_STALE`, or it never loaded) the run fails closed with an Error Reporting entry and writes nothing; the watermark does not move, so the next run counts the same posts. Not an incident by itself; see `docs/runbooks/private-accounts.md` if it repeats.

### 4.5 `GetTrends` errors
- FEATURE_DISABLED `feature=trends`: the flag is off for that caller (0 reads).
- VALIDATION `field=limit` (negative) or `field=prefix` (a control or bidi character, or more than 50 code points after `#`): 0 reads. A limit above 30 is clamped.
- A Firestore error on the one document read is returned as INTERNAL and **not cached**; the next call retries. Look for the request line with `code` not ok.
- RATE_LIMITED with `limit_name` `trends_daily` (W4-28): one uid made more than `TRENDS_CALLS_PER_DAY` (default 400 per instance, so up to 1,200 a day at 3 instances) GetTrends calls in an IST day; 0 reads. The typeahead and the `TrendsCubit` handle it quietly. A heavy honest user normally stays far below it (about 300 typeahead bursts + 100 loads); a user who hits it repeatedly is a scripted account (check `abuse-spike.md`). The cap is per instance and lost with it; raise it with the env var, not by code. The 60/min bucket is unchanged.

## 5. Calling the route in dev
Dev has no Scheduler jobs. With the production-deployer's opt-in grant (founder OK, removed afterwards) and an OIDC identity token for the push service account:
```
curl -X POST -H "Authorization: Bearer $(gcloud auth print-identity-token --audiences=<api URL>)" <api URL>/internal/cron/trends-refresh
```
Expect 204 and one `trends_refresh` (or `trends_skipped`) line. Locally, with the emulators, the integration tests drive the same code (`make test-int`).

## 6. Rollback and kill
- Kill the sweep: `FEATURE_TRENDS=off`, deploy. Kill the RPC for everyone: the same. No data migration.
- The `trends.items` index exemption is not additive: rolling back to a revision that never wrote `trends` is harmless (the collection is unused), and no query reads `items`.
