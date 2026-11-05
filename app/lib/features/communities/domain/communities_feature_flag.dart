/// Name of the Communities flag (`FEATURE_COMMUNITIES`) as exposed through
/// `GetMeResponse.enabled_features` (a missing name means off).
/// It is also the `metadata["feature"]` of the FEATURE_DISABLED answer of every
/// communities RPC, of `GetCommunityTimeline`, of CreatePost with a
/// `community_id` and of SetHomeTabs for a COMMUNITY tab. The server stays
/// authoritative. Never hardcode `'communities'` anywhere else.
const kFeatureCommunities = 'communities';

/// `metadata["limit"]` of LIMIT_REACHED (read as `LimitReachedException.quota`):
/// 2 owned communities per creator, lifetime.
const kCommunitiesOwnedLimit = 'communities_owned';

/// 50 joined communities per user.
const kCommunitiesJoinedLimit = 'communities_joined';

/// 10 moderators per community.
const kCommunityModeratorsLimit = 'community_moderators';

/// `metadata["limit"]` of the daily RATE_LIMITED caps (read as
/// `RateLimitedException.limitName`).
const kCommunityModActionsDailyLimit = 'community_mod_actions_daily';
const kCommunityPostsPerCommunityDailyLimit =
    'community_posts_per_community_daily';

/// The server's caps, for disabling an action with the reason before a wasted
/// call. The server stays authoritative (LIMIT_REACHED).
const kMaxCommunitiesOwned = 2;
const kMaxCommunitiesJoined = 50;
const kMaxCommunityModerators = 10;
const kMaxCommunityRules = 10;

/// Field limits (code points, after NFC and trim).
const kCommunityNameMaxLength = 30;
const kCommunityDescriptionMaxLength = 160;
const kCommunityRuleTitleMaxLength = 60;
const kCommunityRuleTextMaxLength = 300;
