/// Server feature flag for post view counts (`Post.view_count` drawn on a post
/// and `RecordImpressions` for the posts the viewer saw), mirrored to the
/// client via `GetMe.enabled_features`. Per caller: with it off nothing is
/// tracked, no call is sent and no count is drawn.
const kFeaturePostViews = 'post_views';
