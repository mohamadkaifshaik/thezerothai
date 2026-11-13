/// Name of the Beacons ("Plans") flag (`FEATURE_BEACONS`) as exposed through
/// `GetMeResponse.enabled_features` (a missing name means off). It is also the
/// `metadata["feature"]` of the FEATURE_DISABLED answer of every BeaconService
/// RPC. The server stays authoritative. Never hardcode `'beacons'` anywhere
/// else.
const kFeatureBeacons = 'beacons';

/// Name of the plan-embeds-in-posts flag (`FEATURE_POST_BEACON_EMBED`, F5) in
/// `GetMeResponse.enabled_features`: a post's plan card (`Post.beacon`) is
/// drawn only while it is listed. Its Join needs [kFeatureBeacons] as well.
const kFeaturePostBeaconEmbed = 'post_beacon_embed';

/// Name of the one-tap join flag (`FEATURE_BEACON_QUICK_JOIN`) in
/// `GetMeResponse.enabled_features`. With it on (and `beacons`), a plan the
/// viewer may join in one tap (`ViewerState.quick_join_allowed`: the
/// organiser follows them) shows "I'm in", and every other join needs a note.
const kFeatureBeaconQuickJoin = 'beacon_quick_join';

/// `metadata["reason"]` of the FAILED_PRECONDITION a RequestToJoin with an
/// empty note gets when the organiser does not follow the caller.
const kBeaconNoteRequiredReason = 'note_required';

/// `metadata["limit"]` of LIMIT_REACHED (read as `LimitReachedException.quota`):
/// 5 OPEN/FULL plans per organiser.
const kBeaconsOpenLimit = 'beacons_open';

/// 10 REQUESTED rows per user.
const kBeaconRequestsPendingLimit = 'beacon_requests_pending';

/// open_spots above the server's cap (20).
const kBeaconParticipantsLimit = 'beacon_participants';

/// F28: a new start, duration or cost on a plan with more request and
/// participant rows than one transaction can move (200).
const kBeaconEditRowsLimit = 'beacon_edit_rows';

/// The server's caps, for copy and for disabling an action with the reason
/// before a wasted call. The server stays authoritative.
const kMaxOpenBeacons = 5;
const kMaxPendingBeaconRequests = 10;
const kBeaconMinSpots = 1;
const kBeaconMaxSpots = 20;

/// Field limits (code points, after NFC and trim).
const kBeaconTitleMaxLength = 60;
const kBeaconDetailsMaxLength = 300;
const kBeaconVenueMaxLength = 80;
const kBeaconNoteMaxLength = 140;

/// The durations offered (minutes); the server accepts 15-240.
const kBeaconDurations = [15, 30, 45, 60, 90, 120, 180, 240];

/// A plan starts at least 5 minutes and at most 30 days from now.
const kBeaconMinLead = Duration(minutes: 5);
const kBeaconMaxLead = Duration(days: 30);
