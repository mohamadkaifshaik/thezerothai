// Package config loads process configuration from environment variables. Cloud Run injects PORT and
// any Secret Manager-backed env vars; the Firebase/Firestore emulators are honored automatically by
// their client libraries via FIRESTORE_EMULATOR_HOST / FIREBASE_AUTH_EMULATOR_HOST / PUBSUB_EMULATOR_HOST,
// so this package does not special-case them beyond choosing sane local defaults.
//
// Loading is a single, cheap pass over os.Getenv — safe to call before ListenAndServe (cold start budget: nothing heavy in main before the server starts).
package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// MaxCacheTTL is the upper bound for CACHE_TTL: the account-deletion start gate is 120 s, so
// instance caches must expire well inside it.
const MaxCacheTTL = 60 * time.Second

// MinTimelineSettleWindow is the lower bound (and default) for TIMELINE_SETTLE_WINDOW: 3 x the 5 s CreatePost
// transaction deadline.
const MinTimelineSettleWindow = 15 * time.Second

// MaxTimelineTokenTTL is the upper bound for TIMELINE_TOKEN_TTL (90 days, follow-up): a typo must not make
// timeline tokens effectively immortal.
const MaxTimelineTokenTTL = 2160 * time.Hour

// Config is the full process configuration. Constructed once in main via Load/MustLoad.
type Config struct {
	BillingSandbox BillingSandboxConfig
	BillingWebhook BillingWebhookConfig
	// Port is the HTTP listen port. Cloud Run sets PORT explicitly in dev/prod; defaults to 8081 in local
	// dev (M10) so it never collides with the Firestore emulator's fixed port 8080 (firebase.json).
	Port string
	// ProjectID is the GCP/Firebase project. Required; also used as the Firestore/Auth project.
	ProjectID string
	// Env is one of local|dev|prod. Only used for defaults and log fields, never for branching business logic.
	Env string

	Degraded DegradedMode
	AppCheck AppCheckMode

	// CursorHMACKey signs opaque pagination cursors so clients cannot craft unbounded scans.
	// Sourced from a Secret Manager-backed env var in dev/prod; read once here at process start.
	CursorHMACKey []byte

	RateLimit RateLimitConfig
	Quota     QuotaConfig
	// Scheduled holds the SCHEDULED_* limits of scheduled posts (Sweep).
	Scheduled ScheduledConfig
	// Suggestions holds the SUGGESTIONS_* limits and the SUGGESTED_USER_IDS curated list of ListSuggestedUsers.
	Suggestions SuggestionsConfig
	// Messaging holds the MESSAGES_* and CACHE_MESSAGING_* values of direct messages that are neither a rate limit nor a daily
	// quota. The send and read buckets and the daily send cap live in RateLimit; the new-conversation quota in Quota.
	Messaging MessagingConfig
	// Lists holds LISTS_MAX_PER_USER, LIST_MAX_MEMBERS, HOME_TABS_MAX_PINNED and CACHE_LISTS_ENTRIES. The list buckets
	// live in RateLimit.
	Lists ListsConfig
	// Communities holds COMMUNITY_CREATORS, the community caps and the cache sizes. The community buckets and daily caps
	// live in RateLimit.
	Communities CommunitiesConfig
	// Beacons holds BEACONS_MAX_OPEN_PER_USER, BEACONS_MAX_PENDING_REQUESTS and BEACONS_MAX_OPEN_SPOTS. The beacon buckets
	// and the daily create cap live in RateLimit.
	Beacons BeaconsConfig
	// Search holds the cache sizes and trend-refresh values of search and trends. The search buckets and the SearchPeople daily cap
	// live in RateLimit.
	Search SearchConfig
	// Composer holds the poll and GIF limits of the composer extras. The VotePoll bucket
	// lives in RateLimit.
	Composer ComposerConfig
	// Privacy holds PROTECTED_AUTHORS_MAX and PROTECTED_SET_MAX_STALE for private accounts.
	Privacy PrivacyConfig

	// HandleChangeCooldown is the minimum time between successful ChangeHandle calls.
	HandleChangeCooldown time.Duration

	// ShutdownTimeout bounds graceful shutdown; Cloud Run gives the process 10s after SIGTERM.
	ShutdownTimeout time.Duration

	// CacheTTL is the default instance-cache TTL for hot documents (e.g. users/{uid}).
	CacheTTL time.Duration

	// CachePostsEntries and CacheAuthorRecentEntries size the posts module's two instance caches:
	// post docs by id (CACHE_POSTS_ENTRIES, default 20,000) and per-author newest root posts
	// (CACHE_AUTHOR_RECENT_ENTRIES, default 1,000). Both must be > 0: the worst-case memory is
	// entries x ~2.5 KiB (posts) and entries x 20 shared pointers, bounded within the ~150 MiB cache budget.
	CachePostsEntries        int
	CacheAuthorRecentEntries int

	// TimelineTokenTTL is how long timeline since/page/gap tokens stay valid, env
	// TIMELINE_TOKEN_TTL, default 720h (30 days). The client persists since and gap tokens across days. It must
	// be between 24h (the graph-token TTL) and MaxTimelineTokenTTL (90 days); a shorter value would turn every morning refresh into a cold open.
	TimelineTokenTTL time.Duration
	// TimelineSettleWindow is the since-watermark settle window, env TIMELINE_SETTLE_WINDOW,
	// default and minimum MinTimelineSettleWindow: a post whose transaction started before the watermark has
	// committed or timed out (3 x the 5 s transaction deadline), so a `since` refresh cannot skip it.
	TimelineSettleWindow time.Duration

	// InternalOIDCAudience/InternalOIDCAllowedEmails configure /internal/* OIDC verification.
	// Empty only in local dev (no real Pub/Sub push subscriptions exist yet); Load fails closed (M8)
	// if either is unset outside ENV=local, since an unauthenticated /internal/* in dev/prod would accept
	// forged Pub/Sub push/Scheduler calls.
	InternalOIDCAudience      string
	InternalOIDCAllowedEmails []string

	// CORSAllowedOrigins enables browser CORS on the Connect handlers for exactly these origins (M10).
	// Empty means CORS is off — the default outside local, since prod/dev web traffic goes through
	// Firebase Hosting's same-origin `/api/**` rewrite (firebase.json) and never needs a cross-origin
	// request in the first place. Defaulted to common localhost dev origins when Env == "local"; always
	// extended with CORS_ALLOWED_ORIGINS if set (comma-separated), for the rare case dev/prod web needs to
	// call the Cloud Run URL directly instead of through Hosting.
	CORSAllowedOrigins []string

	// TrustedProxyHops, left at the default (<=1), lets ratelimit.ResolveClientIP auto-detect the Firebase
	// Hosting -> Cloud Run path (M2, 2026-09-27 security audit): it recognizes
	// when the rightmost X-Forwarded-For entry is a Google-operated egress address rather than the real
	// client, and if so counts one hop further left. Set above 1 only as an explicit operator override for
	// a topology that heuristic does not fit — it then skips detection and always counts that many entries
	// in from the right, the pre-M2 behavior. Every request logs xff_hops/via_hosting (never the IPs
	// themselves) on the one per-request INFO line (pkg/platform/mw.Logging) so this can be measured from
	// real dev traffic instead of guessed.
	TrustedProxyHops int

	// FeatureGraph is the server feature flag gating every GraphService RPC. Loaded from
	// FEATURE_GRAPH / FEATURE_GRAPH_ALLOWLIST / FEATURE_GRAPH_PERCENT (pkg/platform/flags).
	FeatureGraph flags.Spec

	// FeaturePosts is the server feature flag gating PostService and TimelineService. Loaded from
	// FEATURE_POSTS / FEATURE_POSTS_ALLOWLIST / FEATURE_POSTS_PERCENT (pkg/platform/flags), default off in prod
	// and on in dev and local, like FeatureGraph.
	FeaturePosts flags.Spec

	// FeatureAccountLifecycle is the server flag (wire name `account_lifecycle`) gating DeleteAccount,
	// RequestAccountExport and GetAccountExport. FEATURE_ACCOUNT_LIFECYCLE[_ALLOWLIST|_PERCENT], default off in
	// every environment.
	FeatureAccountLifecycle flags.Spec

	// FeatureReports is the server flag (wire name `reports`) gating ModerationService.ReportContent.
	// FEATURE_REPORTS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureReports flags.Spec
	// FeatureEngagement is the server flag (wire name `engagement`) gating EngagementService, the
	// quote path of CreatePost and viewer-flag hydration. FEATURE_ENGAGEMENT[_ALLOWLIST|_PERCENT], default off.
	FeatureEngagement flags.Spec
	// FeatureQuotes is the quote-creation flag (wire name `quotes`) gating only the
	// quote_of_post_id path of CreatePost, in addition to FEATURE_ENGAGEMENT. FEATURE_QUOTES[_ALLOWLIST|_PERCENT],
	// default off in every environment. Existing quote posts keep displaying regardless.
	FeatureQuotes flags.Spec
	// FeatureContentDisclosure is the flag (wire name `content_disclosure`) gating only SETTING
	// paid_partnership / made_with_ai on CreatePost (either true while off is FEATURE_DISABLED). Existing labels keep
	// rendering. FEATURE_CONTENT_DISCLOSURE[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureContentDisclosure flags.Spec
	// FeatureReplyAudience is the flag (wire name `reply_audience`) gating only SETTING a reply_policy
	// on CreatePost (a non-default value while off is FEATURE_DISABLED). ENFORCEMENT of an already-stored policy is
	// never flag-gated, so turning it off cannot reopen a restricted conversation. FEATURE_REPLY_AUDIENCE[_ALLOWLIST|
	// _PERCENT], default off in every environment.
	FeatureReplyAudience flags.Spec
	// FeatureScheduledPosts is the flag (wire name `scheduled_posts`) gating SchedulePost,
	// ListScheduledPosts and CancelScheduledPost (FEATURE_DISABLED feature=scheduled_posts while off) and the publish
	// sweep (a no-op while off). FEATURE_SCHEDULED_POSTS[_ALLOWLIST|_PERCENT], default off in every environment. It
	// leaves off only after 100% of traffic is on a revision that stores it.
	FeatureScheduledPosts flags.Spec
	// FeatureBookmarks is the flag (wire name `bookmarks`) gating AddBookmark (on for the caller),
	// ListBookmarks and RemoveBookmark (only not globally off, so a caller dropped from the allowlist can still list and
	// remove what they saved). FEATURE_DISABLED feature=bookmarks otherwise. FEATURE_BOOKMARKS[_ALLOWLIST|_PERCENT],
	// default off in every environment; it also needs FEATURE_POSTS, not FEATURE_ENGAGEMENT.
	FeatureBookmarks flags.Spec
	// FeatureMessaging is the flag (wire name `messaging`) gating MessagingService. SendMessage and
	// AcceptMessageRequest need it on for the caller; ListConversations, ListMessages, MarkConversationRead and
	// DeleteConversation only need it not globally off, so a caller dropped from the allowlist can still read and clean
	// up. FEATURE_DISABLED feature=messaging otherwise. FEATURE_MESSAGING[_ALLOWLIST|_PERCENT], default off in every
	// environment (dev stays on an allowlist, no prod raise).
	FeatureMessaging flags.Spec
	// FeatureLists is the flag (wire name `lists`) gating every ListService RPC, GetListTimeline and the LIST entries of
	// SetHomeTabs and GetMe.home_tabs. FEATURE_LISTS[_ALLOWLIST|_PERCENT], default off in every environment (dev stays on an allowlist,
	// no prod raise). It also needs FEATURE_POSTS, like Home.
	FeatureLists flags.Spec
	// FeatureCommunities is the flag (wire name `communities`) gating every CommunityService RPC, GetCommunityTimeline,
	// CreatePost.community_id and the COMMUNITY entries of SetHomeTabs and GetMe.home_tabs. FEATURE_COMMUNITIES[_ALLOWLIST|_PERCENT],
	// default off in every environment (dev stays on an allowlist, no prod raise). CreateCommunity also needs the caller in
	// Communities.Creators (COMMUNITY_CREATORS).
	FeatureCommunities flags.Spec
	// FeatureBeacons is the flag (wire name `beacons`) gating every BeaconService RPC (docs/beacons-plan.md). CreateBeacon,
	// UpdateBeacon, RequestToJoin and RespondToJoinRequest need it on for the caller; the reads, WithdrawJoinRequest,
	// LeaveBeacon, RemoveParticipant and CancelBeacon only need it not globally off, so a caller dropped from the allowlist
	// can still read, leave and cancel. A community-audience beacon also needs FEATURE_COMMUNITIES on for the caller.
	// FEATURE_BEACONS[_ALLOWLIST|_PERCENT], default off when unset in every environment; dev sets it on (ADR-0034 §4), no
	// prod raise yet.
	FeatureBeacons flags.Spec
	// FeatureCommunityMemberSearch is the flag (wire name `community_member_search`) gating CommunityService
	// SearchCommunityMembers (F36), checked after FEATURE_COMMUNITIES. FEATURE_COMMUNITY_MEMBER_SEARCH[_ALLOWLIST|_PERCENT],
	// default off in every environment; it never ramps ahead of FEATURE_COMMUNITIES.
	FeatureCommunityMemberSearch flags.Spec
	// FeaturePostBeaconEmbed is the flag (wire name `post_beacon_embed`) gating CreatePostRequest.beacon_id (a plan shared on a
	// root post) and, while globally off, stripping Post.beacon from every response. On for the caller on top of FEATURE_BEACONS
	// on for the caller. FEATURE_POST_BEACON_EMBED[_ALLOWLIST|_PERCENT], default off in every environment.
	FeaturePostBeaconEmbed flags.Spec
	// FeatureChatSharedPlans is the flag (wire name `chat_shared_plans`) gating BeaconService.ListSharedBeacons, the "plans
	// you share" strip of a chat. On for the caller on top of FEATURE_BEACONS not globally off.
	// FEATURE_CHAT_SHARED_PLANS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureChatSharedPlans flags.Spec
	// FeatureBeaconQuickJoin is the flag (wire name `beacon_quick_join`) gating the follow-gated empty note of
	// BeaconService.RequestToJoin: with it on for the caller, an empty note is accepted only when the organiser follows the
	// caller (else FAILED_PRECONDITION "note_required"), and ViewerState.quick_join_allowed is computed by GetBeacon. On for
	// the caller on top of FEATURE_BEACONS on for the caller. FEATURE_BEACON_QUICK_JOIN[_ALLOWLIST|_PERCENT], default off in
	// every environment.
	FeatureBeaconQuickJoin flags.Spec
	// FeatureReadReceipts is the flag (wire name `read_receipts`) gating read receipts (F3): UpdateProfile.read_receipts=true,
	// the receipt stamp of MarkConversationRead and Conversation.peer_read_at of ListMessages need it on for the caller (peer_read_at
	// also for the peer); Profile.read_receipts is shown unless it is globally off. Needs `messaging` for any effect.
	// FEATURE_READ_RECEIPTS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureReadReceipts flags.Spec
	// FeatureDMPolicy is the flag (wire name `dm_policy`) gating the "Who can message me" setting (F9): setting
	// UpdateProfile.dm_policy to FOLLOWING_ONLY needs it on for the caller, Profile.dm_policy is shown unless it is globally
	// off, and SendMessage applies a recipient's FOLLOWING_ONLY only when it is on for that recipient. Needs `messaging` for
	// any effect. FEATURE_DM_POLICY[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureDMPolicy flags.Spec
	// FeatureProfileExtras is the flag (wire name `profile_extras`) gating the UpdateProfile location, website and
	// pin fields. FEATURE_PROFILE_EXTRAS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureProfileExtras flags.Spec
	// FeatureProfileTabs is the flag (wire name `profile_tabs`) gating GetUserTimeline tab MEDIA and REPOSTS
	// (Posts and Replies stay ungated). FEATURE_PROFILE_TABS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureProfileTabs flags.Spec
	// FeatureLikesList is the flag (wire name `likes_list`) gating EngagementService.ListLikedPosts (on for the
	// caller; it also needs FEATURE_POSTS, not FEATURE_ENGAGEMENT). FEATURE_LIKES_LIST[_ALLOWLIST|_PERCENT], default off in
	// every environment.
	FeatureLikesList flags.Spec
	// FeatureFollowSuggestions is the flag (wire name `follow_suggestions`) gating GraphService.ListSuggestedUsers
	// (on for the caller; it also needs FEATURE_GRAPH). FEATURE_FOLLOW_SUGGESTIONS[_ALLOWLIST|_PERCENT], default off in every
	// environment.
	FeatureFollowSuggestions flags.Spec
	// FeaturePrivateAccounts is the flag (wire name `private_accounts`) gating UpdateProfile(is_private=true)
	// for the caller, plus ListFollowRequests / RespondToFollowRequest in later tickets. Enforcement of an existing
	// protection is never behind it: only mode off stops new protections, and is_private=false is always accepted.
	// FEATURE_PRIVATE_ACCOUNTS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeaturePrivateAccounts flags.Spec
	// FeatureSearch is the flag (wire name `search`) gating SearchPeople and SearchPosts per caller
	// (FEATURE_DISABLED feature=search, rejected before any lookup). FEATURE_SEARCH[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureSearch flags.Spec
	// FeatureTrends is the flag (wire name `trends`) gating GetTrends per caller and the trends refresh step
	// (which honours only a globally-off flag). FEATURE_TRENDS[_ALLOWLIST|_PERCENT], default off in every environment;
	// it never ramps ahead of FEATURE_SEARCH.
	FeatureTrends flags.Spec
	// FeaturePolls is the flag (wire name `polls`) gating CREATING a poll per caller (CreatePost with `poll`,
	// FEATURE_DISABLED feature=polls, rejected before any lookup). VotePoll needs engagement on for the caller and polls NOT globally off.
	// It never ramps ahead of FEATURE_ENGAGEMENT and leaves off only once 100% of traffic is on a revision that stores
	// and enforces polls. FEATURE_POLLS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeaturePolls flags.Spec
	// FeatureDrafts is the client-only flag (wire name `drafts`, like ui_shell): no RPC guard; it is registered
	// so GetMe.enabled_features reports it. FEATURE_DRAFTS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureDrafts flags.Spec
	// FeatureGif is the flag (wire name `gif`) gating CreateUpload with image/gif and CreatePost
	// with a GIF media doc. It never ramps ahead of FEATURE_MEDIA. FEATURE_GIF[_ALLOWLIST|_PERCENT], default off.
	FeatureGif flags.Spec

	// FeatureUIShell is the client-only UI flag (wire name `ui_shell`, W0 plan D3)
	// choosing the new app shell (bottom bar + avatar drawer, account chip, X-style rail) over the legacy four-item
	// navigation. No RPC is gated by it, it only reaches clients through GetMe.enabled_features. FEATURE_UI_SHELL
	// [_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureUIShell flags.Spec

	// FeatureUITablet is the client-only UI flag (wire name `ui_tablet`, tablet layout plan) gating the tablet shell
	// at 600-1199 dp. It only has an effect when ui_shell is also on for the caller; with it off, 600-1199 dp keeps
	// today's layout. No RPC is gated by it, it only reaches clients through GetMe.enabled_features.
	// FEATURE_UI_TABLET[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureUITablet flags.Spec

	// FeatureShells is the client-only UI flag (wire name `shells`) showing the W8
	// coming-soon pages (Creator tools, Premium, Advertise, Calls) and their drawer and rail entries. No RPC is gated by
	// it, it only reaches clients through GetMe.enabled_features. FEATURE_SHELLS[_ALLOWLIST|_PERCENT], default off in
	// every environment.
	FeatureShells flags.Spec

	// FeatureCrashReporting is the client-only telemetry flag (wire name `crash_reporting`) gating the "Send crash reports"
	// switch and Firebase Crashlytics collection in the Android app. No RPC is gated by it, it only reaches clients through
	// GetMe.enabled_features; collection is flag x consent x Android. FEATURE_CRASH_REPORTING[_ALLOWLIST|_PERCENT], default off in
	// every environment.
	FeatureCrashReporting flags.Spec

	// FeatureAnalytics is the client-only telemetry flag (wire name `analytics`) gating the "Share usage statistics"
	// switch and Google Analytics for Firebase collection in the Android app. No RPC is gated by it, it only reaches clients through
	// GetMe.enabled_features; collection is flag x consent x Android. FEATURE_ANALYTICS[_ALLOWLIST|_PERCENT], default off in every
	// environment.
	FeatureAnalytics flags.Spec

	// FeatureRemovedIDs is the server flag (wire name `removed_ids`) gating the moderation removal log
	// read on since_token refreshes (TimelineService removed_ids). FEATURE_REMOVED_IDS[_ALLOWLIST|_PERCENT], default
	// off in every environment: off means no log reads and no suspension-reset cost.
	// The log is still WRITTEN on every hide/restore while this is off, so enabling it later needs no backfill.
	FeatureRemovedIDs flags.Spec
	// FeatureReplies is the server flag (wire name `replies`) gating the reply path of CreatePost and
	// GetThread. FEATURE_REPLIES[_ALLOWLIST|_PERCENT], default off in every environment. It is independent of
	// FEATURE_POSTS but needs it (the posts guard runs first).
	FeatureReplies flags.Spec

	// AccountDeleteReauthMaxAge is ACCOUNT_DELETE_REAUTH_MAX_AGE (default 5m, must be in (0, 10m]): how recent the
	// ID token's auth_time must be for DeleteAccount and RequestAccountExport (authn.RequireRecentSignIn).
	AccountDeleteReauthMaxAge time.Duration

	// FeatureProfileSnapshot is the server flag (wire name `profile_snapshot`) gating the
	// profile-snapshot-refresh job. FEATURE_PROFILE_SNAPSHOT[_ALLOWLIST|_PERCENT],
	// default off in every environment (UpdateProfile/ChangeHandle themselves are not gated).
	FeatureProfileSnapshot flags.Spec

	// ExportBucket is EXPORT_BUCKET, the private account-export bucket. Default `<project>-exports`,
	// the name Terraform gives it.
	ExportBucket string
	// ExportURLTTL is EXPORT_URL_TTL (default 15m, in (0, 1h]): the lifetime of the signed GET URL minted per
	// GetAccountExport call.
	ExportURLTTL time.Duration
	// ExportRetention is EXPORT_RETENTION (default 168h = 7 d, in (0, 7d]): exports/{id}.expireAt = createdAt + this.
	// The bucket's age = 7 lifecycle rule is Terraform's; this value only drives the Firestore TTL field and the
	// NOT_FOUND-after-expiry rule, so it must not exceed what the bucket keeps.
	ExportRetention time.Duration
	// JobsTopic is JOBS_TOPIC, the shared Pub/Sub topic account deletion and export jobs self-chain on (default "jobs").
	JobsTopic string

	// FeatureNotifications is the server flag (wire name `notifications`) gating the
	// NotificationService RPCs, the event producers and the fan-out handler.
	// FEATURE_NOTIFICATIONS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureNotifications flags.Spec
	// FeatureNotificationPrefs is the flag (wire name `notification_prefs`) gating GetNotificationPrefs and
	// UpdateNotificationPrefs (both also need `notifications`) and the push preferences check in the fan-out (a recipient
	// outside the flag is pushed as before). FEATURE_NOTIFICATION_PREFS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureNotificationPrefs flags.Spec
	// NotificationsTopic is NOTIFICATIONS_TOPIC, the Pub/Sub topic producers publish notification events on
	// (default "notifications-fanout", the topic the pubsub Terraform module already owns).
	NotificationsTopic string
	// NotificationsDelivery is NOTIFICATIONS_DELIVERY: "pubsub" (publish to NotificationsTopic; Pub/Sub pushes back to
	// /internal/pubsub/notifications-fanout) or "inline" (deliver in-process on a bounded goroutine, FCM replaced by
	// a log line; local dev and emulator tests only, where no push subscription exists). Default inline when
	// ENV=local, pubsub otherwise; inline is refused outside local (it would run after the response).
	NotificationsDelivery string

	// AuthEmulator is true iff FIREBASE_AUTH_EMULATOR_HOST is non-empty. Only then does the
	// verified-identity gate admit anonymous sign-ins (the e2e helpers mint them). Load refuses the variable
	// when ENV is dev or prod: the Admin SDK would then accept unsigned emulator tokens.
	AuthEmulator bool

	// FeatureMedia is the server flag (wire name `media`) gating MediaService, CreatePost media_ids and the
	// avatar path of UpdateProfile. FEATURE_MEDIA[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureMedia flags.Spec
	// MediaUploadBucket is MEDIA_UPLOAD_BUCKET (private, 2-day lifecycle) and MediaBucket is MEDIA_BUCKET
	// (public-read); defaults `<project>-media-upload` and `<project>-media`, the names Terraform gives them.
	MediaUploadBucket string
	MediaBucket       string
	// MediaPublicBaseURL is MEDIA_PUBLIC_BASE_URL: the URL prefix public objects are served from (no trailing
	// slash). Default https://storage.googleapis.com/<MediaBucket>; local dev points it at the Storage emulator.
	MediaPublicBaseURL string
	// VisionScreenThumb is VISION_SCREEN_THUMB (default true): screen the thumbnail too, so the small image shown
	// in lists is moderated as well as the full image (2 units per image instead of 1). Set false to follow
	// the one-unit wording literally.
	VisionScreenThumb bool
	// ProfileMediaRetire is PROFILE_MEDIA_RETIRE (default off): which replaced or removed profile
	// images the profile_media_retired step deletes after the grace. Per-project retention, not a FEATURE_ flag.
	ProfileMediaRetire ProfileMediaRetire
	// MediaOrphanSweep is MEDIA_ORPHAN_SWEEP (default off): the media orphan sweep's kill switch, off | mark (phase 1 and
	// the restore paths, never a delete) | delete. Per-project operations config, not a FEATURE_ flag.
	MediaOrphanSweep MediaOrphanSweep
	// AuthIdentityAudit is AUTH_IDENTITY_AUDIT (default false): GetMe logs a WARN when the token's signing identity
	// or email differs from what the account had at sign-up. Detection only, it never rejects or changes a
	// response. A plain switch, not a FEATURE_ flag: a flag gates RPCs and would answer FAILED_PRECONDITION.
	AuthIdentityAudit bool
}

// Bounds of the export settings: a signed URL is a bearer credential, and the retention
// promised to users is 7 days.
const (
	MaxExportURLTTL = time.Hour
	// MaxExportRetention matches the exports bucket lifecycle rule (age = 7 d, infra media-buckets): a longer
	// retention would promise a READY export that the bucket has already deleted.
	MaxExportRetention = 7 * 24 * time.Hour
)

// MaxAccountDeleteReauthMaxAge is the upper bound of ACCOUNT_DELETE_REAUTH_MAX_AGE.
const MaxAccountDeleteReauthMaxAge = 10 * time.Minute

// Load reads Config from the environment, applying Stage 0 defaults for anything unset.
func Load() (Config, error) {
	env := getenv("ENV", "local")

	// Exact match only: every relaxed branch below keys on env == "local" or env == "prod", so a typo such as
	// "Prod" or "staging" must not slip through as a third, half-permissive environment.
	if env != "local" && env != "dev" && env != "prod" {
		return Config{}, fmt.Errorf("config: invalid ENV %q (want local|dev|prod)", env)
	}

	// Cloud Run sets K_SERVICE (services) or CLOUD_RUN_JOB (jobs). ENV=local relaxes auth (unauthenticated
	// /internal/*, AllowAll moderator, hard-coded cursor key, App Check monitor), so a missing ENV there must
	// fail closed, not default to it.
	if env == "local" && (os.Getenv("K_SERVICE") != "" || os.Getenv("CLOUD_RUN_JOB") != "") {
		return Config{}, fmt.Errorf("config: ENV=local (or unset) is refused on Cloud Run (K_SERVICE or CLOUD_RUN_JOB is set); set ENV to dev or prod")
	}

	// Emulator hosts redirect the client libraries (and, for Auth, accept unsigned tokens), so they are local-only.
	if env != "local" {
		for _, k := range []string{"FIREBASE_AUTH_EMULATOR_HOST", "FIRESTORE_EMULATOR_HOST", "PUBSUB_EMULATOR_HOST", "STORAGE_EMULATOR_HOST"} {
			if os.Getenv(k) != "" {
				return Config{}, fmt.Errorf("config: %s must not be set in env %q", k, env)
			}
		}
	}

	// FIREBASE_PROJECT_ID is the canonical var (Terraform sets it); GOOGLE_CLOUD_PROJECT, GCP_PROJECT_ID
	// and GCP_PROJECT are accepted fallbacks so this also runs unmodified under tooling/environments that
	// only set one of Google's own conventional project-id vars (B2).
	projectID := firstNonEmpty(
		os.Getenv("FIREBASE_PROJECT_ID"),
		os.Getenv("GOOGLE_CLOUD_PROJECT"),
		os.Getenv("GCP_PROJECT_ID"),
		os.Getenv("GCP_PROJECT"),
	)
	if projectID == "" {
		if env == "local" {
			projectID = "demo-dzeroth-local"
		} else {
			return Config{}, fmt.Errorf(
				"config: one of FIREBASE_PROJECT_ID, GOOGLE_CLOUD_PROJECT, GCP_PROJECT_ID or GCP_PROJECT is required in env %q", env)
		}
	}

	degraded := DegradedMode(getenv("DEGRADED_MODE", string(DegradedOff)))
	if !degraded.valid() {
		return Config{}, fmt.Errorf("config: invalid DEGRADED_MODE %q (want off|readonly|nomedia)", degraded)
	}

	appCheckDefault := string(AppCheckEnforce)
	if env == "local" {
		appCheckDefault = string(AppCheckMonitor)
	}
	appCheck := AppCheckMode(getenv("APP_CHECK_MODE", appCheckDefault))
	if !appCheck.valid() {
		return Config{}, fmt.Errorf("config: invalid APP_CHECK_MODE %q (want enforce|monitor)", appCheck)
	}

	cursorKey := os.Getenv("CURSOR_HMAC_KEY")
	if cursorKey == "" {
		if env == "local" {
			cursorKey = "local-dev-only-cursor-hmac-key-not-for-prod"
		} else {
			return Config{}, fmt.Errorf(
				"config: CURSOR_HMAC_KEY is required in env %q (Secret Manager secret %q wired to this env var)", env, "cursor-hmac-key")
		}
	}

	shutdownTimeout, err := getDuration("SHUTDOWN_TIMEOUT", 8*time.Second)
	if err != nil {
		return Config{}, err
	}
	timelineTokenTTL, err := getDuration("TIMELINE_TOKEN_TTL", 720*time.Hour)
	if err != nil {
		return Config{}, err
	}
	if timelineTokenTTL < 24*time.Hour || timelineTokenTTL > MaxTimelineTokenTTL {
		return Config{}, fmt.Errorf("config: TIMELINE_TOKEN_TTL %v must be between 24h and %v (default 720h)", timelineTokenTTL, MaxTimelineTokenTTL)
	}
	timelineSettleWindow, err := getDuration("TIMELINE_SETTLE_WINDOW", MinTimelineSettleWindow)
	if err != nil {
		return Config{}, err
	}
	if timelineSettleWindow < MinTimelineSettleWindow {
		return Config{}, fmt.Errorf("config: TIMELINE_SETTLE_WINDOW %v must be at least %v (3 x the 5 s CreatePost transaction deadline, ADR-0010 D13)", timelineSettleWindow, MinTimelineSettleWindow)
	}
	cacheTTL, err := getDuration("CACHE_TTL", 60*time.Second)
	if err != nil {
		return Config{}, err
	}
	// The account-deletion start gate is 120 s; instance caches must expire well inside it so
	// a purge cannot race a stale cache entry.
	if cacheTTL > MaxCacheTTL {
		return Config{}, fmt.Errorf(
			"config: CACHE_TTL %v exceeds the maximum of %.0fs: the account-deletion start gate is 120s and the instance cache TTL must stay below it so PurgeUser cannot race stale caches (ADR-0009)",
			cacheTTL, MaxCacheTTL.Seconds())
	}
	cachePostsEntries, err := getInt("CACHE_POSTS_ENTRIES", 20_000)
	if err != nil {
		return Config{}, err
	}
	cacheAuthorRecentEntries, err := getInt("CACHE_AUTHOR_RECENT_ENTRIES", 1_000)
	if err != nil {
		return Config{}, err
	}
	for name, v := range map[string]int{
		"CACHE_POSTS_ENTRIES":         cachePostsEntries,
		"CACHE_AUTHOR_RECENT_ENTRIES": cacheAuthorRecentEntries,
	} {
		if v <= 0 {
			return Config{}, fmt.Errorf("config: %s must be > 0 (got %d)", name, v)
		}
	}
	handleCooldown, err := getDuration("HANDLE_CHANGE_COOLDOWN", 7*24*time.Hour)
	if err != nil {
		return Config{}, err
	}
	newAccountWindow, err := getDuration("QUOTA_NEW_ACCOUNT_WINDOW", 24*time.Hour)
	if err != nil {
		return Config{}, err
	}

	rl := RateLimitConfig{}
	if rl.PerUserPerMinute, err = getInt("RATE_LIMIT_PER_USER_PER_MIN", 60); err != nil {
		return Config{}, err
	}
	if rl.TimelinePerUserPerMinute, err = getInt("RATE_LIMIT_TIMELINE_PER_MIN", 6); err != nil {
		return Config{}, err
	}
	// R-N8 (2026-09-28 readiness review): raised from 10 to 20/min.
	if rl.CheckHandlePerUserPerMinute, err = getInt("RATE_LIMIT_CHECK_HANDLE_PER_MIN", 20); err != nil {
		return Config{}, err
	}
	if rl.LikesPerUserPerMinute, err = getInt("RATE_LIMIT_LIKES_PER_MIN", 30); err != nil {
		return Config{}, err
	}
	if rl.PerIPPerMinute, err = getInt("RATE_LIMIT_PER_IP_PER_MIN", 120); err != nil {
		return Config{}, err
	}
	if rl.TimelinePerUserPerMinute <= 0 {
		return Config{}, fmt.Errorf("config: RATE_LIMIT_TIMELINE_PER_MIN must be > 0 (got %d)", rl.TimelinePerUserPerMinute)
	}
	// GetUserTimeline 30/min, CreatePost 10/min, DeletePost 20/min.
	for _, b := range []struct {
		key string
		def int
		dst *int
	}{
		{"RATE_LIMIT_USER_TIMELINE_PER_MIN", 30, &rl.UserTimelinePerMinute},
		{"RATE_LIMIT_POST_CREATE_PER_MIN", 10, &rl.PostCreatePerMinute},
		{"RATE_LIMIT_POST_DELETE_PER_MIN", 20, &rl.PostDeletePerMinute},
		// FinalizeUpload has its own bucket, split from CreateUpload's (10/min per instance, 30 with 3).
		{"RATE_LIMIT_MEDIA_FINALIZE_PER_MIN", 10, &rl.MediaFinalizePerMinute},
		{"RATE_LIMIT_REPORT_PER_MIN", 5, &rl.ReportPerMinute},
		// AddBookmark and RemoveBookmark share one bucket (30/min); ListBookmarks has its own (10/min).
		{"RATE_LIMIT_BOOKMARKS_PER_MIN", 30, &rl.BookmarksPerUserPerMinute},
		{"RATE_LIMIT_BOOKMARKS_LIST_PER_MIN", 10, &rl.BookmarksListPerUserPerMinute},
		// ListSuggestedUsers 10/min, ListLikedPosts 10/min, GetProfileRelationship 60/min (all per instance).
		// SearchPeople 30/min and SearchPosts 20/min (per instance, 90 and 60 with 3). GetTrends uses the default bucket.
		{"RATE_LIMIT_SEARCH_PEOPLE_PER_MIN", 30, &rl.SearchPeoplePerUserPerMinute},
		// VotePoll 30/min per instance (90 with 3).
		{"RATE_LIMIT_POLL_VOTE_PER_MIN", 30, &rl.PollVotePerUserPerMinute},
		{"RATE_LIMIT_SEARCH_POSTS_PER_MIN", 20, &rl.SearchPostsPerUserPerMinute},
		{"RATE_LIMIT_SUGGESTIONS_PER_MIN", 10, &rl.SuggestionsPerUserPerMinute},
		{"RATE_LIMIT_LIKES_LIST_PER_MIN", 10, &rl.LikesListPerUserPerMinute},
		{"RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN", 60, &rl.ProfileRelationshipPerUserPerMinute},
		// RespondToFollowRequest 60/min per instance (180 with 3). ListFollowRequests uses the graph list bucket.
		{"RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN", 60, &rl.FollowRequestsRespondPerUserPerMinute},
		// SendMessage 20/min (per instance, 60 with 3); the read RPCs (lists, polls, mark-read) 30/min.
		{"RATE_LIMIT_MESSAGES_SEND_PER_MIN", 20, &rl.MessagesSendPerUserPerMinute},
		{"RATE_LIMIT_MESSAGES_READ_PER_MIN", 30, &rl.MessagesReadPerUserPerMinute},
		// ListNotifications 30/min per instance (90 with 3); it used to fall back to the 60/min default.
		{"RATE_LIMIT_NOTIFICATIONS_LIST_PER_MIN", 30, &rl.NotificationsListPerUserPerMinute},
		// The six list mutations 30/min, GetList / ListUserLists / ListListMembers 30/min, GetListTimeline 12/min (all per
		// instance, x3 with 3 instances).
		{"RATE_LIMIT_LISTS_WRITE_PER_MIN", 30, &rl.ListsWritePerUserPerMinute},
		{"RATE_LIMIT_LISTS_READ_PER_MIN", 30, &rl.ListsReadPerUserPerMinute},
		{"RATE_LIMIT_LIST_TIMELINE_PER_MIN", 12, &rl.ListTimelinePerUserPerMinute},
		// The seven community mutations 20/min, the five community reads 30/min, GetCommunityTimeline 12/min (per instance, x3).
		{"RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN", 20, &rl.CommunitiesWritePerUserPerMinute},
		{"RATE_LIMIT_COMMUNITIES_READ_PER_MIN", 30, &rl.CommunitiesReadPerUserPerMinute},
		{"RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN", 12, &rl.CommunityTimelinePerUserPerMinute},
		// Beacons: Create/Update/Cancel 10/min, the five participation actions 20/min, the four reads 30/min (per instance, x3).
		{"RATE_LIMIT_BEACONS_WRITE_PER_MIN", 10, &rl.BeaconsWritePerUserPerMinute},
		{"RATE_LIMIT_BEACONS_ACTION_PER_MIN", 20, &rl.BeaconsActionPerUserPerMinute},
		{"RATE_LIMIT_BEACONS_READ_PER_MIN", 30, &rl.BeaconsReadPerUserPerMinute},
	} {
		v, err := getInt(b.key, b.def)
		if err != nil {
			return Config{}, err
		}
		if v <= 0 {
			return Config{}, fmt.Errorf("config: %s must be > 0 (got %d)", b.key, v)
		}
		*b.dst = v
	}
	if rl.PreAuthIPPerMinute, err = getInt("RATE_LIMIT_PRE_AUTH_IP_PER_MIN", 120); err != nil {
		return Config{}, err
	}
	// Follow/Unfollow 30/min; Block/Unblock/Mute/Unmute 20/min; lists 20/min; GetRelationships
	// uses PerUserPerMinute (the 60/min default) — no separate config needed for it.
	if rl.GraphFollowPerMinute, err = getInt("RATE_LIMIT_GRAPH_FOLLOW_PER_MIN", 30); err != nil {
		return Config{}, err
	}
	if rl.GraphBlockPerMinute, err = getInt("RATE_LIMIT_GRAPH_BLOCK_PER_MIN", 20); err != nil {
		return Config{}, err
	}
	if rl.GraphListPerMinute, err = getInt("RATE_LIMIT_GRAPH_LIST_PER_MIN", 20); err != nil {
		return Config{}, err
	}
	graphMutationsPerDay, err := getInt("GRAPH_MUTATIONS_PER_DAY", 500)
	if err != nil {
		return Config{}, err
	}
	rl.GraphMutationsPerDay = int64(graphMutationsPerDay)
	// M-1: ONE daily cap over AddBookmark + RemoveBookmark (limit_name "bookmark_mutation_daily"); see
	// RateLimitConfig.BookmarkMutationsPerDay for the default's math. A cap of 0 would lock every user out of the RPCs.
	bookmarkMutationsPerDay, err := getInt("BOOKMARK_MUTATIONS_PER_DAY", 1500)
	if err != nil {
		return Config{}, err
	}
	if bookmarkMutationsPerDay <= 0 {
		return Config{}, fmt.Errorf("config: BOOKMARK_MUTATIONS_PER_DAY must be > 0 (got %d)", bookmarkMutationsPerDay)
	}
	rl.BookmarkMutationsPerDay = int64(bookmarkMutationsPerDay)
	// SendMessage daily cap (limit_name "messages_daily"); see RateLimitConfig.MessagesSendsPerDay. A cap
	// of 0 would lock every user out of the RPC.
	messagesSendsPerDay, err := getInt("MESSAGES_SENDS_PER_DAY", 300)
	if err != nil {
		return Config{}, err
	}
	if messagesSendsPerDay <= 0 {
		return Config{}, fmt.Errorf("config: MESSAGES_SENDS_PER_DAY must be > 0 (got %d)", messagesSendsPerDay)
	}
	rl.MessagesSendsPerDay = int64(messagesSendsPerDay)
	// Security review M-1: MarkConversationRead's own daily cap (limit_name "messages_mark_read_daily") and ONE
	// cap shared by AcceptMessageRequest + DeleteConversation (limit_name "messages_mutation_daily"); see
	// RateLimitConfig.MessagesMarkReadPerDay / MessagesMutationsPerDay for the defaults' math. A cap of 0 would lock every
	// user out of the RPCs.
	for _, f := range []struct {
		dst *int64
		key string
		def int
	}{
		{&rl.MessagesMarkReadPerDay, "MESSAGES_MARK_READ_PER_DAY", 500},
		{&rl.MessagesMutationsPerDay, "MESSAGES_MUTATIONS_PER_DAY", 500},
		// Community mod actions (Hide, SetMemberRole) per actor, CreatePost into one community per uid|cid, SearchPeople alone,
		// and ListFollowers + ListFollowing together; all in memory per instance.
		{&rl.CommunityModActionsPerDay, "COMMUNITY_MOD_ACTIONS_PER_DAY", 200},
		{&rl.CommunityPostsPerCommunityPerDay, "COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY", 20},
		{&rl.SearchPeopleCallsPerDay, "SEARCH_PEOPLE_CALLS_PER_DAY", 1000},
		{&rl.FollowListCallsPerDay, "FOLLOW_LIST_CALLS_PER_DAY", 1000},
		// CreateBeacon per uid, limit_name "beacons_created_daily".
		{&rl.BeaconsCreatedPerDay, "BEACONS_CREATED_PER_DAY", 10},
	} {
		v, err := getInt(f.key, f.def)
		if err != nil {
			return Config{}, err
		}
		if v <= 0 {
			return Config{}, fmt.Errorf("config: %s must be > 0 (got %d)", f.key, v)
		}
		*f.dst = int64(v)
	}
	// L-4: UpdateProfile daily call cap (limit_name "profile_update_daily"); see RateLimitConfig.ProfileUpdatesPerDay
	// for the default's math. A cap of 0 would lock every user out of the RPC.
	profileUpdatesPerDay, err := getInt("PROFILE_UPDATES_PER_DAY", 100)
	if err != nil {
		return Config{}, err
	}
	if profileUpdatesPerDay <= 0 {
		return Config{}, fmt.Errorf("config: PROFILE_UPDATES_PER_DAY must be > 0 (got %d)", profileUpdatesPerDay)
	}
	rl.ProfileUpdatesPerDay = int64(profileUpdatesPerDay)
	notifRecipients, err := getInt("NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY", 200)
	if err != nil {
		return Config{}, err
	}
	rl.NotificationRecipientsPerActorPerDay = int64(notifRecipients)
	notifRecipientsNew, err := getInt("NOTIFICATION_RECIPIENTS_PER_NEW_ACTOR_PER_DAY", 50)
	if err != nil {
		return Config{}, err
	}
	rl.NotificationRecipientsPerNewActorPerDay = int64(notifRecipientsNew)
	notifPushes, err := getInt("NOTIFICATION_PUSHES_PER_RECIPIENT_PER_HOUR", 10)
	if err != nil {
		return Config{}, err
	}
	rl.NotificationPushesPerRecipientPerHour = int64(notifPushes)
	// m3: a zero/negative cap would lock every uid out after one call (NewDailyCap clamps it to 1), so it is
	// a startup error, not a way to "disable" a cap.
	for name, v := range map[string]int{
		"NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY":     notifRecipients,
		"NOTIFICATION_RECIPIENTS_PER_NEW_ACTOR_PER_DAY": notifRecipientsNew,
		"NOTIFICATION_PUSHES_PER_RECIPIENT_PER_HOUR":    notifPushes,
	} {
		if v <= 0 {
			return Config{}, fmt.Errorf("config: %s must be > 0 (got %d)", name, v)
		}
	}

	trustedProxyHops, err := getInt("TRUSTED_PROXY_HOPS", 1)
	if err != nil {
		return Config{}, err
	}

	q := QuotaConfig{NewAccountWindow: newAccountWindow}
	// 20 reports/day, 5 for accounts younger than the new-account window.
	if q.ReportsPerDay, err = getInt("QUOTA_REPORTS_PER_DAY", 20); err != nil {
		return Config{}, err
	}
	if q.NewAccountReportsPerDay, err = getInt("QUOTA_NEW_ACCOUNT_REPORTS_PER_DAY", 5); err != nil {
		return Config{}, err
	}
	// A hard cap of 1,000 bookmarks per user (the userLikes array length is the exact cap check).
	if q.BookmarksMaxPerUser, err = getInt("BOOKMARKS_MAX_PER_USER", 1000); err != nil {
		return Config{}, err
	}
	if q.BookmarksMaxPerUser <= 0 {
		return Config{}, fmt.Errorf("config: BOOKMARKS_MAX_PER_USER must be > 0 (got %d)", q.BookmarksMaxPerUser)
	}
	// 20 new conversations per IST day, 5 for accounts younger than the new-account window (quota.DMNew).
	if q.DMNewConversationsPerDay, err = getInt("QUOTA_DM_NEW_CONVERSATIONS_PER_DAY", 20); err != nil {
		return Config{}, err
	}
	if q.NewAccountDMNewConversationsPerDay, err = getInt("QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY", 5); err != nil {
		return Config{}, err
	}
	for name, v := range map[string]int{
		"QUOTA_DM_NEW_CONVERSATIONS_PER_DAY":             q.DMNewConversationsPerDay,
		"QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY": q.NewAccountDMNewConversationsPerDay,
	} {
		if v <= 0 {
			return Config{}, fmt.Errorf("config: %s must be > 0 (got %d)", name, v)
		}
	}
	scheduled, err := loadScheduled()
	if err != nil {
		return Config{}, err
	}
	messaging, err := loadMessaging()
	if err != nil {
		return Config{}, err
	}
	communities, err := loadCommunities()
	if err != nil {
		return Config{}, err
	}
	beacons, err := loadBeacons()
	if err != nil {
		return Config{}, err
	}
	lists, err := loadLists()
	if err != nil {
		return Config{}, err
	}
	privacy, err := loadPrivacy()
	if err != nil {
		return Config{}, err
	}
	search, err := loadSearch()
	if err != nil {
		return Config{}, err
	}
	composer, err := loadComposer()
	if err != nil {
		return Config{}, err
	}
	suggestions, err := loadSuggestions()
	if err != nil {
		return Config{}, err
	}

	// With the Auth emulator variable set, the Admin SDK accepts unsigned tokens. That must
	// never be true in a deployed environment, so refuse to start.
	authEmulator := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") != ""
	if authEmulator && env != "local" {
		return Config{}, fmt.Errorf("config: FIREBASE_AUTH_EMULATOR_HOST must not be set in env %q (the Admin SDK would accept unsigned tokens)", env)
	}

	allowedEmails := splitCSV(os.Getenv("INTERNAL_OIDC_ALLOWED_EMAILS"))
	internalOIDCAudience := os.Getenv("INTERNAL_OIDC_AUDIENCE")

	// M8: fail closed outside local. Without both of these, pkg/platform/pubsubpush would leave
	// /internal/* (Pub/Sub push, Cloud Scheduler) unauthenticated — acceptable only in local dev, where no
	// real push subscription exists to forge a call from.
	if env != "local" {
		switch {
		case internalOIDCAudience == "" && len(allowedEmails) == 0:
			return Config{}, fmt.Errorf("config: INTERNAL_OIDC_AUDIENCE and INTERNAL_OIDC_ALLOWED_EMAILS are both required in env %q", env)
		case internalOIDCAudience == "":
			return Config{}, fmt.Errorf("config: INTERNAL_OIDC_AUDIENCE is required in env %q", env)
		case len(allowedEmails) == 0:
			return Config{}, fmt.Errorf("config: INTERNAL_OIDC_ALLOWED_EMAILS is required in env %q", env)
		}
	}

	// Rollout plan: off in prod, on in dev and local by default (an operator can always
	// override via FEATURE_GRAPH). LoadSpec fails startup fast on an invalid mode/percent.
	graphDefaultMode := flags.On
	if env == "prod" {
		graphDefaultMode = flags.Off
	}
	featureGraph, err := flags.LoadSpec("GRAPH", "graph", graphDefaultMode)
	if err != nil {
		return Config{}, err
	}
	// Same rollout shape as graph (dev on, prod off; Terraform sets it explicitly).
	featurePosts, err := flags.LoadSpec("POSTS", "posts", graphDefaultMode)
	if err != nil {
		return Config{}, err
	}

	// Off everywhere until the founder turns it on; the reauth window is bounded so a typo cannot
	// quietly disable the recent-sign-in check.
	featureAccountLifecycle, err := flags.LoadSpec("ACCOUNT_LIFECYCLE", "account_lifecycle", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureNotifications, err := flags.LoadSpec("NOTIFICATIONS", "notifications", flags.Off)
	if err != nil {
		return Config{}, err
	}
	notifDeliveryDefault := "pubsub"
	if env == "local" {
		notifDeliveryDefault = "inline"
	}
	notifDelivery := getenv("NOTIFICATIONS_DELIVERY", notifDeliveryDefault)
	switch {
	case notifDelivery != "pubsub" && notifDelivery != "inline":
		return Config{}, fmt.Errorf("config: NOTIFICATIONS_DELIVERY must be pubsub or inline (got %q)", notifDelivery)
	case notifDelivery == "inline" && env != "local":
		return Config{}, fmt.Errorf("config: NOTIFICATIONS_DELIVERY=inline is only allowed in env local (got %q)", env)
	}
	// Media is off everywhere until the founder ramps it. Every image is always screened: there is no setting that
	// caps or disables the SafeSearch spend (the old VISION_MONTHLY_CAP and VISION_EXHAUSTED_POLICY keys are ignored).
	featureMedia, err := flags.LoadSpec("MEDIA", "media", flags.Off)
	if err != nil {
		return Config{}, err
	}
	profileMediaRetire, err := ParseProfileMediaRetire(os.Getenv("PROFILE_MEDIA_RETIRE"))
	if err != nil {
		return Config{}, err
	}
	mediaOrphanSweep, err := ParseMediaOrphanSweep(os.Getenv("MEDIA_ORPHAN_SWEEP"))
	if err != nil {
		return Config{}, err
	}
	visionScreenThumb := true
	switch v := strings.ToLower(getenv("VISION_SCREEN_THUMB", "true")); v {
	case "true", "1":
	case "false", "0":
		visionScreenThumb = false
	default:
		return Config{}, fmt.Errorf("config: invalid VISION_SCREEN_THUMB %q (want true|false)", v)
	}
	authIdentityAudit := false
	switch v := strings.ToLower(getenv("AUTH_IDENTITY_AUDIT", "false")); v {
	case "true", "1":
		authIdentityAudit = true
	case "false", "0":
	default:
		return Config{}, fmt.Errorf("config: invalid AUTH_IDENTITY_AUDIT %q (want true|false)", v)
	}
	mediaBucket := getenv("MEDIA_BUCKET", projectID+"-media")

	featureProfileSnapshot, err := flags.LoadSpec("PROFILE_SNAPSHOT", "profile_snapshot", flags.Off)
	if err != nil {
		return Config{}, err
	}
	// Replies are off everywhere until the founder ramps them.
	featureReplies, err := flags.LoadSpec("REPLIES", "replies", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureReports, err := flags.LoadSpec("REPORTS", "reports", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureEngagement, err := flags.LoadSpec("ENGAGEMENT", "engagement", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureQuotes, err := flags.LoadSpec("QUOTES", "quotes", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureContentDisclosure, err := flags.LoadSpec("CONTENT_DISCLOSURE", "content_disclosure", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureReplyAudience, err := flags.LoadSpec("REPLY_AUDIENCE", "reply_audience", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureScheduledPosts, err := flags.LoadSpec("SCHEDULED_POSTS", "scheduled_posts", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureBookmarks, err := flags.LoadSpec("BOOKMARKS", "bookmarks", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureMessaging, err := flags.LoadSpec("MESSAGING", "messaging", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureLists, err := flags.LoadSpec("LISTS", "lists", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureCommunities, err := flags.LoadSpec("COMMUNITIES", "communities", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureBeacons, err := flags.LoadSpec("BEACONS", "beacons", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureCommunityMemberSearch, err := flags.LoadSpec("COMMUNITY_MEMBER_SEARCH", "community_member_search", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featurePostBeaconEmbed, err := flags.LoadSpec("POST_BEACON_EMBED", "post_beacon_embed", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureChatSharedPlans, err := flags.LoadSpec("CHAT_SHARED_PLANS", "chat_shared_plans", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureBeaconQuickJoin, err := flags.LoadSpec("BEACON_QUICK_JOIN", "beacon_quick_join", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureReadReceipts, err := flags.LoadSpec("READ_RECEIPTS", "read_receipts", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureDMPolicy, err := flags.LoadSpec("DM_POLICY", "dm_policy", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureNotificationPrefs, err := flags.LoadSpec("NOTIFICATION_PREFS", "notification_prefs", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureProfileExtras, err := flags.LoadSpec("PROFILE_EXTRAS", "profile_extras", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureProfileTabs, err := flags.LoadSpec("PROFILE_TABS", "profile_tabs", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureLikesList, err := flags.LoadSpec("LIKES_LIST", "likes_list", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureFollowSuggestions, err := flags.LoadSpec("FOLLOW_SUGGESTIONS", "follow_suggestions", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featurePrivateAccounts, err := flags.LoadSpec("PRIVATE_ACCOUNTS", "private_accounts", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureSearch, err := flags.LoadSpec("SEARCH", "search", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureTrends, err := flags.LoadSpec("TRENDS", "trends", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featurePolls, err := flags.LoadSpec("POLLS", "polls", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureDrafts, err := flags.LoadSpec("DRAFTS", "drafts", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureGif, err := flags.LoadSpec("GIF", "gif", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureUIShell, err := flags.LoadSpec("UI_SHELL", "ui_shell", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureUITablet, err := flags.LoadSpec("UI_TABLET", "ui_tablet", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureShells, err := flags.LoadSpec("SHELLS", "shells", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureCrashReporting, err := flags.LoadSpec("CRASH_REPORTING", "crash_reporting", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureAnalytics, err := flags.LoadSpec("ANALYTICS", "analytics", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureRemovedIDs, err := flags.LoadSpec("REMOVED_IDS", "removed_ids", flags.Off)
	if err != nil {
		return Config{}, err
	}
	reauthMaxAge, err := getDuration("ACCOUNT_DELETE_REAUTH_MAX_AGE", 5*time.Minute)
	if err != nil {
		return Config{}, err
	}
	if reauthMaxAge <= 0 || reauthMaxAge > MaxAccountDeleteReauthMaxAge {
		return Config{}, fmt.Errorf("config: ACCOUNT_DELETE_REAUTH_MAX_AGE must be > 0 and <= %s (got %s)", MaxAccountDeleteReauthMaxAge, reauthMaxAge)
	}

	exportURLTTL, err := getDuration("EXPORT_URL_TTL", 15*time.Minute)
	if err != nil {
		return Config{}, err
	}
	if exportURLTTL <= 0 || exportURLTTL > MaxExportURLTTL {
		return Config{}, fmt.Errorf("config: EXPORT_URL_TTL must be > 0 and <= %s (got %s)", MaxExportURLTTL, exportURLTTL)
	}
	exportRetention, err := getDuration("EXPORT_RETENTION", 7*24*time.Hour)
	if err != nil {
		return Config{}, err
	}
	if exportRetention <= 0 || exportRetention > MaxExportRetention {
		return Config{}, fmt.Errorf("config: EXPORT_RETENTION must be > 0 and <= %s (got %s)", MaxExportRetention, exportRetention)
	}

	// M10: PORT defaults to 8081 in local dev so `go run ./cmd/api` never collides with the Firestore
	// emulator's fixed port 8080 (firebase.json); Cloud Run always sets PORT explicitly in dev/prod, so
	// that default is unchanged there.
	portDefault := "8080"
	if env == "local" {
		portDefault = "8081"
	}

	// M10: CORS is on by default for common local dev origins (Flutter web via `flutter run -d chrome`
	// talks to the API directly, a different origin than the emulators); off by default otherwise, since
	// Firebase Hosting's same-origin `/api/**` rewrite means dev/prod web never makes a cross-origin
	// request. CORS_ALLOWED_ORIGINS can add origins in any env (e.g. a one-off cross-origin dev/test tool).
	var corsOrigins []string
	if env == "local" {
		corsOrigins = []string{"http://localhost:*", "http://127.0.0.1:*"}
	}
	corsOrigins = append(corsOrigins, splitCSV(os.Getenv("CORS_ALLOWED_ORIGINS"))...)

	billingWebhook, err := loadBillingWebhook(env)
	if err != nil {
		return Config{}, err
	}
	billingSandbox, err := loadBillingSandbox(env)
	if err != nil {
		return Config{}, err
	}
	return Config{
		BillingSandbox:               billingSandbox,
		BillingWebhook:               billingWebhook,
		Port:                         getenv("PORT", portDefault),
		ProjectID:                    projectID,
		Env:                          env,
		Degraded:                     degraded,
		AppCheck:                     appCheck,
		CursorHMACKey:                []byte(cursorKey),
		RateLimit:                    rl,
		Quota:                        q,
		Scheduled:                    scheduled,
		Suggestions:                  suggestions,
		Privacy:                      privacy,
		Messaging:                    messaging,
		Lists:                        lists,
		Communities:                  communities,
		Beacons:                      beacons,
		Search:                       search,
		Composer:                     composer,
		HandleChangeCooldown:         handleCooldown,
		ShutdownTimeout:              shutdownTimeout,
		CacheTTL:                     cacheTTL,
		CachePostsEntries:            cachePostsEntries,
		CacheAuthorRecentEntries:     cacheAuthorRecentEntries,
		TimelineTokenTTL:             timelineTokenTTL,
		TimelineSettleWindow:         timelineSettleWindow,
		InternalOIDCAudience:         internalOIDCAudience,
		InternalOIDCAllowedEmails:    allowedEmails,
		CORSAllowedOrigins:           corsOrigins,
		TrustedProxyHops:             trustedProxyHops,
		FeatureGraph:                 featureGraph,
		FeaturePosts:                 featurePosts,
		AuthEmulator:                 authEmulator,
		FeatureAccountLifecycle:      featureAccountLifecycle,
		FeatureReports:               featureReports,
		FeatureEngagement:            featureEngagement,
		FeatureQuotes:                featureQuotes,
		FeatureContentDisclosure:     featureContentDisclosure,
		FeatureReplyAudience:         featureReplyAudience,
		FeatureScheduledPosts:        featureScheduledPosts,
		FeatureBookmarks:             featureBookmarks,
		FeatureMessaging:             featureMessaging,
		FeatureLists:                 featureLists,
		FeatureCommunities:           featureCommunities,
		FeatureCommunityMemberSearch: featureCommunityMemberSearch,
		FeatureBeacons:               featureBeacons,
		FeaturePostBeaconEmbed:       featurePostBeaconEmbed,
		FeatureChatSharedPlans:       featureChatSharedPlans,
		FeatureBeaconQuickJoin:       featureBeaconQuickJoin,
		FeatureReadReceipts:          featureReadReceipts,
		FeatureProfileExtras:         featureProfileExtras,
		FeatureProfileTabs:           featureProfileTabs,
		FeatureLikesList:             featureLikesList,
		FeatureFollowSuggestions:     featureFollowSuggestions,
		FeaturePrivateAccounts:       featurePrivateAccounts,
		FeatureSearch:                featureSearch,
		FeatureTrends:                featureTrends,
		FeaturePolls:                 featurePolls,
		FeatureDrafts:                featureDrafts,
		FeatureGif:                   featureGif,
		FeatureUIShell:               featureUIShell,
		FeatureUITablet:              featureUITablet,
		FeatureShells:                featureShells,
		FeatureCrashReporting:        featureCrashReporting,
		FeatureAnalytics:             featureAnalytics,
		FeatureRemovedIDs:            featureRemovedIDs,
		FeatureProfileSnapshot:       featureProfileSnapshot,
		FeatureReplies:               featureReplies,
		AccountDeleteReauthMaxAge:    reauthMaxAge,
		ExportBucket:                 getenv("EXPORT_BUCKET", projectID+"-exports"),
		ExportURLTTL:                 exportURLTTL,
		ExportRetention:              exportRetention,
		JobsTopic:                    getenv("JOBS_TOPIC", "jobs"),
		FeatureNotifications:         featureNotifications,
		FeatureDMPolicy:              featureDMPolicy,
		FeatureNotificationPrefs:     featureNotificationPrefs,
		NotificationsTopic:           getenv("NOTIFICATIONS_TOPIC", "notifications-fanout"),
		NotificationsDelivery:        notifDelivery,
		FeatureMedia:                 featureMedia,
		MediaUploadBucket:            getenv("MEDIA_UPLOAD_BUCKET", projectID+"-media-upload"),
		MediaBucket:                  mediaBucket,
		MediaPublicBaseURL:           strings.TrimRight(getenv("MEDIA_PUBLIC_BASE_URL", "https://storage.googleapis.com/"+mediaBucket), "/"),
		VisionScreenThumb:            visionScreenThumb,
		ProfileMediaRetire:           profileMediaRetire,
		MediaOrphanSweep:             mediaOrphanSweep,
		AuthIdentityAudit:            authIdentityAudit,
	}, nil
}

// MustLoad calls Load and panics on error. Only safe at process startup (never on a request path).
func MustLoad() Config {
	cfg, err := Load()
	if err != nil {
		panic(err)
	}
	return cfg
}
