/// Name of the Creator Studio insights flag (`FEATURE_CREATOR_INSIGHTS`) as
/// exposed through `GetMeResponse.enabled_features` (a missing name means
/// off). It is also the `metadata["feature"]` of the FEATURE_DISABLED answer of
/// `IdentityService.GetCreatorInsights`. Never hardcode `'creator_insights'`
/// anywhere else.
const kFeatureCreatorInsights = 'creator_insights';

/// The windows the selector offers (IST days, today included).
const kInsightsWindows = [7, 28];

/// The default window.
const kInsightsDefaultWindow = 28;
