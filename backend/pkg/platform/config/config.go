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
	"strconv"
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

// ReadBudgetMaxCallReads is the worst-case Firestore reads of ONE call, the figure ADR-0010 D5's
// cost bound and the read budget's single-flight guard use: home timeline 2 + C + 2 * page_size = 269 at
// 5,000 following (C = 30-uid chunks = 167) and page 50 (timeline.proto). Keep it in sync with that RPC's
// doc comment; tests use this constant, not a literal.
const ReadBudgetMaxCallReads = 269

// IPReadBudgetMaxCallReads is the per-call hold M of the IP read budget (ADR-0010 D5 A1). Since A8 nothing
// reserves the IP key (it is charge-only everywhere), so this hold has no admission role; it is the constant any
// future enforced IP procedure must respect. It is true because a profile-less call charged to the IP key stops
// at account status after at most 1 read, and a call that finds a profile is charged 0 there (A9). CreateProfile
// reads several docs but is charge-only, never held.
const IPReadBudgetMaxCallReads = 2

// DegradedMode gates writes/media at the platform level (CLAUDE.md "degraded-mode switch").
type DegradedMode string

const (
	DegradedOff      DegradedMode = "off"
	DegradedReadonly DegradedMode = "readonly"
	DegradedNoMedia  DegradedMode = "nomedia"
)

func (m DegradedMode) valid() bool {
	switch m {
	case DegradedOff, DegradedReadonly, DegradedNoMedia:
		return true
	default:
		return false
	}
}

// AppCheckMode controls whether a missing/invalid App Check token rejects the request (ADR-0006 §2).
type AppCheckMode string

const (
	AppCheckEnforce AppCheckMode = "enforce"
	AppCheckMonitor AppCheckMode = "monitor"
)

func (m AppCheckMode) valid() bool {
	switch m {
	case AppCheckEnforce, AppCheckMonitor:
		return true
	default:
		return false
	}
}

// RateLimitConfig holds the in-memory token-bucket limits from ADR-0006 §3. Approximate per instance
// (effective ceiling is ~limit x max-instances).
type RateLimitConfig struct {
	PerUserPerMinute            int
	TimelinePerUserPerMinute    int
	CheckHandlePerUserPerMinute int
	LikesPerUserPerMinute       int
	PerIPPerMinute              int

	// Posts/timeline per-procedure buckets (ADR-0010 T4). GetHomeTimeline uses TimelinePerUserPerMinute (6) and
	// GetPost uses PerUserPerMinute (the 60/min default).
	UserTimelinePerMinute int // GetUserTimeline, env RATE_LIMIT_USER_TIMELINE_PER_MIN, default 30
	PostCreatePerMinute   int // CreatePost, env RATE_LIMIT_POST_CREATE_PER_MIN, default 10
	PostDeletePerMinute   int // DeletePost, env RATE_LIMIT_POST_DELETE_PER_MIN, default 20

	// PreAuthIPPerMinute is the coarse, pre-auth per-IP token bucket (M1, docs/reviews/security-audit-v0.1.0.md):
	// plain net/http middleware in front of the whole Connect handler chain, so an unauthenticated flood
	// is rejected before it costs any App Check / ID token JWT-verify CPU. Deliberately generous — this is
	// a flood backstop, not the fine-grained per-uid/IP limiting PerIPPerMinute already does once a request
	// is inside the Connect chain (a separate bucket; see ratelimit.PreAuthIPMiddleware).
	PreAuthIPPerMinute int

	// Graph per-procedure buckets (ADR-0008 D7). GetRelationships uses PerUserPerMinute (the 60/min default).
	GraphFollowPerMinute int // Follow, Unfollow
	GraphBlockPerMinute  int // Block, Unblock, Mute, Unmute
	GraphListPerMinute   int // ListFollowers, ListFollowing, ListBlockedUsers, ListMutedUsers

	// GraphListCallsPerDay is the in-memory daily cap on list RPCs per uid per instance (ADR-0008 D7/T4:
	// "an extension of the existing limiter", ratelimit.DailyCap), logged as limit_name "graph_list_daily".
	GraphListCallsPerDay int64

	// GraphMutationsPerDay is the in-memory daily cap on ALL graph mutations (Follow, Unfollow, Block,
	// Unblock, Mute, Unmute share one counter) per uid per instance, ratelimit.DailyCap, logged as
	// limit_name "graph_mutation_daily" (security review M2). It bounds the read cost of replays and no-ops,
	// which reserve no Firestore quota (ADR-0008 D7) but still read 1-4 docs each.
	//
	// Default 500. Worst case per account per day: 500 calls x 4 reads (Follow replay is the most expensive
	// mutation, 4 cold: caller + target profiles, caller graph, quotas; ADR-0008 A2) x 3 instances (the cap is per
	// instance, max-instances 3) = 6,000 reads (500x4x3, ADR-0008 Amendment cost impact), versus 172.8k/day (Follow + Block replay loops at the per-minute buckets) before the cap,
	// and ADR-0008's accepted 30.6k/day list-scraping bound. Legitimate use fits with room: 200 follows +
	// 200 blocks/mutes (the Firestore quotas) plus their undos is under 500.
	GraphMutationsPerDay int64

	// ReadBudgetPerUIDPerDay is the per-uid daily Firestore read budget every RPC is charged against
	// (ADR-0010 D5, ratelimit.Config.ReadBudget), env READ_BUDGET_PER_UID_PER_DAY, default 2,000 (~9-11x a
	// typical day of ~183 reads). The counter is per instance LIFETIME (in memory, reset only at the IST day
	// boundary, lost when the instance dies): a uid spends at most 2,000 - 1 + ReadBudgetMaxCallReads = 2,268 reads
	// on the budget plus 40 on account_ops_daily = 2,308 per instance lifetime (ADR-0010 D5 A1, A6). The daily
	// total is that times the lifetimes the uid touches: 3 on a steady day, up to 6 on a rollout day, and up to
	// ~270 when an attacker idle-cycles instances (residual R2, accepted; abuse-spike.md has the churn check).
	ReadBudgetPerUIDPerDay int64
	// ReadBudgetPerIPNoProfilePerDay is the per-IP (IPv4 or IPv6 /64) daily read METER (ADR-0010 D5 A3, A8, A9),
	// env READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY, default 500. Since A8 it never rejects: it is charged on
	// CheckHandleAvailability, CreateProfile and the calls of a verified caller without a profile. The cap is the
	// level at which a farm behind one address shows up (alert: jsonPayload.read_budget_ip_spent >= 500).
	ReadBudgetPerIPNoProfilePerDay int64
	// CheckHandleCallsPerDay is the per-uid daily call cap on CheckHandleAvailability (a ratelimit.DailyCap,
	// limit_name "check_handle_daily"), env CHECK_HANDLE_CALLS_PER_DAY, default 100.
	CheckHandleCallsPerDay int64
	// AccountOpsCallsPerDay is the per-uid daily call cap shared by DeleteAccount, RequestAccountExport and
	// GetAccountExport (ADR-0010 D5 A6; a ratelimit.DailyCap, limit_name "account_ops_daily"), env
	// ACCOUNT_OPS_CALLS_PER_DAY, default 20. Those calls are charge-only on the read budget, so this is their bound.
	AccountOpsCallsPerDay int64
}

// QuotaConfig holds the daily per-user quotas from ADR-0006 §4, persisted in quotas/{uid}.
type QuotaConfig struct {
	PostsPerDay   int
	FollowsPerDay int
	MediaPerDay   int
	ExportsPerDay int

	// Lower quotas for accounts younger than NewAccountWindow.
	NewAccountPostsPerDay   int
	NewAccountFollowsPerDay int
	NewAccountMediaPerDay   int
	NewAccountWindow        time.Duration

	// BlocksPerDay/NewAccountBlocksPerDay cover Block + Mute together (ADR-0008 D7, quota.Blocks).
	// Unblock/Unmute are never quota-gated.
	BlocksPerDay           int
	NewAccountBlocksPerDay int
}

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

	// AuthEmulator is true iff FIREBASE_AUTH_EMULATOR_HOST is non-empty (ADR-0010 D5 A10). Only then does the
	// verified-identity gate admit anonymous sign-ins (the e2e helpers mint them). Load refuses the variable
	// when ENV is dev or prod: the Admin SDK would then accept unsigned emulator tokens.
	AuthEmulator bool
}

// Load reads Config from the environment, applying Stage 0 defaults (ADR-0002/0003/0006) for anything unset.
func Load() (Config, error) {
	env := getenv("ENV", "local")

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
	// m3: a zero/negative cap would lock every uid out after one call (NewDailyCap clamps it to 1), so it is
	// a startup error, not a way to "disable" the budget (rule 11: caps are reviewed like logic).
	for name, v := range map[string]int{
		"READ_BUDGET_PER_UID_PER_DAY":           readBudgetUID,
		"READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY": readBudgetIP,
		"CHECK_HANDLE_CALLS_PER_DAY":            checkHandleCalls,
		"ACCOUNT_OPS_CALLS_PER_DAY":             accountOpsCalls,
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

	// ADR-0010 D5 A10: with the Auth emulator variable set, the Admin SDK accepts unsigned tokens. That must
	// never be true in a deployed environment, so refuse to start.
	authEmulator := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") != ""
	if authEmulator && (env == "dev" || env == "prod") {
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

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// splitCSV parses a comma-separated env var, trimming whitespace and dropping empty entries. Returns nil
// (not an empty non-nil slice) for an empty input, so callers can treat nil/empty interchangeably as "off".
func splitCSV(v string) []string {
	if v == "" {
		return nil
	}
	var out []string
	for _, s := range strings.Split(v, ",") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func getInt(key string, def int) (int, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("config: invalid int for %s: %w", key, err)
	}
	return n, nil
}

func getDuration(key string, def time.Duration) (time.Duration, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("config: invalid duration for %s: %w", key, err)
	}
	return d, nil
}
