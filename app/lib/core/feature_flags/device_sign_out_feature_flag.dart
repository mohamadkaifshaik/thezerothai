/// `GetMe.enabled_features` entry of `FEATURE_DEVICE_SIGN_OUT` (removal
/// design §3.3): a REMOTE device removal also ends the account's other
/// sessions. Client side (lane D PR 4) it gates the re-sign-in before a
/// removal and the removal copy; the SESSION_ENDED handling is not gated
/// (the server sends it only when it enforces a cut).
const kFeatureDeviceSignOut = 'device_sign_out';
