/// Name of the shells flag as exposed through
/// `GetMeResponse.enabled_features` (`FEATURE_SHELLS`, plan
/// W0 plan). Client-only: no RPC is gated by it. On
/// means the read-only Creator Studio, Premium, Advertise and Calls pages exist
/// (their routes work; the entry points also need `ui_shell`); a missing name
/// means off, and every shell path redirects Home. Never hardcode `'shells'`
/// anywhere else.
const kFeatureShells = 'shells';
