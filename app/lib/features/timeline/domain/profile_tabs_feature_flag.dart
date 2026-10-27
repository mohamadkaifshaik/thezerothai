/// Name of the profile-tabs flag (`FEATURE_PROFILE_TABS`) as exposed through
/// `GetMeResponse.enabled_features` (ADR-0024 D5; a missing name means off),
/// and the `metadata["feature"]` of the FEATURE_DISABLED answer a
/// `GetUserTimeline` with tab REPOSTS or MEDIA gets while it is off for the
/// caller. The profile's Reposts and Media tabs exist only while it is
/// listed; the Posts and Replies tabs never need it. Never hardcode
/// `'profile_tabs'` anywhere else.
const kFeatureProfileTabs = 'profile_tabs';
