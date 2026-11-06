/// Name of the Beacons ("Plans") flag (`FEATURE_BEACONS`) as exposed through
/// `GetMeResponse.enabled_features` (a missing name means off). It is also the
/// `metadata["feature"]` of the FEATURE_DISABLED answer of every BeaconService
/// RPC. The server stays authoritative. Never hardcode `'beacons'` anywhere
/// else.
const kFeatureBeacons = 'beacons';

/// `metadata["limit"]` of LIMIT_REACHED (read as `LimitReachedException.quota`):
/// 5 OPEN/FULL plans per organiser.
const kBeaconsOpenLimit = 'beacons_open';

/// The server's caps, for copy and for disabling an action with the reason
/// before a wasted call. The server stays authoritative.
const kMaxOpenBeacons = 5;
const kBeaconMinSpots = 1;
const kBeaconMaxSpots = 20;

/// Field limits (code points, after NFC and trim).
const kBeaconTitleMaxLength = 60;
const kBeaconDetailsMaxLength = 300;
const kBeaconVenueMaxLength = 80;

/// The durations offered (minutes); the server accepts 15-240.
const kBeaconDurations = [15, 30, 45, 60, 90, 120, 180, 240];

/// A plan starts at least 5 minutes and at most 30 days from now.
const kBeaconMinLead = Duration(minutes: 5);
const kBeaconMaxLead = Duration(days: 30);
