# Redmi K20 Pro QA checklist

Base commit `d96c2904`. ADB and Flutter detected the physical Redmi K20 Pro running Android 11 (API 30). The checkboxes below track device verification.


## Session checkpoint

Paused at the user's request on November 26, 2026. Worktree and branch are both named `redmi-feed-audit` (branch prefix `qa/`). The reported dev post is `0118586290563739648`. The affected client is Chrome on the Redmi K20 Pro.

- The full post-fix Flutter suite passed **21,747 tests**, with **273 skipped**. Post-fix analysis found no issues.
- A warm return to the reported strip row on hosted dev was observed for 66 seconds. Pixels sampled inside 13 strips already matched the final image at the first capture, 1.72 seconds after scrolling. This run did not reproduce the minute-long mask.
- The synthetic local user created and pinned the private list Hello and switched between Hello and Following. Search found the disposable peer. A message to that peer appeared in the local conversation.
- **Resume at the Android photo picker.** It was showing the 16 synthetic `QA-strip-00.jpg` through `QA-strip-15.jpg` files under `Pictures/redmi-qa-phone-fixture`. No photos had been selected. Continue with selection, crop, upload, feed/detail and offline retry. The local Storage emulator cannot itself validate production V4 signatures.
- The feature-enabled local API was listening on host port 8082, with device port 8081 forwarded there. Auth used device and host port 9099. Check the live processes and `adb reverse --list` after resuming. Disposable emulator state is runtime state and may be lost on host restart.
- The earlier dev post tab was restored after the controlled browser benchmark. No credentials were copied into this checkpoint.
- Remaining coverage includes a cold patched run against the exact hosted post, upload completion, offline recovery, full receiving-side messaging, and the unchecked feature and release workflows below. Production deployment and release signing have not been verified.

## Verified fixes

| Issue | Reproduction and expected behavior | Change and verification |
|---|---|---|
| Medium. Redundant image requests on narrow feed rows | Open the reported post from Following in Redmi Chrome. If originals are needed, each thin tile should display at full clarity without another download competing with it. The hosted Home page requested 16 originals and 16 thumbnails. | In `app/lib/shared/widgets/post/post_media.dart`, a narrow tile that needs an original now requests the thumbnail only after an original-load error. Data saver and the existing URL-refresh check still apply. The widget regression covers all 16 image choices and the error fallback. |
| Medium. Debug Android signup failed over USB | Start the app with local emulators and an explicit, USB-forwarded 127.0.0.1 Auth address. Signup failed because Firebase remapped that address to 10.0.2.2 and Android rejected cleartext HTTP. | Bootstrap preserves the explicit host. The debug network policy permits HTTP for loopback and the Android emulator alias. The handset then completed signup, email verification and profile creation. `app/test/app/auth_emulator_test.dart` covers the mapping. |

### Time to paint in Chrome

The same release-mode PostMedia fixture was run before and after the change on the Redmi at DPR 2.75 with a 320 logical pixel column. It serves 16 distinct 54 x 1440 originals and 41 x 1080 thumbnails over USB loopback with 45 ms server delay per response and browser caching disabled. The timer starts at app mount. A sampled row of rendered pixels must contain all 16 full-color strips to stop the timer.

| Foreground trials | Originals | Thumbnails | All strips painted, ms |
|---|---:|---:|---|
| Baseline | 16 | 16 | 1427, 789, 815, 847 |
| Patched | 16 | 0 | 502, 558, 536, 535 |

These timings describe the controlled fixture. The hosted dev trace did not reproduce the reported minute-long wait. The patch has not been deployed to the dev site. Background-tab measurements are excluded because Chrome can suspend painting.

### Verification

- Baseline Flutter suite passed 21,745 tests and skipped 273. All 46 targeted media and Auth regression tests passed after the fixes. Static analysis passed both before and after.
- Go unit suites passed for media, posts, engagement, identity, messaging and timeline.
- On-device local actions used disposable emulator accounts. Signup, verification, profile creation and session restoration succeeded. An empty composer stayed open. A rapid double-submit of one text post produced one original in the feed. Post detail showed the like, repost and bookmark states. A submitted reply appeared in the thread.
- On-device navigation reached the profile, Explore, notification inbox, new message recipient picker, messages, Plans and Manage pinned. A message to a synthetic peer appeared with its pending-acceptance state. Plans displayed its paused state in this local configuration.

## Device workflows

- [ ] Following and pinned list tabs (including Hello if the test user pinned that list). Open a 15-strip post cold, return from detail, scroll away and back, change tabs during loading, repeat offline and after reconnect. Measure first clear frame and request counts.
- [ ] Sign up, verify, sign in, finish onboarding, reopen session and sign out.
- [ ] Compose text, attach multiple narrow photos, edit and crop, add alt text, publish, open detail and viewer. Cover empty, over-limit and emoji input, interrupted upload, back and retry.
- [ ] Like, repost, bookmark and reply. Double-tap actions and reconcile feed, detail and bookmarks.
- [ ] Search for users and posts, open a profile, follow and inspect notifications.
- [ ] Open conversations, compose and receive messages, exercise vault lock, offline recovery and back navigation.
- [ ] Open account, privacy, data usage and notification settings. Repeat media loading with data saver enabled.
- [ ] Exercise lists, articles, communities, discovery, location, beacons, calls, moderation, premium and creator screens with eligible test fixtures.

## Feature inventory

Dart declarations and named sheet files under each feature. Cross-feature navigation lives in `app/lib/core/router`.

| Feature | Screens and sheets | BLoCs and Cubits |
|---|---|---|
| account | AccountDeletedScreen, DataExportScreen, DeleteAccountScreen | AccountCubit, DataExportCubit |
| advertise | AdvertiseScreen | None named |
| articles | ArticlesScreen | None named |
| auth | AuthScreen, SignInScreen, SignUpScreen, WelcomeScreen | AuthBloc, PasswordResetCubit |
| beacons | BeaconPeopleScreen, BeaconScreen, BeaconsScreen, CreateBeaconScreen, EditBeaconScreen, JoinNoteSheet, MyBeaconsScreen | BeaconDetailCubit, BeaconPeopleCubit, BeaconsCubit, CreateBeaconCubit, EditBeaconCubit, MyBeaconsCubit, NearbyPlansCubit |
| calls | CallsScreen | None named |
| communities | CommunitiesScreen, CommunityMembersScreen, CommunityModerationLogScreen, CommunityScreen, CreateCommunityScreen | CommunitiesCubit, CommunityDetailCubit, CommunityMemberSearchCubit, CommunityModerationCubit, CommunityModerationLogCubit, CreateCommunityCubit |
| creator_insights | None named | CreatorInsightsCubit |
| creator_studio | CreatorStudioScreen | None named |
| engagement | BookmarksScreen, repost_sheet | BookmarksCubit, BookmarksListCubit, EngagementCubit, LikesListCubit, PollCubit, PostHistoryCubit |
| graph | BlockedAccountsScreen, FollowRequestsScreen, GraphListScreen, MutedAccountsScreen | RelationshipCubit, SuggestionsCubit, UserListCubit |
| home | HomeScreen | None named |
| keys | None named | None named |
| lists | AddToListsSheet, DiscoverListsScreen, ListDetailScreen, ListEditorSheet, ListMembersScreen, ListsScreen, ManagePinnedScreen, UserListsScreen | AddToListsCubit, HomeTabsCubit, ListDetailCubit, ListEditorCubit, ListFeedCubit, ListSuggestionsCubit, ListsCubit |
| location | AreaPickerScreen, LocationRationaleScreen, LocationSettingsScreen | AreaPickerCubit, LocationSettingsCubit |
| media | None named | AttachmentsCubit |
| messages | ConversationsScreen, DraftThreadScreen, ThreadInfoSheet, ThreadScreen | ConversationsCubit, EncryptionStatusCubit, MessageComposerCubit, MessageSearchCubit, MessageSuggestionsCubit, MessagesBadgeCubit, RecipientPickerCubit, SecurityCodeCubit, SharePostCubit, ThreadCubit |
| moderation | ReportSheet | ReportCubit |
| notifications | NotificationSettingsScreen, NotificationsScreen | FollowBackCubit, FollowRequestsPreviewCubit, NotificationPrefsCubit, NotificationsCubit, PushCubit, PushOptInCubit, UnreadBadgeCubit |
| onboarding | CreateProfileScreen, ProfilePhotoStepScreen, SessionErrorScreen | OnboardingBloc |
| posts | AudienceSheet, ComposerScreen, DraftsScreen, PostDetailScreen, PostPhotoScreen, ReplyAudienceSheet, ReplyComposerScreen, ScheduledPostsScreen, ThreadScreen | ComposerCubit, DraftsCubit, PendingPostsCubit, PostDetailCubit, ScheduleDialogCubit, ScheduledPostsCubit, ThreadCubit, ThreadModerationCubit, UnsentPostsCubit |
| premium | None named | SubscriptionCubit |
| profile | ChangeHandleScreen, EditProfileScreen, ProfileScreen | ChangeHandleCubit, EditProfileCubit, PinnedPostCubit, PostPinCubit, ProfileCubit |
| search | ExploreMediaScreen, ExploreScreen, ExploreSettingsScreen, ExploreTrendingScreen, SearchResultsScreen | ExploreMediaCubit, PagedTrendingCubit, SearchCommunitiesCubit, SearchResultsCubit, SearchSuggestionsCubit, TrendingFeedCubit, TrendingMediaCubit, TrendsCubit |
| settings | DataUsageScreen, EncryptionAboutScreen, EncryptionSettingsScreen, MessageSettingsScreen, ResetEncryptionScreen, SettingsScreen | DataUsageCubit, EncryptionDevicesCubit, MessagePrivacyCubit, ProtectPostsCubit, ResetEncryptionCubit, ScheduledWaitingCubit, UndoSendCubit |
| timeline | None named | TimelineCubit |

## Firebase and release checks

Firestore and Storage rules both deny all direct client reads and writes. Authenticated operations go through the Go API. Production media uses bucket IAM and signed URLs.

- [ ] Verify the deployed rules match `firebase/firestore.rules` and `firebase/storage.rules`.
- [ ] Check resource ownership and audience restrictions in Go services, including posts, profiles, bookmarks and messages. Review upload size, type and content validation at slot creation and finalization.
- [ ] Check private bucket IAM, scoped URL signing, telemetry redaction, vault persistence and logout behavior.
- [ ] Require release signing, verify the release target and test a signed release build on the handset.

## Data access inventory

Literal Firestore collection names used by the Go backend (includes subcollections). Dynamic names and nested ownership paths require service-level review.

articles, billingCustomerOwners, billingCustomers, users

## Initial results

- The media widget uses a lazy horizontal list with width-limited decodes and zero-duration image fades. One stale attachment URL triggers an audience-checked GetPost before media tiles can paint. The timeline also throttles automatic refresh to 60 seconds. Neither observation establishes the cause of the reported delay.
- The API deduplicates object names within a response and signs up to eight concurrently. Signed media links are valid for five minutes. A feed tile may fetch a thumbnail and full image when the thumbnail is undersized.
- A batch lookup of 219 hosted Dart package versions from pubspec.lock against OSV returned zero matching advisories. Flutter pub outdated found 49 locked upgrades and 19 constraints below resolvable versions. Native Android, Rust and Go dependencies are outside that lookup.
- Flutter analysis passed on the fetched baseline. The native Redmi media integration suite passed its Android WebM-to-MP4 conversion case. Its in-feed playback case is web-only and was skipped.
- On the reported dev post in Chrome on the Redmi, resource timing showed a shared group of 16 objects in the detail and Home tabs. On Home, each object generated both an original and a thumbnail request. The first started 10.572 s after navigation and the last completed at 12.386 s. These timestamps establish a 1.814 s network window. They do not measure time to paint.
- Sampling one attachment in the phone browser returned 54 x 1440 for the original and 41 x 1080 for the thumbnail. The client infers a 400 px thumbnail for a longest edge of 1440. The response schema carries only the original width and height.
- A narrow scan for private-key headers and service-account keys found no matching files under app/lib and app/android. Android vault key handling is implemented in VaultKeyChannel.kt using Android Keystore.
