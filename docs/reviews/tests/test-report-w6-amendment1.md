# Test report: W6-41, ADR-0029 Amendment 1 (poll blocking, vote changes, Vision attempt cap)

Branch `test/w6-41-amendment1` on `origin/main` 4c00cdbf. Scope: A1 (block either way), A2 (vote changes), A5 (attempt cap, units cap, refunds), the W6-42 test
follow-ups (part 2 L-1 and I-7; part 1 I-5 and the H-3 loop shapes). No production code changed. Emulators only, cost 0.

## Method

1. Inventory first: every row of the Amendment 1 tables and of `security-w6-36-poll-changes.md` / `security-w6-40-attempt-cap.md` was mapped to an existing test
   (landed with W6-36, W6-37, W6-40, W6-49, W6-50) or marked missing.
2. Only the missing rows got new tests (below). Nothing was deleted. "Flips": `git diff 13b5080f origin/main -- '*_test.go' '*_test.dart'` shows one removed
   `func Test`: `TestW617_ConcurrencyManyVotersRacingThemselves`, which W6-36 flipped into the two arms (the function and its name remain; arm bodies are
   `w617ConcurrencyArmA` and `w636ConcurrencyArmB`). The other removed lines are `dart format` re-wraps of the same tests (`testWidgets('a direct switch ...')`
   still exists) and the drift schema 9 to 10 version assertion. The one-vote-final pins (`ALREADY_VOTED` for a different choice) were flipped by W6-36 to
   `expected_choice` cases (`TestVotePoll_ChangeMatrix`, `TestW617_RepostIDVotesInTheOriginal`); no test of the old behaviour remains un-flipped.

## Matrix to test to status

| Row (source) | Test | Status |
|---|---|---|
| A1: voter blocks author: cast, replay, change, old client, `expected_choice` 0/1/3 (TARGET_BLOCKED, 0 writes, 0 vote reads) | `TestVotePoll_BlockMatrix` (unit); `TestW636_VoterBlocksAuthor` (chain, reads 0 / writes 0 measured, ceiling 7) | existing |
| A1: order (no poll, author, closed, range before the block); closed + blocked = POLL_CLOSED | `TestVotePoll_BlockMatrix/the order...` | existing |
| A1: REPOST id acts on the original's author; blocking the reposter is not a block | `TestVotePoll_BlockMatrix/a REPOST id...`; `TestW617_NotFoundBytesIdentical` (TARGET_BLOCKED by REPOST id and post id) | existing |
| A1: mute is not a block; unblock reopens; fails closed (no graph / graph error); +0 reads | `TestVotePoll_BlockMatrix` subtests | existing |
| A1: author blocks voter: NOT_FOUND byte-identical, first vote, `e = 0` | `TestW617_NotFoundBytesIdentical`; unit subtest of `TestVotePoll_BlockMatrix` | existing |
| **A1 / L-1: author blocks a voter who HAD voted; replay, change, stale, old client; `expected_choice` set; by post id and by REPOST id; bytes equal a missing post; 0 writes; vote, counts, userLikes unchanged** | `TestW641_L1_AuthorBlocksAVoterWhoVoted_NotFoundBytes` (raw HTTP bytes, fresh instance) | **new** |
| **L-1 at the service: full error equal (code, reason, message, metadata, retry_after), no vote-store access** | `TestW641_L1_AuthorBlocksAVoterWhoVoted_SameErrorAsAMissingPost` (unit; post id only, REPOST case is the chain test) | **new** |
| A1.5 `viewer_poll_vote_blocked` on GetPost, GetThread, GetUserTimeline; cleared on withheld; never on lists/embeds; guard over producers | `TestToViewAt_PollVoteBlocked`, `TestServer_PollVoteBlocked_GetPostAndThread`, `TestUserTimeline_PollVoteBlocked`, `TestPollConverterGuard_Repo`, `TestApplyWithheld_ClearsPollVoteBlocked`, `TestW617_NotFoundBytesIdentical` (GetPost) | existing |
| A1.4 block writes nothing to votes | `TestW636_VoterBlocksAuthor` (counts, vote docs unchanged) | existing |
| A2.2 decision table (new, replay, change, cap, stale, `e = 0`), shape of `expected_choice` | `TestVotePoll_ChangeMatrix`, `TestVotePoll_ExpectedChoiceShape`, `TestW636_ChangeBudgetCapAndClose` | existing |
| A2.3 change write: 4 writes, 1 read, 2 writes to one `userLikes` doc in one commit; post gone; missing userLikes; legacy entry | `TestRepoChangeVote_BatchBudgetAndEffects`, `_PostGoneAndMissingUserLikes`, `_ReplacesLegacyEntry`; `TestW636_ChangeBudgetCapAndClose` (reads=1 writes=4 per change) | existing |
| A2.3 precondition races, same voter, close re-check | `TestVotePoll_ChangeRaces`, `_ConcurrentChangeRace`, `_ConcurrentSameVoter_ChangeArm`, `_ChangeAfterClose` | existing |
| A2.4 change cap (`POLL_VOTE_CHANGES_MAX`, 0 = final), LIMIT_REACHED metadata, 0 writes | `TestVotePoll_ChangeCap`, `TestW636_ChangeBudgetCapAndClose` (reads=1 writes=0) | existing |
| A2.5 / A2.6 close, export `changedAt`, eraser keeps counts | `TestVotePoll_ChangeAfterClose`, `TestPollVoteExporter_ChangedAt*`, `TestPollVoteEraser_*` | existing |
| A2.7 cache replaces the entry, counts clamp | `TestPost_VoteChanged`, `TestCache_AdjustPollChange` | existing |
| **I-7: change through a REPOST id leaves one `userLikes.pollVotes` entry for the original, three-part form** | assertion added at the end of `TestW617_RepostIDVotesInTheOriginal` (`onePollEntry(got, pid, 0)`) | **new assertion** |
| **A2.3 race, 60 voters x 3 choices, two arms (new votes; changes)** | `TestW641_RaceInvariants/arm a`, `/arm b` | **new** (the W6-36 flipped test stays, see Defects D-1) |
| A5.3 outcome table (assessed, retry, terminal, busy, not claimed) and counters | `TestW640_NoValidAssessmentConsumesARetryNotAnAttempt`, `_OnlyAssessedAttemptsCountTowardsTheCapOfThree`, `_PublishFailureAfterACompletedScreeningConsumesAnAttempt`, `_BlockingVerdictIsFinalEvenIfTheOtherCallFailed`, `_RetriesConfigSetsTheClaimsCeiling`, `_BusyGIFSlotNeverConsumesAnAttemptAndWritesNothing` | existing |
| A5.5 units cap before the claim, both tiers, tier by age (W6-50 zero `createdAt` = new) | `TestW640_UnitsCapRefusesBeforeTheClaim`, `_UnitsCapTierFollowsTheAccountAge`, `TestW650_*` | existing |
| A5.5 / W6-49 refunds: only 429, 5xx, not-sent; timeouts, resets and answers never; 3 s floor | `TestW640_UnitsAreRefundedOnlyWhenNothingWasSent`, `TestW649_*`, H-1 cancellation tests | existing |
| A5.7 per-doc bound 16 units, 9th call bills nothing | `TestW640_PerDocBillableUnitsAreAtMost16` | existing |
| **H-3 loop shape: outage loop on one doc (refunded) stops at 8 claims; later loops cost nothing** | `TestW641_H3_LoopOnAnOutageStopsAtTheClaimsCeiling` | **new** |
| **H-3 loop shape: timeouts across many documents stop at the units cap (both tiers); refused calls claim and call nothing** | `TestW641_H3_LoopAcrossDocumentsStopsAtTheUnitsCap` | **new** |
| **H-3 loop shape: alternating outages and assessed attempts end terminal within 8 claims, 3 assessed, 16 units** | `TestW641_H3_AlternatingOutagesAndAssessedAttemptsAreTerminalWithin8Claims` | **new** |
| **security-w6-40 I-5: a lost claim race (`ErrConflict`) returns the whole charge** | `TestW641_I5_LostClaimRaceRefundsTheWholeCharge` (adds `claimFn` hook to the test fake `fakeRepo`) | **new** |
| W6-37 client flows (Change vote control, changing mode, blocked state, error answers, `expected_choice`, fresh key, drop retries) | `app/test/shared/widgets/post/poll_change_vote_card_test.dart`, `post_card_poll_test.dart`, `w6_poll_flow_test.dart`, `poll_display_test.dart`, engagement cubit tests | existing; no Flutter test added, none run |

## Budgets measured (request-line `fs_reads` / `fs_writes`, emulator chain)

| Outcome | Reads | Writes | Ceiling asserted | Test |
|---|---|---|---|---|
| change (VotePoll, warm instance) | 1 | 4 | 9 / 4 | `TestW636_ChangeBudgetCapAndClose` |
| LIMIT_REACHED | 1 | 0 | writes 0 | same |
| TARGET_BLOCKED | 0 | 0 | 7 / 0 | `TestW636_VoterBlocksAuthor` |
| NOT_FOUND, author blocks a voter who voted (post id and REPOST id, 10 shapes) | 0 to 4 (first call on the fresh instance 4, then cached 0 to 2) | 0 | 7 / 0 | `TestW641_L1_...` |

Media (unit, fake repo): per document at most 8 claims and 16 Vision units; the cap-refused call makes 0 claims and 0 Vision calls (asserted). Media
Firestore reads and writes are fake-counted only, as before.

## Commands run (worktree `.claude/worktrees/w6-41`, `GOWORK=off`)

- `go vet ./...` and `go vet -tags=integration ./...`: clean. `gofmt -l internal`: clean. `staticcheck -tags=integration` on `internal/apiserver`,
  `internal/media`, `internal/engagement`: no finding in files of this change (pre-existing findings in `search_chain_integration_test.go` only).
- `go test -count=1 ./internal/engagement/... ./internal/media/...`: ok.
- Integration, Firestore + Auth + Storage emulators on ports 55080 / 55099 / 55199 (hub 55400, UI off), wrapped in `scripts/with-private-tmp.sh`, project
  `demo-dzeroth-local`: `go test -count=1 -tags=integration ./internal/engagement/... ./internal/media/... ./internal/apiserver/...`: all three packages ok
  (apiserver 218 s). **The Pub/Sub emulator would not start on this machine** (`Port 55085 is not open`, two attempts, debug log empty), so it was left out of
  `--only`; none of these packages' tests use Pub/Sub (they passed without it), but the exact prescribed `--only` list was not run.
- Flake check: `TestW641_RaceInvariants` with `-count=8` in one emulator session: 8 of 8 pass (4.3 to 13.9 s each).
- `-race` was not used: this Windows toolchain has `CGO_ENABLED=0` (`go: -race requires cgo`). CI runs it.

## Defects found

None in production code. Observations for the owners:

- **D-1 (test debt, not a product defect).** `TestW617_ConcurrencyManyVotersRacingThemselves` is a known CI flake (exact winner counts, a 20 ms sleep and a
  cached-view lag log). It passed here once. `TestW641_RaceInvariants` covers the same race with invariants only (no exact winner count, UNAVAILABLE allowed,
  a vote doc exists if and only if one three-part `userLikes` entry equals the stored choice, `changes` is 1 exactly when the choice moved). Recommendation:
  quarantine the old test under a ticket; it was left untouched as the ticket says "never delete".
- **Wording.** The brief says "60 concurrent requests from 3 voters"; ADR A2.3 defines the race as 60 voters x 3 choices, which is what was built.
- **Residual not tested (by design).** The staleness bound of A1.1 (up to 60 s per instance after a block) is exercised only by routing the post-block
  requests to a fresh instance; the cached-instance case is the documented bound. Real `OPTIMISTIC` contention of a change race is W6-22's dev smoke (plan).

VERDICT: PASS
