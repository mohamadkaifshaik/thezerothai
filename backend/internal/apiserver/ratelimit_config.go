package apiserver

import (
	"time"

	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	postsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// idleBucketTTL is how long an idle per-key token bucket is kept before eviction.
const idleBucketTTL = 10 * time.Minute

// RateLimitConfig builds the post-auth rate-limit interceptor's config: per-minute buckets, the per-uid daily
// call caps and the ADR-0010 D5 read budget (uid, plus IP on profileExempt procedures). It is a function of
// cfg alone so the guard test (guard_test.go) can inspect exactly what Build wires.
func RateLimitConfig(cfg config.Config) ratelimit.Config {
	rlDefault := ratelimit.NewLimiter(cfg.RateLimit.PerUserPerMinute, idleBucketTTL)
	rlCheckHandle := ratelimit.NewLimiter(cfg.RateLimit.CheckHandlePerUserPerMinute, idleBucketTTL)
	rlIP := ratelimit.NewLimiter(cfg.RateLimit.PerIPPerMinute, idleBucketTTL)

	// ADR-0008 D7: Follow/Unfollow 30/min, Block/Unblock/Mute/Unmute 20/min, lists 20/min; GetRelationships
	// uses rlDefault (the 60/min default). A shared DailyCap (not a second limiter) backs the per-uid daily
	// list cap (T4), logged as limit_name "graph_list_daily".
	rlGraphFollow := ratelimit.NewLimiter(cfg.RateLimit.GraphFollowPerMinute, idleBucketTTL)
	rlGraphBlock := ratelimit.NewLimiter(cfg.RateLimit.GraphBlockPerMinute, idleBucketTTL)
	rlGraphList := ratelimit.NewLimiter(cfg.RateLimit.GraphListPerMinute, idleBucketTTL)
	graphListDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.GraphListCallsPerDay)
	// M2: ONE shared cap across every graph mutation (same DailyCap type, one counter per uid): replays and
	// no-ops reserve no Firestore quota but still read 1-3 docs. See config.RateLimitConfig.GraphMutationsPerDay
	// for the default's math. Logged as limit_name "graph_mutation_daily".
	graphMutationDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.GraphMutationsPerDay)
	// ADR-0010 D5 / T3: CheckHandleAvailability call cap, limit_name "check_handle_daily".
	checkHandleDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.CheckHandleCallsPerDay)
	// ADR-0010 D5 A6: limit_name "account_ops_daily", shared by DeleteAccount, RequestAccountExport, GetAccountExport.
	accountOpsDailyCap := ratelimit.NewDailyCap(cfg.RateLimit.AccountOpsCallsPerDay)

	// ADR-0010 T4: home 6/min (the existing RATE_LIMIT_TIMELINE_PER_MIN), user timeline 30/min, CreatePost 10/min,
	// DeletePost 20/min; GetPost uses rlDefault (60/min). Posts are bounded per day by quota.Posts (100, 20 for
	// new accounts) and every read by the ADR-0010 D5 read budget, so there is no extra daily call cap.
	rlHomeTimeline := ratelimit.NewLimiter(cfg.RateLimit.TimelinePerUserPerMinute, idleBucketTTL)
	rlUserTimeline := ratelimit.NewLimiter(cfg.RateLimit.UserTimelinePerMinute, idleBucketTTL)
	rlPostCreate := ratelimit.NewLimiter(cfg.RateLimit.PostCreatePerMinute, idleBucketTTL)
	rlPostDelete := ratelimit.NewLimiter(cfg.RateLimit.PostDeletePerMinute, idleBucketTTL)

	return ratelimit.Config{
		Default: rlDefault,
		PerProcedure: map[string]*ratelimit.Limiter{
			timelinev1connect.TimelineServiceGetHomeTimelineProcedure:         rlHomeTimeline,
			timelinev1connect.TimelineServiceGetUserTimelineProcedure:         rlUserTimeline,
			postsv1connect.PostServiceCreatePostProcedure:                     rlPostCreate,
			postsv1connect.PostServiceDeletePostProcedure:                     rlPostDelete,
			identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: rlCheckHandle,
			graphv1connect.GraphServiceFollowProcedure:                        rlGraphFollow,
			graphv1connect.GraphServiceUnfollowProcedure:                      rlGraphFollow,
			graphv1connect.GraphServiceBlockProcedure:                         rlGraphBlock,
			graphv1connect.GraphServiceUnblockProcedure:                       rlGraphBlock,
			graphv1connect.GraphServiceMuteProcedure:                          rlGraphBlock,
			graphv1connect.GraphServiceUnmuteProcedure:                        rlGraphBlock,
			graphv1connect.GraphServiceListFollowersProcedure:                 rlGraphList,
			graphv1connect.GraphServiceListFollowingProcedure:                 rlGraphList,
			graphv1connect.GraphServiceListBlockedUsersProcedure:              rlGraphList,
			graphv1connect.GraphServiceListMutedUsersProcedure:                rlGraphList,
		},
		DailyCaps: map[string]ratelimit.NamedDailyCap{
			graphv1connect.GraphServiceListFollowersProcedure:    {Name: "graph_list_daily", Cap: graphListDailyCap},
			graphv1connect.GraphServiceListFollowingProcedure:    {Name: "graph_list_daily", Cap: graphListDailyCap},
			graphv1connect.GraphServiceListBlockedUsersProcedure: {Name: "graph_list_daily", Cap: graphListDailyCap},
			graphv1connect.GraphServiceListMutedUsersProcedure:   {Name: "graph_list_daily", Cap: graphListDailyCap},

			graphv1connect.GraphServiceFollowProcedure:   {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnfollowProcedure: {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceBlockProcedure:    {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnblockProcedure:  {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceMuteProcedure:     {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},
			graphv1connect.GraphServiceUnmuteProcedure:   {Name: "graph_mutation_daily", Cap: graphMutationDailyCap},

			identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: {Name: "check_handle_daily", Cap: checkHandleDailyCap},

			// A6: ONE shared call cap for the three charge-only account operations (their only bound).
			identityv1connect.IdentityServiceDeleteAccountProcedure:        {Name: "account_ops_daily", Cap: accountOpsDailyCap},
			identityv1connect.IdentityServiceRequestAccountExportProcedure: {Name: "account_ops_daily", Cap: accountOpsDailyCap},
			identityv1connect.IdentityServiceGetAccountExportProcedure:     {Name: "account_ops_daily", Cap: accountOpsDailyCap},
		},
		// ADR-0010 D5: covers every procedure; ReadBudgetExempt stays empty (guard_test.go). WithMaxCallReads
		// arms the single-flight guard near the cap (review M1).
		ReadBudget:   ratelimit.NewDailyCap(cfg.RateLimit.ReadBudgetPerUIDPerDay).WithMaxCallReads(config.ReadBudgetMaxCallReads),
		ReadBudgetIP: ratelimit.NewDailyCap(cfg.RateLimit.ReadBudgetPerIPNoProfilePerDay).WithMaxCallReads(config.IPReadBudgetMaxCallReads),
		// ADR-0010 D5 A8: the IP key never rejects. ReadBudgetIPEnforce is empty (the guard test keeps it so; a
		// procedure added needs an ADR amendment); both exempt procedures are charge-only, so one account behind a
		// shared IPv4 address cannot block sign-ups for everyone behind it. Together they must equal
		// profileExemptProcedures (guard test, security L6).
		ReadBudgetIPEnforce: map[string]struct{}{},
		ReadBudgetIPChargeOnly: map[string]struct{}{
			identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure: {},
			identityv1connect.IdentityServiceCreateProfileProcedure:           {},
		},
		// ADR-0010 D5 A6 (review M2, CLAUDE.md rule 10): charged, never rejected. Each entry needs a reason in
		// guard_test.go allowedReadBudgetChargeOnly and a DailyCaps entry below (account_ops_daily).
		ReadBudgetChargeOnly: map[string]struct{}{
			// Right to delete: must work for a user who has spent today's budget (App Store / Play / DPDP).
			identityv1connect.IdentityServiceDeleteAccountProcedure: {},
			// Right to export: same reason; a small read count, and the per-minute bucket still applies.
			identityv1connect.IdentityServiceRequestAccountExportProcedure: {},
			// Polls the export produced by RequestAccountExport; must not be blocked while that job is pending.
			identityv1connect.IdentityServiceGetAccountExportProcedure: {},
		},
		IP:               rlIP,
		TrustedProxyHops: cfg.TrustedProxyHops,
	}
}

// RestrictedAllowedProcedures is the exact set of procedures a SUSPENDED or DELETING caller may still reach
// (ADR-0011 Q2/Q3): DeleteAccount only. A suspended user keeps the right to erase their own account, and a client
// that retries DeleteAccount after a lost response must get a replay, not ACCOUNT_RESTRICTED. Build wires it into
// authn.AccountStatusInterceptor and guard_test.go asserts it is exactly one procedure.
func RestrictedAllowedProcedures() []string {
	return []string{identityv1connect.IdentityServiceDeleteAccountProcedure}
}

// profileExemptProcedures is the set of procedures allowed before a profile exists (ADR-0006 §2). Build and the
// guard test share it, so the ratelimit IP sets cannot drift from it.
func profileExemptProcedures() map[string]struct{} {
	return authn.ProfileExemptProcedures(
		identityv1connect.IdentityServiceCreateProfileProcedure,
		// CheckHandleAvailability is read-only and must work before a profile exists (sign-up form);
		// see the ADR-0006 deviation note in pkg/platform/authn.ProfileExemptProcedures.
		identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure,
	)
}
