# Runbook: search and trends (ADR-0028)

Owner module: `backend/internal/search`. Plan: `docs/plans/ui-w4-discovery-search.md` (W4-9 refresh, W4-9b cron host, W4-10
GetTrends; the People and Posts sections arrive with W4-5 and W4-7). This file covers the **trends** half today.

Data: two documents. `trends/current` = `{schemaVersion 1, items [{tag, posts, authors}] (at most 100, rank order), windowStart,
watermark {at, id}, computedAt, postsScanned, backlog}`. Tags and counts only: **no uid** is stored (distinct authors are
counted in memory), so the collection has no eraser step and is not exported (`lifecycle_collections_guard_test.go` row
`trends`, `notPersonal`). `trends.items` is exempt from single-field indexing (fieldOverride, acknowledged in
`firebase/field-overrides.ack`). `trends/hidden` = `{schemaVersion 1, tags [folded key] (at most 100), updatedAt}` is the operator hide list (4.3): written only by `opsctl trends hide|unhide`, never by the sweep; it holds no uid and no actor, and has no index exemption (the 100-key cap keeps the automatic index small; a raise needs a `trends.tags` exemption, gate files). Same guard row `trends`. Client rules stay deny-all.

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
| Run inside `TRENDS_MIN_INTERVAL` (12 h) of the last list (`fresh`) | 1 (the document; the hide list is not read) | 0 |
| Run, nothing new | 2 + 1 (document, hide list, the empty page billed as 1) | 1 |
| Run, N new posts (N <= `TRENDS_MAX_POSTS_PER_RUN` 2,000) | 2 + N (document, hide list, one projected read per post) | 1 |
| Worst run | 2,002 | 1 |
| `GetTrends` cold / warm (instance copy, 10 min) | 3 / 0-1 (the interceptor's profile read counts in both; `trends/current` and `trends/hidden` are read together once per instance per 10 min, at most 864 a day at 3 instances) | 0 |
| `opsctl trends hide` / `unhide` | 1 (transaction) | 1 when the list changes, else 0 |
| `opsctl trends list` | 1 | 0 |

The protected set is read by the identity loader on its detached `protected_set_reads` counter, never charged to the run.
Budget assertions: `search/trends_integration_test.go` and `search/trends_hide_integration_test.go` (run 2 + N reads, 1 write; GetTrends 2 cold plus the interceptor's 1, 0 warm; fresh skip 1 read; kill switch 0; hide, unhide and list as above; `opsctl` in `cmd/opsctl/trends_integration_test.go`) and the `fs_reads` / `fs_writes` fields of the `trends_refresh` line.

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
- **Force a fresh window**: delete `trends/current` (console or an operator script). The next run starts at `now - 24h`. It leaves the hide list (`trends/hidden`) alone, which is why the list is a separate document. Safe: the document holds no user data and GetTrends answers an empty list until the next run (and for up to 10 min after the delete on a warm instance).
- **A wrong `computedAt`** (clock skew, a manual edit) makes `fresh` skip nights: delete the document as above.

### 4.3 An offensive, abusive or spam tag trends (fast removal)
Two levers, and a floor. The hide list needs no deploy and no console click (ADR-0028 note 2026-10-31, review M-1).

**Hide it now** (any time, prod included; the usual typed project id applies in prod):
```
opsctl trends hide '#the-tag' --project <project>      # quote the tag: an unquoted # starts a shell comment
opsctl trends list --project <project>                 # the hide list, folded keys, at most 100
opsctl trends unhide the-tag --project <project>
```
1. `hide` folds the tag into its key (`search.TrendKey`: NFKC, lower-case, the leading `#`, U+200C, U+200D and `_` removed), so `#Sl_u<ZWJ>r`, fullwidth letters and a decomposed spelling are all the key `slur`. It writes `trends/hidden` (1 read, 1 write; a repeat writes 0). It refuses an empty key, a key longer than 50 code points and a 101st key (unhide one first).
2. **When it is live:** GetTrends serves a copy that is at most 10 min old on each instance, so the tag leaves the list on every server within 10 min; Explore's client copy lives 5 min (`kTrendsClientTtl`), so on every screen within 15 min. The next nightly sweep drops it too. Nothing else to do; do not delete `trends/current`.
3. **Audit trail.** `hide` and `unhide` print one `audit:` line (project, UTC time, key, whether it wrote, list size). The document records no actor, so paste that line into the incident or report note. The key it prints is the operator's own input; do not paste post text.
4. **A variant keeps coming back** (a different spelling, a digit appended, a Cyrillic or Greek look-alike): the key folds only compatibility forms, joiners and `_`. Each homoglyph variant is its own key and costs one more `hide`. A ring that keeps changing the tag is the cue to raise `TRENDS_MIN_AUTHORS` (blunt) or to switch `FEATURE_TRENDS` off (section 6).
5. **Unhide** puts the tag back at the next list load (10 min) if it still qualifies. It is not remembered between hides.
6. **The list cannot be read** (`trends/hidden` read fails): GetTrends answers an error for new loads (and caches nothing) rather than serve an unfiltered list, and the sweep fails the run with nothing written. Look for Error Reporting `cron/trends-refresh` and `GetTrends` request lines with `code` not ok. A Firestore outage is the usual cause; nothing to repair.

**Deploy-time floor.** `TRENDS_DENYLIST` (Terraform variable `trends_denylist` in `envs/dev` and `envs/prod`, comma-separated tag bodies, default empty) is applied by GetTrends at serve time and by the sweep, with the same folding. A change is a prod release (ADR-0019) and applies on the new revision at once, with no wait for the next sweep. Use it for tags that should never trend; use `opsctl trends hide` for anything urgent.

**Other notes.**
- Sockpuppet rings of 3 or more accounts can still push a tag until it is hidden (ADR-0028, accepted residual; W4-26 raises the bar).
- Posts hidden by a moderator, REPOSTs and posts by protected authors are never counted; a protect after a run is reflected at the next run.
- The hide list is separate from `trends/current` on purpose: the sweep replaces `trends/current` whole, and 4.2's delete of it must not erase the list. Never put the list inside `trends/current`.
- Cost: GetTrends reads 2 documents per instance load (<= 864 a day at 3 instances), the sweep +1 read, each `hide` / `unhide` 1 read and at most 1 write.

### 4.4 Protected set unavailable
The step needs `identity.ProtectedAuthors`. When the loader cannot produce a trusted set (`PROTECTED_SET_MAX_STALE`, or it never loaded) the run fails closed with an Error Reporting entry and writes nothing; the watermark does not move, so the next run counts the same posts. Not an incident by itself; see `docs/runbooks/private-accounts.md` if it repeats.

### 4.5 `GetTrends` errors
- FEATURE_DISABLED `feature=trends`: the flag is off for that caller (0 reads).
- VALIDATION `field=limit` (negative) or `field=prefix` (a control or bidi character, or more than 50 code points after `#`): 0 reads. A limit above 30 is clamped.
- A Firestore error on the load (both documents are read together) is returned as INTERNAL and **not cached**; the next call retries. An unreadable hide list is never served as empty (4.3 item 6). Look for the request line with `code` not ok.

## 5. Calling the route in dev
Dev has no Scheduler jobs. With the production-deployer's opt-in grant (founder OK, removed afterwards) and an OIDC identity token for the push service account:
```
curl -X POST -H "Authorization: Bearer $(gcloud auth print-identity-token --audiences=<api URL>)" <api URL>/internal/cron/trends-refresh
```
Expect 204 and one `trends_refresh` (or `trends_skipped`) line. Locally, with the emulators, the integration tests drive the same code (`make test-int`).

## 6. Rollback and kill
- Kill the sweep: `FEATURE_TRENDS=off`, deploy. Kill the RPC for everyone: the same. No data migration.
- The `trends.items` index exemption is not additive: rolling back to a revision that never wrote `trends` is harmless (the collection is unused), and no query reads `items`.
