/// Name of the likes-list flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0024 D9, `FEATURE_LIKES_LIST`). A
/// missing name means off. With it off the History screen has no Likes tab
/// and no `ListLikedPosts` call is sent; the server answers FEATURE_DISABLED
/// (`feature: likes_list`) to the RPC. It does not need `engagement` (rows
/// then come back with `liked_by_viewer` false and the cards show no action
/// row). Never hardcode `'likes_list'` anywhere else.
const kFeatureLikesList = 'likes_list';

/// How many likes the server keeps in `userLikes.recent` (ADR-0024 D6): the
/// Likes list can never show more, and the empty / end copy says so.
const kLikesListLimit = 1000;
