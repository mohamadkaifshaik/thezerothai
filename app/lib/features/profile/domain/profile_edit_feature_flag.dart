/// Name of the profile-snapshot flag (`FEATURE_PROFILE_SNAPSHOT`) as exposed
/// through `GetMeResponse.enabled_features`; a missing name means off. It
/// gates the Edit profile and Change handle entry points and routes
/// so the whole edit surface ships dark, even though UpdateProfile and
/// ChangeHandle themselves are not flag-gated on the server. Never hardcode
/// `'profile_snapshot'` anywhere else.
const kFeatureProfileSnapshot = 'profile_snapshot';

/// Name of the profile-extras flag (`FEATURE_PROFILE_EXTRAS`) as
/// exposed through `GetMeResponse.enabled_features`; a missing name means off.
/// It gates the SETTING of the location, website and pinned-post
/// fields of `UpdateProfile`: with it off for the
/// caller the server answers FEATURE_DISABLED `feature=profile_extras` to a
/// non-empty value for any of those fields (and to a clear next to one), so a
/// client that is not in the cohort must never put one in the request (a name
/// or bio save would fail with it). An exact `""` only clears, and the server
/// accepts it whatever the flag: Edit profile offers
/// Remove for a saved location and website, and the pin menu offers
/// Unpin, without the flag. Rendering stays ungated. Never hardcode
/// `'profile_extras'` anywhere else.
const kFeatureProfileExtras = 'profile_extras';
