/// Name of the engagement flag as exposed through
/// `GetMeResponse.enabled_features` (`FEATURE_ENGAGEMENT`). A
/// missing name means off. It gates every EngagementService RPC, the like /
/// repost / quote actions and the quote composer (the server answers a quote
/// `CreatePost` with `FEATURE_DISABLED, feature: quotes` while it is off);
/// never hardcode `'engagement'` anywhere else.
const kFeatureEngagement = 'engagement';
