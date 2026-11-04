package communities

// Names of the in-memory daily caps (RATE_LIMITED metadata["limit"], communities.proto). Limits are per instance, so
// the effective limit is x max-instances (3).
const (
	// LimitModActionsDaily (COMMUNITY_MOD_ACTIONS_PER_DAY, 200) is shared by HideCommunityPost and
	// SetMemberRole (bans go through it), per actor; RestoreCommunityPost is not capped; wired in apiserver.RateLimitConfig.
	LimitModActionsDaily = "community_mod_actions_daily"
	// LimitPostsPerCommunityDaily (COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY, 20) caps CreatePost into one community per uid and community
	// (a ratelimit.DailyCap keyed "uid|cid"). It is not a procedure cap (the interceptor keys by uid) and posts never imports this
	// package, so the cap is built and drawn on by the communities-side implementation of posts.CommunityGate (PostGate.AllowPost); the
	// config value is RateLimitConfig.CommunityPostsPerCommunityPerDay.
	LimitPostsPerCommunityDaily = "community_posts_per_community_daily"
)
