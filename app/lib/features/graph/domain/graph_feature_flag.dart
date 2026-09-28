/// Name of the graph feature flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0008 D6). A missing name means off.
/// This is the only string any client code should compare against — never
/// hardcode `'graph'` anywhere else.
const kFeatureGraph = 'graph';
