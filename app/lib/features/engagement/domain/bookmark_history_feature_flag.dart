/// Name of the bookmark-history flag as exposed through
/// `GetMeResponse.enabled_features` (`FEATURE_BOOKMARK_HISTORY`). A missing
/// name means off: no History tab, and nothing is recorded when a post opens.
/// Never hardcode `'bookmark_history'` anywhere else.
const kFeatureBookmarkHistory = 'bookmark_history';

/// How many opened posts the device keeps per account (newest first).
const kBookmarkHistoryCap = 100;

/// How many post reads run at once when the History tab loads its rows.
const kBookmarkHistoryReadConcurrency = 6;
