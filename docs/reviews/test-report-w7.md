# Test report: UI wave W7 (Messaging v1), backend

Plan: `docs/plans/ui-w7-messaging.md` (W7-20). Design: ADR-0027 and its dated notes (idempotency, takedown reach). The client half is
W7-21; the load shapes (50 sends/s into one conversation, 300 concurrent pollers) are W7-23 and are not run here.

## W7-20: backend tests, traceability audit (2026-10-29)

Tester: tester agent. Branch `test/ui-w7-20-backend-tests` on `main@60f1e353` (W7-5 to W7-12 and W7-19 merged; W7-18 merged as #442).

**VERDICT: PASS for W7-20 as specified**, with two Low defects filed as skipped tests (D-1, D-2, section 5) and four observations (section 6).
Every acceptance criterion of W7-4 to W7-12 and every bullet of the W7-20 description has a named test (section 3). All 45 explicit
acceptance criteria already had a named package-level test when the audit started; six of them (the read RPCs outside the allowlist, a
non-participant's NOT_FOUND bytes on ListMessages, the 31st poll, and the badge after a mark-read, in W7-4, W7-7, W7-8 and W7-11) had never
run through the interceptor chain, and the W7-20 description and the W7-8 description named seven more cases with no test at all
(blockedByOverflow accounts, the per-minute and daily send caps of an established account, concurrent first messages, the reference-account
budgets, a mid-range percent, degraded mode for MarkConversationRead and the reads, and the "malformed-after-validation" NOT_FOUND). The audit
added 18 test functions for those 13 gaps (16 run, 2 are skipped for D-1 and D-2). No production code was edited.

---

### 1. What was run

| Suite | Command | Result |
|---|---|---|
| Messaging package, unit + integration, with coverage | `GOWORK=off go test -tags=integration -count=1 -coverprofile=... ./internal/messaging/...` against the emulators | **green**, coverage **93.7 %** of statements (gate 70 %) |
| New apiserver chain tests | `go test -tags=integration -run 'TestMessagingChain_(Read\|Percent\|Readonly\|MarkRead\|SendCaps\|Suspended\|BlockedBy)' ./internal/apiserver` | green; the defect test is skipped (section 5) and reproduced with `W720_RUN_DEFECTS=1` |
| Whole module, one package at a time | `go test -tags=integration -p 1 -coverprofile=cover-internal.out -coverpkg=./internal/... ./...` (the `make test-int` command, see environment note) | **green**, 39 packages `ok`, none failed, combined `internal/` coverage **92.9 %** (gate 70 %). That run was before the last edits to three tests (the read limiter's limit of 5, the D-2 test, the eraser formula); after them and after merging `origin/main` (W7-21, client and docs only) the packages `internal/messaging` (93.7 %), `internal/apiserver`, `internal/notifications`, `internal/moderation`, `internal/identity` and `cmd/opsctl` were run again in full, all `ok` |
| gofmt, `go vet -tags=integration`, `golangci-lint run --build-tags integration` | on `./internal/messaging/...` and `./internal/apiserver/...` | clean, 0 issues |
| Promotion checks | `check-flag-registry.sh` (23 flags registered, `messaging` included), `check-field-overrides.sh` (42 overrides acknowledged) | pass |

Environment notes:
- `-race` was not run: CGO is off on this Windows machine. CI on Linux runs it.
- Emulators ran from an untracked scratch config on ports 44xxx (`docs/runbooks/emulator-collisions.md` section 4) behind
  `scripts/with-private-tmp.sh`, started with `emulators:start` and kept up while I iterated, so the final whole-module run is the
  same `go test` command `make test-int` runs, not `make test-int` itself. The scratch config is deleted before the commit.
- Nothing was run against dev or prod.

### 2. What was added

| File | Tests | Covers |
|---|---|---|
| `backend/internal/apiserver/messaging_reads_chain_integration_test.go` | `TestMessagingChain_ReadBudgetTable`, `TestMessagingChain_ReadAuthzIsByteIdentical` | budgets of the three read RPCs through the whole chain; wire-level NOT_FOUND bytes and token VALIDATION |
| `backend/internal/apiserver/messaging_matrix_chain_integration_test.go` | `TestMessagingChain_ReadRPCsFlagClass`, `_PercentBucketDecidesCallerAndRecipient`, `_ReadonlyKeepsReadsAndRefusesMarkRead`, `_ReadLimiterSharedBucket`, `_MarkReadDropsTheBadgeOnTheNextGetMe`, `_SendCapsOfAnEstablishedAccount`, `_SuspendedRecipientAndCallerMute`, `_BlockedByOverflowAccountsOnSend`, `_BlockedByCallerReadSide` (control), `_BlockedByOverflowCallerReadSide` (skipped, D-1), `_ListMessagesMalformedParticipantListIsNotFound` (skipped, D-2) | the F6 flag classes of the read RPCs, percent buckets, degraded mode, the read limiter, the badge after a mark-read, the send caps, suspended recipient, the caller's own mute, blockedByOverflow, a malformed participant list |
| `backend/internal/messaging/concurrency_integration_test.go` | `TestSend_ConcurrentSameKeyIsOneMessage`, `TestSend_ConcurrentRequestCapHolds`, `TestSend_ConcurrentSendsLoseNoUnreadIncrement` | sends racing from several instances |
| `backend/internal/messaging/reference_budget_integration_test.go` | `TestEraser_ReferenceAccountBudget`, `TestExport_ReferenceAccountBudget` | the plan's reference account (20 conversations, 300 own messages) |

The tests reuse `dmChain`, `budgettest`, `wireBytes` and `lineBudget` from the existing chain tests; the new helpers (`listConvs`, `listMsgs`,
`markRead`, `block`, `overflow`) are methods on `dmChain` in the new files.

### 3. Traceability

Paths: `msg/` = `backend/internal/messaging/`, `api/` = `backend/internal/apiserver/`, `notif/` = `backend/internal/notifications/`,
`cfg/` = `backend/pkg/platform/config/`, `ident/` = `backend/internal/identity/`, `modr/` = `backend/internal/moderation/`.
"chain" means through `apiserver.Build` with the interceptors; "new" marks a test added by this ticket.

#### W7-4: flag, config, skeleton

| Criterion | Test(s) |
|---|---|
| `FEATURE_MESSAGING` unset: any RPC FEATURE_DISABLED with 0 reads | `msg/server_test.go:TestServer_AllSixHandlers`; chain: `api/messaging_matrix_chain_integration_test.go:TestMessagingChain_ReadRPCsFlagClass/off` (new, the 3 reads at 1 read), `api/messaging_chain_integration_test.go:TestMessagingChain_FlagModes` (send), `api/messaging_accept_delete_chain_integration_test.go:TestMessagingChain_AcceptDeleteFlagModes` |
| Allowlisted uid: `GetMe.enabled_features` has `messaging` for that uid only | `msg/service_test.go:TestEnabledFeatures`; `cfg/messaging_test.go:TestLoad_MessagingOverridesAndValidation`; chain: `TestMessagingChain_ReadRPCsFlagClass` and `TestMessagingChain_PercentBucketDecidesCallerAndRecipient` (new) |
| Allowlist mode, caller outside: ListConversations works, SendMessage FEATURE_DISABLED | `msg/service_list_test.go:TestListConversations_FlagClass`; `msg/list_integration_test.go:TestList_WorksForACallerOutsideTheAllowlist`; chain: `TestMessagingChain_ReadRPCsFlagClass/allowlist_without_the_caller` (new, all three reads) |
| `check-flag-registry.sh` passes; the guard test sees every RPC in the read budget | the script (run for this report, pass); `api/messaging_ratelimit_test.go:TestMessagingRateLimitWiring` |
| Flag modes off / allowlist / percent per RPC class | `msg/service_test.go:TestService_FlagModes`; chain `TestMessagingChain_ReadRPCsFlagClass` (off, allowlist with and without the caller, percent 0, on); `TestMessagingChain_PercentBucketDecidesCallerAndRecipient` (new, a mid percent that puts the caller in and the recipient out, on two instances) |
| Config bounds (reject 0 and negatives); quota record round trip | `cfg/messaging_test.go:TestLoad_MessagingDefaults`, `TestLoad_MessagingOverridesAndValidation`; `cfg/config_test.go` env list; `backend/pkg/platform/quota/quota_test.go:TestDMNewKind` |
| Startup `feature_flags` line lists `messaging` | chain `TestMessagingChain_ReadRPCsFlagClass` and `TestMessagingChain_PercentBucketDecidesCallerAndRecipient` (new) |

#### W7-5: SendMessage

| Criterion | Test(s) |
|---|---|
| Mutual follows: B's `dmInbox` entry, unread 1, one event | `msg/send_integration_test.go:TestSend_MutualGoesToInboxWithOneEvent`; chain `TestMessagingChain_MutualRequestAndTheFourthMessage` |
| Non-mutual: B's `dmRequests`, no event | `msg/send_integration_test.go:TestSend_RequestPathAndTheFourthMessage`; chain `TestMessagingChain_MutualRequestAndTheFourthMessage` |
| 4th request message: LIMIT_REACHED `request_unanswered` | the same two tests; concurrent: `msg/concurrency_integration_test.go:TestSend_ConcurrentRequestCapHolds` (new) |
| 21st new conversation: `dm_new_daily` (5 for a new account) | `msg/send_integration_test.go:TestSend_NewConversationDailyQuota`; `msg/service_send_test.go:TestSend_NewAccountDailyCap`; chain `TestMessagingChain_NewConversationQuota` |
| B blocks A: CANNOT_MESSAGE, bytes equal to a deleted account and a recipient with messaging off | `msg/service_send_test.go:TestSend_RefusalsAreByteIdentical`; chain `TestMessagingChain_RefusalsAreByteIdentical` (block either way, DELETING, messaging off, gone); `TestMessagingChain_SuspendedRecipientAndCallerMute` (new, SUSPENDED); `TestMessagingChain_BlockedByOverflowAccountsOnSend` (new) |
| B muted A: delivered, `silent`, no unread, no event | `msg/send_integration_test.go:TestSend_MutedSenderIsDeliveredSilently`; chain `TestMessagingChain_MutedSenderIsSilent`; the caller's own mute: `TestMessagingChain_SuspendedRecipientAndCallerMute` (new) |
| Same key twice: one message, second call 0 writes | `msg/send_integration_test.go:TestSend_ReplayAndKeyReuse`; chain `TestMessagingChain_ReplayAndKeyReuse`; concurrent: `msg/concurrency_integration_test.go:TestSend_ConcurrentSameKeyIsOneMessage` (new) |
| Same key, other text: VALIDATION | the same two replay tests |
| `gone` conversation: CANNOT_MESSAGE | `msg/send_integration_test.go:TestSend_GoneConversation`; chain `TestMessagingChain_RefusalsAreByteIdentical` |
| `DEGRADED_MODE=readonly` refused by the interceptor | chain `TestMessagingChain_DegradedReadonlyRefusesSend`; `msg/server_test.go:TestServer_ReadonlyRefusesTheMutations` |
| Flag matrix (caller and recipient) | `msg/service_send_test.go:TestSend_FlagMatrix`; chain `TestMessagingChain_FlagModes` |
| `budgettest` 5 / 7 cold, 2.5 planning, writes 3 / 4 / 5 | chain `TestMessagingChain_BudgetTable` (accepted 5 / 3, new conversation 7 / 5 mutual and request, request 2nd message 5 / 4, accepting reply 5 / 4 / 1, warm 1 / 3) |
| Concurrency: two senders on one new conversation create one | `msg/send_integration_test.go:TestSend_TwoSendersCreateOneConversation` |
| Fuzz of the text through the shared fixtures | `msg/text_fixture_test.go:TestSend_SharedTextFixture`, `FuzzSendText` |
| Per-minute cap, daily cap of an established account | chain `TestMessagingChain_SendCapsOfAnEstablishedAccount` (new); new-account daily: `TestMessagingChain_NewAccountDailySendCap` |
| Request line has no text or uid | chain `TestMessagingChain_RequestLineHasNoSecrets` |

#### W7-6: lifecycle

| Criterion | Test(s) |
|---|---|
| A deleted, B with 5 messages each: A's 5 are `DELETED_ACCOUNT`, B's 5 intact, B's entry "Deleted account", A's entries gone, a send by B CANNOT_MESSAGE | `msg/lifecycle_integration_test.go:TestEraser_DeletedUserLeavesTombstonesForThePeer` (CANNOT_MESSAGE at lines 290 and 292), `TestEraser_RequestRecipientEntryInDmRequests`, `TestEraser_RequesterDeleted`; chain `api/account_lifecycle_messaging_integration_test.go:TestAccountLifecycle_MessagingCrashAtEverySideEffect` |
| Both deleted: no doc under `conversations/{convId}` | `msg/lifecycle_integration_test.go:TestEraser_BothDeletedLeavesNothing`, `TestEraser_BothDeletedConcurrently`; `api/account_lifecycle_messaging_integration_test.go:TestAccountLifecycle_MessagingBothDeleted` |
| A crash at every page boundary resumes with no duplicate or missing work | `msg/eraser_test.go:TestEraser_ResumesAfterACrashOrErrorAtEveryCall`, `TestEraser_StateMachine`; `api/account_lifecycle_messaging_integration_test.go:TestAccountLifecycle_MessagingCrashAtEverySideEffect` (production job handler, T16 fault injection) |
| Export matches the golden; no peer uid, no received text | `msg/lifecycle_integration_test.go:TestExport_MatchesGolden`; `msg/export_test.go:TestExport_OwnTextReceivedAsTimeOnlyNoPeerUID` |
| Guard test passes and fails if any of the four rows is removed | `api/lifecycle_collections_guard_test.go:TestLifecycleCollections_GuardCatchesGaps` ("without the conversations / messages / dmInbox / dmRequests row"), `TestLifecycleCollections_EveryCollectionHasARow` |
| `budgettest` per page; reference account | `msg/lifecycle_integration_test.go:TestEraser_TombstonesInPagesOf500` (every call at most 500 writes); `msg/reference_budget_integration_test.go:TestEraser_ReferenceAccountBudget`, `TestExport_ReferenceAccountBudget` (new, section 4) |
| Queries need no composite index | `msg/lifecycle_integration_test.go:TestQueries_RunWithoutAnyCompositeIndex` |

#### W7-7: ListConversations

| Criterion | Test(s) |
|---|---|
| 25 conversations: pages of 20 + 5, newest first | `msg/list_integration_test.go:TestList_PagesNewestFirstWithinBudget`; `msg/service_list_test.go:TestListConversations_PagesAndSince` |
| `since` token and 1 new message: exactly that entry | `msg/list_integration_test.go:TestList_SinceReturnsTheMovedEntry`; `msg/service_list_changed_test.go:TestListConversations_SinceFollowsChangedAt` |
| Request from a blocked account: absent, the token still advances | `msg/list_integration_test.go:TestList_RequestsHideBlockedMutedBlockingPeers`; `msg/service_list_test.go:TestListConversations_HiddenEntriesStillAdvanceTokens` |
| Foreign or tampered token: VALIDATION with 0 reads | `msg/list_integration_test.go:TestList_ForeignOrTamperedTokenCostsNothing`; chain `api/messaging_reads_chain_integration_test.go:TestMessagingChain_ReadAuthzIsByteIdentical` (new, VALIDATION at the interceptor's 1 read) |
| Allowlist-off for the caller: the list still works | `msg/list_integration_test.go:TestList_WorksForACallerOutsideTheAllowlist`; chain `TestMessagingChain_ReadRPCsFlagClass` (new) |
| Budget 23 cold first page, 3 refresh | chain `TestMessagingChain_ReadBudgetTable` (new): first page of 20 = 23, REQUESTS of 3 = 5, older page of 2 = 4, `since` with nothing new = 2; package level `TestList_PagesNewestFirstWithinBudget` |
| Block and mute matrix; INBOX keeps blocked entries with `can_reply = false` | `msg/list_integration_test.go:TestList_InboxKeepsBlockedWithoutReply`, `TestList_RequestsHideBlockedMutedBlockingPeers`; `msg/service_list_test.go:TestListConversations_RequestsReadTimeRules`, `TestListConversations_InboxKeepsEverything`; overflowed caller: `TestMessagingChain_BlockedByCallerReadSide` (new, control) and D-1 |
| Token binding to `(uid, folder)` | `msg/service_list_test.go:TestListConversations_Validation`; `msg/list_integration_test.go:TestList_ForeignOrTamperedTokenCostsNothing` ("another user", "another folder") |
| `request_count` on the first INBOX page only | `msg/service_list_test.go:TestListConversations_RequestCountOnFirstInboxPageOnly`; chain `TestMessagingChain_ReadBudgetTable` (`request_count` = 3) |

#### W7-8: ListMessages and MarkConversationRead

| Criterion | Test(s) |
|---|---|
| 45 messages: 20 / 20 / 5 | `msg/messages_integration_test.go:TestListMessages_PagesWithinBudget`; `msg/service_messages_test.go:TestListMessages_PagesNewestFirst` |
| Poll with 0 new: 1 query read (+ interceptor and conversation when cold) | `msg/messages_integration_test.go:TestListMessages_PollWithinBudget`; chain `TestMessagingChain_ReadBudgetTable` (new: cold poll 3, with 1 new 4) |
| Non-participant: the same bytes as an unknown id | `msg/messages_integration_test.go:TestListMessages_NotFoundByteIdentical`; `msg/service_messages_test.go:TestListMessages_NotFoundIsByteIdentical`; chain `TestMessagingChain_ReadAuthzIsByteIdentical` (new: non-participant, unknown, well-formed-but-underived id, and SendMessage by `conversation_id`, all one byte string, at most 2 reads); the "malformed-after-validation" case (a conversation document whose participant list is not a pair): `TestMessagingChain_ListMessagesMalformedParticipantListIsNotFound` (new, **skipped: D-2**) |
| `clearedAt` set: older messages not returned | `msg/messages_integration_test.go:TestListMessages_ClearedAtOnEmulator`; `msg/service_messages_test.go:TestListMessages_ClearedAt` |
| 31 polls in a minute: RATE_LIMITED | `api/messaging_ratelimit_test.go:TestMessagingReadBucketLimitsPolls`; chain `TestMessagingChain_ReadLimiterSharedBucket` (new, the first call over a 5-a-minute limit on the shared ListConversations + ListMessages bucket, 0 reads; another user and MarkConversationRead unaffected; the 30 / 31st is the unit test) |
| MarkConversationRead: the badge drops on the next GetMe from this instance | `msg/service_messages_test.go:TestMarkRead` ("writes and evicts the badge"); chain `TestMessagingChain_MarkReadDropsTheBadgeOnTheNextGetMe` (new) |
| Budgets 24 / 54 cold, 3 poll cold; mark-read 1 write | chain `TestMessagingChain_ReadBudgetTable` (new): first page of 20 = 24, of 50 = 54, older page 24, poll 3 / 4, MarkConversationRead 1 read + 1 write (0 writes with no entry); package level `TestListMessages_PagesWithinBudget`, `TestMarkRead_WritesOwnEntryOnly` |
| Settle-window duplicates; tombstone render | `msg/messages_integration_test.go:TestListMessages_GapFillOnEmulator`, `TestListMessages_PollWithinBudget`, `TestListMessages_TombstonesAndDeletedPeer` |
| Foreign or tampered since / page tokens | `msg/service_messages_test.go:TestListMessages_Validation`; chain `TestMessagingChain_ReadAuthzIsByteIdentical` (new, six cases at 1 read) |
| MarkConversationRead of a conversation that is not the caller's | `msg/messages_integration_test.go:TestMarkRead_RequestsFolderAndMissingEntry`; chain `TestMessagingChain_ReadAuthzIsByteIdentical` (new, success with 0 writes, nobody else's entry touched) |

#### W7-9: Accept and Delete

| Criterion | Test(s) |
|---|---|
| B accepts: both see it in the Inbox, B's next reply pushes to A | `msg/accept_delete_integration_test.go:TestAccept_MovesTheRequestWithinBudget` (lines 94 to 165: no event on accept, one push on B's reply); chain `api/messaging_accept_delete_chain_integration_test.go:TestMessagingChain_AcceptMovesTheRequest` |
| A accepts its own request: NOT_FOUND | `msg/accept_delete_integration_test.go:TestAccept_OnlyTheRecipient_NotFoundByteIdentical`; chain `TestMessagingChain_AcceptDeleteNotFoundIsByteIdentical` |
| B deletes: gone from B's inbox, A's next message re-creates B's request entry with only that message | `msg/accept_delete_integration_test.go:TestDelete_ThenANewMessageRecreatesTheEntry`, `TestDelete_RequestKeepsTheSendersCap`; chain `TestMessagingChain_DeleteAppliesAtOnce` |
| Budget 3 reads / 2 writes / 1 delete; replay; races | chain `TestMessagingChain_AcceptMovesTheRequest` (3 / 2 / 1, replay 2), `TestMessagingChain_DeleteAppliesAtOnce` (3 / 1 / 1); `msg/accept_delete_integration_test.go:TestAcceptVsDelete_Race`, `TestAcceptVsSend_Race`, `TestAccept_ReplayOnEmulator` |
| Accept per caller, Delete not globally off | `msg/service_accept_delete_test.go:TestAcceptDelete_FlagModes`; chain `TestMessagingChain_AcceptDeleteFlagModes` |

#### W7-10: push hook

| Criterion | Test(s) |
|---|---|
| `message` event: 0 rows, 1 FCM send per device, `pushed=1` | `notif/message_push_test.go:TestDeliver_MessageIsPushOnly`; `notif/repo_firestore_integration_test.go:TestIntegration_MessagePushIsPushOnlyAndBudgeted` (0 writes, 0 rows, budget 4 / 7 with 5 devices) |
| Recipient muted the actor: `suppressed=1`, no send | `notif/message_push_test.go:TestDeliver_MessageSuppressionAndFlags` |
| 21st message push in an hour `push_throttled`, like and follow pushes still go out | `notif/message_push_test.go:TestDeliver_MessageOwnLimiterBucket`; `notif/repo_firestore_integration_test.go:TestIntegration_MessagePushIsPushOnlyAndBudgeted` (21st throttled at 2 reads) |
| An older revision drops it as `unknown_type` with no error | `notif/message_push_test.go:TestHandler_MessageAndOldRevision` |
| FCM payload has no handle, text or uid | `notif/message_push_test.go:TestMessagePushPayload`; `notif/repo_firestore_integration_test.go:TestIntegration_MessagePushIsPushOnlyAndBudgeted` (data keys are exactly `type` and `conversationId`); `notif/push_ids_only_test.go:TestPush_CarriesIdsOnlyForEveryType` |
| Flag matrix `notifications` x `messaging` | `notif/message_push_test.go:TestEmitterRequiresMessagingFlag`; `notif/repo_firestore_integration_test.go:TestIntegration_MessagePushFlagMatrix` (0 reads when either is off) |
| Messaging adapter reaches the fan-out push-only; `ListNotifications` never lists it | `api/messaging_wiring_test.go:TestMessageNotifier`, `TestMessageEvent_ReachesTheFanoutAsPushOnly`; no row exists to list (`TestDeliver_MessageIsPushOnly`) |
| Validate event shape | `notif/message_push_test.go:TestValidateMessageEvent` |

#### W7-11: GetMe badge

| Criterion | Test(s) |
|---|---|
| 3 unread: 3 | `msg/badge_integration_test.go:TestIntegration_UnreadConversationsCount`; chain `api/messaging_badge_integration_test.go:TestMessagingChain_GetMeUnreadConversations` (3 reads cold, 0 warm) |
| 150 unread: 100 (the cap) | `msg/badge_integration_test.go:TestIntegration_UnreadConversationsCount` ("150 unread, capped") |
| Flag off: 0 and 0 extra reads | chain `TestMessagingChain_GetMeUnreadConversations` (messaging off for the caller: 0, 2 reads, no cache field logged); `ident/message_badge_test.go:TestGetMe_UnreadConversationCount` |
| Mark-read on this instance: the next GetMe recounts | chain `TestMessagingChain_MarkReadDropsTheBadgeOnTheNextGetMe` (new); after a send: `TestMessagingChain_GetMeUnreadConversations`; `ident/message_badge_test.go:TestGetMe_UnreadConversationCache` |

#### W7-12: report a message

| Criterion | Test(s) |
|---|---|
| B reports A's message: a report with that text, `already_reported` on a repeat | `api/messaging_report_chain_integration_test.go:TestMessageReport_EvidenceDuplicateAndLog`; `modr/message_test.go:TestReport_MessageCopiesOnlyThatMessageAsEvidence`, `TestReport_MessageRepeatIsAlreadyReported` |
| Non-participant guessing ids: NOT_FOUND, the bytes of an unknown message | `api/messaging_report_chain_integration_test.go:TestMessageReport_ParticipantMatrixAndOneNotFound`, `TestMessageReport_NonParticipantSameBytesWarmOrCold`; `msg/report_test.go:TestReportableMessage_EveryNotFoundCauseIsTheSameValue` |
| Takedown: both participants see "This message was removed" | `msg/report_integration_test.go:TestReportAndTakedown_BothParticipantsSeeTheMessageRemoved`; `msg/takedown_reach_integration_test.go:TestTakedownReach_LastMessageReachesBothParticipants`; `api/messaging_report_chain_integration_test.go:TestMessageReport_TakedownAndReporterErasure` |
| Budget 6 cold / 3 warm, 2 writes | `api/messaging_report_chain_integration_test.go:TestMessageReport_BudgetColdWarmAndDuplicate`, `TestMessageReport_ColdBudgetsOfRefusalsAndDuplicate`; takedown 4 / 4: `msg/report_integration_test.go:TestReportAndTakedown_BothParticipantsSeeTheMessageRemoved`, `msg/takedown_reach_integration_test.go:TestTakedownReach_WritesAndBudget` |
| Participant matrix | `msg/report_test.go:TestReportableMessage_ParticipantMatrix`; `api/messaging_report_chain_integration_test.go:TestMessageReport_RequestRecipientCanReport`, `TestMessageReport_BlockedPeerIsStillReportable`, `TestMessageReport_StaysReportableAfterDeleteForMe` |
| `opsctl` dry run | `backend/cmd/opsctl/messages_test.go:TestMessagesTakedown_DryRunWritesNothing`; `msg/report_integration_test.go:TestTakedown_DryRunReadsTheSameAndWritesNothing` |
| Flag `reports` + `messaging` not globally off | `api/messaging_report_chain_integration_test.go:TestMessageReport_FlagMatrix`; `modr/message_test.go:TestServer_MessageReportFlagMatrix`; `api/moderation_messages_test.go:TestMessageReportFlagName_IsMessagingsOwn` |

#### W7-20 description bullets

| Bullet | Test(s) |
|---|---|
| Flag modes off / allowlist / percent / on, caller x recipient, not-globally-off reads | `TestMessagingChain_FlagModes`, `TestMessagingChain_ReadRPCsFlagClass` (new), `TestMessagingChain_PercentBucketDecidesCallerAndRecipient` (new), `TestMessagingChain_AcceptDeleteFlagModes`, `TestMessageReport_FlagMatrix`, `notif TestIntegration_MessagePushFlagMatrix` |
| Authz matrix with byte-identical NOT_FOUND | `TestMessagingChain_ReadAuthzIsByteIdentical` (new), `TestMessagingChain_AcceptDeleteNotFoundIsByteIdentical`, `TestMessageReport_ParticipantMatrixAndOneNotFound`, `msg TestListMessages_NotFoundByteIdentical` |
| Block and mute matrix on send and read, both directions, `blockedByOverflow` accounts, refusal bytes identical across causes | send: `TestMessagingChain_RefusalsAreByteIdentical`, `TestMessagingChain_SuspendedRecipientAndCallerMute` (new), `TestMessagingChain_BlockedByOverflowAccountsOnSend` (new); read: `msg TestList_RequestsHideBlockedMutedBlockingPeers`, `TestList_InboxKeepsBlockedWithoutReply`, `TestMessagingChain_BlockedByCallerReadSide` (new); overflowed caller on read: `TestMessagingChain_BlockedByOverflowCallerReadSide` (new, skipped, D-1) |
| Caps: per minute, daily, new conversations (new accounts), request unanswered | `TestMessagingChain_SendCapsOfAnEstablishedAccount` (new), `TestMessagingChain_NewAccountDailySendCap`, `TestMessagingChain_NewConversationQuota`, `TestMessagingChain_MutualRequestAndTheFourthMessage`, `TestSend_ConcurrentRequestCapHolds` (new) |
| Idempotency: replay, same key other body, concurrent first messages | `TestMessagingChain_ReplayAndKeyReuse`, `msg TestSend_ReplayAndKeyReuse`, `TestSend_TwoSendersCreateOneConversation`, `TestSend_ConcurrentSameKeyIsOneMessage` (new), `TestDelete_RetryWithTheSameKeyAfterANewerMessage`, `TestMessagingChain_DeleteRetryWithTheSameKey` |
| `budgettest` on every RPC per the table | section 4 |
| Eraser (tombstone, both gone, crash resume) and export golden | W7-6 table above |
| Push hook (no row, suppression, own limiter, payload golden) | W7-10 table above |
| GetMe badge | W7-11 table above |
| Report MESSAGE | W7-12 table above |
| `DEGRADED_MODE=readonly` | Send: `TestMessagingChain_DegradedReadonlyRefusesSend`; Accept and Delete: `TestMessagingChain_DegradedReadonlyRefusesAcceptAndDelete`; MarkConversationRead refused and the two list RPCs still served: `TestMessagingChain_ReadonlyKeepsReadsAndRefusesMarkRead` (new) |
| Load shapes (50 sends/s into one conversation, 300 pollers) | **W7-23** (not run here); a modest concurrency check of the same contention path is `msg TestSend_ConcurrentSendsLoseNoUnreadIncrement` (new, 8 instances) |
| Coverage on `internal/messaging` at least 70 % | 93.7 % (section 1) |

### 4. Budgets per RPC (cold instance, through the chain, `budgettest` on the logged `fs_reads` / `fs_writes` / `fs_deletes`)

Ceilings are the proto doc comments (the budget source). Every measured figure is at or under its ceiling; the list RPCs and MarkConversationRead
are new in this ticket, the rest were already asserted and are repeated for completeness.

| RPC and case | Reads (ceiling) | Writes (ceiling) | Deletes | Test |
|---|---|---|---|---|
| SendMessage, accepted conversation, cold | 5 (5) | 3 (3) | 0 | `TestMessagingChain_BudgetTable` |
| SendMessage, new conversation (mutual / request), cold | 7 (7) | 5 (5) | 0 | same |
| SendMessage, request 2nd message, cold | 5 (5) | 4 (4) | 0 | same |
| SendMessage, reply that accepts a request, cold | 5 (5) | 4 (4) | 1 (1) | same |
| SendMessage, accepted conversation, warm | 1 (1) | 3 (3) | 0 | same |
| SendMessage, any refusal (block, suspended, deleted, flag off for recipient, overflowed) | 5 (5) | 0 | 0 | `_RefusalsAreByteIdentical`, `_SuspendedRecipientAndCallerMute`, `_BlockedByOverflowAccountsOnSend` |
| SendMessage, FEATURE_DISABLED / over a cap | 1 (1) | 0 | 0 | `_FlagModes`, `_ReadRPCsFlagClass`, `_SendCapsOfAnEstablishedAccount` |
| ListConversations, INBOX first page of 20 + `request_count`, cold | **23** (23) | 0 | 0 | `TestMessagingChain_ReadBudgetTable` |
| ListConversations, INBOX older page (2 rows) / REQUESTS (3 rows), cold | 4 (3 + rows) / 5 (2 + rows) | 0 | 0 | same |
| ListConversations, `since`, nothing new, cold | 2 (3) | 0 | 0 | same |
| ListMessages, first page of 20 / of 50, cold | **24** (24) / **54** (54) | 0 | 0 | same |
| ListMessages, older page of 20, cold | 24 (24) | 0 | 0 | same |
| ListMessages, poll (the settle-window message back), cold / with 1 new | 3 (3) / 4 (3 + 1) | 0 | 0 | same |
| ListMessages, NOT_FOUND (non-participant, unknown, underived id) | 2 (2) | 0 | 0 | `TestMessagingChain_ReadAuthzIsByteIdentical` |
| ListMessages / ListConversations, foreign or tampered token | 1 (1) | 0 | 0 | same |
| ListMessages, over the read limit | 0 (0) | 0 | 0 | `TestMessagingChain_ReadLimiterSharedBucket` |
| MarkConversationRead (own entry / no entry / foreign id) | 1 (1) | 1 (1) / 0 / 0 | 0 | `TestMessagingChain_ReadBudgetTable`, `_ReadAuthzIsByteIdentical` |
| MarkConversationRead under `readonly` | 0 (0) | 0 | 0 | `TestMessagingChain_ReadonlyKeepsReadsAndRefusesMarkRead` |
| AcceptMessageRequest, cold / replay | 3 (3) / 2 (2) | 2 (2) / 0 | 1 (1) / 0 | `TestMessagingChain_AcceptMovesTheRequest` |
| DeleteConversation, cold / retry with the same key | 3 (3) / 2 (3) | 1 (1) / 0 | 1 (1) / 0 | `TestMessagingChain_DeleteAppliesAtOnce`, `_DeleteRetryWithTheSameKey` |
| GetMe with the badge, cold / warm / messaging off | 3 (3) / 0 (0) / 2 (2) | 0 | 0 | `TestMessagingChain_GetMeUnreadConversations` |
| ReportContent MESSAGE, cold / warm / duplicate / refusal | 6 (6) / 3 (3) / 2 / 1 to 5 | 2 (2) / 2 / 0 / 0 | 0 | `TestMessageReport_BudgetColdWarmAndDuplicate`, `_ColdBudgetsOfRefusalsAndDuplicate` |
| Eraser step, reference account (20 conversations, 300 own messages), all calls | 381 (381, from the per-call costs) | 360 (360) | 20 (20) | `msg TestEraser_ReferenceAccountBudget` (new) |
| Export section `messages`, same account | 620 (620) | 0 | 0 | `msg TestExport_ReferenceAccountBudget` (new) |
| Push fan-out of a `message` event, 2 devices / 5 devices / throttled / flag off (ceilings) | 4 / 7 / 2 / 0 | 0 | 0 | `notif TestIntegration_MessagePushIsPushOnlyAndBudgeted`, `_MessagePushFlagMatrix` |

### 5. Defects

Both are Low, both are filed as skipped tests (`t.Skip("defect: ...")`) that reproduce with `W720_RUN_DEFECTS=1`, and neither blocks W7-22 or W7-24.

**D-1 (Low): for a caller with `blockedByOverflow`, the read-time block rules do not apply.**
`ListConversations` and `ListMessages` decide "the peer blocks the caller" from `graph.Snapshot.BlockedBy` only
(`backend/internal/messaging/service_list.go:258` `requestHiddenBy` and `:287` `canReply`), and the comment at `:257` records that the overflow
flag is deliberately not consulted. For an account blocked by so many others that `blockedBy` stopped listing them, this means:
- a REQUEST from an account that has since blocked the caller is still listed in REQUESTS (ADR-0027 D4 "On read" and W7-7 say it is hidden);
- an INBOX conversation with such an account reads `can_reply = true` (D4 and F9 say it is read-only), in the list and in the `ListMessages` header.

Repro (`TestMessagingChain_BlockedByOverflowCallerReadSide`, skipped; run it with `W720_RUN_DEFECTS=1`): X receives a non-mutual request from
`asker` and has an accepted conversation with `friend`; both then block X; X's graph document is set to `blockedByOverflow: true` with both
removed from `blockedBy`. X's REQUESTS lists 1 entry (want 0), the INBOX row has `can_reply = true` (want false), and the thread header has `can_reply = true`.
The control, `TestMessagingChain_BlockedByCallerReadSide`, runs the same scenario without the overflow and passes.

Impact: nothing leaks and nothing can be sent, because the send path reads each side's own `Blocked` set, which is authoritative
(`TestMessagingChain_BlockedByOverflowAccountsOnSend` passes in both directions with the same bytes as a plain block). The effect is a composer
that shows and then fails with CANNOT_MESSAGE, and a request from a blocker that stays visible, only for accounts that many people have blocked.
It is a spec gap rather than a regression: the ADR does not carve overflow out of the read rule. Owner: backend-developer, with architect to say
whether the rule is "accept and document" (then change D4 and this test) or "consult the peer's own graph for an overflowed caller" (+1 read per
page per such caller).

**D-2 (Low, reachable only by editing a document by hand): `ListMessages` on a conversation whose participant list is not a pair answers INTERNAL,
not the NOT_FOUND of an unknown id.** ADR-0027 D5 and W7-8 say the NOT_FOUND is byte-identical for "unknown, malformed-after-validation and
non-participant". `SendMessage` by `conversation_id` treats a malformed participant list as that NOT_FOUND (`service_send.go`, `peerOf == ""` returns
`notFound()`; unit test `TestSend_ByConversationID`, and through the chain in the repro below). `listMessages` (`service_messages.go`, the
`peer := peerOf(conv.Participants, uid)` line) has no such check, goes on, and asks the directory for the empty peer.
Repro (`TestMessagingChain_ListMessagesMalformedParticipantListIsNotFound`, skipped): after one message between A and B, set
`conversations/{id}.participants` to `[A]` (every other field as the service wrote it). Through the chain, `ListMessages` by A is INTERNAL
(want NOT_FOUND, same bytes as `ListMessages` of `ConversationID(A, "uid-nobody-at-all")`); `SendMessage` by A with `conversation_id` is NOT_FOUND with
those bytes (the test's last assertion; verified to pass while the first fails). No RPC, the eraser or `opsctl` writes such a document, so this is
only an inconsistency between two handlers on corrupt data, and an INTERNAL there reaches Error Reporting, which is arguably the better signal. Owner:
backend-developer; the fix is one guard (`peer == ""` is NOT_FOUND) or an ADR line saying INTERNAL is intended.

### 6. Observations (not defects)

1. **The plan's eraser figure for the reference account is stale, the code matches its own per-call documentation.** The plan and ADR-0027 say
   "about 340 reads, 340 writes, 20 deletes" for 20 conversations and 300 own messages. Measured over the 81 step calls: 381 reads, 360 writes,
   20 deletes. That is exactly the sum of the per-call costs in `repo_lifecycle.go`: the conversation cursor query (20 documents plus a terminating
   empty page, 21 reads), `MarkGone` (2 reads, 2 writes per conversation), `TombstonePage` (1 read and 1 write per own message) and the closing step
   (1 read, 1 write on the conversation document, 1 delete of the user's entry per conversation). The plan's summary left out `MarkGone`'s second read
   and the closing step's read and write (+1 read and +1 write per conversation, +12 % reads, +6 % writes). `TestEraser_ReferenceAccountBudget` therefore
   asserts that derived formula (381 / 360 / 20), not the rounded plan figure and not a tolerance. Correcting the plan and the `cost-model.md` row is
   for sre-performance (W7-23); the money at stake is a one-off 41 reads and 20 writes per deleted account. The export section is exactly the plan's
   620 reads (20 conversations + 20 x 30 messages) and 0 writes (`TestExport_ReferenceAccountBudget`).
2. **A poll re-delivers what falls in the 5 s settle window.** The `ListMessages` since token trails the newest message by `SettleWindow`, so an
   "empty" poll of a quiet thread returns the newest message again (3 reads, the query's minimum read plus that one; the documented 3 holds), but a poll
   within 5 s of a burst returns up to a page of it (55 messages sent in about 3 s: 20 re-delivered, about 23 reads). The documented "+1 per message
   returned" covers it; W7-23 should measure how often a real poll lands inside a burst. The `ListConversations` first-page `since_token` is `now - 5 s`,
   so a refresh taken within 5 s of a write returns that entry again (client dedupes).
3. **`MarkConversationRead` is on the default per-user bucket, not the shared read bucket** (`ratelimit_config.go:107` says so; the plan's "a per-uid read
   limiter covers the polls" means the two list RPCs). The limiter test therefore counts only those two. The chain test runs the bucket at 5 a
   minute instead of 30 so that the one token a bucket refills every 12 s cannot reach the 6th call on a slow CI run; the default 30 and the refusal of
   the 31st call are pinned by `TestMessagingReadBucketLimitsPolls`.
4. **If CI's `-race` run goes red, look at the three concurrency tests first.** They absorb the retryable "busy" answer (UNAVAILABLE) of a lost
   transaction and assert the invariants (one message per key, request cap never above 3, no lost unread increment), so they should not flake, but they
   are the only tests here that depend on emulator timing. On this machine the 8-racer test had 8 of 8 sends succeed; a round costs about 3 s.

### 7. Not covered here, and why

- The load shapes (50 sends/s into one conversation, 300 pollers at 15 s): W7-23.
- The `changedAt DESC, __name__ DESC` + `EndBefore` inbox query against real Firestore indexes: owed before W7-24 (the emulator does not enforce indexes); noted in W7-12's Built note.
- Android push delivery through real FCM: the dev smoke in W7-24.
- Client behaviour (poller, screens, drift wipe on sign-out): W7-21.

VERDICT: PASS (two Low defects filed as skipped tests: D-1 blockedByOverflow caller on the read side, D-2 ListMessages on a malformed participant list)
