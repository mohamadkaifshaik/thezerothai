# Redmi K20 Pro QA checklist

Initial base commit `d96c2904`. The QA branch subsequently merged GitHub main at `72401aa8`. ADB and Flutter detected the physical Redmi K20 Pro running Android 11 (API 30). The checkboxes below track device verification.


## November 27 device results

The allowlisted account published one [16-strip QA post on dev](https://dev.dzeroth.com/post/0119719063282896896) from Chrome on the Redmi. This is a different post from the [original report](https://dev.dzeroth.com/post/0118586290563739648). Hosted measurements use the version deployed to dev. The controlled release-mode benchmark below uses this worktree.

| Workflow | Observed on the Redmi |
|---|---|
| Android composer with local emulators | The Android picker returned 16 JPEGs. Applied the 9:16 crop to the first attachment, saved its alt text, and verified the composer offered to edit the saved description. |
| Local failure and retry | Loss of USB port forwarding interrupted posting. The pending row kept Edit and Retry available. Restoring the connection and tapping Retry reached CreateUpload. Local signing failed because the Storage client lacked a signing identity. No local post was published. |
| Hosted dev composer and publication | Entered the QA caption, attached 16 synthetic strips, saved alt text for the first, and tapped Post once. Four upload reservations succeeded. One finalization returned HTTP 503 and recovered on retry. CreatePost succeeded about 91 seconds after the tap. This is time to publish, not time to render an existing post. |
| Following, detail and photo viewer | A screenshot check found all 16 expected colors in order in Following. Tapping the first tile opened photo 1 of the QA post. Back returned to Following and tapping the row opened the correct detail route. All 16 colors appeared in detail. |
| Cold hosted page loads | With Chrome HTTP caching disabled, all 16 colors first appeared in Following at the 8.1-second sample after reloading the page. On a separate detail reload they appeared between 7.142 and 7.557 seconds after navigation. These timings include page startup and RPCs. |
| Offline and retry | An already-painted Following row retained all 16 colors when Chrome went offline. Opening detail showed a connection error with Retry. After reconnecting, one Retry restored all 16 colors within 2.59 seconds. |
| Rapid tab switching and scrolling | Sent six Following/Hello round trips and four vertical scroll gestures on hosted dev. Following still displayed all 16 fixture colors afterward. During this five-second run, Chrome recorded 169 animation-frame intervals, 21 above 50 ms, with a 100 ms p95 and 182 ms maximum. These are frame scheduling intervals for the page as a whole. The trace does not attribute a stall to a particular widget. |
| Local privacy and data settings | Opened the blocked and muted lists. Switched Data saver on, reopened Data usage, confirmed it persisted, and restored its original off setting. |
| Local message receipt and reply | A disposable peer sent a request through the emulator-backed API. On the Redmi, the recipient opened the request, saw the message, accepted, and replied. The peer read the reply through ListMessages. |
| Android release configuration | Gradle merged the release manifest successfully on this checkout. It sets allowBackup to false and contains neither the debug network configuration nor a cleartext override. No release upload key was configured in this worktree. |

The local signer failure was confirmed in the API log at CreateUpload. The debug emulator signup fix works independently. The dev browser used the existing signed-in account and feature access. Verification of the original post against a deployed copy of the patch remains open. The controlled benchmark covers the patch locally. The deployed dev run covers the complete upload and read paths. No production deployment, access-list edit, Firebase rules change or release signing was performed.

### Hosted Data saver comparison

In Chrome on the Redmi, Data saver was initially off. With HTTP caching disabled, the 16-color QA post requested 16 originals and 16 thumbnails. After enabling Data saver, the same post requested 16 thumbnails and zero originals. All 16 strip colors painted in the expected order in each state. The original off setting was restored and checked. This comparison measures request selection on the deployed dev build.

### Merged-branch checks on November 28

The QA branch merged GitHub main at `72401aa8`. On the merged code, Flutter analysis found no issues and the full Flutter suite passed 21,838 tests with 273 skipped. Go tests passed in all nine packages checked across posts, media, identity, messaging, engagement, keys, timeline, authentication and object storage.

On the physical Redmi, all eight vault-session integration tests passed, covering explicit sign-out, interrupted sign-out, marker durability and recovery for the same user after session loss. Both device-key integration tests passed. They checked registration, idempotent startup, removal at sign-out, deletion of the local vault and issuance of a fresh device ID on the next sign-in. The tests used isolated databases and a fake key directory. The vault test emitted a Drift debug warning about multiple database instances during the simulated restarts. The Android build also warned that some plugins still apply the Kotlin Gradle Plugin.

Read-only navigation on hosted dev also showed the limits of testing features through a URL. Creator Studio, articles, communities, Explore settings and Premium landed on Home. Notification settings landed on Settings. Calls and Advertise retained their paths in one sample, but their content in a second sample was the Following feed. None of these URL attempts verified the corresponding feature workflow. Premium requires opening the dialog from inside the app according to `app/lib/core/router/shell_entries.dart`.

## November 26 checkpoint

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

| Journey | Verified on device | Remaining device checks |
|---|---|---|
| Feed and pinned lists | Following, pinned Hello, switching tabs, flings, cold QA post, viewer, back, offline and reconnect | Cold original post with the patch deployed, scroll across multiple strip posts |
| Authentication | Signup, verification, onboarding and restored session with disposable accounts | Interactive sign-out and sign-in cycle |
| Composer | Text double-submit, empty form, 16 images, first-image crop and alt text, interruption, retry and hosted publication | Over-limit and emoji input, back during upload |
| Engagement | Like, repost, bookmark and reply from detail | Double-tap each control and verify feed, detail and bookmarks agree |
| Discovery and social | Search for a disposable user, open profile and notifications | Post search, follow and resulting notification |
| Messaging | Open conversations, send and accept a request, reply and confirm receipt | Offline message recovery, user-facing vault controls |
| Settings | Blocked and muted lists, Data saver persistence, actual thumbnail and original request selection with Data saver on and off | Edit and restore notification preferences in a disposable account |
| Other features | Manage pinned lists and open Plans | Articles, communities, location, beacons, calls, moderation, subscriptions and creator workflows need individual walkthroughs |

Three saved Android logs from the original device run and the emulator-backed runs contained no matches for RenderFlex overflows, unhandled exceptions or BLoC updates after close. These samples do not cover long-session memory growth.

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

The media bucket Terraform module sets uniform bucket-level access and enforces public access prevention on the upload, serving and export buckets. Firestore and Storage rules both deny all direct client reads and writes. Authenticated operations go through the Go API. The production configuration uses bucket IAM and signed URLs. Keep the direct-client rules closed. The media bucket module grants object administration on each bucket to the runtime service account.

- [ ] Verify the deployed rules match `firebase/firestore.rules` and `firebase/storage.rules`.
- Reviewed authenticated ownership in the Go source. Post deletion compares the caller with the stored author (`backend/internal/posts/service_delete.go`). Profile updates use the authenticated user's ID (`backend/internal/identity/server.go`, `service.go` and `repo_firestore.go`). Bookmark RPCs authenticate the caller and scope records to their namespace (`backend/internal/engagement/server_bookmarks.go` and `repo_bookmarks.go`). Message reads check conversation membership before returning messages (`backend/internal/messaging/service_messages.go`). This review covers those operations. Other operations and audience combinations need separate checks.
- Reviewed upload reservation and finalization in `backend/internal/media/service.go` and `finalize.go`. The service constrains accepted media formats, dimensions and sizes, checks the stored object's metadata and checksum, and pins its generation. `backend/pkg/platform/objstore` scopes signed uploads by method and required headers, including create-only preconditions. Actual deployed IAM and rules still need comparison against the repository.
- Crash reporting uses an allowlist for exception messages. The scrubber removes URLs, email addresses, handles, long alphanumeric strings and long digit runs, then caps the text at 200 characters. Connect failures emit the code and structured reason. See `app/lib/core/telemetry/crash_payload.dart` and `crash_scrubber.dart`. Other log sinks and deployed IAM still need review.
- [ ] Require release signing, verify the release target and test a signed release build on the handset.

## Data access inventory

Collection names found in Go repository constants and literal Firestore calls under `backend/internal`. Names can occur at several levels of a document path. Dynamically constructed paths and collections managed outside those packages require separate review.

| Backend package | Collection or subcollection names |
|---|---|
| articles | articles |
| beacons | beaconMemberships, beaconParticipants, beacons, users |
| billing | billingCustomerOwners, billingCustomers, users |
| communities | communities, communityMembers, communityMemberships |
| engagement | bookmarks, impressions, likes, pollVotes, postShares, reposts, userLikes, users |
| graph | followRequests, follows, graph |
| identity | dailyStats, exports, handles, notifications, privacy, private, publicIds, users |
| keys | keyDeviceRemovals, keyDevices, keyPackages, users |
| lists | listFollows, lists |
| location | locationArea, locationConsents, users |
| media | admin, media |
| messaging | commits, conversations, dmInbox, dmRequests, dmWelcomes, messages, users |
| moderation | evidence, reports |
| notifications | deviceTokens, devices, notifications, settings, users |
| posts | postRemovals, posts, scheduled, users, viewDirty, viewRollup, viewShards |
| search | trends |

In `backend/internal/media/service.go`, upload objects use `u/{uid}/{id}.{ext}`. Served objects use `m/{id}-{suffix}.{ext}`. Thumbnails insert `_t` before the extension. The service still recognizes earlier served names without a suffix.

## Initial results

- The media widget uses a lazy horizontal list with width-limited decodes and zero-duration image fades. One stale attachment URL triggers an audience-checked GetPost before media tiles can paint. The timeline also throttles automatic refresh to 60 seconds. Neither observation establishes the cause of the reported delay.
- The API deduplicates object names within a response and signs up to eight concurrently. Signed media links are valid for five minutes. A feed tile may fetch a thumbnail and full image when the thumbnail is undersized.
- A batch lookup of 219 hosted Dart package versions from pubspec.lock against OSV returned zero matching advisories. Flutter pub outdated found 49 locked upgrades and 19 constraints below resolvable versions. Native Android, Rust and Go dependencies are outside that lookup.
- Flutter analysis passed on the fetched baseline. The native Redmi media integration suite passed its Android WebM-to-MP4 conversion case. Its in-feed playback case is web-only and was skipped.
- On the reported dev post in Chrome on the Redmi, resource timing showed a shared group of 16 objects in the detail and Home tabs. On Home, each object generated both an original and a thumbnail request. The first started 10.572 s after navigation and the last completed at 12.386 s. These timestamps establish a 1.814 s network window. They do not measure time to paint.
- Sampling one attachment in the phone browser returned 54 x 1440 for the original and 41 x 1080 for the thumbnail. The client infers a 400 px thumbnail for a longest edge of 1440. The response schema carries only the original width and height.
- A narrow scan for private-key headers and service-account keys found no matching files under app/lib and app/android. Android vault key handling is implemented in VaultKeyChannel.kt using Android Keystore.
