/// `GetMe.enabled_features` entry of `FEATURE_DEVICE_SIGN_OUT` (removal
/// design §3.3): a REMOTE device removal also ends the account's other
/// sessions. Client side (lane D PR 4) it gates only the removal copy (the
/// named title, "signed out on all your other devices", the footer and,
/// once Task 13-ii passes `other_sessions_ended`, the result text). The
/// re-sign-in before a removal is NOT gated (the server wants it for every
/// REMOTE removal), nor is the SESSION_ENDED handling (the server sends it
/// only when it enforces a cut).
const kFeatureDeviceSignOut = 'device_sign_out';
