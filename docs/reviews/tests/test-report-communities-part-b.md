# Test report: UI wave W5 Part B (Communities), backend

Plan: `docs/plans/ui-w5-lists-communities.md` (W5-36). Design: ADR-0031 (`docs/adr/0031-communities-and-moderation-scope.md`, N1 to N10). Built by W5-23/24
(#601), W5-25 (#613), W5-25b (#626), W5-26 (#629), W5-26b (#633), W5-27 (#634), W5-28 (#636), W5-29 (#639). The client half is W5-37; the security review
(moderator abuse) is W5-38; the load shapes and the budget table are W5-39 and are not run here beyond the 50-join burst.

Tester: tester agent. Branch `test/communities-w5-36-backend-tests` on `origin/main@78279fc9` (merged). **No production code was edited and no test seam was added.**

**VERDICT: PASS** (with the skipped cells listed in section 3 and defect D-1, Low)

---

## 1. Method

1. Read the ticket, ADR-0031 (D1 to D14, N1 to N10), the plan text of W5-23 to W5-29 with their "as built" notes (which supersede the original wording where
   they differ) and the reports of W5-27 and W5-28 for the attack list.
2. Listed every test in `internal/communities`, `internal/timeline` (`community_*`, `home_tabs`), `internal/posts` (`community_*`, `moderate_community_*`),
   `internal/moderation`, `internal/engagement`, `internal/apiserver` (`communities_*`, `account_lifecycle_communities_*`, `lifecycle_*guard*`),
   `cmd/opsctl` (`community*`), `pkg/platform/config` and `pkg/platform/quota`, and mapped each acceptance criterion and each ticket item to a test (section 3).
   A criterion counts as covered only when a test fails if the behaviour is removed, and only when it runs through the layer the criterion names: a package
   test below the interceptors does not prove a flag gate, a read count or the bytes a client receives.
3. Wrote tests only for the holes (section 2), at the layer that was missing, with the existing harnesses (`cmChain`, `seedCommunity`, `seedCommunityPosts`,
   `commRig`, `newJoinEnv`) and `budgettest`. Every new test is named `TestW536_*` (one `-run TestW536` selects them; no `|` in a pattern).
4. Mutation check on the two boundary tests (a strict `After` in `communityRemovals` changed to "not Before": `TestW536_TruncationAtTheTokenCutoff` fails on
   the "exactly the cutoff" case), then restored.
5. Ran everything against the Firebase emulators (Firestore, Auth, Pub/Sub, Storage) on a private port block (8581 / 9185 / 8586 / 9285 / 4443 / 4543) and a
   private temp dir per run (`scripts/with-private-tmp.sh`).

## 2. What was added

| File | Tests | Gap closed |
|---|---|---|
| `backend/internal/timeline/community_w536_test.go` (unit, fakes, `-race`) | `TestW536_DroppedRemovalShowsOnlyUntilTheEntryExpires` | Attack list: an entry between 60 s and 5 min old and a removal the capped array has dropped. Pins the documented staleness bound: the stale entry still shows the hidden post, a `since` token older than the drop is rejected (so the client cold-opens and lands on the bound), the post is gone once the entry expires. |
| | `TestW536_RestoredPostReturnsWhenTheEntryExpires` | The mirror image: a restore that puts a row back below the entry's range comes back only at the entry's expiry (<= 5 min). Pinned as the bound. See defect D-1. |
| | `TestW536_TruncationAtTheTokenCutoff` | Attack list: `removalsTruncatedAt` == the token cutoff (`issued - RemovalLag`): equal and one nanosecond earlier are accepted, one nanosecond later is rejected (`removed_reset`); a removal at exactly the cutoff is not listed, one nanosecond newer is. Fails under a mutation of the strict comparison. |
| | `TestW536_SinceTokenAcrossInstances` | Attack list: a `since` token issued by one `Server` is answered by a second one with no entry (same cursor key): window query only, new post and `removed_ids` returned, 5 reads, and the second's token is accepted by the first; a foreign key is VALIDATION at 0 reads. |
| | `TestW536_ConcurrentColdFills` | Attack list: 12 concurrent cold opens (`-race`): identical 20-row pages, no query beyond the page, each request inside the cold ceiling of page + 4 (24), the entry left is a clean warm hit. |
| | `TestW536_RefreshWithTwentyFiveNewPostsOnAWarmEntry` | Attack list: a refresh with 25 new posts on an expired entry: one query of at most the page, 20 posts + a gap token, the gap page holds the other 5 and closes. (The existing `TestCommunity_RefreshGapToken` has an entry-less refresh.) |
| | `TestW536_PageFiftyAgainstTheThirtyRowEntry` | Attack list: page 50 against the 30-row entry at 29, 30, 31, 45 and 60 posts: warm queries 0 / 0 / 1 / 1 / 1 reading exactly the rows below the entry (1, 15, 20), never more than the page, cold and warm pages identical. |
| | `TestW536_ModeratorSeesAllowedOnARaiderRow` | Attack list: F14 reply-hint edge pinned as intended (moderator keeps the raider's row and the hint is ALLOWED; a plain member does not see the row). |
| | `TestW536_LogFieldsNameNoIDs` | The request-line fields of the community feed carry counts and enums, never the community or caller id. |
| `backend/internal/apiserver/communities_w536_chain_integration_test.go` (real `Build` chain) | `TestW536_TakedownThenRefreshListsRemovedIDs` | **W5-29 acceptance 3 end to end** (moved here by #639): a takedown of a community post (`posts.FirestoreRepo.Takedown`, then `communities.FirestoreRepo.Append`, the two calls `opsctl takedown-post` makes), then the next `GetCommunityTimeline` refresh on another instance lists it in `removed_ids` (4 reads, token from the first instance accepted); a cold open drops it; a repeat `Append` writes nothing. |
| | `TestW536_ModeratorHideLeavesTheProfileRowUnlabelledAndListsRemovedIDs` | W5-28 over the wire: a member's hide is FORBIDDEN `not_moderator`; the moderator's hide costs 5 reads / 4 writes cold (first action); the post stays on the author's profile and in `GetPost` **without** its label while visible posts keep theirs; the next refresh lists it in `removed_ids`; a cold open drops it; a restore brings the label back. |
| | `TestW536_HideAndRestoreAreImmediateOnTheSameInstance` | A hide and a restore through the RPC take effect at once on the instance that served them (cached entry and cached community), through `removed_ids` and a cold open. |
| | `TestW536_SuspendedMidPagination` | **W5-29 acceptance 2 + N3**: a community suspended after page 1: the page token, the `since` token and a cold open (member, owner, outsider) answer the byte-identical NOT_FOUND of a missing id at <= 2 reads and 0 writes; GetCommunity shows it to its owner alone with status SUSPENDED; a member's CreatePost into it is NOT_FOUND and writes nothing; after the restore the very same tokens work again. |
| | `TestW536_CommunityReportThroughTheChain` | **W5-29 acceptance 1**: COMMUNITY report over the chain: 5 reads / 2 writes cold, 2 / 2 warm; report doc fields (owner as `targetOwnerId`, `authorHandle`, name, description, rules, creation time) and no member or moderator id in the evidence; repeat is `already_reported`; own community is VALIDATION `target_id`; suspended and missing are the same NOT_FOUND; the request log names `COMMUNITY` and never the community, text or uids. |
| | `TestW536_FlagModesAndTheCreatorsList` | **Flag modes and the creators list on the wire** (9 cases: off, allowlist with and without the caller, percent 0 and 100, on; creator and non-creator): FEATURE_DISABLED `feature=communities` at <= the interceptor's read and 0 writes on CreateCommunity, GetCommunity and GetCommunityTimeline; FORBIDDEN `reason=not_creator` with nothing read by the service (the whole request is the interceptor's read); `GetMe.enabled_features` carries `communities` exactly when the caller passes the gate. |
| | `TestW536_F14ReplyHintOnTheWire` | F14 with a real block through the graph RPC: the moderator keeps the blocked raider's row, the hint is ALLOWED, and the reply is NOT_FOUND (no oracle). Also members-only replies on the wire: a member's reply succeeds, an outsider sees NOT_ALLOWED and gets FORBIDDEN `not_member` with nothing written; a member the raider blocks does not see the row. |
| | `TestW536_RemovalsOverflowResetsTheSinceToken` | `recentRemovals` overflow on the wire with the real repository: 50 removals are listed (no reset); the 51st sets `removalsTruncatedAt`, the old token is VALIDATION `since_token` at 2 reads (the interceptor and the community, before any post read), a cold open works; a token issued inside the lag window is rejected too (by design, `posts.RemovalLag`), and accepted once the truncation is older than the lag. |
| `backend/internal/communities/repo_w536_integration_test.go` | `TestW536_JoinBurstOfFiftyKeepsMemberCountExact` | Counters under a join burst: 50 distinct users join one document at once. Every call succeeds or answers UNAVAILABLE with `outcome=contention`; after same-key retries `memberCount` == member docs == 51, every memberships doc names the community once. Measured on the emulator: 50 of 50 succeeded at once, `community_txn_attempts` = 1 for all 50 (the blind `Increment` never joins a read set). |

Not added, because the existing test already pins it through the right layer (named in section 3): the role x action matrix (repository, five roles for
hide and restore, eight role/target cases for SetMemberRole, six for ListModerationLog), the ban race, `budgettest` per RPC, the A1 query shapes, the
eraser, the export and the residue sweep, opsctl `community suspend|restore|archive` and `takedown-post` / `suspend-user` appends.

## 3. Acceptance criteria to named tests

All paths under `backend/`. Package names are the directory (`communities` = `internal/communities`). "NEW" is added by this ticket.

### W5-23 (write path)
| Criterion | Test |
|---|---|
| Caller not in `COMMUNITY_CREATORS`: FORBIDDEN `not_creator` with 0 reads | `communities TestCreateCommunity_CreatorsCheckIsFirst`, `TestNewWithoutCreatorsRefusesEveryone`; `pkg/platform/config TestLoad_CommunityCreators`; NEW wire `apiserver TestW536_FlagModesAndTheCreatorsList` (the whole request is the interceptor's read, 0 writes) |
| 2 owned: LIMIT_REACHED `limit=communities_owned` | `communities TestCreate_CapsAreExactAndWriteNothing` |
| Replay: 0 writes | `communities TestCreate_ReplayWritesNothingAndAnotherBodyIsRefused`, `TestCreate_ConcurrentSameKeyCreatesOne` |
| 11 rules: VALIDATION `field=rules` | `communities TestCreateCommunity_Validation`, `TestCreateCommunity_Boundaries` |
| Budgets Create / Update / Get (cold and warm) | `communities TestCreate_WritesThreeDocsAndTheRecordWithinBudget`, `TestUpdate_BudgetsModlogAndMemberships`, `TestGet_ColdAndWarmReads`, `TestGetCommunity_ColdReadsFitTheBudget` |
| SUSPENDED is NOT_FOUND (owner excepted in GetCommunity), ARCHIVED readable | `communities TestGet_SuspendedAndMissingCostTheSame`, `TestGetCommunity_NotFoundBytesAreIdentical`, `TestUpdate_RefusalsWriteNothing`; NEW wire `TestW536_SuspendedMidPagination` |

### W5-24 (lifecycle)
| Criterion | Test |
|---|---|
| Owner with one moderator: the moderator becomes owner, counts right | `communities TestEraser_OwnerWithModeratorsHandsOverToTheFirstActiveOne`, `TestEraser_OnlyAnActiveAccountMayTakeOver`, `TestEraser_SuccessorWhoseMembershipsAreGoneIsSkipped`, `TestEraser_HandoverTrimsTheLogToItsCap` |
| Owner without moderators: ARCHIVED, empty `ownerId`, text kept | `communities TestEraser_OwnerWithoutAnActiveModeratorArchivesAndKeepsTheText` |
| Rerun: 0 writes; resumable | `communities TestEraser_NoMembershipsIsOneReadAndDone`, `TestEraser_ChunksResumesAndDeletesMembershipsLast`, `TestEraser_ResumeSurvivesAChangedList`, `TestEraser_ErrorKeepsTheCheckpointAndTheMembershipsDoc`; `apiserver TestAccountLifecycle_CommunitiesEraserIsCrashSafe` (a kill after every side effect) |
| Moderator who hid, left, then deleted: the modlog no longer names the uid | `communities TestEraser_FormerModeratorAndBannedMemberLeaveNoTrace`, `TestModeration_BannedThenUnbannedThenDeletedLeavesNoTrace`; `apiserver TestAccountLifecycle_FormerModeratorLeavesNoTrace` |
| Residue sweep: no field names the uid | `apiserver TestAccountLifecycle_CommunitiesEraserIsCrashSafe`, `TestAccountLifecycle_FormerModeratorLeavesNoTrace` (`requireNoResidue`); `lifecycle_collections_guard_test.go` (T11 rows `communities`, `communityMembers`, `communityMemberships` and the negative cases) |
| Export `{joined, owned, banned, moderationActions, redactedCount}`, no other uid, reference-account budgets | `communities TestExport_ShapeRedactionAndNoOtherUID`, `TestExport_EmptyAndErrors`, `TestExport_ReferenceAccountReadsAndShape`, `TestExport_OwnerBannedSuspendedAndAnyNumberOfCommunities`, `TestEraser_ReferenceAccountMatchesTheADRBudget`; `apiserver TestAccountLifecycle_ExportContentsGolden` (the `communities` section of the golden) |
| A member whose community is gone, a banned member's deletion, `memberships` union | `communities TestEraser_MemberWhoseCommunityIsGoneOnlyLosesTheMemberDoc`, `TestMemberships_UnionIsSortedAndDeduplicated`, `TestScrub` |
| Eraser is never flag-gated | `apiserver lifecycle_wiring_test.go`; the lifecycle env runs with `FEATURE_COMMUNITIES` off and still erases |

### W5-25 (join, leave, My Communities)
| Criterion | Test |
|---|---|
| Banned user joins: FORBIDDEN `banned` | `communities TestJoin_BannedArchivedSuspendedAndGone`, `TestJoin_MapsRepoErrors` |
| Owner leaves: FAILED_PRECONDITION `owner` | `communities TestLeave_OwnerBannedAndStates` |
| Moderator leaves: out of `moderatorIds`, GetCommunity no longer lists them | `communities TestLeave_ModeratorLeavesModeratorIDsAndGetCommunityFollows`, `TestLeave_ModeratorPromotedElsewhereIsCaughtByModlogged`, `TestModeratorLeaveRacingAJoinBurstStaysConsistent` |
| 51 joins: LIMIT_REACHED | `communities TestJoin_FiftyFirstIsLimitReachedAndTheCapIsExact` |
| `memberCount` exact under a 10-join burst | `communities TestJoin_TenJoinsBurstKeepMemberCountExact`, `TestJoinLeaveRaces_KeepTheInvariantsAndMemberCountExact`; NEW `TestW536_JoinBurstOfFiftyKeepsMemberCountExact` (50 on one document, contention outcome checked) |
| Contention is retryable and logged (the `ABORTED` metric) | `communities TestMembership_ContentionIsRetryableAndLogged` (ABORTED -> UNAVAILABLE, `outcome=contention`), `TestNoteAttempts_RecordsTheCommunityField`; NEW burst test reads the attempts and outcome fields of every call |
| Daily join quota and the new-account tier; budgets Join / Leave / ListMyCommunities | `communities TestJoin_DailyQuotaAndTheNewAccountTier`, `TestJoin_BudgetsColdWarmAndWrites`, `TestLeave_BudgetsAndWrites`, `TestListMyCommunities_BudgetsOrderAndFilters`; `pkg/platform/quota TestCommunityKinds`, `TestCommunityKinds_QuotaMetadataName` |
| Already a member: 1 write (the idempotency doc); replay 0 | `communities TestJoin_AlreadyAMemberWritesTheIdempotencyDocOnly`, `TestJoin_ReplayWritesNothingAndAnotherBodyIsRefused`, `TestJoin_SameUserTwoKeysJoinsOnce` |

### W5-25b (directory and member list)
| Criterion | Test |
|---|---|
| SUSPENDED or ARCHIVED absent from the directory | `communities TestDirectory_OrderFilterAndBudgets`, `TestDirectory_SuspendedAfterTheTTLDisappears`, `TestListCommunities_FiltersAndRoles` |
| Warm directory entry: 0 to 1 reads | `communities TestListCommunities_WarmEntryAndTTL`, `TestDirectory_WorstCaseAt50AndAtStage0` |
| A member who blocks the viewer is absent from that viewer's page | `communities TestListCommunityMembers_Drops`, `TestMembers_BlocksAndTamperedToken` |
| BANNED rows for a non-moderator: FORBIDDEN `not_moderator` | `communities TestListCommunityMembers_BannedPage`, `TestMembers_BannedPageForModeratorsOnly`, `TestMembers_BanMovesARowFromOnePageToTheOther` |
| Tampered token: VALIDATION with 0 reads; cursor binding | `communities TestListCommunities_PageTokenIsValidationAt0Reads`, `TestListCommunityMembers_PagingAndCursorBinding`, `TestMembers_BlocksAndTamperedToken` |
| Budgets directory 52 cold / members 43 and 103 | `communities TestDirectory_OrderFilterAndBudgets`, `TestMembers_BudgetsAtPage20And50`, `TestListCommunityMembers_ColdBudgetAtPage20` |

### W5-26 (posting into a community)
| Criterion | Test |
|---|---|
| Non-member: FORBIDDEN `not_member`, 0 writes | `posts TestCommunityPost_Refusals`; `communities TestPostGate_Admit`, `TestPostGate_CheckMember` |
| A ban on another instance a second ago: the next post is refused (fresh read) | `posts TestCommunityPost_BanOnAnotherInstanceStopsTheNextPost` |
| 51 community posts in a day: QUOTA_EXCEEDED `community_posts`; per-community cap | `posts TestCommunityPost_QuotaAndCap`; `communities TestPostGate_AllowPost` |
| `ByCommunity` on 25 posts: 20 + 5 newest first; A1 query shapes (Before, After, settle sentinel, gap window, missing community) | `posts TestByCommunity_PagesNewestFirst`, `TestCommunityBoundsOf`; page size clamp `posts TestClampLimit`-style table in `service_test.go`; `timeline TestCommunity_TwentyFivePostsPageTwentyThenFive` |
| Budget +2 cold / +1 warm reads, +0 writes; fields stored | `posts TestCommunityPost_StoresFieldsAndBudgetDelta`, `TestCreate_CommunityPostFields`, `TestCreate_CommunityShape`, `TestCreate_CommunityGateOrder` |
| Archived, suspended, protected caller, reply with `community_id`, quote into a community | `posts TestCommunityPost_Refusals`, `TestCommunityPost_QuoteIntoCommunity`, `TestCreate_CommunityShape` |
| SUSPENDED: CreatePost into it is refused | `posts TestCommunityPost_Refusals` ("suspended"); NEW wire `apiserver TestW536_SuspendedMidPagination` |

### W5-26b (members-only replies and the label kill switch)
| Criterion | Test |
|---|---|
| Reply by a non-member: FORBIDDEN, 0 writes | `posts TestCommunityReply_MembersOnlyAndBudget`, `TestCreate_MembersOnlyReply`; `communities TestPostGate_CanReply`; NEW wire `apiserver TestW536_F14ReplyHintOnTheWire` |
| Reply by a member: +1 cold / +0 warm reads | `posts TestCommunityReply_MembersOnlyAndBudget` |
| Reply to a non-community post: +0 reads | `posts TestCreate_ReplyToPlainPostNeverAsksTheGate`, `TestCommunityReply_MembersOnlyAndBudget` |
| `communities` globally off: no `PostView` carries `community` (every builder) | `posts TestToView_CommunityLabel`, `TestHydrateViewer_CommunitiesGloballyOff`, `TestServer_CommunityLabelAndReplyHint`, `TestCreatePost_ResponseCarriesTheLabel`; `timeline TestTimelines_CommunityLabel` (home, user, list x on / hidden / off / allowlist), `TestCommunity_GloballyOffCarriesNoLabel`; `engagement TestLists_CommunityLabel`, `TestVotePoll_CommunityLabel` |
| `viewer_reply_permission` from the role (no new enum value) | `timeline TestCommunity_ReplyPermissionFromRole`; NEW `TestW536_ModeratorSeesAllowedOnARaiderRow` |

### W5-27 (GetCommunityTimeline and tabs)
| Criterion | Test |
|---|---|
| 25 posts: pages of 20 + 5 | `timeline TestCommunity_TwentyFivePostsPageTwentyThenFive`; chain `apiserver TestCommunityTimelineChain_Budgets` |
| Hidden post dropped and listed in `removed_ids` on the next refresh | `timeline TestCommunity_RefreshReadsAndRemovals`, `TestCommunity_HiddenByModerationIsDropped`, `TestCommunity_HiddenPostDroppedAndNeverLabelled`; NEW wire `TestW536_ModeratorHideLeavesTheProfileRowUnlabelledAndListsRemovedIDs`, `TestW536_HideAndRestoreAreImmediateOnTheSameInstance` |
| Post by a user the viewer blocks is dropped; F14 moderators keep raiders | `timeline TestCommunity_BlockedAuthorsDroppedPerViewer`, `TestCommunity_AuthorRules`, `TestCommunity_ProtectedAuthorDroppedEvenForModerators`; NEW wire `TestW536_F14ReplyHintOnTheWire` |
| Warm entry: 0 to 3 reads; cold 25 / 55; empty refresh 4 | `timeline TestCommunity_WarmEntryAndRefill`, `TestCommunity_ColdBudgetAtPageFifty`, `TestCommunity_RefreshWithoutEntryQueriesTheWindowOnly`; chain `TestCommunityTimelineChain_Budgets` (whole-request figures from a fresh `Build`) |
| A List token on a community: VALIDATION (and every other binding) | `timeline TestCommunity_TokenBinding`; chain `TestCommunityTimelineChain_StatusAndTokens` |
| SetHomeTabs with a joined (or any ACTIVE / ARCHIVED) community accepted | `timeline TestSetHomeTabs_CommunityTabs`; chain `apiserver TestCommunityTimelineChain_HomeTab`; `identity TestHomeTabs_*` |
| Status rules: SUSPENDED NOT_FOUND for everyone, byte-identical to missing; ARCHIVED readable | `timeline TestCommunity_StatusRules`; chain `TestCommunityTimelineChain_StatusAndTokens`; NEW `TestW536_SuspendedMidPagination` |
| `recentRemovals` overflow and token reset | `timeline TestCommunity_RemovalsTruncationAndOverflow`; NEW `TestW536_TruncationAtTheTokenCutoff`, wire `TestW536_RemovalsOverflowResetsTheSinceToken` |
| Flag modes (`communities` and `posts`) | `timeline TestCommunity_FlagModes`; NEW wire `TestW536_FlagModesAndTheCreatorsList` |
| Parallel cold fills, refills, gap | `timeline TestCommunity_ParallelColdOpens`, `TestCommunity_RefillWithFullPageReplacesEntry`, `TestCommunity_RefreshGapToken`; NEW `TestW536_ConcurrentColdFills`, `TestW536_RefreshWithTwentyFiveNewPostsOnAWarmEntry`, `TestW536_PageFiftyAgainstTheThirtyRowEntry` |

### W5-28 (moderation)
| Criterion | Test |
|---|---|
| A member hides: FORBIDDEN `not_moderator` | `communities TestHideRestore_RoleMatrixAndPostRules` (owner, moderator, member, banned, outsider x hide and restore); NEW wire `TestW536_ModeratorHideLeavesTheProfileRowUnlabelledAndListsRemovedIDs` |
| A moderator bans the owner or another moderator: FORBIDDEN | `communities TestSetMemberRole_RoleMatrix` (21 role/target/action cases, including `not_owner`, `moderator`, self, banned and non-member targets) |
| After a hide the post stays on the profile and Home without its label | `posts TestCommunityModerator_SetCommunityListing`; `communities TestHideRestore_BudgetsEffectsAndLateRetry`; `timeline TestTimelines_CommunityLabel` (hidden row, three surfaces); NEW wire (the real hide, the real profile timeline and `GetPost`) |
| 201 actions a day: RATE_LIMITED `community_mod_actions_daily` | `apiserver TestCommunityDailyCaps_StopTheCapPlusFirstCall`, `TestCommunitiesRateLimit_Guard` |
| 101 modlog entries: the oldest is dropped | `communities TestModlog_CapsAndTruncationMarker`, `TestAppendLog_KeepsTheNewest100AndNumbersEntries`, `TestLeave_ModlogIsTrimmedToTheCap` |
| First hide adds the community to `modlogged`, a second adds no write | `communities TestHideRestore_BudgetsEffectsAndLateRetry` (exact reads and writes), `TestSetMemberRole_BanUnbanBudgetsAndRecords` |
| Role x action matrix incl. ListModerationLog (owner, moderator only) | `communities TestListModerationLog_RolesPagingAndPeople`, `TestListModerationLog_StatusRules` |
| Idempotent replay (a late retry of a hide after a restore does not re-hide) | `communities TestHideRestore_BudgetsEffectsAndLateRetry`, `TestHideCommunityPost_ReplayAndNoChangeLeaveTheCacheAlone` |
| Budgets Hide / Restore 5 / 4 reads, 3 writes (+1); SetMemberRole | NEW wire (HideCommunityPost cold: 5 reads / 4 writes); `communities TestHideRestore_BudgetsEffectsAndLateRetry`, `TestSetMemberRole_BanUnbanBudgetsAndRecords` |
| Ban race: the fresh read wins | `posts TestCommunityPost_BanOnAnotherInstanceStopsTheNextPost`; `communities TestLeave_FreshReadOfAnOwnerThroughAStaleHintIsRefused`, `TestPostGate_CheckMember` |

### W5-29 (platform levers)
| Criterion | Test |
|---|---|
| COMMUNITY report: a report doc with the evidence, 2 writes; 5 cold / 2 warm reads | `moderation TestReport_CommunityStoresTheSnapshot`, `TestRepo_CommunityEvidenceRoundTripAndRetention`, `TestServer_CommunityReportFlagMatrix`, `communities TestReportableCommunity_Table`; NEW wire `TestW536_CommunityReportThroughTheChain` (evidence fields, 5 / 2 cold, 2 / 2 warm) |
| Suspended: GetCommunity and the feed NOT_FOUND, CreatePost refused | `communities TestPlatform_SuspendRestoreBudgetsAndEffects`; `timeline TestCommunity_StatusRules`; `posts TestCommunityPost_Refusals`; NEW wire `TestW536_SuspendedMidPagination` (all three, mid-pagination and with a `since` token) |
| Takedown of a community post: the next community refresh lists it in `removed_ids` | halves: `opsctl TestTakedownAndSuspend_Integration_CommunityRemovals`, `TestTakedownPost_AppendsToTheCommunityRemovalLog`, `posts TestModerator_TakedownReportsTheCommunity`; **NEW end to end `apiserver TestW536_TakedownThenRefreshListsRemovedIDs`** |
| opsctl `community suspend|restore|archive`, `--report`, dry runs, N10 | `opsctl TestCommunity_Integration_CLI`, `TestCommunity_UsageAndValidation`, `TestCommunity_SuspendRestoreCostAndOutput`, `TestCommunity_Archive`, `TestCommunity_SuspendWithReport`, `TestCommunity_MissingCommunityIsAnErrorWithNothingWritten`, `TestSuspendUser_AppendsToTheCommunityRemovalLog`, `TestRestoreAndUnsuspendDoNotTouchTheRemovalLog`; `communities TestPlatform_*` |
| Report target validation and quota tier | `moderation TestReport_CommunityValidationDoesNoWork`, `TestReport_CommunityNewAccountGetsTheLowerQuota`, `TestReport_CommunityOwnIsValidationTargetID`, `TestReport_CommunityNotFoundIsOneAnswer`, `TestReport_CommunityRepeatIsAlreadyReported`, `TestReportID_SeparatesCommunityTargets` |

### Ticket items (plan W5-36 "Description")
| Item | Test |
|---|---|
| Flag modes for `communities` | package: `communities TestGuard_FlagModes`, `TestServer_FlagGateOnEveryRPC`; `timeline TestCommunity_FlagModes`; `posts TestServer_CommunitiesFlagModes`; `moderation TestServer_CommunityReportFlagMatrix`; `pkg/platform/config TestLoad_CommunitiesFlagModes`; NEW wire `TestW536_FlagModesAndTheCreatorsList` |
| Creators allowlist | see W5-23 |
| Role x action matrix | see W5-28 |
| Ban races | see W5-28 |
| Members-only replies | see W5-26b |
| `budgettest` per the W5-20 table | every RPC has a `budgettest` assertion at the repository (exact) and the apiserver chain (whole request): see the rows above and section 7 |
| A1 query shapes | see W5-26 |
| `recentRemovals` overflow and token reset | see W5-27 |
| Counters under a join burst | see W5-25 |
| Eraser hand-over and archive; export; residue sweep | see W5-24 |
| Report targets and opsctl suspension (incl. W5-29 acceptance 3 end to end, suspension mid-pagination) | see W5-29 |

### Attack list (W5-27 and W5-28 reports)
| Item | Test |
|---|---|
| An entry 60 s to 5 min old with a dropped removal | NEW `timeline TestW536_DroppedRemovalShowsOnlyUntilTheEntryExpires` (bound pinned), `TestW536_RestoredPostReturnsWhenTheEntryExpires` |
| `removalsTruncatedAt` == the token cutoff | NEW `timeline TestW536_TruncationAtTheTokenCutoff` |
| A cross-instance `since` token | NEW `timeline TestW536_SinceTokenAcrossInstances`; chain `apiserver TestCommunityTimelineChain_Budgets` (token from one `Build`, refresh on another) and `TestW536_TakedownThenRefreshListsRemovedIDs` |
| Concurrent cold fills | NEW `timeline TestW536_ConcurrentColdFills` (`-race`); existing `TestCommunity_ParallelColdOpens` |
| A hide on another instance while a cached entry holds the post | `timeline TestCommunity_RefreshReadsAndRemovals`; NEW wire `TestW536_ModeratorHideLeavesTheProfileRowUnlabelledAndListsRemovedIDs` (hide on one `Build`, refresh on another) |
| F14 reply-hint edge: a moderator sees ALLOWED where CreatePost says NOT_FOUND, on purpose | NEW `timeline TestW536_ModeratorSeesAllowedOnARaiderRow`, wire `apiserver TestW536_F14ReplyHintOnTheWire` |
| A refresh with >= 25 new posts | existing `timeline TestCommunity_RefreshGapToken`; NEW `TestW536_RefreshWithTwentyFiveNewPostsOnAWarmEntry` |
| Page 50 vs a 30-row entry | existing `timeline TestCommunity_ColdBudgetAtPageFifty`; NEW `TestW536_PageFiftyAgainstTheThirtyRowEntry` (29, 30, 31, 45, 60) |

**Summary: every acceptance criterion of W5-23 to W5-29 now has a named test.** 70 criteria / ticket items mapped; 56 were already covered, 14 are
covered by new tests (13 of them also gain a wire-level test through the real chain; W5-29 acceptance 3 end to end is the one criterion that had none at all).

### Pending W5-53 / W5-51 (skipped, NOT passed)

Founder decision 2026-11-02 (F9 taken literally): a moderator may NOT hide or restore the owner's posts or another moderator's posts (FORBIDDEN `not_owner`).
Today's code lets a moderator do both, and the existing `TestHideRestore_RoleMatrixAndPostRules` never touches such a post (its posts are authored by a plain
user), so it does not encode the old behaviour. The cells are added as skipped tests so they turn on when the feature lands:

| Cell | Test | Status |
|---|---|---|
| mod1 hides the owner's post -> PermissionDenied `not_owner` | `communities TestHideRestore_ModeratorCannotTouchOwnerOrModeratorPosts/mod_hides_the_owner's_post` | SKIP, pending W5-53 |
| mod1 restores the owner's post -> `not_owner` | same test, `.../mod_restores_the_owner's_post` | SKIP, pending W5-53 |
| mod1 hides mod2's post -> `not_owner` | same test, `.../mod_hides_another_moderator's_post` | SKIP, pending W5-53 |
| mod1 restores mod2's post -> `not_owner` | same test, `.../mod_restores_another_moderator's_post` | SKIP, pending W5-53 |
| Moderator hides a reply (W5-51) | not written: W5-51 does not exist and there is no natural place for it | PENDING W5-51 |
| D-1: restore on the same instance returns a hidden post at once | `apiserver TestW536_RestoreOnTheSameInstanceReturnsAHiddenPostAtOnce` | SKIP, "D-1 follow-up (W5-38 plan follow-ups)" |

The W5-28 row "A member hides: FORBIDDEN" and the owner/moderator/member/banned/outsider matrix pass for posts by plain authors; owner-post and moderator-post
cells are the pending ones above.

## 4. Defects

**D-1 (Low). `timeline.Server.ForgetCommunityFeed` is never called in production code.** The hook is defined (`internal/timeline/service_community.go`
`ForgetCommunityFeed`), documented in `docs/code-map.md` as "the eviction hook for hide/restore (W5-28)" and in `docs/runbooks/communities.md` ("A hide or
restore handled on this instance should call `timeline.Server.ForgetCommunityFeed(cid)` (W5-28 owns the hook)"), but no hide, restore, ban or suspension calls it
(`grep -rn ForgetCommunityFeed backend --include=*.go` finds only the definition and tests).
- Effect: a **restore** on the instance that served it does not bring back a post that was hidden before that instance filled its entry: the row stays out
  until the entry expires (60 s TTL for an incremental refill, which cannot see a row below the entry's range, then at most 5 min). Hides are not affected
  (the written `recentRemovals` is applied to every entry row at once; `TestW536_HideAndRestoreAreImmediateOnTheSameInstance` passes).
- Repro: `TestW536_RestoreOnTheSameInstanceReturnsAHiddenPostAtOnce` (skipped with the reason "D-1 follow-up (W5-38 plan follow-ups)"; remove the `t.Skip` to see it fail): hide a post, open the feed
  on instance A (entry fills without it), restore on A, cold-open on A: expected 3 posts, actual 2.
- Bound: the documented 5 minutes, so not a correctness break; the hook was meant to make it immediate. Owner: backend-developer (W5-28 follow-up: call
  the hook from the apiserver wiring of HideCommunityPost / RestoreCommunityPost, or amend the runbook and code-map to say the hook is unused).

No other defect. Observations (not defects):

1. **A fresh token after an overflow is rejected for `RemovalLag` (135 s).** After the 51st removal, a client that cold-opens gets a `since_token` whose cutoff
   (`issued - RemovalLag`) is still older than `removalsTruncatedAt`, so its first refresh inside the lag window is VALIDATION and it cold-opens again.
   This is the documented Home rule (`posts/removals.go`: "tokens issued up to RemovalLag after it being rejected too"); pinned by
   `TestW536_RemovalsOverflowResetsTheSinceToken`. With more than 50 hides in a community inside 135 s the clients cold-open each poll; the runbook row covers it.
2. **No single-flight on a cold community fill.** Concurrent cold requests each query their own page (<= the page size each), the last writer sets the entry. Bounded and
   correct (`TestW536_ConcurrentColdFills`), but a burst on a fresh instance pays N x 20 reads instead of 20. At Stage 0 volumes this is noise.
3. **The LRU hard expiry runs on the real clock**, so the 5 min bound is tested by calling `ForgetCommunityFeed` (the same `Delete` the expiry performs) rather than
   by moving a clock. No seam was added.
4. **Emulator on Windows.** Port 8586 was unavailable on this machine for the whole run (`EADDRINUSE` on 127.0.0.1:8586 with no owner visible in `netstat`), so the
   private config uses 8587 for Pub/Sub; the owning PID could not be determined (`netstat -ano` showed no row for the port). Separately, `npx firebase-tools@latest`
   wants Pub/Sub emulator 0.8.37 while the global `firebase` 15.31.0 wants 0.8.36; each deletes the other's files in `~/.cache/firebase/emulators` as "outdated",
   which makes concurrent sessions fail with "Could not start Pub/Sub Emulator". Use the same `firebase` the Makefile resolves (the global one) in every session.

## 5. Lint

From `backend/` (`GOWORK=off`), 2026-11-02, on the merge of `origin/main@78279fc9`: `gofmt -l ./internal ./cmd ./pkg` prints nothing; `go vet -tags=integration ./...` clean;
`golangci-lint run ./...` (the `make lint` command): `0 issues.`

## 6. Results

Command (own port block 8581 / 9185 / 8586 / 9285 / 4443 / 4543, private temp dir, project `demo-dzeroth-local`, local config `firebase.w5-36.local.json`, untracked):

```
bash scripts/with-private-tmp.sh firebase emulators:exec --config firebase.w5-36.local.json --project demo-dzeroth-local --only firestore,auth,pubsub,storage \
  'bash backend/.w536run.sh'   # go test -tags=integration -race -count=1 -coverprofile=... -coverpkg=./internal/communities/... ./internal/communities/... ./internal/timeline/... ./internal/apiserver/...
```

| Package | Result | Time |
|---|---|---|
| `internal/communities` | ok | 27.1 s |
| `internal/timeline` | ok | 12.5 s |
| `internal/timeline/integration` | ok | 36.1 s |
| `internal/apiserver` | ok | 320.3 s |

- **Coverage of `internal/communities`** (combined profile of those four packages, `-coverpkg=./internal/communities/...`): **92.1 %** (92.0 % from its own package alone). Gate 70 %.
- **Skipped:** 5 (D-1 repro; the 4 W5-53 cells). Everything else ran and passed under `-race`.
- **Join burst, Go side** (`TestW536_JoinBurstOfFiftyKeepsMemberCountExact`): 50 distinct users on one community document: 50 of 50 succeeded first try, **0 ABORTED / 0 contention
  outcomes**, `community_txn_attempts` 1 for every call, `memberCount` == member docs == 51. W5-39 measured 401 joins with 0 ABORTED through k6 (the cloud-shaped
  load); this is the exact-count check on the emulator. The `ABORTED` -> UNAVAILABLE `outcome=contention` mapping is pinned separately by `TestMembership_ContentionIsRetryableAndLogged`.
- Emulator hygiene: the Pub/Sub emulator took ports 8586 and (on a retry) 8587 and left two orphan `java.exe` processes that I started; both were killed, no listener remains on the block.
  `ForgetCommunityFeed`/D-1 and the F9 cells are the only open items.

## 7. Budgets measured through the real chain (request-line `fs_reads` / `fs_writes`, interceptor included)

| RPC and shape | Measured | Documented |
|---|---|---|
| GetCommunityTimeline, empty `since` refresh after a takedown, cold instance | 4 / 0 | 4 |
| GetCommunityTimeline, suspended or missing, cold, every caller and token | 2 / 0 | <= 2 |
| GetCommunityTimeline, removal-log reset (`removalsTruncatedAt` newer than the cutoff) | 2 / 0 | before any post read |
| HideCommunityPost, cold, the moderator's first action | 5 / 4 | 5 / 4 (+1 on the first action) |
| ReportContent COMMUNITY, cold / warm | 5 / 2 reads, 2 writes | 5 / 2, 2 writes |
| CreateCommunity / GetCommunity / GetCommunityTimeline with `communities` off or not allowlisted | <= 1 / 0 | the interceptor's read only |
| CreateCommunity `not_creator` | <= 1 / 0 (the service reads nothing) | 0 service reads |
| CreateCommunity by a creator | 2 reads, 4 writes (with the profile cached) | 3 / 2 reads, 4 writes |
| JoinCommunity, 50 distinct users on one document | 50 of 50 first attempt, `community_txn_attempts` 1 | `memberCount` exact |

The cold and warm GetCommunityTimeline figures (25 / 55 cold, 3 warm) and the per-RPC repository budgets are asserted by `TestCommunityTimelineChain_Budgets` and the
repository tests listed in section 3 and were green in the full run.

## 8. Not run

- **Real-Firestore index proof.** The emulator never reports a missing index; the `communityId ==` plus `__name__` order shape (A1) was proven on dev by W5-26 (2026-11-01).
  No query here reported "requires an index"; `firebase/firestore.indexes.json` was not touched.
- **Load shapes of `stage-ladder`** (one community at 50 posts a minute): W5-39. The 50-join burst above is the join half.
- **Flutter / client tests:** W5-37. Security review of moderator abuse: W5-38.
- **`make ci` end to end** (Flutter analyze/test, buf): not part of a backend-tests ticket.
- **The warm-instance 60 s window** of a platform lever (a suspension or takedown written by opsctl is seen by a warm instance within the cache TTL): documented
  (ADR-0031 D12) and not asserted, because the suite does not sleep for synchronisation.

## 9. Reuse report

- Reused: `cmChain`, `newCMChain`-style construction through `newChain`, `seedCommunity`, `seedCommunityPosts`, `communitiesOn`, `feedIDs`, `ltUser`, `wireError`, `marshalDet`,
  `contractKey`, `lineBudget`, `rpcGetCommunityTimeline`, `rpcReportContent`, `budgettest` (apiserver); `commRig`, `newCommRig`, `wantAPIErr`, `commPosts`, `fakeCommunities` (timeline);
  `newJoinEnv`, `e.user`, `e.seedOwned`, `e.join`, `e.count`, `e.memberships` (communities).
- Extended: none.
- Generalized/moved: none.
- Created: `w536` / `w536Seed` (apiserver test file only): a chain with the community, graph and reports clients and a seeder that also writes moderators, members, banned members and
  rules, because `seedCommunity` seeds one member and no rules. Local to the one test file; not a shared helper.
- Catalog updated: no (test helpers only).
