package apiserver

import (
	"time"

	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// idleBucketTTL is how long an idle per-key token bucket is kept before eviction.
const idleBucketTTL = 10 * time.Minute

// rateLimitConfig builds the post-auth rate-limit interceptor's config: per-minute buckets, the per-uid daily
// call caps and the ADR-0010 D5 read budget (uid, plus IP on profileExempt procedures). It is a function of
// cfg alone so the guard test (guard_test.go) can inspect exactly what Build wires.
func rateLimitConfig(cfg config.Config, profileExempt map[string]struct{}) ratelimit.Config {
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

	return ratelimit.Config{
		Default: rlDefault,
		PerProcedure: map[string]*ratelimit.Limiter{
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
		},
		// ADR-0010 D5: covers every procedure; ReadBudgetExempt stays empty (guard_test.go). WithMaxCallReads
		// arms the single-flight guard near the cap (review M1).
		ReadBudget:   ratelimit.NewDailyCap(cfg.RateLimit.ReadBudgetPerUIDPerDay).WithMaxCallReads(config.ReadBudgetMaxCallReads),
		ReadBudgetIP: ratelimit.NewDailyCap(cfg.RateLimit.ReadBudgetPerIPNoProfilePerDay).WithMaxCallReads(config.ReadBudgetMaxCallReads),
		// ADR-0010 D5 amendment (review M2, CLAUDE.md rule 10): charged, never rejected. Each entry needs a
		// reason in guard_test.go allowedReadBudgetChargeOnly.
		ReadBudgetChargeOnly: map[string]struct{}{
			// Right to delete: must work for a user who has spent today's budget (App Store / Play / DPDP).
			identityv1connect.IdentityServiceDeleteAccountProcedure: {},
			// Right to export: same reason; a small read count, and the per-minute bucket still applies.
			identityv1connect.IdentityServiceRequestAccountExportProcedure: {},
			// Polls the export produced by RequestAccountExport; must not be blocked while that job is pending.
			identityv1connect.IdentityServiceGetAccountExportProcedure: {},
		},
		ProfileExempt:    profileExempt,
		IP:               rlIP,
		TrustedProxyHops: cfg.TrustedProxyHops,
	}
}
