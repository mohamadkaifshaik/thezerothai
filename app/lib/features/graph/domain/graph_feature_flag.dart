/// Name of the graph feature flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0008 D6). A missing name means off.
/// This is the only string any client code should compare against — never
/// hardcode `'graph'` anywhere else.
const kFeatureGraph = 'graph';

/// Name of the "Who to follow" flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0024 D9). It gates
/// `GraphService.ListSuggestedUsers` after `graph` itself, so a client shows
/// the suggestions only when both names are present.
const kFeatureFollowSuggestions = 'follow_suggestions';
