# Profile edit + author-snapshot refresh job (Phase 1 slice P2)
Plan owner: backend (resumed 2026-10-11) · Stage 0 ($0) · Flag: `FEATURE_PROFILE_SNAPSHOT` (wire name `profile_snapshot`, default OFF everywhere)
Inputs: CLAUDE.md, `docs/plans/phase1.md` P2, ADR-0003 ("Author snapshot refresh", "Quotas"), ADR-0011 (shared `jobs` topic),
`backend/internal/identity/{service,lifecycle_jobs}.go`, `backend/internal/posts/snapshot.go`.

## Goal
A display-name edit or a handle rename shows up on the author's newest 100 posts within the 60 s cache bound,
without any write fan-out on the request path.

## Design (no proto change, no new infra)
- `UpdateProfile` / `ChangeHandle` bump `users/{uid}.snapshotVersion` **in the same write** as the edit (unconditional).
- After the commit, with the flag on for the caller, a best-effort `profile_snapshot_refresh` message goes to the existing
  shared `jobs` topic (P8, ADR-0011). Publish failure is logged and never fails the RPC.
- The P8 jobs handler dispatches the new kind: re-read the profile, call `identity.SnapshotWriter` (adapted to
  `posts.FirestoreRepo.RefreshAuthor` in `apiserver/profile_snapshot_wiring.go`), ack. Replay-safe: posts whose
  `snapshotVersion >= version` are skipped, so a duplicate delivery writes 0.
- Display-name edits spend one of `QUOTA_SNAPSHOT_EDITS_PER_DAY` (default 5, ADR-0003) on `quotas/{uid}.snapshotEdits`
  (same IST day). Handle changes are bounded by the 7-day cooldown and do not spend it.
- Flag off: no quota reservation, no message; a delivered message is acked without work. The version bump still rides the
  write, so turning the flag on heals posts at the next edit.
- Avatar stays rejected until P4.

## Tickets
| ID | Ticket | Owner | Status |
|---|---|---|---|
| P2-T1 | `snapshotVersion` bump in UpdateProfile/ChangeHandle, `SnapshotEdits` quota kind, config + flag | backend | Done (this PR) |
| P2-T2 | `posts.RefreshAuthor` (newest 100, version skip, field-path updates) | backend | Done (this PR) |
| P2-T3 | Job kind + dispatch in the P8 handler, flag gate, wiring | backend | Done (this PR) |
| P2-T4 | Unit tests (fakes) + emulator integration test with budget assertions | tester | Done (this PR) |
| P2-T5 | Flutter Edit profile + Change handle screens (RPCs exist; no UI) | frontend | Open (follow-up PR; widget test per screen) |
| P2-T6 | Terraform env vars `FEATURE_PROFILE_SNAPSHOT*` per env (default in code is off, so not required to ship) | deployer | Open (rollout: dev on, prod allowlist) |

## Worst-case Firestore reads/writes
| Path | Reads | Writes |
|---|---|---|
| UpdateProfile (flag off) | unchanged from pre-P2 (1 cold / 0 warm profile) | 1 |
| UpdateProfile, display name changed (flag on) | +1 (`quotas/{uid}`) | +1 (quotas); 2 total; + 1 Pub/Sub publish |
| ChangeHandle (flag on) | unchanged | unchanged (+1 Pub/Sub publish) |
| `profile_snapshot_refresh` job delivery | 1 profile (+1 if cold) + <= 100 post reads (`Select("snapshotVersion")`, `Limit(100)`; 1 if none) | <= 100 (one batch); replay 0 |

Index: reuses `posts (authorId ASC, createdAt DESC)`. No new index.

## Cost line
$0. At 0.02 snapshot edits/DAU, 300 DAU: <= 6 jobs/day x <= 101 reads and <= 100 writes = <= 606 R / 600 W per day
(about 1% of the read and 3% of the write free quota). Pub/Sub: negligible against 10 GiB.

## Decisions (delegated 2026-10-10)
1. **Reuse the P8 `jobs` topic**, a new `kind` in `JobMessage`; no new topic, subscription or DLQ.
2. **Flag `FEATURE_PROFILE_SNAPSHOT`, default OFF**; UpdateProfile/ChangeHandle themselves are not gated.
3. **Trigger after commit, best effort** (publish timeout 2 s, `context.WithoutCancel`); no outbox. A lost message
   leaves the old snapshot until the next edit (ADR-0003 accepts this at Stage 0).
4. **Version-based idempotency** (`snapshotVersion` skip) rather than an idempotency doc for the job.
5. **Only the newest 100 posts** are refreshed (ADR-0003); older posts keep the old snapshot.
6. **Instance caches are not evicted**; staleness is bounded by the 60 s TTL.
7. **Flutter screens split to a follow-up ticket (P2-T5)** so this PR stays backend-only and generated Dart is untouched.
