/// Server feature flag for the share count (`Post.share_count` shown on the
/// post, and `RecordPostShare` for a copied link or a completed share sheet),
/// mirrored to the client via `GetMe.enabled_features`. Per caller: the count
/// is shown and shares are reported only while it is on.
const kFeatureShareCount = 'share_count';
