package communities

import (
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// Names of the in-memory daily caps (RATE_LIMITED metadata["limit"], communities.proto; ADR-0031 D11). Limits are per instance, so
// the effective limit is x max-instances (3).
const (
	// LimitMutationDaily (COMMUNITY_MUTATIONS_PER_DAY, 200) is shared by CreateCommunity, UpdateCommunity, JoinCommunity and
	// LeaveCommunity, per uid; wired in apiserver.RateLimitConfig.
	LimitMutationDaily = "community_mutation_daily"
	// LimitModActionsDaily (COMMUNITY_MOD_ACTIONS_PER_DAY, 200) is shared by HideCommunityPost, RestoreCommunityPost and
	// SetMemberRole, per actor; wired in apiserver.RateLimitConfig.
	LimitModActionsDaily = "community_mod_actions_daily"
	// LimitPostsPerCommunityDaily (COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY, 20) caps CreatePost into one community per uid and
	// community. It is not a procedure cap (the interceptor keys by uid): the posts gate draws on NewPostsPerCommunityCap with
	// PostsCapKey (W5-26).
	LimitPostsPerCommunityDaily = "community_posts_per_community_daily"
)

// NewPostsPerCommunityCap builds the uid|cid DailyCap of CreatePost into a community (ADR-0031 D11, limit_name
// LimitPostsPerCommunityDaily). One instance per process; memory is bounded by the DailyCap's LRU.
func NewPostsPerCommunityCap(limit int64) *ratelimit.DailyCap { return ratelimit.NewDailyCap(limit) }

// PostsCapKey is the key of NewPostsPerCommunityCap: the author uid and the community id. A uid never contains "|" (ids.ValidUID:
// [A-Za-z0-9-]) and a community id is 19 digits, so the key is unambiguous.
func PostsCapKey(uid, communityID string) string { return uid + "|" + communityID }
