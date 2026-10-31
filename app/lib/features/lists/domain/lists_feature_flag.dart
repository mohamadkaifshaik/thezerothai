/// Name of the Lists flag (`FEATURE_LISTS`) as exposed through
/// `GetMeResponse.enabled_features` (ADR-0030 D1; a missing name means off).
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

/// `metadata["quota"]` of QUOTA_EXCEEDED on CreateList.
const kListCreatesQuota = 'list_creates';

/// `metadata["quota"]` of QUOTA_EXCEEDED on AddListMember.
const kListAddsQuota = 'list_adds';

/// HOME_TABS_MAX_PINNED: the most tabs a user can pin after Following.
const kMaxPinnedHomeTabs = 5;
