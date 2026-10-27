/// Name of the profile-snapshot flag (`FEATURE_PROFILE_SNAPSHOT`) as exposed
/// through `GetMeResponse.enabled_features`; a missing name means off. It
/// gates the Edit profile and Change handle entry points and routes (P2-T5)
/// so the whole edit surface ships dark, even though UpdateProfile and
/// ChangeHandle themselves are not flag-gated on the server. Never hardcode
/// `'profile_snapshot'` anywhere else.
const kFeatureProfileSnapshot = 'profile_snapshot';

/// Name of the profile-extras flag (`FEATURE_PROFILE_EXTRAS`, ADR-0024 D9) as
/// exposed through `GetMeResponse.enabled_features`; a missing name means off.
/// It gates the SETTING of the banner, location, website and pinned-post
/// fields of `UpdateProfile` and `CreateUpload(BANNER)`: with it off for the
/// caller the server answers FEATURE_DISABLED `feature=profile_extras` to a
/// non-empty value for any of those fields (and to a clear next to one), so a
/// client that is not in the cohort must never put one in the request (a name
/// or bio save would fail with it). An exact `""` only clears, and the server
/// accepts it whatever the flag (ADR-0024 Amendment 1 A2): Edit profile offers
/// Remove for a saved banner, location and website, and the pin menu offers
/// Unpin, without the flag. Rendering stays ungated. Never hardcode
/// `'profile_extras'` anywhere else.
const kFeatureProfileExtras = 'profile_extras';
