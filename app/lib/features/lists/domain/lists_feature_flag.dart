/// Name of the Lists flag (`FEATURE_LISTS`) as exposed through
/// `GetMeResponse.enabled_features` (a missing name means off).
/// It is also the `metadata["feature"]` of the FEATURE_DISABLED answer of
/// every lists RPC and of SetHomeTabs for a LIST tab. With it off there is no
/// Lists row, no list route and no list tab on Home; the server stays
/// authoritative. Never hardcode `'lists'` anywhere else.
const kFeatureLists = 'lists';

/// `metadata["limit"]` of the LIMIT_REACHED answers (read as
/// `LimitReachedException.quota`): the 20-lists-per-owner cap on CreateList.
const kListsPerUserLimit = 'lists_per_user';

/// The member cap of one list (150 by default, server config), on AddListMember (`metadata["limit"]`).
const kListMembersLimit = 'list_members';

/// `metadata["limit"]` of SetHomeTabs' LIMIT_REACHED (more than
/// [kMaxPinnedHomeTabs] pinned tabs).
const kHomeTabsLimit = 'home_tabs';

/// HOME_TABS_MAX_PINNED: the most tabs a user can pin after Following.
const kMaxPinnedHomeTabs = 5;

/// The most Lists one owner can have (`LISTS_PER_USER`, server config). The
/// server stays authoritative (LIMIT_REACHED `lists_per_user`); the client
/// only uses it to disable Create with the reason before a wasted call.
const kMaxListsPerUser = 20;

/// Field limits of a List (the proto `max_len` rules).
const kListNameMaxLength = 25;
const kListDescriptionMaxLength = 100;

/// Name of the list-follows flag (`FEATURE_LIST_FOLLOWS`) in
/// `GetMe.enabled_features`: Follow / Following on a public List, the
/// follower count, "Lists you follow" and Discover. Off: none of it shows and
/// none of FollowList, UnfollowList, ListFollowedLists, DiscoverLists is sent.
const kFeatureListFollows = 'list_follows';

/// Name of the list-suggestions flag (`FEATURE_LIST_SUGGESTIONS`): the
/// "Suggested members" card on the members page of a List the caller owns.
const kFeatureListSuggestions = 'list_suggestions';

/// `metadata["limit"]` of FollowList's LIMIT_REACHED (100 followed Lists).
const kListFollowsLimit = 'list_follows';

/// The most Lists one person can follow (server config); the server stays
/// authoritative.
const kMaxListFollows = 100;

/// Page size of ListFollowedLists and DiscoverLists.
const kListFollowsPageSize = 20;

/// `max_results` of ListSuggestedMembers (the card shows up to ten people).
const kListSuggestionsMax = 10;

/// "1 follower" / "N followers".
String listFollowerCountLabel(int count) =>
    count == 1 ? '1 follower' : '$count followers';
