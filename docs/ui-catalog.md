# UI catalog (Flutter). One line per reusable widget/provider/helper.

| Item | Location | Use it for |
|---|---|---|
| AppSpacing / AppRadius / AppBreakpoints | app/lib/core/theme/app_theme.dart | spacing, radius and responsive-breakpoint tokens — never hardcode sizes |
| appLightTheme / appDarkTheme / buildAppTheme | app/lib/core/theme/app_theme.dart | Material 3 ThemeData for MaterialApp.router |
| ResponsiveScaffold / AppNavDestination | app/lib/core/widgets/responsive_scaffold.dart | adaptive shell: bottom nav (phone) / rail (tablet) / rail + side column (desktop) |
| AppErrorView | app/lib/core/widgets/app_error_view.dart | typed, friendly rendering of an AppException (degraded mode, quota, rate limit, network, etc.) |
| SplashScreen | app/lib/core/widgets/splash_screen.dart | shown while the initial Firebase auth state is unknown |
| PrivacyPolicyLink / launchPrivacyPolicy / privacyPolicyUri | app/lib/core/widgets/privacy_policy_link.dart | the tappable "Privacy Policy" link (sign-up, sign-in, Settings) and the one place that resolves/opens its URL |
| AppException hierarchy | app/lib/core/network/app_exception.dart | typed domain errors every repository throws; branch on type, never on message text |
| mapConnectError | app/lib/core/network/connect_error_mapper.dart | converts a ConnectException (+ common.ErrorDetail) into an AppException |
| guardApiCall | app/lib/core/network/api_client.dart | wraps a repository's API call, converting thrown errors via mapConnectError |
| ApiClient | app/lib/core/network/api_client.dart | the one Connect-RPC client for the app (identity/graph/media/posts/timeline) |
| AuthTokenProvider / AppCheckTokenProvider | app/lib/core/network/auth_token_provider.dart | interfaces ApiClient depends on for the two auth headers, implemented by AuthRepository / FirebaseAppCheckTokenProvider |
| RequestMetadataInterceptor / AuthHeadersInterceptor / RetryInterceptor | app/lib/core/network/interceptors.dart | connect-dart interceptors: request id, ID token + App Check token, retry-with-backoff for side-effect-free RPCs |
| createPlatformHttpClient | app/lib/core/network/http_client_factory.dart | platform HttpClient for connect-dart transport (dart:io vs fetch) |
| AppDatabase / ProfileCacheEntries / FollowingCacheEntries / TimelineItemEntries / TimelineStateEntries | app/lib/core/storage/app_database.dart | drift local cache (profiles, own follows, timeline feeds; schema v3; add tables here, not a second database) |
| SessionEpoch / AppDatabase.sessionEpoch | app/lib/core/storage/session_epoch.dart | the one session generation every cache writer (TimelineStore, GraphRepository, IdentityRepository) reads before an RPC and passes to guarded drift writes (`epoch:`); `end()` on sign-out drops stale in-flight writes (CLAUDE.md rule 10) |
| AppRouter | app/lib/core/router/app_router.dart | the app's single go_router instance + auth/onboarding redirect logic; `profilePath(handle)` for typed handles, `profileByIdPath(userId)` (`/u/:userId`) for post cards and mentions |
| MainShell | app/lib/core/router/main_shell.dart | bottom-nav/rail chrome around Home/Profile/Settings, used by AppRouter's ShellRoute |
| GoRouterRefreshStream | app/lib/core/router/go_router_refresh_stream.dart | turns bloc streams into a Listenable for go_router's refreshListenable |
| AppConfig | app/lib/app/app_config.dart | --dart-define environment config (API base URL, emulator flags, App Check keys) |
| AuthGate | app/lib/features/auth/presentation/widgets/auth_gate.dart | wraps protected routes; swaps in the email-verification prompt when needed |
| EmailPasswordForm | app/lib/features/auth/presentation/widgets/email_password_form.dart | shared email/password fields + validation for sign-in and sign-up |
| SocialSignInButtons | app/lib/features/auth/presentation/widgets/social_sign_in_buttons.dart | Google + (platform-gated) Apple sign-in buttons |
| VerifyEmailView | app/lib/features/auth/presentation/widgets/verify_email_view.dart | full-screen "verify your email" prompt (no dedicated route); reused by CreateProfileScreen (`banner`/`onBack`) for `ERROR_REASON_EMAIL_NOT_VERIFIED` from CreateProfile |
| FollowButton | app/lib/shared/widgets/follow_button.dart | Follow/Following/Unblock/Requested action; reads a `RelationshipCubit` provided above it — one per profile header or list row |
| kFeatureGraph | app/lib/features/graph/domain/graph_feature_flag.dart | the `"graph"` feature-flag name (ADR-0008 D6) — never hardcode the string elsewhere |
| isGraphEnabled / graphEnabledSnapshot | app/lib/features/graph/presentation/graph_feature_flags.dart | thin graph wrappers over `isFeatureEnabled`; gate every graph UI element and route on `GetMe.enabled_features` (via `OnboardingBloc`) |
| isFeatureEnabled / featureEnabledSnapshot | app/lib/core/feature_flags/feature_flags.dart | generic `GetMe.enabled_features` check for any flag name (generalised from `isGraphEnabled`; use it for every new flagged feature) |
| AccountRepository / AccountExport | app/lib/features/account/data/account_repository.dart | DeleteAccount, RequestAccountExport, GetAccountExport; caller owns the idempotency key |
| AccountCubit | app/lib/features/account/presentation/bloc/account_cubit.dart | delete/export intents: one key per intent; delete re-auths up front (call from the tap, popup stays in the gesture), export re-auths once on REAUTH_REQUIRED (not on web); cancel sends nothing; `reset()` frees a stuck flow (no-op while DeleteAccount is in flight) |
| AuthRepository.reauthenticate / revokeAppleToken | app/lib/features/auth/data/auth_repository.dart | provider/password re-auth + forced token refresh; Apple token revocation (plan Q7) |
| kFeatureAccountLifecycle / isAccountLifecycleEnabled | app/lib/features/account/domain/account_feature_flag.dart (name) + app/lib/features/account/presentation/account_feature_flags.dart (helpers) | gate delete-account and export UI |
| DataExportCubit / DataExportScreen | app/lib/features/account/presentation/bloc/data_export_cubit.dart + data_export_screen.dart | Settings -> Download my data (`/settings/export`, flag-gated): request + <=10 backed-off polls (10 s to 60 s); `resume()` = retry with a fresh budget, no new request; saved export id resumes on reopen; stale URL (14 min / expiry-1 min) re-fetched; never logs the URL |
| AppDatabase.savedExport(uid) / saveExport / clearSavedExport | app/lib/core/storage/app_database.dart | the one pending data export of one uid (id + lifetime, schema v4; other uids absent+deleted), written under SessionEpoch, wiped by `clearAll` |
| UnexpectedErrorReporter / reportUnexpectedError | app/lib/app/session_wiring.dart | one shared non-fatal error hook, provided by AppWidget; pass to cubits as `onUnexpectedError` (never include URLs) |
| showPasswordPromptDialog | app/lib/features/account/presentation/widgets/password_prompt_dialog.dart | the `PasswordPrompt` for `AccountCubit` re-auth (password accounts); null = cancelled |
| AppRouter.exportDataPath | app/lib/core/router/app_router.dart | `/settings/export`; `_accountFlagRedirect` sends flag-off visitors to `/settings` (T14 adds delete-account to `_accountOnlyRoutes`) |
| ReauthRequiredException | app/lib/core/network/app_exception.dart | typed `ERROR_REASON_REAUTH_REQUIRED` |
| kFeaturePosts / kPostsSubFeature{Replies,Quotes,Media} | app/lib/features/posts/domain/posts_feature_flag.dart | the `"posts"` flag name (ADR-0010 D1) and the `metadata["feature"]` sub-feature names (D2) - never hardcode the strings |
| PostsFeatureGate | app/lib/features/posts/domain/posts_feature_flag.dart | wraps every posts/timeline RPC (`run`): flag off => no RPC; FEATURE_DISABLED with `feature` hides only that sub-feature, without it all of posts; `subFeatureEnabled(name)` for UI; `reset()` after GetMe; Crashlytics hook for unexpected errors |
| PostsRepository | app/lib/features/posts/data/posts_repository.dart | `PostService` client: create/get/delete post; keeps cached feeds consistent (own post prepended, NOT_FOUND/deleted post pruned from every feed) |
| TimelineRepository / TimelineSnapshot / TimelineEntry | app/lib/features/timeline/data/timeline_repository.dart | `TimelineService` client over drift: `cached` (offline, no network), `refresh` (since_token, dedupe by post_id, gap rows), `loadOlder`, `fillGap`; rejected since/page token => drop + one cold open (ADR-0010 D14) |
| TimelineStore / kTimelineRetention | app/lib/features/timeline/data/timeline_store.dart | drift persistence + every feed merge rule (dedupe by post_id, gap markers, newest 500 per feed); tables `TimelineItemEntries`/`TimelineStateEntries` in `AppDatabase` |
| buildPostsGate / wipeSessionData | app/lib/app/session_wiring.dart | bootstrap wiring: posts gate tied to `GetMe.enabled_features` (whole-service FEATURE_DISABLED triggers a GetMe refresh, every GetMe resets the gate); sign-out wipe (`wipeSessionData(database:, timelineRepository:)`: ends the shared `SessionEpoch`, clears the timeline's in-flight work, then one-transaction `clearAll`) |
| PostCard | app/lib/shared/widgets/post_card.dart | any post row (Home, profile tabs, detail): author row (tap -> `/u/:userId`), relative time, rich text, overflow menu (Delete own with confirm / Block / Mute / Unblock / Unmute via one `RelationshipCubit` per card, `onRelationshipChanged` for the timeline); display only, navigation and launch are injectable |
| PostRichText / launchPostLink | app/lib/shared/widgets/post_card.dart | post body as tappable spans (owns the recognizers); `launchPostLink` opens an http(s) URL in the external browser (returns false instead of throwing) |
| parsePostText / PostSpan / PostSpanKind | app/lib/features/posts/domain/post_text_parser.dart | pure text -> plain/link/mention/hashtag spans: http(s) links only (no userinfo, non-ASCII hosts or bidi controls), mentions matched case-insensitively against `mentions[].handle` and carrying `user_id`, ADR-0010 D8 hashtags |
| AppAvatar | app/lib/shared/widgets/app_avatar.dart | user avatar (post card, list rows, profile header): disk-cached network image decoded at display size, person-icon fallback |
| formatRelativeTime / formatRelativeTimeSpoken | app/lib/shared/format/relative_time.dart | `now`/`5m`/`3h`/`2d`/date for rows, and the spoken form (`5 minutes ago`) for semantics |
| FeedKey | app/lib/features/timeline/domain/feed_key.dart | identifies a cached feed: `home`, or a user's Posts/Replies tab (also what server tokens are bound to) |
| GraphRepository / GraphPage | app/lib/features/graph/data/graph_repository.dart | `GraphService` client + session relationship cache (primed from list rows and the drift `following` cache); follow/unfollow/block/unblock/mute/unmute + paged lists |
| RelationshipCubit / RelationshipState | app/lib/features/graph/presentation/bloc/relationship_cubit.dart | optimistic follow/block/mute state for one (viewer, target) pair, with rollback |
| relationshipErrorMessage | app/lib/features/graph/presentation/graph_error_messages.dart | friendly snackbar text for graph-action `AppException`s |
| ProfileHeader | app/lib/features/profile/presentation/widgets/profile_header.dart | avatar/name/handle/bio/counts/FollowButton/block-mute menu for `ProfileScreen` (ADR-0008 D13: the posts plan owns the tabs/body below it) |
| showBlockConfirmationDialog | app/lib/features/profile/presentation/widgets/block_confirmation_dialog.dart | the "Block this account?" confirmation sheet |
| ProfileCubit / ProfileState | app/lib/features/profile/presentation/bloc/profile_cubit.dart | loads `GetProfile` + the viewer's relationship for one handle |
| UserListCubit / UserListState | app/lib/features/graph/presentation/bloc/user_list_cubit.dart | pages any `FetchGraphPage` (followers/following/blocked/muted) with load-more, pull-to-refresh, and optimistic remove/restore |
| PagedUserList | app/lib/features/graph/presentation/widgets/paged_user_list.dart | renders a `UserListCubit`'s loading/ready/error/rate-limited/empty states as a scrollable, prefetching list |
| UserListRow | app/lib/features/graph/presentation/widgets/user_list_row.dart | one row (avatar, name, handle, trailing) in any graph user list; defaults to a `FollowButton` seeded from `UserListItem.relationship` |
| BlockedAccountsScreen / MutedAccountsScreen | app/lib/features/graph/presentation/managed_accounts_screen.dart | Settings → Blocked/Muted accounts, optimistic unblock/unmute + undo |
| GraphListScreen | app/lib/features/graph/presentation/graph_list_screen.dart | `/profile/:handle/followers` and `/profile/:handle/following`, tabbed, paged; lazy per-tab `UserListCubit`, flag-off redirects to the profile |
| analyzePostDraft / PostDraft / PostDraftProblem / kMaxPostCodePoints / kMaxPostLines | app/lib/features/posts/domain/post_text_rules.dart | client mirror of ADR-0010 D9 (+D21 G2/G4): normalise, NFC, trim, count code points/lines, why Post is disabled; the server stays authoritative |
| ComposerScreen / CharacterCounter | app/lib/features/posts/presentation/composer_screen.dart | `/compose`: 280 code-point composer with counter, EMAIL_NOT_VERIFIED -> `VerifyEmailView` |
| ComposerCubit / ComposerState | app/lib/features/posts/presentation/bloc/composer_cubit.dart | create-post intent: one idempotency key per intent (reused on retry), optimistic pending post, rollback on error |
| PendingPostsCubit / PendingPost | app/lib/features/posts/presentation/bloc/pending_posts_cubit.dart | app-wide, session-only list of optimistic posts; provided by `AppWidget`, cleared on sign-out |
| PendingPostsSection | app/lib/shared/widgets/pending_posts_section.dart | optimistic posts above a feed (Home, own profile via `authorId`); mounted by `TimelineFeedView` |
| createPostErrorMessage | app/lib/features/posts/presentation/post_error_messages.dart | friendly snackbar text for CreatePost `AppException`s (quota, rate limit, degraded, flag off, network) |
| AppRouter.composePath | app/lib/core/router/app_router.dart | the `/compose` route (outside the shell) |
| TimelineCubit / TimelineState / kAutoRefreshInterval | app/lib/features/timeline/presentation/bloc/timeline_cubit.dart | one cached feed (Home, a profile's Posts tab): cache first, throttled refresh, "N new posts" hold-back, older pages, gaps, optimistic delete, local hide of blocked/muted authors, RATE_LIMITED notice |
| TimelineFeedView | app/lib/features/timeline/presentation/timeline_feed_view.dart | scrolling feed body over a `TimelineCubit` (slivers + `headerSlivers`): pull-to-refresh, pill, notice banner, pending posts, gap rows, 70 % prefetch, empty/error/loading, foreground-only 30 s tick; reuse for any feed |
| NewPostsPill / TimelineGapRow | app/lib/features/timeline/presentation/widgets/ | the "N new posts" pill and the "Show more posts" gap row |
| timelineNoticeMessage | app/lib/features/timeline/presentation/timeline_error_messages.dart | friendly banner text for a failed refresh over cached posts |
| TimelineRepository.sinceRefresh / rateLimitedFor | app/lib/features/timeline/data/timeline_repository.dart | monotonic refresh stamp (60 s throttle across screen re-creation) and the RATE_LIMITED hold timeline calls must respect |
| PostsRepository.removedPosts | app/lib/features/posts/data/posts_repository.dart | stream of post ids that left every cached feed (delete / NOT_FOUND); mounted feeds drop them |
| PostDetailScreen / PostDetailCubit | app/lib/features/posts/presentation/post_detail_screen.dart | `/post/:id`: GetPost, "This post isn't available", blocked-author banner, delete |
| AppRouter.postPath | app/lib/core/router/app_router.dart | the `/post/:id` deep link |
| HomeScreen | app/lib/features/home/presentation/home_screen.dart | Home timeline (`TimelineFeedView` + `TimelineCubit`); placeholder with the posts flag off |
| ProfileHeader.showPostsCount / ProfileCubit.postDeleted | app/lib/features/profile/ | "N Posts" in the header and its local decrement after a delete |
