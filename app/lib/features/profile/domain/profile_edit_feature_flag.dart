/// Name of the profile-snapshot flag (`FEATURE_PROFILE_SNAPSHOT`) as exposed
/// through `GetMeResponse.enabled_features`; a missing name means off. It
/// gates the Edit profile and Change handle entry points and routes (P2-T5)
/// so the whole edit surface ships dark, even though UpdateProfile and
/// ChangeHandle themselves are not flag-gated on the server. Never hardcode
/// `'profile_snapshot'` anywhere else.
const kFeatureProfileSnapshot = 'profile_snapshot';
