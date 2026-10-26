/// Name of the bookmarks flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0023 D5, `FEATURE_BOOKMARKS`). A
/// missing name means off. With it off the bookmark icon is absent from the
/// post action row (which itself needs [kFeatureEngagement]); the server
/// answers FEATURE_DISABLED (`feature: bookmarks`) to AddBookmark. Never
/// hardcode `'bookmarks'` anywhere else.
const kFeatureBookmarks = 'bookmarks';

/// The server's `metadata["limit"]` of a LIMIT_REACHED answer to AddBookmark
/// (the 1,000-post cap) and `metadata["quota"]` of its QUOTA_EXCEEDED
/// (ADR-0023 D4). Both carry the same word.
const kBookmarksLimitName = 'bookmarks';
