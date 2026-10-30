/// Server feature flags of discovery (W4-3 registers them), mirrored to the
/// client via `GetMe.enabled_features`. `search` gates SearchPeople and
/// SearchPosts; `trends` gates GetTrends. The server stays authoritative.
const kFeatureSearch = 'search';
const kFeatureTrends = 'trends';
