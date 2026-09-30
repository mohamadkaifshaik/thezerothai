# 0009. Unfollow no-op: close review item N4 with a documented invariant, not an extra read
Status: Accepted (2026-09-30)
Date: 2026-09-30
Deciders: architect, founder (accepted 2026-09-30)

Inputs: `docs/reviews/graph-code-review.md:69-71` (N4), ADR-0008 (D3, D10, A2, B1), `docs/plans/graph.md` (T7, T27),
PR #58 (`feat/graph-t27-lazy-cleanup`, open). Line numbers are for `origin/main` at `bf81b23` (after PR #59 and #60).

## Context
`FirestoreRepo.Unfollow` commits one blind batch: `Delete(follows/{a}_{b}, Exists)`, `ArrayRemove` on
`graph/{a}.following`, and two `users` counter `Update`s (`repo_firestore.go:350-358`). Any `NotFound` or
`FailedPrecondition` on commit is treated as "wasn't following": it returns `(false, nil)`, 0 writes
(`repo_firestore.go:368-372`, `431-434`), and the RPC answers NONE (`rpcs.go:99-108`). N4 is the case where that no-op
answer is wrong: the caller still has the target in `following` and can never unfollow. Detecting it needs a read,
and the documented Unfollow budget is 0 reads in the batch, 3 writes, 1 delete (ADR-0008 A2 table line 470, B table
line 636). The same budget appears in `graph.proto:37-41`, the `firestore-data-model` skill (row "Unfollow") and
`docs/plans/graph.md:99,405,409`.

The review wording is wider than "edge missing". `isPreconditionFailed` cannot tell which op failed, so there are two
stuck states:
- **S1.** `follows/{a}_{b}` is missing while `b ∈ graph/{a}.following`. The `Exists` delete fails.
- **S2.** The edge and the array entry both exist, but `users/{b}` (or `graph/{a}`) is missing. The counter `Update`
  fails with NotFound (`identity/repo_firestore.go:398-404`: plain `Update`, which requires the doc to exist). The
  review's example is this one.

Stage 0: 0 to ~300 DAU, $0 target. Unfollow is 0.1 calls/DAU/day. The released scope (identity + graph) is 20.4
reads/DAU and runs out of free reads at about 2,450 DAU. The whole product, with planned rows, is about 191 reads/DAU
and is already past the free line at about 262 DAU (`cost-model.md` §3).

### (1) Is the state reachable? Not through any API path. Only through ops deviations.
Every writer of `follows/*` and `following[]`, and why each keeps ADR-0008 invariant 1 (edge ⇔ array entry) for a
caller who can reach Unfollow:

| Writer | Edge op | `following` op | Atomic? | Code |
|---|---|---|---|---|
| Follow | `Create` | `ArrayUnion` | Same transaction, which also reads the caller graph fresh | `repo_firestore.go:259-322` (writes 308-314) |
| Unfollow | `Delete, Exists` | `ArrayRemove` | Same batch. A failure writes nothing | `repo_firestore.go:350-360` |
| Block | `Delete, Exists` on each direction the arrays show | `ArrayRemove` on both arrays | Same transaction. Edges are deleted only when the fresh array read shows them, so S1 would make Block fail, not create S1 | `repo_firestore.go:497-534` |
| Purge step 2 (incoming edges of purged `u`) | `Delete, Exists` | `ArrayRemove(u)` on the follower | Same batch. The retry path skips the array update only when `graph/{follower}` is missing, and then there's no array | `purge.go:161-188` |
| Purge step 1 (outgoing edges of `u`) | `Delete, Exists` | **none**: `graph/{u}.following` keeps the entries until step 5 deletes the doc | Batch | `purge.go:173-178`, `319` |
| T27 lazy clean-up (PR #58) | none | never: `kind` must be `blocked` or `muted` | Single update | `lists_cleanup.go:27-29` (PR #58) |
| `InitGraph` | none | creates an empty array | In `CreateProfile`'s transaction | `repo_firestore.go:152-160` |

No other code writes `following` or `follows` (repo-wide grep of `backend/`). The only code-produced S1 is the account
being purged, between step 1 and step 5. That account is `DELETING`, and `AccountStatusInterceptor` rejects every
non-exempt RPC from it (`pkg/platform/authn/interceptor.go:161-163`). Only `CreateProfile` and
`CheckHandleAvailability` are exempt (`apiserver/apiserver.go:133-138`).

S2 needs `users/{b}` deleted while an edge to `b` still exists. No code deletes `users/*`. Only runbook Step 2 does
(`docs/runbooks/account-deletion.md:75-77`), and it comes after the purge (`:45-46`). An edge to `b` can't appear
after the purge starts:
- Follow drops non-ACTIVE targets through `Directory.GetProfiles` (`rpcs.go:40-47`, `identity/service.go:295-332`).
- The purge start gate waits 120 s after `DELETING` (`cmd/opsctl/main.go:27-29`, `195-209`). That's 2× the default
  `CACHE_TTL` of 60 s (`config/config.go:221`).
- `purgeFinish` re-checks both edge queries before deleting `graph/{u}` (`purge.go:309-318`).

The emulator suite already proves this for every scenario. `assertGraphInvariants` runs as a cleanup on every
integration test (`fixtures_integration_test.go:127`). It checks I1 in both directions (`invariants_integration_test.go:101-107`,
`148-153`) and flags edges that point at a missing `users` doc (`:176-184`). The purge tests that stop mid-purge opt
out explicitly (`purge_integration_test.go:168`).

**Interleavings that do produce N4. All of them are ops actions outside the code's guarantees:**
1. **S2, wrong order.** An operator runs Step 2 (deletes `users/{b}`) before `purge-graph` prints `purged:`, for
   example after "giving up after 5 consecutive errors" (`account-deletion.md:72-73`). Every follower of `b` is then
   stuck.
2. **S2, gate bypassed.** `--skip-start-gate` is used on an account whose `users` doc still exists
   (`account-deletion.md:71` forbids this). A Follow that passed the Directory check commits after `purgeFinish`'s
   re-check. The edge survives, and Step 2 then removes `users/{b}`.
3. **S2, TTL above the gate.** `CACHE_TTL` is set above 120 s. Stale ACTIVE profiles outlive the gate, and the result
   is interleaving 2 without the flag. Nothing enforces `CACHE_TTL ≤ 60 s` today.
4. **S1, un-delete.** An operator sets `DELETING` back to `ACTIVE` after purge step 1 has run. Every outgoing edge of
   the user is now S1. The user's own `followingCount` is also wrong, because step 1 doesn't maintain it
   (`invariants_integration_test.go:164-167`). No runbook says deletion is one-way.
5. **Either state, hand edits.** A Firestore console or REST edit of `follows` or `graph`. That's click-ops, which
   CLAUDE.md already forbids.

Races that look risky but are safe:
- Unfollow vs Block: covered by `TestT16a_Race_FollowAndUnfollowVsBlock` (`mutations_integration_test.go:972`, cases
  `:1025`, `:1044`).
- Unfollow vs purge step 2 of the target: both are `Exists` deletes of the same edge. The loser fails atomically, and
  the purge re-queries (`purge.go:117-131`).
- Unfollow retried after `Aborted`: `repo_firestore.go:343-380`.

### What I could not verify
- Firestore batch and transaction atomicity is a platform guarantee from the Firestore docs. I didn't test it here.
- Which gRPC code and message production Firestore returns for a failed `Exists` delete versus an `Update` on a missing
  doc. The code comment says it varies (`repo_firestore.go:427-430`). Emulator only.
- That no prod or dev data is in S1 or S2 today. No query was run. The dev deletion drill found no edge residue
  (`account-deletion.md:107`).
- That Cloud Run's request timeout (30 s per the `gcp-terraform` skill) is what prod actually runs. The argument
  "a Follow that passed the Directory check commits well inside 120 s" depends on it.
- PR #58 is unmerged. I read it at its branch head.

## Options
Per-call numbers are Firestore reads/writes/deletes for the Unfollow batch path. The interceptor read of 1 cold
(ADR-0008 B1) is unchanged in every option. $ uses the `cost-model.md` §7 upper bound of $0.06 per 100k reads. The
marginal reads are priced as overage, because the whole product is past the free line at 300 DAU.

### A. Accept and document the invariant (plus the ops guards in E)
- Pros: 0 reads. The budget and every doc stay as they are. The invariant is already swept by every emulator test.
- Cons: if an ops deviation happens, the stuck user sees NONE with no signal. Detection relies on the runbook residue
  check and user reports.
- Cost: Unfollow 0 / 3 / 1 (0 / 0 / 0 on a no-op). +0 reads/day at every DAU. $0.

### B. Unconditional read of `graph/{caller}` before the batch
- Pros: detects S1 and S2 before committing. Could also skip the batch on a known no-op, saving nothing, because a
  no-op already writes 0.
- Cons: breaks the 0-read batch in the proto, skill, plan and ADR-0008. The read is outside any transaction, so it
  can race a concurrent Follow and still needs the precondition. It pays on 100% of calls for a state no API path
  produces.
- Cost: Unfollow 1 / 3 / 1.
  - Per DAU: +0.1 reads/day.
  - At 300 DAU: +30 reads/day (0.06% of 50k), about $0.0005/month.
  - At 3k DAU: +300/day, about $0.005/month.
  - At 2× the released-scope read cliff (4.9k DAU): +490/day, about $0.009/month.
  - At 10× (24.5k DAU): +2,450/day, about $0.044/month.
  - Whole-product 80% crossover: 40,000 / 191.1 vs 40,000 / 191, a shift of under 0.1 DAU.
  - Abuse: a no-op loop is capped at 500 × 3 instances × (1 + 1 interceptor) = 3k reads/day per account. That's under
    the existing 6k Follow-replay bound (`config.go:80-90`).

### C. Read `graph/{caller}` only when the precondition fails
- Mechanics: in the `isPreconditionFailed` branch (`repo_firestore.go:368-372`), do 1 plain `Get`.
  - If `target ∈ following`, re-run the batch once. That covers a Follow that committed between the failed commit and
    the read; last writer wins, which is acceptable.
  - If the batch fails again, log WARN `unfollow_stuck` (no uids, ADR-0008 log rules) and still return NONE.
  - The `Aborted` retry path, the backoff and the scratch-counter accounting are untouched, because the read happens
    only after a non-contention outcome.
  - Idempotency holds: the read is observation only, and the re-attempt is the same state-setting batch.
- Pros: 0 reads on the success path, so the documented 0 / 3 / 1 stands. The budget gains one no-op row.
- Cons: detection only. It can't repair S1 or S2 safely: the right counter fix depends on which ops accident caused
  the state (interleaving 4 needs the caller's own counter fixed, 1 to 3 need the follower's edge deleted). It adds a
  new code path whose only trigger is ops error.
- Cost: no-op Unfollow 1 / 0–3 / 0–1. Assume ≤ 10% of Unfollows are no-ops (replays, double taps): +0.01 reads/DAU/day,
  +3 reads/day at 300 DAU, under $0.001/month at 10× that DAU. The abuse bound is the same as B.

### D. Self-heal on read, or a repair cron
- **D1. Extend T27 to own `ListFollowing`.** Hydration already knows which followees have no `users` doc (T27's
  `LookupProfiles`, 0 extra reads). For S2 only, it could delete the own edge (`Exists`), `ArrayRemove` it, and
  decrement the own `followingCount`: +2 writes and 1 delete per stale edge, once. It can't see S1, because the list
  is driven by `follows` docs, not the array. It also puts writes on a read path for an ops-only state.
- **D2. Scheduler repair job.** It would scan `follows` for edges to missing users, which reads every edge (O(edges)
  reads per run). It also spends one of the 3 free Scheduler jobs. Rejected on cost.

### E. Close the ops holes that are the only producers (chosen, together with A)
- The runbook's Step 2 gets a precondition: a `purge-graph --dry-run` showing `outgoing_edges=0 incoming_edges=0`
  (2 count reads) before `users/{uid}` is deleted.
- The runbook states that deletion is one-way once Step 1 has started. Never set `ACTIVE` again. Restoring an account
  is a new plan with its own ADR.
- The runbook documents the repair for a stuck S2: `opsctl purge-graph --skip-start-gate --uid <deleted uid>`. This
  resumes steps 1 and 2 by query, and step 2 only touches the followers' docs (`purge.go:173-186`). `getGraph` treats a
  missing graph doc as empty (`repo_firestore.go:171-172`). I read this path but didn't run it.
- `config` rejects `CACHE_TTL > 60s` at startup, so the 120 s start gate stays at least 2× the TTL. That's a code cap,
  rule 11.
- Cost: $0, 0 reads per Unfollow.
- **E′ (considered, not chosen).** A 0-read WARN made by parsing the commit error for the failing collection
  (`follows` vs `users` or `graph`). It depends on the unverified production error text. Hold it for the reopen path.

### (3) Privacy and oracle check (all options)
- Unfollow must keep returning NONE on every no-op, never a distinct code or reason. A distinct answer for S2 would
  reveal "target's account doc is gone" as opposed to blocked-by. Blocked-by is already a plain no-op, because Block
  removed the edge (ADR-0008 D9 row "Unfollow(B)").
- B and C read only the caller's own `graph` doc and never the target's.
- C's extra latency (1 read) appears only when the caller wasn't following the target. The caller already knows that
  from their own data, so it isn't a timing oracle about the target.
- D1 acts only on confirmed-missing `users` docs (T27 semantics: SUSPENDED and DELETING are never treated as missing),
  so it reveals nothing beyond what GetProfile's NOT_FOUND already does.
- A and E change no response.
- Logs never carry uids or array contents (ADR-0008 "Required log fields").

## Cost impact
- Fixed monthly cost added: **$0**. No new service, API, Terraform resource or Scheduler job.
- Free-tier quota consumed (A + E): **+0 reads, +0 writes per Unfollow**. The Unfollow row stays at 0 reads (batch) +
  1 logged interceptor read, 3 writes, 1 delete, 0.1 calls/DAU. The budget numbers in ADR-0008 B1, `cost-model.md` §3–§4,
  the proto, the skill and the plan are unchanged.
- For comparison, the rejected B would add 0.1 reads/DAU/day (+30/day at 300 DAU, about $0.04/month at 24.5k DAU). C
  would add about 0.01 reads/DAU/day.
- Trigger (free-tier-budget §6): none fires. This is a correctness decision, not a scale-up.

## Decision
(4) **Close N4 as unreachable through the API.** Adopt **A + E**:
- Record as a standing data-model invariant: "for any account that can call graph RPCs (ACTIVE), `follows/{a}_{b}`
  exists ⇔ `b ∈ graph/{a}.following` ⇔ both `users/{a}` and `users/{b}` exist; only the account under purge may
  violate it, and it can't call RPCs."
- Unfollow's `(false, nil)` on a failed precondition is correct under that invariant. The 0-read batch stays.
- Pin the invariant with tests.
- Remove the four ops paths that are its only producers.

B pays on every call for a state no code path creates. C and D add code whose only trigger is operator error, and
neither can pick the right counter repair without knowing which error happened. Both stay on the shelf behind the
reopen criteria below.

**Reopen criteria (any one). Reopening goes to C first, then D1:**
1. Any `unfollow` user report or support ticket of "can't unfollow".
2. An I1 or I2 violation found by the invariant checker in a dev or prod drill, or by the runbook residue check.
3. An automated account-deletion job (account-lifecycle plan) replaces the manual runbook. That job must enforce "purge
   done ⇒ then delete `users`" in code, and its ADR re-checks this one.
4. An account-restore, un-delete or data-import feature is planned.
5. A new writer of `follows` or `following` appears (for example follow requests under D1 private accounts, or T27
   extended to `following`).
6. `CACHE_TTL` or the start gate changes.

## Consequences
- Positive:
  - $0 and 0 reads.
  - No budget or doc churn across the proto, skill, plan and ADR-0008.
  - The invariant becomes an explicit, tested contract that later writers must preserve.
  - The runbook closes the only real producers.
- Negative: an ops mistake still produces a silently stuck user until someone reports it or a drill finds it. The
  repair is manual (`purge-graph --skip-start-gate`) and needs a counter check afterwards (`docs/runbooks/graph.md` §2).
- Follow-up: T32 to T35 below. N4 is marked closed in `graph-code-review.md` when T32 merges.

## Handoff
Tickets. The planner numbers them into `docs/plans/graph.md`. No proto, index or rules change.
- **tester, T32 [S]: N4 invariant tests (emulator).**
  - Case 1. For each API-reachable no-op cause (never followed, replay, lost race with Block, lost race with purge
    step 2 of the target, blocked-by), assert that once Unfollow returns NONE, `target ∉ graph/{caller}.following`
    and `follows/{caller}_{target}` is absent. Budget: 0 reads, 0 writes, 0 deletes.
  - Case 2. Seed S2 (follow, then delete `users/{b}` directly, with the sweep skipped and the reason given): Unfollow
    returns NONE with 0 writes, the checker reports I2 "edges exist but users/b does not", and running
    `PurgeUser(b)` to completion clears the state and satisfies I1 and I2. This pins both the ops-only failure and
    its documented repair.
- **backend-developer, T33 [XS].**
  - Config validation: `CACHE_TTL` must be ≤ 60 s. Fail startup otherwise, and add a unit test.
  - Update the comments at `repo_firestore.go:329-332` and `427-430` to cite the ADR-0009 invariant: a failed
    precondition is a correct no-op because the invariant holds for ACTIVE callers.
  - No behaviour change.
- **production-deployer, T34 [XS].** In `docs/runbooks/account-deletion.md`:
  - Step 2 precondition: the dry run shows 0/0 edges.
  - "Deletion is one-way after Step 1".
  - The S2 repair recipe.
  In `docs/runbooks/graph.md` §2: add the symptom "a user can't unfollow an account that no longer exists" → the
  repair recipe.
- **architect, T35 [XS]: doc sync.**
  - The `firestore-data-model` skill: add the invariant under "Deletes & privacy". The Unfollow row is unchanged.
  - `graph.proto:37-38`: comment only. "Not following ⇒ NONE" also covers the documented invariant. `buf breaking` is
    unaffected.
  - The ADR-0008 D3 invariant 1: add a pointer to this ADR in a new amendment note. Don't edit the Accepted text.
  - `docs/reviews/graph-code-review.md:69-71`: mark N4 closed.
  - `docs/plans/graph.md` T7 (`:389-391`) and the Risks table (`:976`): add a reference to the invariant.
- **frontend-developer:** nothing. Unfollow's contract is unchanged.
- **sre-performance:** nothing. The cost model is unchanged.
