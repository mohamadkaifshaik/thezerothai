/// Server feature flags of discovery (registers them), mirrored to the
/// client via `GetMe.enabled_features`. `search` gates SearchPeople and
/// SearchPosts; `trends` gates GetTrends. The server stays authoritative.
const kFeatureSearch = 'search';
const kFeatureTrends = 'trends';

/// `search_lists` (`FEATURE_SEARCH_LISTS`): SearchLists and SearchCommunities,
/// the Lists and Communities result tabs. The server also needs `lists`
/// (Lists tab) or `communities` (Communities tab) on for the caller.
const kFeatureSearchLists = 'search_lists';

/// `search_filters` (`FEATURE_SEARCH_FILTERS`): `SearchPostsRequest.from_following`,
/// the "People you follow" filter of the Latest and Media tabs.
const kFeatureSearchFilters = 'search_filters';

/// `trending_media` (`FEATURE_TRENDING_MEDIA`): the global media feed on the
/// Trending page (`ExploreMedia`). The server also needs `search` on for the
/// caller; the page mounts the section only when both are on.
const kFeatureTrendingMedia = 'trending_media';

/// `trending_posts` (`FEATURE_TRENDING_POSTS`): the newest public posts on the
/// Trending page (`ExplorePosts`). The server also needs `search` on for the
/// caller; the page mounts the Posts section only when both are on.
const kFeatureTrendingPosts = 'trending_posts';
