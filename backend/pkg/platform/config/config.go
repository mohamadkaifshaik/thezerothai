// Package config loads process configuration from environment variables. Cloud Run injects PORT and
// any Secret Manager-backed env vars; the Firebase/Firestore emulators are honored automatically by
// their client libraries via FIRESTORE_EMULATOR_HOST / FIREBASE_AUTH_EMULATOR_HOST / PUBSUB_EMULATOR_HOST,
// so this package does not special-case them beyond choosing sane local defaults.
//
// Loading is a single, cheap pass over os.Getenv — safe to call before ListenAndServe (ADR-0002 cold
// start budget: nothing heavy in main before the server starts).
package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// MaxCacheTTL is the upper bound for CACHE_TTL (ADR-0009 T33): the account-deletion start gate is 120 s, so
// instance caches must expire well inside it.
const MaxCacheTTL = 60 * time.Second

// MinTimelineSettleWindow is the lower bound (and default) for TIMELINE_SETTLE_WINDOW: 3 x the 5 s CreatePost
// transaction deadline (ADR-0010 D13).
const MinTimelineSettleWindow = 15 * time.Second

// MaxTimelineTokenTTL is the upper bound for TIMELINE_TOKEN_TTL (90 days, T28 follow-up): a typo must not make
// timeline tokens effectively immortal.
const MaxTimelineTokenTTL = 2160 * time.Hour

// RemovalLogMaxReads is the most reads the shared moderation removal log refresh (ADR-0016 D10) can cost: a full
// incremental page (50) followed by the reload of the newest 50, once per instance per CACHE_TTL and only when 50
// or more log entries are new. Since the 2026-10-18 (b) amendment (security audit RID-4) it is charged to a
// detached counter (log field removal_log_reads), NOT to the user whose request triggered it, so it is no longer
// part of ReadBudgetMaxCallReads. posts.RemovalWorstReads is the source; a test pins them equal.
const RemovalLogMaxReads = 100

// RemovalWindowMaxReads is the most reads the per-feed window query of one since_token refresh can charge to the
// caller: when the token is older than the instance cache's coverage and the feed has at most 6 x 30 authors, at
// most 51 new documents across the chunks, 50 more for boundary entries returned twice, plus one read per
// empty chunk. posts.RemovalWindowWorstReads is the source;
// a test pins them equal.
const RemovalWindowMaxReads = 107

// ReadBudgetMaxCallReads is the worst-case Firestore reads of ONE call charged to the user, the figure ADR-0010
// D5's cost bound and the read budget's single-flight guard use: home timeline 2 + C + 2 * page_size = 269 at
// 5,000 following (C = 30-uid chunks = 167) and page 50 (timeline.proto). The removal log adds nothing to that
// worst case: its shared refresh is detached (RemovalLogMaxReads) and its window query
// (RemovalWindowMaxReads = 107) only runs for feeds of at most 180 authors (C <= 7, so such a call is at most
// 2 + 7 + 100 + 107 = 216). Keep it in sync with that RPC's doc comment; tests use this constant, not a literal.
const ReadBudgetMaxCallReads = 269

// IPReadBudgetMaxCallReads is the per-call hold M of the IP read budget (ADR-0010 D5 A1). Since A8 nothing
// reserves the IP key (it is charge-only everywhere), so this hold has no admission role; it is the constant any
// future enforced IP procedure must respect. It is true because a profile-less call charged to the IP key stops
// at account status after at most 1 read, and a call that finds a profile is charged 0 there (A9). CreateProfile
// reads several docs but is charge-only, never held.
const IPReadBudgetMaxCallReads = 2

// Config is the full process configuration. Constructed once in main via Load/MustLoad.
type Config struct {
	// Port is the HTTP listen port. Cloud Run sets PORT explicitly in dev/prod; defaults to 8081 in local
	// dev (M10) so it never collides with the Firestore emulator's fixed port 8080 (firebase.json).
	Port string
	// ProjectID is the GCP/Firebase project. Required; also used as the Firestore/Auth project.
	ProjectID string
	// Env is one of local|dev|prod. Only used for defaults and log fields, never for branching business logic.
	Env string

	Degraded DegradedMode
	AppCheck AppCheckMode

	// CursorHMACKey signs opaque pagination cursors (ADR-0003) so clients cannot craft unbounded scans.
	// Sourced from a Secret Manager-backed env var in dev/prod; read once here at process start.
	CursorHMACKey []byte

	RateLimit RateLimitConfig
	Quota     QuotaConfig
	// Scheduled holds the SCHEDULED_* limits of scheduled posts (ADR-0021 D4, Sweep).
	Scheduled ScheduledConfig
	// Suggestions holds the SUGGESTIONS_* limits and the SUGGESTED_USER_IDS curated list of ListSuggestedUsers (ADR-0024 D8).
	Suggestions SuggestionsConfig
	// Privacy holds PROTECTED_AUTHORS_MAX and PROTECTED_SET_MAX_STALE for private accounts (ADR-0025 D2, D3).
	Privacy PrivacyConfig

	// HandleChangeCooldown is the minimum time between successful ChangeHandle calls.
	HandleChangeCooldown time.Duration

	// ShutdownTimeout bounds graceful shutdown; Cloud Run gives the process 10s after SIGTERM.
	ShutdownTimeout time.Duration

	// CacheTTL is the default instance-cache TTL for hot documents (e.g. users/{uid}).
	CacheTTL time.Duration

	// CachePostsEntries and CacheAuthorRecentEntries size the posts module's two instance caches (ADR-0010 D15):
	// post docs by id (CACHE_POSTS_ENTRIES, default 20,000) and per-author newest root posts
	// (CACHE_AUTHOR_RECENT_ENTRIES, default 1,000). Both must be > 0: the worst-case memory is
	// entries x ~2.5 KiB (posts) and entries x 20 shared pointers, bounded within the ~150 MiB cache budget.
	CachePostsEntries        int
	CacheAuthorRecentEntries int

	// TimelineTokenTTL is how long timeline since/page/gap tokens stay valid (ADR-0010 D14), env
	// TIMELINE_TOKEN_TTL, default 720h (30 days). The client persists since and gap tokens across days. It must
	// be between 24h (the graph-token TTL) and MaxTimelineTokenTTL (90 days); a shorter value would turn every morning refresh into a cold open.
	TimelineTokenTTL time.Duration
	// TimelineSettleWindow is the since-watermark settle window (ADR-0010 D13), env TIMELINE_SETTLE_WINDOW,
	// default and minimum MinTimelineSettleWindow: a post whose transaction started before the watermark has
	// committed or timed out (3 x the 5 s transaction deadline), so a `since` refresh cannot skip it.
	TimelineSettleWindow time.Duration

	// InternalOIDCAudience/InternalOIDCAllowedEmails configure /internal/* OIDC verification (ADR-0006
	// §5). Empty only in local dev (no real Pub/Sub push subscriptions exist yet); Load fails closed (M8)
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
	// Hosting -> Cloud Run path (M2, 2026-09-27 security audit amendment to ADR-0006 §3): it recognizes
	// when the rightmost X-Forwarded-For entry is a Google-operated egress address rather than the real
	// client, and if so counts one hop further left. Set above 1 only as an explicit operator override for
	// a topology that heuristic does not fit — it then skips detection and always counts that many entries
	// in from the right, the pre-M2 behavior. Every request logs xff_hops/via_hosting (never the IPs
	// themselves) on the one per-request INFO line (pkg/platform/mw.Logging) so this can be measured from
	// real dev traffic instead of guessed.
	TrustedProxyHops int

	// FeatureGraph is the ADR-0008 D6 server feature flag gating every GraphService RPC. Loaded from
	// FEATURE_GRAPH / FEATURE_GRAPH_ALLOWLIST / FEATURE_GRAPH_PERCENT (pkg/platform/flags).
	FeatureGraph flags.Spec

	// FeaturePosts is the ADR-0010 D1 server feature flag gating PostService and TimelineService. Loaded from
	// FEATURE_POSTS / FEATURE_POSTS_ALLOWLIST / FEATURE_POSTS_PERCENT (pkg/platform/flags), default off in prod
	// and on in dev and local, like FeatureGraph.
	FeaturePosts flags.Spec

	// FeatureAccountLifecycle is the P8 T4 server flag (wire name `account_lifecycle`) gating DeleteAccount,
	// RequestAccountExport and GetAccountExport. FEATURE_ACCOUNT_LIFECYCLE[_ALLOWLIST|_PERCENT], default off in
	// every environment.
	FeatureAccountLifecycle flags.Spec

	// FeatureReports is the P7 server flag (wire name `reports`, ADR-0016 D1) gating ModerationService.ReportContent.
	// FEATURE_REPORTS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureReports flags.Spec
	// FeatureEngagement is the P5 server flag (wire name `engagement`, ADR-0018 D8) gating EngagementService, the
	// quote path of CreatePost and viewer-flag hydration. FEATURE_ENGAGEMENT[_ALLOWLIST|_PERCENT], default off.
	FeatureEngagement flags.Spec
	// FeatureQuotes is the quote-creation flag (wire name `quotes`, ADR-0018 amendment 2026-10-18) gating only the
	// quote_of_post_id path of CreatePost, in addition to FEATURE_ENGAGEMENT. FEATURE_QUOTES[_ALLOWLIST|_PERCENT],
	// default off in every environment. Existing quote posts keep displaying regardless.
	FeatureQuotes flags.Spec
	// FeatureContentDisclosure is the ADR-0021 D3 flag (wire name `content_disclosure`) gating only SETTING
	// paid_partnership / made_with_ai on CreatePost (either true while off is FEATURE_DISABLED). Existing labels keep
	// rendering. FEATURE_CONTENT_DISCLOSURE[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureContentDisclosure flags.Spec
	// FeatureReplyAudience is the ADR-0021 D2 flag (wire name `reply_audience`) gating only SETTING a reply_policy
	// on CreatePost (a non-default value while off is FEATURE_DISABLED). ENFORCEMENT of an already-stored policy is
	// never flag-gated, so turning it off cannot reopen a restricted conversation. FEATURE_REPLY_AUDIENCE[_ALLOWLIST|
	// _PERCENT], default off in every environment.
	FeatureReplyAudience flags.Spec
	// FeatureScheduledPosts is the ADR-0021 D4 flag (wire name `scheduled_posts`) gating SchedulePost,
	// ListScheduledPosts and CancelScheduledPost (FEATURE_DISABLED feature=scheduled_posts while off) and the publish
	// sweep (a no-op while off). FEATURE_SCHEDULED_POSTS[_ALLOWLIST|_PERCENT], default off in every environment. It
	// leaves off only after 100% of traffic is on a revision that stores it (ADR-0021 L-1).
	FeatureScheduledPosts flags.Spec
	// FeatureBookmarks is the ADR-0023 D5 flag (wire name `bookmarks`) gating AddBookmark (on for the caller),
	// ListBookmarks and RemoveBookmark (only not globally off, so a caller dropped from the allowlist can still list and
	// remove what they saved). FEATURE_DISABLED feature=bookmarks otherwise. FEATURE_BOOKMARKS[_ALLOWLIST|_PERCENT],
	// default off in every environment; it also needs FEATURE_POSTS, not FEATURE_ENGAGEMENT.
	FeatureBookmarks flags.Spec
	// FeatureProfileExtras is the ADR-0024 D9 flag (wire name `profile_extras`) gating the UpdateProfile banner, location,
	// website and pin fields and CreateUpload(BANNER) (which also needs `media`). FEATURE_PROFILE_EXTRAS[_ALLOWLIST|_PERCENT],
	// default off in every environment. W3-4 registers it; W3-5 and W3-6 add the gates.
	FeatureProfileExtras flags.Spec
	// FeatureProfileTabs is the ADR-0024 D9 flag (wire name `profile_tabs`) gating GetUserTimeline tab MEDIA and REPOSTS
	// (Posts and Replies stay ungated). FEATURE_PROFILE_TABS[_ALLOWLIST|_PERCENT], default off in every environment.
	// W3-4 registers it; W3-9 adds the gate.
	FeatureProfileTabs flags.Spec
	// FeatureLikesList is the ADR-0024 D9 flag (wire name `likes_list`) gating EngagementService.ListLikedPosts (on for the
	// caller; it also needs FEATURE_POSTS, not FEATURE_ENGAGEMENT). FEATURE_LIKES_LIST[_ALLOWLIST|_PERCENT], default off in
	// every environment.
	FeatureLikesList flags.Spec
	// FeatureFollowSuggestions is the ADR-0024 D9 flag (wire name `follow_suggestions`) gating GraphService.ListSuggestedUsers
	// (on for the caller; it also needs FEATURE_GRAPH). FEATURE_FOLLOW_SUGGESTIONS[_ALLOWLIST|_PERCENT], default off in every
	// environment.
	FeatureFollowSuggestions flags.Spec
	// FeaturePrivateAccounts is the ADR-0025 D12 flag (wire name `private_accounts`) gating UpdateProfile(is_private=true)
	// for the caller, plus ListFollowRequests / RespondToFollowRequest in later tickets. Enforcement of an existing
	// protection is never behind it: only mode off stops new protections, and is_private=false is always accepted.
	// FEATURE_PRIVATE_ACCOUNTS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeaturePrivateAccounts flags.Spec

	// FeatureUIShell is the client-only UI flag (wire name `ui_shell`, ADR-0020 / docs/plans/ui-w0-foundations.md D3)
	// choosing the new app shell (bottom bar + avatar drawer, account chip, X-style rail) over the legacy four-item
	// navigation. No RPC is gated by it, it only reaches clients through GetMe.enabled_features. FEATURE_UI_SHELL
	// [_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureUIShell flags.Spec

	// FeatureShells is the client-only UI flag (wire name `shells`, docs/plans/ui-w8-shells.md) showing the W8
	// coming-soon pages (Creator tools, Premium, Advertise, Calls) and their drawer and rail entries. No RPC is gated by
	// it, it only reaches clients through GetMe.enabled_features. FEATURE_SHELLS[_ALLOWLIST|_PERCENT], default off in
	// every environment.
	FeatureShells flags.Spec

	// FeatureRemovedIDs is the ADR-0016 D10 server flag (wire name `removed_ids`) gating the moderation removal log
	// read on since_token refreshes (TimelineService removed_ids). FEATURE_REMOVED_IDS[_ALLOWLIST|_PERCENT], default
	// off in every environment: off means no log reads and no suspension-reset cost (docs/runbooks/moderation.md 3b).
	// The log is still WRITTEN on every hide/restore while this is off, so enabling it later needs no backfill.
	FeatureRemovedIDs flags.Spec
	// FeatureReplies is the P3 server flag (wire name `replies`) gating the reply path of CreatePost and
	// GetThread. FEATURE_REPLIES[_ALLOWLIST|_PERCENT], default off in every environment. It is independent of
	// FEATURE_POSTS but needs it (the posts guard runs first).
	FeatureReplies flags.Spec

	// AccountDeleteReauthMaxAge is ACCOUNT_DELETE_REAUTH_MAX_AGE (default 5m, must be in (0, 10m]): how recent the
	// ID token's auth_time must be for DeleteAccount (authn.RequireRecentSignIn).
	AccountDeleteReauthMaxAge time.Duration

	// FeatureProfileSnapshot is the P2 server flag (wire name `profile_snapshot`) gating the
	// profile-snapshot-refresh job and the snapshot-edit quota. FEATURE_PROFILE_SNAPSHOT[_ALLOWLIST|_PERCENT],
	// default off in every environment (UpdateProfile/ChangeHandle themselves are not gated).
	FeatureProfileSnapshot flags.Spec

	// ExportBucket is EXPORT_BUCKET, the private account-export bucket (ADR-0011 D-B). Default `<project>-exports`,
	// the name Terraform gives it.
	ExportBucket string
	// ExportURLTTL is EXPORT_URL_TTL (default 15m, in (0, 1h]): the lifetime of the signed GET URL minted per
	// GetAccountExport call.
	ExportURLTTL time.Duration
	// ExportRetention is EXPORT_RETENTION (default 168h = 7 d, in (0, 7d]): exports/{id}.expireAt = createdAt + this.
	// The bucket's age = 7 lifecycle rule is Terraform's; this value only drives the Firestore TTL field and the
	// NOT_FOUND-after-expiry rule (ADR-0011 Q6), so it must not exceed what the bucket keeps.
	ExportRetention time.Duration
	// JobsTopic is JOBS_TOPIC, the shared Pub/Sub topic account deletion and export jobs self-chain on (default "jobs").
	JobsTopic string

	// FeatureNotifications is the P6 server flag (wire name `notifications`, ADR-0017 D7) gating the
	// NotificationService RPCs, the event producers and the fan-out handler.
	// FEATURE_NOTIFICATIONS[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureNotifications flags.Spec
	// NotificationsTopic is NOTIFICATIONS_TOPIC, the Pub/Sub topic producers publish notification events on
	// (default "notifications-fanout", the topic the pubsub Terraform module already owns).
	NotificationsTopic string
	// NotificationsDelivery is NOTIFICATIONS_DELIVERY: "pubsub" (publish to NotificationsTopic; Pub/Sub pushes back to
	// /internal/pubsub/notifications-fanout) or "inline" (deliver in-process on a bounded goroutine, FCM replaced by
	// a log line; local dev and emulator tests only, where no push subscription exists). Default inline when
	// ENV=local, pubsub otherwise; inline is refused outside local (it would run after the response).
	NotificationsDelivery string

	// AuthEmulator is true iff FIREBASE_AUTH_EMULATOR_HOST is non-empty (ADR-0010 D5 A10). Only then does the
	// verified-identity gate admit anonymous sign-ins (the e2e helpers mint them). Load refuses the variable
	// when ENV is dev or prod: the Admin SDK would then accept unsigned emulator tokens.
	AuthEmulator bool

	// FeatureMedia is the P4 server flag (wire name `media`) gating MediaService, CreatePost media_ids and the
	// avatar path of UpdateProfile. FEATURE_MEDIA[_ALLOWLIST|_PERCENT], default off in every environment.
	FeatureMedia flags.Spec
	// MediaUploadBucket is MEDIA_UPLOAD_BUCKET (private, 2-day lifecycle) and MediaBucket is MEDIA_BUCKET
	// (public-read); defaults `<project>-media-upload` and `<project>-media`, the names Terraform gives them.
	MediaUploadBucket string
	MediaBucket       string
	// MediaPublicBaseURL is MEDIA_PUBLIC_BASE_URL: the URL prefix public objects are served from (no trailing
	// slash). Default https://storage.googleapis.com/<MediaBucket>; local dev points it at the Storage emulator.
	MediaPublicBaseURL string
	// VisionMonthlyCap is VISION_MONTHLY_CAP (default 10,000): the most SafeSearch units one calendar month may
	// consume (ADR-0005). At the cap, VisionExhaustedPolicy applies. 0 disables screening spend entirely (every
	// upload takes the exhausted path).
	VisionMonthlyCap int
	// VisionExhaustedPolicy is VISION_EXHAUSTED_POLICY (ADR-0005): what an upload becomes once the cap is hit.
	VisionExhaustedPolicy VisionExhaustedPolicy
	// VisionScreenThumb is VISION_SCREEN_THUMB (default true): screen the thumbnail too, so the small image shown
	// in lists is moderated as well as the full image (2 units per image instead of 1). Set false to follow
	// ADR-0005's one-unit wording literally.
	VisionScreenThumb bool
	// ProfileMediaRetire is PROFILE_MEDIA_RETIRE (ADR-0024 Amendment 1 A4, default off): which replaced or removed profile
	// images the profile_media_retired step deletes after the grace. Per-project retention, not a FEATURE_ flag.
	ProfileMediaRetire ProfileMediaRetire
}

// Bounds of the export settings (ADR-0011 D-B): a signed URL is a bearer credential, and the retention
// promised to users is 7 days.
const (
	MaxExportURLTTL = time.Hour
	// MaxExportRetention matches the exports bucket lifecycle rule (age = 7 d, infra media-buckets): a longer
	// retention would promise a READY export that the bucket has already deleted.
	MaxExportRetention = 7 * 24 * time.Hour
)

// MaxAccountDeleteReauthMaxAge is the upper bound of ACCOUNT_DELETE_REAUTH_MAX_AGE (P8 T4).
const MaxAccountDeleteReauthMaxAge = 10 * time.Minute

// Load reads Config from the environment, applying Stage 0 defaults (ADR-0002/0003/0006) for anything unset.
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
	// ADR-0009 T33: the account-deletion start gate is 120 s; instance caches must expire well inside it so
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
	// R-N8 (2026-09-28 readiness review / ADR-0008 D7): raised from 10 to 20/min.
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
	// ADR-0010 T4 / Handoff: GetUserTimeline 30/min, CreatePost 10/min, DeletePost 20/min.
	for _, b := range []struct {
		key string
		def int
		dst *int
	}{
		{"RATE_LIMIT_USER_TIMELINE_PER_MIN", 30, &rl.UserTimelinePerMinute},
		{"RATE_LIMIT_POST_CREATE_PER_MIN", 10, &rl.PostCreatePerMinute},
		{"RATE_LIMIT_POST_DELETE_PER_MIN", 20, &rl.PostDeletePerMinute},
		{"RATE_LIMIT_REPORT_PER_MIN", 5, &rl.ReportPerMinute},
		// ADR-0023 D4: AddBookmark and RemoveBookmark share one bucket (30/min); ListBookmarks has its own (10/min).
		{"RATE_LIMIT_BOOKMARKS_PER_MIN", 30, &rl.BookmarksPerUserPerMinute},
		{"RATE_LIMIT_BOOKMARKS_LIST_PER_MIN", 10, &rl.BookmarksListPerUserPerMinute},
		// ADR-0024 D10: ListSuggestedUsers 10/min, ListLikedPosts 10/min, GetProfileRelationship 60/min (all per instance).
		{"RATE_LIMIT_SUGGESTIONS_PER_MIN", 10, &rl.SuggestionsPerUserPerMinute},
		{"RATE_LIMIT_LIKES_LIST_PER_MIN", 10, &rl.LikesListPerUserPerMinute},
		{"RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN", 60, &rl.ProfileRelationshipPerUserPerMinute},
		// ADR-0025 D13: RespondToFollowRequest 60/min per instance (180 with 3). ListFollowRequests uses the graph list bucket.
		{"RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN", 60, &rl.FollowRequestsRespondPerUserPerMinute},
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
	// ADR-0008 D7: Follow/Unfollow 30/min; Block/Unblock/Mute/Unmute 20/min; lists 20/min; GetRelationships
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
	graphListCallsPerDay, err := getInt("LIST_CALLS_PER_DAY", 100)
	if err != nil {
		return Config{}, err
	}
	rl.GraphListCallsPerDay = int64(graphListCallsPerDay)
	graphMutationsPerDay, err := getInt("GRAPH_MUTATIONS_PER_DAY", 500)
	if err != nil {
		return Config{}, err
	}
	rl.GraphMutationsPerDay = int64(graphMutationsPerDay)
	// W2-14 M-1: ONE daily cap over AddBookmark + RemoveBookmark (limit_name "bookmark_mutation_daily"); see
	// RateLimitConfig.BookmarkMutationsPerDay for the default's math. A cap of 0 would lock every user out of the RPCs.
	bookmarkMutationsPerDay, err := getInt("BOOKMARK_MUTATIONS_PER_DAY", 1500)
	if err != nil {
		return Config{}, err
	}
	if bookmarkMutationsPerDay <= 0 {
		return Config{}, fmt.Errorf("config: BOOKMARK_MUTATIONS_PER_DAY must be > 0 (got %d)", bookmarkMutationsPerDay)
	}
	rl.BookmarkMutationsPerDay = int64(bookmarkMutationsPerDay)
	// ADR-0024 D10: ListSuggestedUsers daily call cap (limit_name "suggestions_daily"); see
	// RateLimitConfig.SuggestionsCallsPerDay for the default's math. A cap of 0 would lock every user out of the RPC.
	suggestionsCallsPerDay, err := getInt("SUGGESTIONS_CALLS_PER_DAY", 50)
	if err != nil {
		return Config{}, err
	}
	if suggestionsCallsPerDay <= 0 {
		return Config{}, fmt.Errorf("config: SUGGESTIONS_CALLS_PER_DAY must be > 0 (got %d)", suggestionsCallsPerDay)
	}
	rl.SuggestionsCallsPerDay = int64(suggestionsCallsPerDay)
	// W3-22 L-4: UpdateProfile daily call cap (limit_name "profile_update_daily"); see RateLimitConfig.ProfileUpdatesPerDay
	// for the default's math. A cap of 0 would lock every user out of the RPC.
	profileUpdatesPerDay, err := getInt("PROFILE_UPDATES_PER_DAY", 100)
	if err != nil {
		return Config{}, err
	}
	if profileUpdatesPerDay <= 0 {
		return Config{}, fmt.Errorf("config: PROFILE_UPDATES_PER_DAY must be > 0 (got %d)", profileUpdatesPerDay)
	}
	rl.ProfileUpdatesPerDay = int64(profileUpdatesPerDay)
	readBudgetUID, err := getInt("READ_BUDGET_PER_UID_PER_DAY", 2000)
	if err != nil {
		return Config{}, err
	}
	rl.ReadBudgetPerUIDPerDay = int64(readBudgetUID)
	readBudgetIP, err := getInt("READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY", 500)
	if err != nil {
		return Config{}, err
	}
	rl.ReadBudgetPerIPNoProfilePerDay = int64(readBudgetIP)
	checkHandleCalls, err := getInt("CHECK_HANDLE_CALLS_PER_DAY", 100)
	if err != nil {
		return Config{}, err
	}
	rl.CheckHandleCallsPerDay = int64(checkHandleCalls)
	accountOpsCalls, err := getInt("ACCOUNT_OPS_CALLS_PER_DAY", 20)
	if err != nil {
		return Config{}, err
	}
	rl.AccountOpsCallsPerDay = int64(accountOpsCalls)
	notifDeviceCalls, err := getInt("NOTIFICATION_DEVICES_CALLS_PER_DAY", 10)
	if err != nil {
		return Config{}, err
	}
	rl.NotificationDevicesCallsPerDay = int64(notifDeviceCalls)
	notifSeenCalls, err := getInt("NOTIFICATION_SEEN_CALLS_PER_DAY", 200)
	if err != nil {
		return Config{}, err
	}
	rl.NotificationSeenCallsPerDay = int64(notifSeenCalls)
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
	// a startup error, not a way to "disable" the budget (rule 11: caps are reviewed like logic).
	for name, v := range map[string]int{
		"READ_BUDGET_PER_UID_PER_DAY":           readBudgetUID,
		"READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY": readBudgetIP,
		"CHECK_HANDLE_CALLS_PER_DAY":            checkHandleCalls,
		"ACCOUNT_OPS_CALLS_PER_DAY":             accountOpsCalls,
		"NOTIFICATION_DEVICES_CALLS_PER_DAY":    notifDeviceCalls,
		"NOTIFICATION_SEEN_CALLS_PER_DAY":       notifSeenCalls,

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
	if q.PostsPerDay, err = getInt("QUOTA_POSTS_PER_DAY", 100); err != nil {
		return Config{}, err
	}
	if q.FollowsPerDay, err = getInt("QUOTA_FOLLOWS_PER_DAY", 200); err != nil {
		return Config{}, err
	}
	if q.MediaPerDay, err = getInt("QUOTA_MEDIA_PER_DAY", 20); err != nil {
		return Config{}, err
	}
	if q.ExportsPerDay, err = getInt("QUOTA_EXPORTS_PER_DAY", 1); err != nil {
		return Config{}, err
	}
	if q.SnapshotEditsPerDay, err = getInt("QUOTA_SNAPSHOT_EDITS_PER_DAY", 5); err != nil {
		return Config{}, err
	}
	if q.NewAccountPostsPerDay, err = getInt("QUOTA_NEW_ACCOUNT_POSTS_PER_DAY", 20); err != nil {
		return Config{}, err
	}
	if q.NewAccountFollowsPerDay, err = getInt("QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY", 50); err != nil {
		return Config{}, err
	}
	if q.NewAccountMediaPerDay, err = getInt("QUOTA_NEW_ACCOUNT_MEDIA_PER_DAY", 5); err != nil {
		return Config{}, err
	}
	// ADR-0008 D7: Block + Mute share one daily counter (quota.Blocks).
	if q.BlocksPerDay, err = getInt("QUOTA_BLOCKS_PER_DAY", 200); err != nil {
		return Config{}, err
	}
	if q.NewAccountBlocksPerDay, err = getInt("QUOTA_NEW_ACCOUNT_BLOCKS_PER_DAY", 50); err != nil {
		return Config{}, err
	}
	// ADR-0016 D1: 20 reports/day, 5 for accounts younger than the new-account window.
	if q.ReportsPerDay, err = getInt("QUOTA_REPORTS_PER_DAY", 20); err != nil {
		return Config{}, err
	}
	if q.NewAccountReportsPerDay, err = getInt("QUOTA_NEW_ACCOUNT_REPORTS_PER_DAY", 5); err != nil {
		return Config{}, err
	}
	// ADR-0018 D3: 500 likes/day, 100 for accounts younger than the new-account window.
	if q.LikesPerDay, err = getInt("QUOTA_LIKES_PER_DAY", 500); err != nil {
		return Config{}, err
	}
	if q.NewAccountLikesPerDay, err = getInt("QUOTA_NEW_ACCOUNT_LIKES_PER_DAY", 100); err != nil {
		return Config{}, err
	}
	// ADR-0021 D4: 50 SchedulePost calls/day, 10 for accounts younger than the new-account window (review L-4).
	if q.SchedulesPerDay, err = getInt("QUOTA_SCHEDULES_PER_DAY", 50); err != nil {
		return Config{}, err
	}
	if q.NewAccountSchedulesPerDay, err = getInt("QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY", 10); err != nil {
		return Config{}, err
	}
	for name, v := range map[string]int{
		"QUOTA_SCHEDULES_PER_DAY":             q.SchedulesPerDay,
		"QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY": q.NewAccountSchedulesPerDay,
	} {
		if v <= 0 {
			return Config{}, fmt.Errorf("config: %s must be > 0 (got %d)", name, v)
		}
	}
	// ADR-0023 D4: 200 AddBookmark writes/day, 50 for accounts younger than the new-account window, and a hard cap of
	// 1,000 bookmarks per user (the userLikes array length is the exact cap check).
	if q.BookmarksPerDay, err = getInt("QUOTA_BOOKMARKS_PER_DAY", 200); err != nil {
		return Config{}, err
	}
	if q.NewAccountBookmarksPerDay, err = getInt("QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY", 50); err != nil {
		return Config{}, err
	}
	if q.BookmarksMaxPerUser, err = getInt("BOOKMARKS_MAX_PER_USER", 1000); err != nil {
		return Config{}, err
	}
	for name, v := range map[string]int{
		"QUOTA_BOOKMARKS_PER_DAY":             q.BookmarksPerDay,
		"QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY": q.NewAccountBookmarksPerDay,
		"BOOKMARKS_MAX_PER_USER":              q.BookmarksMaxPerUser,
	} {
		if v <= 0 {
			return Config{}, fmt.Errorf("config: %s must be > 0 (got %d)", name, v)
		}
	}
	// ADR-0025 D8: 4 is_private changes per IST day, both directions (quota.PrivacyToggles). A request counts under follows.
	if q.PrivacyTogglesPerDay, err = getInt("QUOTA_PRIVACY_TOGGLES_PER_DAY", 4); err != nil {
		return Config{}, err
	}
	if q.PrivacyTogglesPerDay <= 0 {
		return Config{}, fmt.Errorf("config: QUOTA_PRIVACY_TOGGLES_PER_DAY must be > 0 (got %d)", q.PrivacyTogglesPerDay)
	}
	scheduled, err := loadScheduled()
	if err != nil {
		return Config{}, err
	}
	privacy, err := loadPrivacy()
	if err != nil {
		return Config{}, err
	}
	suggestions, err := loadSuggestions()
	if err != nil {
		return Config{}, err
	}

	// ADR-0010 D5 A10: with the Auth emulator variable set, the Admin SDK accepts unsigned tokens. That must
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

	// ADR-0008 D6/rollout plan: off in prod, on in dev and local by default (an operator can always
	// override via FEATURE_GRAPH). LoadSpec fails startup fast on an invalid mode/percent.
	graphDefaultMode := flags.On
	if env == "prod" {
		graphDefaultMode = flags.Off
	}
	featureGraph, err := flags.LoadSpec("GRAPH", "graph", graphDefaultMode)
	if err != nil {
		return Config{}, err
	}
	// ADR-0010 D1: same rollout shape as graph (dev on, prod off; Terraform sets it explicitly in T26).
	featurePosts, err := flags.LoadSpec("POSTS", "posts", graphDefaultMode)
	if err != nil {
		return Config{}, err
	}

	// P8 T4: off everywhere until the founder turns it on; the reauth window is bounded so a typo cannot
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
	// P4: media is off everywhere until the founder ramps it; the Vision cap is a runaway-bill guard (ADR-0005), so
	// a negative value or an unknown policy name fails startup instead of silently changing what is published.
	featureMedia, err := flags.LoadSpec("MEDIA", "media", flags.Off)
	if err != nil {
		return Config{}, err
	}
	visionCap, err := getInt("VISION_MONTHLY_CAP", 10000)
	if err != nil {
		return Config{}, err
	}
	if visionCap < 0 {
		return Config{}, fmt.Errorf("config: VISION_MONTHLY_CAP must be >= 0 (got %d)", visionCap)
	}
	visionPolicy := VisionExhaustedPolicy(getenv("VISION_EXHAUSTED_POLICY", string(VisionPolicyEstablished)))
	if !visionPolicy.valid() {
		return Config{}, fmt.Errorf("config: invalid VISION_EXHAUSTED_POLICY %q (want unscreened_established|reject)", visionPolicy)
	}
	profileMediaRetire, err := ParseProfileMediaRetire(os.Getenv("PROFILE_MEDIA_RETIRE"))
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
	mediaBucket := getenv("MEDIA_BUCKET", projectID+"-media")

	featureProfileSnapshot, err := flags.LoadSpec("PROFILE_SNAPSHOT", "profile_snapshot", flags.Off)
	if err != nil {
		return Config{}, err
	}
	// P3: replies are off everywhere until the founder ramps them (flag-rollout skill).
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
	featureUIShell, err := flags.LoadSpec("UI_SHELL", "ui_shell", flags.Off)
	if err != nil {
		return Config{}, err
	}
	featureShells, err := flags.LoadSpec("SHELLS", "shells", flags.Off)
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

	return Config{
		Port:                      getenv("PORT", portDefault),
		ProjectID:                 projectID,
		Env:                       env,
		Degraded:                  degraded,
		AppCheck:                  appCheck,
		CursorHMACKey:             []byte(cursorKey),
		RateLimit:                 rl,
		Quota:                     q,
		Scheduled:                 scheduled,
		Suggestions:               suggestions,
		Privacy:                   privacy,
		HandleChangeCooldown:      handleCooldown,
		ShutdownTimeout:           shutdownTimeout,
		CacheTTL:                  cacheTTL,
		CachePostsEntries:         cachePostsEntries,
		CacheAuthorRecentEntries:  cacheAuthorRecentEntries,
		TimelineTokenTTL:          timelineTokenTTL,
		TimelineSettleWindow:      timelineSettleWindow,
		InternalOIDCAudience:      internalOIDCAudience,
		InternalOIDCAllowedEmails: allowedEmails,
		CORSAllowedOrigins:        corsOrigins,
		TrustedProxyHops:          trustedProxyHops,
		FeatureGraph:              featureGraph,
		FeaturePosts:              featurePosts,
		AuthEmulator:              authEmulator,
		FeatureAccountLifecycle:   featureAccountLifecycle,
		FeatureReports:            featureReports,
		FeatureEngagement:         featureEngagement,
		FeatureQuotes:             featureQuotes,
		FeatureContentDisclosure:  featureContentDisclosure,
		FeatureReplyAudience:      featureReplyAudience,
		FeatureScheduledPosts:     featureScheduledPosts,
		FeatureBookmarks:          featureBookmarks,
		FeatureProfileExtras:      featureProfileExtras,
		FeatureProfileTabs:        featureProfileTabs,
		FeatureLikesList:          featureLikesList,
		FeatureFollowSuggestions:  featureFollowSuggestions,
		FeaturePrivateAccounts:    featurePrivateAccounts,
		FeatureUIShell:            featureUIShell,
		FeatureShells:             featureShells,
		FeatureRemovedIDs:         featureRemovedIDs,
		FeatureProfileSnapshot:    featureProfileSnapshot,
		FeatureReplies:            featureReplies,
		AccountDeleteReauthMaxAge: reauthMaxAge,
		ExportBucket:              getenv("EXPORT_BUCKET", projectID+"-exports"),
		ExportURLTTL:              exportURLTTL,
		ExportRetention:           exportRetention,
		JobsTopic:                 getenv("JOBS_TOPIC", "jobs"),
		FeatureNotifications:      featureNotifications,
		NotificationsTopic:        getenv("NOTIFICATIONS_TOPIC", "notifications-fanout"),
		NotificationsDelivery:     notifDelivery,
		FeatureMedia:              featureMedia,
		MediaUploadBucket:         getenv("MEDIA_UPLOAD_BUCKET", projectID+"-media-upload"),
		MediaBucket:               mediaBucket,
		MediaPublicBaseURL:        strings.TrimRight(getenv("MEDIA_PUBLIC_BASE_URL", "https://storage.googleapis.com/"+mediaBucket), "/"),
		VisionMonthlyCap:          visionCap,
		VisionExhaustedPolicy:     visionPolicy,
		VisionScreenThumb:         visionScreenThumb,
		ProfileMediaRetire:        profileMediaRetire,
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
