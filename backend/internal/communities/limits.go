package communities

// Names of the in-memory daily caps (RATE_LIMITED metadata["limit"], communities.proto; ADR-0031 D11). Limits are per instance, so
// the effective limit is x max-instances (3).
const (
	// LimitMutationDaily (COMMUNITY_MUTATIONS_PER_DAY, 200) is shared by CreateCommunity, UpdateCommunity, JoinCommunity and
	// LeaveCommunity, per uid; wired in apiserver.RateLimitConfig.
	LimitMutationDaily = "community_mutation_daily"
	// LimitModActionsDaily (COMMUNITY_MOD_ACTIONS_PER_DAY, 200) is shared by HideCommunityPost, RestoreCommunityPost and
	// SetMemberRole, per actor; wired in apiserver.RateLimitConfig.
	LimitModActionsDaily = "community_mod_actions_daily"
	// LimitPostsPerCommunityDaily (COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY, 20) caps CreatePost into one community per uid and community
	// (a ratelimit.DailyCap keyed "uid|cid"). It is not a procedure cap (the interceptor keys by uid) and posts never imports this
	// package, so the cap is built and drawn on by the communities-side implementation of posts.CommunityGate (W5-26); W5-22 ships the
	// config value (RateLimitConfig.CommunityPostsPerCommunityPerDay) and this name only.
	LimitPostsPerCommunityDaily = "community_posts_per_community_daily"
)
