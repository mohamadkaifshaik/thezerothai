# Test report: UI wave W6 (polls), backend

Plan: `docs/plans/ui-w6-composer-extras.md` (W6-17). Design: ADR-0029 and its as-built notes (N2, PR #520, merged). The GIF
half is W6-18; the client half is W6-19; the 50 votes/s for 60 s load shape belongs with W6-21 and is not run here.

## W6-17: backend tests for polls (2026-10-31)

Tester: tester agent. Branch `test/ui-w6-17-poll-tests` on `main@88e1c7f4` (W6-5, W6-6, W6-7 + W6-8 as #515, the ADR as-built notes #520 and W6-18 #519
merged). I first built on `main@212c0249` plus the then-current head of `feat/ui-w6-7-vote-poll`; section 5 records what that older head showed.

**VERDICT: PASS for W6-17 as specified.** All 12 tests added here pass on the merged base, and a mutation check shows the lifecycle test fails
when the `poll_votes` step is not registered. The whole module's integration suite (the `make test-int` command, 43 packages) is green on this head with combined `internal/` coverage **93.2 %** (gate 70 %), and the `TestAccountLifecycle_` family (23 tests) is green. No production defect
was found. Three red lifecycle tests seen on the older #515 head (+1 read each, one missing golden section) were fixed in the head that merged and
are re-verified green (section 5). Every acceptance criterion of W6-5 to W6-8 has a named test (section 3). Three observations (O-1, O-2, O-4)
and four gaps (section 7) are for the owners.

---

### 1. What was run

| Suite | Command | Result |
|---|---|---|
| New W6-17 tests | `go test -tags=integration -run TestW617_ ./internal/apiserver` on Firestore, Auth and Storage emulators plus a standalone Pub/Sub emulator, on the merged base | **12 pass** (the two lifecycle tests included) |
| Mutation check | `registerPollVoteLifecycle` replaced by `error(nil)` in `apiserver.go:468`, then `-run TestW617_Lifecycle` | **both lifecycle tests fail**, as they should (export empty, 2 vote docs survive, residue sweep reports them). Reverted |
| Lifecycle family, all of `TestAccountLifecycle_` | `-run TestAccountLifecycle_ ./internal/apiserver` on `main@5ce07b43`, 214 s (also inside the whole-module run below) | **23 pass, 0 fail** (the older #515 head: 3 red, section 5) |
| Whole module, the `make test-int` command | `go test -tags=integration -p 1 -coverprofile=cover-internal.out -coverpkg=./internal/... ./...` on Firestore, Auth and Storage emulators plus a standalone Pub/Sub, on the head of this PR (just before the last docs commit) | **43 packages ok, 0 failed, EXIT=0**; combined `internal/` statement coverage **93.2 %** (gate 70 %); per file: `engagement/service_polls.go` 95.2 %, `purge_polls.go` 91.6 %, `repo_polls.go` 84.5 %, `posts/poll.go` 100 % (mean of function coverage) |
| `gofmt -l`, `golangci-lint run --build-tags integration ./internal/apiserver/...` | the three new files | gofmt clean; lint reports 4 issues, all in `search_chain_integration_test.go` (not this PR), none in the new files |
| Developers' poll tests, unit | `go test -cover ./internal/engagement ./internal/posts` | green; statement coverage 59.6 % (engagement) and 64.9 % (posts), **unit tests only** |
| Terraform TTL guard | `TestW617_PollVotesTTLFieldIsInTerraform` (no emulator) | pass |
| `go vet -tags=integration ./internal/apiserver` | | clean |

Environment notes:
- `-race` was not run: CGO is off on this machine. CI on Linux runs it. The new concurrency test keeps its shared state behind per-index
  slots and a `WaitGroup`, so it has no data race by construction.
- Emulators ran from a scratch config outside the repo on ports 58xxx behind `scripts/with-private-tmp.sh`. The firebase-tools launch of the
  Pub/Sub emulator failed on this shared machine ("Port ... is not open") for the last two hours of the session, on every port set tried. The
  Pub/Sub jar itself starts in about a second, so the final runs used `emulators:exec --only firestore,auth,storage` with a standalone Pub/Sub
  emulator (the same jar, one process I started, on 58778 and 58779, each stopped by PID afterwards) and `PUBSUB_EMULATOR_HOST` set. The earlier full-family run on
  the older head used the normal launch.
- `make test-int` itself was not run; its command was (above), with `-p 1` and the standalone Pub/Sub. `make ci` (the Flutter half) was not run.
- Nothing was run against dev or prod.

### 2. What was added

All in `backend/internal/apiserver/`, test names prefixed `TestW617_` so one `-run` selects them. No production code was edited and no helper
was added outside the test files.

| File | Tests | Covers |
|---|---|---|
| `w617_polls_chain_integration_test.go` | `TestW617_RedactionBytesIdentical` | hidden counts are the same bytes for the splits {57,0,0}, {0,0,57}, {0,57,0}, {19,19,19} (total 57), and the choices bytes equal those of a 0-vote poll; `total_votes` stays real; the author sees the real split; the user timeline (a list producer) gives the same bytes as `GetPost` |
| | `TestW617_NotFoundBytesIdentical` | raw HTTP status and body of `VotePoll` equal those of a missing id for: author blocks voter, same by REPOST id, taken-down post, suspended-author post (`SUSPENDED_AUTHOR`), a missing id on another instance; 0 vote docs and an unchanged total. Pins that a voter who blocked the author is **not** refused (observation O-1) |
| | `TestW617_ReplayAfterClose` | replay, another choice and a new voter after `closesAt` are all `POLL_CLOSED` with 0 writes; the vote and the counts are untouched; the closed poll shows real counts to author, voter and non-voter; `expireAt = closesAt + POLL_VOTE_TTL_AFTER_CLOSE` on the real doc; the wait is a deadline loop on the server clock |
| | `TestW617_NewAccountCap` | the new-account cap as the as-built note says: boundary (call N passes, N+1 refused, 0 writes), replays count, refusals count, per instance (a second Build accepts the vote the first refused), refusal shape equals the interceptor's own `poll_votes_daily` refusal (code, reason, message, metadata, `retry_after` within 5 s) |
| | `TestW617_ConcurrencyManyVotersRacingThemselves` | 60 voters, each firing 3 calls with 3 different choices at once, spread over two Build instances on one Firestore (180 concurrent calls) |
| | `TestW617_DegradedModes` | `DEGRADED_MODE=readonly`: `DEGRADED_MODE` with a `retry_after`, 0 writes, no vote doc, `GetPost` still renders the poll; `nomedia` does not touch voting |
| | `TestW617_FlagModes` | creation per caller (polls allowlist: listed caller creates, other gets `FEATURE_DISABLED feature=polls`, but can vote); polls off: creation refused and the globally-off reveal for a non-voter; engagement off for the voter: no `viewer_poll_choice`, counts hidden, vote refused at 1 read and 0 writes |
| | `TestW617_RepostIDVotesInTheOriginal` | a REPOST id votes in the original (vote doc, counts, response all name the original), replay through the original id, `ALREADY_VOTED` through the REPOST id, the REPOST row carries `viewer_poll_choice` and its embedded poll never carries counts |
| | `TestW617_ReadBudgetPollVsPlain` | `GetPost` costs the same reads for a poll post as for a plain post (voter and non-voter, cold caches) |
| `w617_polls_lifecycle_integration_test.go` | `TestW617_LifecycleVoterDeletes` | real votes by V and W, V's export lists the votes with **0-based** choices and no other voter, the author's export carries `poll {choices, closesAt, counts, total}`, then V deletes the account through the real jobs endpoint: every `pollVotes` doc of V and `userLikes/V` gone, the sweep clean, **counts and totals unchanged** (D8, F6), W's vote doc and view intact, no raw uid in logs |
| | `TestW617_LifecycleAuthorDeletes` | the author deletes: the post is gone, the sweep is clean, the voters' vote docs stay with no author uid and `expireAt = closesAt + 30 d`, the poll answers `NOT_FOUND`, a voter's export still lists the vote and carries no post text |
| `w617_poll_ttl_guard_test.go` | `TestW617_PollVotesTTLFieldIsInTerraform` | `ttl_fields.poll_votes_expire_at = {pollVotes, expireAt}` in `infra/terraform/modules/firestore/variables.tf` and the repo still writes `expireAt` (no emulator needed) |

### 3. Traceability: every acceptance criterion of W6-5 to W6-8

Paths: `posts/` = `backend/internal/posts/`, `eng/` = `backend/internal/engagement/`, `api/` = `backend/internal/apiserver/`,
`chain` = through `apiserver.Build` with the interceptors. "new" marks a test added by this ticket.

#### W6-5: CreatePost with a poll

| Criterion | Test(s) |
|---|---|
| 2 choices and 1 day: `closesAt = createdAt + 24 h`, the response echoes the poll | `posts/poll_test.go:TestCreate_PollStored`; emulator `posts/poll_integration_test.go:TestCreate_Integration_Poll` |
| 5 choices, a 26-code-point choice, "Yes"/"yes", 4 minutes, 8 days: VALIDATION `field=poll`, 0 writes | `TestCreate_PollValidation` (12 cases, asserts field, 0 reads, 0 writes), `TestPollRules_SharedFixture`; emulator "rejected poll" budget `{}` |
| Poll with a photo, a reply, a quote (and empty text): VALIDATION | `TestCreate_PollValidation` (with media, alt text only, reply, quote, empty, blank) |
| Same key and poll replays; a different poll is `IDEMPOTENCY_KEY_REUSED` | `TestCreate_PollReplayAndReuse`; emulator replay line at `TestCreate_Integration_Poll` |
| No poll: `requestHash` equals today's | `TestCreate_PollRequestHash`: four no-poll goldens built from the documented preimage string; the poll hash is pinned to its formula |
| Budget: +0 reads, +0 writes over a root post | `TestCreate_Integration_Poll` (`budgettest` 2 reads, 4 writes); `TestCreate_PollStored` |
| Flag matrix for `polls` (create per caller) | `posts/polls_flag_modes_test.go:TestServer_PollsFlagModes`, `posts/polls_gate_test.go`; chain: `TestW617_FlagModes` (new) |

#### W6-6: viewer choice and redaction

| Criterion | Test(s) |
|---|---|
| Non-voter on an open poll: votes 0, `total_votes` real | `posts/poll_view_test.go:TestToViewAt_PollViewerMatrix`; chain: `api/engagement_polls_chain_integration_test.go:TestPollVoteChain_ContractAndBudgets` (GetPost by a non-voter), `TestW617_RedactionBytesIdentical` (new) |
| The author sees real votes | `TestToViewAt_PollViewerMatrix`; `TestW617_RedactionBytesIdentical` (new, control) |
| Closed: real for everyone | `TestToViewAt_PollViewerMatrix`; chain `TestPollVoteChain_Closed`; `TestW617_ReplayAfterClose` (new, author, voter and non-voter) |
| REPOST row of a voted poll: `viewer_poll_choice` set (original id) | `posts/poll_view_test.go:TestToView_RepostRowViewerChoice`; chain `TestW617_RepostIDVotesInTheOriginal` (new) |
| `engagement` off for the viewer: no `userLikes` read, counts hidden, choice 0 | `TestHydrateViewer_Polls`, `TestToViewAt_PollViewerMatrix`; chain `TestW617_FlagModes` (new, voter with engagement off) |
| Home, user timeline, GetPost, GetThread, ListBookmarks apply the same rule | `TestServer_GetPost_PollViewer`, `TestServer_GetThread_PollViewer`, `timeline/poll_viewer_test.go`, `eng/poll_lists_test.go`; chain: user timeline in `TestW617_RedactionBytesIdentical` (new) |
| A4 guard over every PostView producer | `posts/poll_converter_guard_test.go:TestPollConverterGuard_Repo` and `_SelfTest` |
| Hidden counts identical whether the real count is 0 or 57 | `posts/poll_view_test.go:TestToView_HiddenPollBytesIgnoreCounts`; chain `TestW617_RedactionBytesIdentical` (new; see the note under it in section 6) |
| +0 reads on lists | `TestW617_ReadBudgetPollVsPlain` (new, GetPost); the user timeline is not budget-compared (gap G-4) |
| `globally off` reveals results | `TestToViewAt_PollViewerMatrix`; chain `TestW617_FlagModes` (new) |

#### W6-7: VotePoll

| Criterion | Test(s) |
|---|---|
| First vote: 3 writes, counts +1, total +1, response shows results | `api/engagement_polls_chain_integration_test.go:TestPollVoteChain_ContractAndBudgets` (reads at most 8, writes exactly 3); `eng/service_polls_test.go:TestVotePoll_FirstVote`; `eng/repo_polls_integration_test.go:TestRepoVote_BatchBudgetAndOutcomes` |
| Same call again: 0 writes, same response | `TestPollVoteChain_ContractAndBudgets` (replay, 9 reads worst); `TestVotePoll_ReplayAndAlreadyVoted`, `TestVotePoll_ReplayAfterTrim` |
| Another choice: `ALREADY_VOTED` and 0 writes | `TestPollVoteChain_ContractAndBudgets` (reason, `metadata.choice`, 0 writes); `TestVotePoll_ReplayAndAlreadyVoted`; `TestW617_ConcurrencyManyVotersRacingThemselves` (new, every loser) |
| 50 concurrent votes by 50 users: `total = 50` | `TestPollVoteChain_Concurrency`; `TestVotePoll_ConcurrentVoters`; `TestW617_ConcurrencyManyVotersRacingThemselves` (new, 60 voters over two instances, per-choice tally, `userLikes`) |
| 10 concurrent votes by one user: exactly 1 counted | `TestPollVoteChain_Concurrency`; `TestVotePoll_ConcurrentSameVoter`; new test, each of 60 voters races itself 3 ways |
| Closed: `POLL_CLOSED`, 0 writes | `TestPollVoteChain_Closed`; `TestVotePoll_Refusals`; `TestW617_ReplayAfterClose` (new: replay, another choice, new voter) |
| Author: VALIDATION | `TestPollVoteChain_ContractAndBudgets` (refusals); `TestVotePoll_Refusals` ("the author") |
| Blocked by the author: NOT_FOUND, bytes identical to a missing post | `TestPollVoteChain_BlockedIsNotFound` (proto `String()`); `TestW617_NotFoundBytesIdentical` (new: raw HTTP bytes; REPOST id; taken-down; suspended author) |
| 31 votes in a minute: `RATE_LIMITED` | `TestPollVoteChain_BucketLimit`; `pollVoteViolations` guard (`api/poll_guard_test.go`) |
| `DEGRADED_MODE=readonly`: `DEGRADED_MODE` | `TestW617_DegradedModes` (new) |
| New-account cap | `TestPollVoteChain_NewAccountCap`; `TestVotePoll_NewAccountDailyCap`; `TestW617_NewAccountCap` (new, five properties) |
| Flag matrix: allowlist caller outside the list still votes; polls globally off refuses; engagement off refuses | `eng/server_polls_test.go:TestVotePoll_FlagMatrix`; chain `TestPollVoteChain_FlagGate`, `TestW617_FlagModes` (new) |
| Budgets: new vote, replay, refusal | `TestPollVoteChain_ContractAndBudgets` (8 / 3 writes, 9 / 0, 7 / 0), `_Closed` (7), `_FlagGate` (1); measured, see section 4 |
| A voter whose `userLikes` doc does not exist yet: vote stored, choice on the next GetPost | `TestVotePoll_NoUserLikesDocYet`; chain `TestPollVoteChain_ContractAndBudgets` (new voter, then GetPost) |
| Contention: `UNAVAILABLE` + `contention=true` | `TestVotePoll_Contention` (fake); **not reproducible on the emulator** (gap G-1) |
| Trim of `userLikes.pollVotes` | `TestVotePoll_LazyTrim`, `TestRepoTrimPollVotes` |
| Hot-poll cache | `posts/poll_vote_test.go:TestPostVoted_CopyOnWrite`, `TestCacheAdjustPoll`; `TestW617_ConcurrencyManyVotersRacingThemselves` (new, see O-2) |

#### W6-8: lifecycle and runbook

| Criterion | Test(s) |
|---|---|
| 120 votes: the eraser deletes 120 docs, the export lists 120 | `eng/repo_polls_integration_test.go:TestPollVoteEraser_120Votes`, `TestPollVoteExporter_120Votes`; `eng/purge_polls_test.go` |
| `make ci`: the T11 guard passes | `api/lifecycle_collections_guard_test.go`, `api/lifecycle_wiring_test.go` (pinned order); `go vet` clean here, `make ci` not run |
| A vote by a deleted account on an open poll: counts unchanged, no doc names the uid | **new:** `TestW617_LifecycleVoterDeletes` (real votes, real job chain), `TestW617_LifecycleAuthorDeletes` (new) |
| Crash-resume checkpoint | `eng/repo_polls_integration_test.go:TestPollVoteEraser_CrashResume`. The crash harness `newCrashChain` (`api/account_lifecycle_crash_integration_test.go:276`) does **not** register `poll_votes`, so the rich-account crash tests never run the step (G-2) |
| Pinned order, T11 row | `lifecycle_wiring_test.go`, `lifecycle_collections_guard_test.go` |
| TTL field in Terraform | **new:** `TestW617_PollVotesTTLFieldIsInTerraform` |
| Runbook "Polls" section | `docs/runbooks/engagement.md` (read, not tested) |

### 4. Budget results (request line `fs_reads` / `fs_writes`, interceptor read included)

Ceilings are the ones `TestPollVoteChain_*` asserts; `budgettest.Assert` is "at most".

| RPC case | Measured here | Ceiling asserted | Test |
|---|---|---|---|
| VotePoll new vote | 3 writes exactly | 8 reads, 3 writes | `TestPollVoteChain_ContractAndBudgets` |
| VotePoll replay or `ALREADY_VOTED` | 0 writes | 9 reads | same |
| VotePoll refused at step 5 | 0 writes | 7 reads | same, `_Closed` |
| VotePoll closed replay (new) | 0 or 1 read, 0 writes | 7 reads | `TestW617_ReplayAfterClose` |
| VotePoll refused by a flag | 0 reads | 1 read | `_FlagGate`, `TestW617_FlagModes` |
| VotePoll refused by the new-account cap (new) | at most 1 read, 0 writes | not in the ADR table; the as-built note says +0 | `TestW617_NewAccountCap` |
| VotePoll under `DEGRADED_MODE=readonly` (new) | at most 1 read, 0 writes | n/a | `TestW617_DegradedModes` |
| GetPost, poll post vs plain post (new) | equal reads | +0 | `TestW617_ReadBudgetPollVsPlain` |
| CreatePost with a poll | 2 reads, 4 writes warm | +0 over a root post | `TestCreate_Integration_Poll` |
| Account deletion, reference account (1 post, 1 following, 1 follower, 1 export) | 29 reads, 4 writes, 9 deletes | 29 reads (28 before the step) | `TestAccountLifecycle_Chain`, green |
| Account export, reference account (P=300 O=100 I=100) | 716 reads, 2 writes | 716 | `TestAccountLifecycle_ReferenceAccountBudgets`, green |
| Account deletion, reference account (P=300 O=100 I=100 E=1) | 526 reads, 301 writes, 506 deletes | 526 | same, green |

The extra read in each of the three is the empty first page of the new `poll_votes` eraser or export section (an empty query bills 1 read),
exactly as the earlier steps' comments in those files account for theirs.

### 5. Defects

**No open defect, and no production defect.** On my first base (the head of `feat/ui-w6-7-vote-poll` before its last push) three tests of the
lifecycle family were red, each the stale expectation of one more empty-query read or one more empty export section from the new `poll_votes`
step. The head that merged as #515 (`3f9b04e1`) fixed all three, and a full `TestAccountLifecycle_` run on `main@5ce07b43` (23 tests, 214 s) is
green. They are kept here as the record of what the step costs, and of why the lifecycle budgets carry one more read:

| ID | Where (as found) | Found | Status |
|---|---|---|---|
| D-1 | `account_lifecycle_integration_test.go:447`: reference-account deletion work delivery measured 29 reads against a limit of 28 | `TestAccountLifecycle_Chain` | fixed in #515: limit 29, comment line added |
| D-2 | `account_lifecycle_reference_integration_test.go:43`, `:27`, `:52`: export 716 reads against 715, deletion 526 against 525 and 524 + D | `TestAccountLifecycle_ReferenceAccountBudgets` | fixed in #515: constants +1, comments added |
| D-3 | `testdata/account_export_golden.json`: no `"poll_votes": {"poll_votes": []}` section between `notifications` and `posts` | `TestAccountLifecycle_ExportContentsGolden` | fixed in #515: golden has the section (line 109) |

The cost of the step is +1 read per account deletion and +1 per export (the empty first page); no budget constant was changed by this PR.

### 6. Observations (not defects)

- **O-1. "Blocked either way" in the plan ticket is not what the code does, and the code follows the ADR.** A voter who blocked the author can
  still view the post and vote (`Viewable` hides a post only from a caller whom the **author** blocks, as `GetPost` and `Like` do; D6 step 4 says
  "visibility as GetPost"). `TestW617_NotFoundBytesIdentical` pins this. If the founder wants a blocker unable to vote, that is an architect
  decision and a change in `posts.Viewable`, not a VotePoll fix.
- **O-2. A cached poll can lag the store by up to the post-cache TTL (60 s) across instances.** In the 60-voter run the two busy instances showed
  the author totals of 25 and 35 against 60 stored (50 and 10, then 30 and 30, in other runs), each self-consistent (choices sum to the total, not
  observed above the store; a double count within one instance, a cold read that already holds a vote followed by that vote's own cache bump, is not excluded by this test, and would be bounded by the same TTL as likes). A cold instance showed the exact tally. This is the documented behaviour ("a replay does not bump the cache", and a vote on another
  instance never does), costs nothing in reads, and the counts are hidden from voters-to-be anyway; it matters only for an author watching a hot
  poll across instances and for the voter's own response, which shows the cached counts plus their vote.
- **O-3. The redaction byte-identity is about the choices, not the whole poll.** `total_votes` is the real total by design (F3), so a poll with
  0 votes and one with 57 differ in that one field. The test therefore holds the total fixed and varies the split, and separately compares the
  choices bytes against a 0-vote poll.
- **O-4. The `requestHash` goldens are formulas, not literal digests.** `TestCreate_PollRequestHash` rebuilds the SHA-256 of the documented
  preimage (`v1|text=...|...`) and compares. That pins the preimage format, which is what matters for stored keys, but a change to the helper
  that builds the string in both places would pass. No change made.
- **O-5. The new-account cap behaves as the as-built note says**: per instance (a second Build accepts the vote the first refused, so the
  effective limit is N times the instances), replays and refusals count, the refusal is shaped like the interceptor's own (code, reason,
  message, metadata, `retry_after` within 5 s) and writes nothing.

### 7. Gaps, and what was not run

- **G-1. Real contention.** The emulator serialises writes: 180 concurrent calls produced **0** `poll_vote_contention` lines and 0
  `UNAVAILABLE` after retries. The test proves the invariants under concurrency (one vote per voter, counts equal the tally of vote docs, every
  answer agrees with the stored choice, `userLikes` holds one entry), not the `ABORTED` and `CommitWithRetry` path. That path is covered only by
  the fake-based `TestVotePoll_Contention`. Real `OPTIMISTIC` contention is the W6-22 dev smoke, as for #292.
- **G-2. The crash harness does not run `poll_votes`** (`newCrashChain`, `account_lifecycle_crash_integration_test.go:276`). Adding the step there
  would change the clean run's side-effect list that the crash tests pin; left for the owner. The step's checkpoint is covered at repo level.
- **G-3. Not run:** `-race`; `make ci`; `make test-int` itself (its command ran, section 1);
  the load shape of one poll at 50 votes/s for 60 s (W6-21); prod `OPTIMISTIC` contention (W6-22); any
  Flutter test; anything against dev or prod.
- **G-4. The user timeline and the other list producers are not budget-compared for polls at chain level** (only `GetPost` is). The per-producer
  redaction tables and the A4 guard cover the rule; the read cost of a list with a poll is the hydrate read it already paid.

VERDICT: PASS
