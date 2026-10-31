//
//  Generated code. Do not modify.
//  source: dzeroth/search/v1/search.proto
//

import "package:connectrpc/connect.dart" as connect;
import "search.pb.dart" as dzerothsearchv1search;

abstract final class SearchService {
  /// Fully-qualified name of the SearchService service.
  static const name = 'dzeroth.search.v1.SearchService';

  /// People whose handle starts with the query (ADR-0028 D2), in handle order. At most limit rows (0 => 10, max 20)
  /// and NO PAGINATION: there is no page token, by design (handle enumeration costs one call per 20 handles).
  /// Rows: accounts that are not ACTIVE and accounts that block the caller are left out (the answer is then the same
  /// as for a handle nobody has); accounts the caller blocks or mutes stay, with relationship.blocking / muting set.
  /// Protected accounts are listed, with user.is_private set. Each row carries the caller's relationship (follow
  /// state incl. REQUESTED, from the caller's graph, 0 extra reads); since is unset. The caller appears when matched.
  /// A caller whose blocked-by list overflowed (ADR-0008 D2) sees only accounts they follow and themselves.
  /// Staleness: matches are cached per instance for 60 s and shared across callers, so a new handle or a rename shows
  /// within 60 s; block and relationship filtering is per caller, from the 60 s graph snapshot.
  /// Flag: "search". Rate limits: RATE_LIMIT_SEARCH_PEOPLE_PER_MIN 30/min/uid per instance (90/min at 3 instances);
  /// SEARCH_CALLS_PER_DAY 300 calls/uid/IST day per instance shared with SearchPosts (<= 900 at 3) => RATE_LIMITED,
  /// metadata["limit"] = "search_daily".
  /// Firestore: reads 7 cold at limit 5 / 22 at limit 20 (interceptor 1, caller graph 1, query <= limit, min 1),
  /// 0-2 warm (the prefix entry is cached); a grammar rejection or an unsupported query reads nothing beyond the
  /// interceptor. Writes 0.
  static const searchPeople = connect.Spec(
    '/$name/SearchPeople',
    connect.StreamType.unary,
    dzerothsearchv1search.SearchPeopleRequest.new,
    dzerothsearchv1search.SearchPeopleResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Posts carrying one hashtag (ADR-0028 D3). The tab picks the order:
  /// - TOP (also UNSPECIFIED): the newest 30 tagged posts, those from the last 7 days ranked by likes + 2 x reposts +
  ///   2 x quotes + replies, ties newest first. One page of at most 20; next_page_token is always "" (show "See
  ///   latest").
  /// - LATEST: newest first, paged with next_page_token. The query windows are fixed tiers, independent of page_size
  ///   (page 1: the 30-post entry, or 50 rows at page_size 31..50; an older page: 20 rows at page_size <= 20, else 50).
  ///   A window is filtered whole and then cut to page_size, so a page can be SHORT while next_page_token is non-empty.
  ///   A window that came back not full is the end of the tag; its token (only when the page was cut) is a tail token and
  ///   the next call reads the whole rest of the tag. The token position is the last returned row when the page was cut,
  ///   else the last row of the window.
  /// - MEDIA: posts with their own images (a quote's embedded images do not count), newest first. Each older call scans
  ///   30 older tagged posts and returns the ones with images, so a page may be short or EMPTY while next_page_token is
  ///   non-empty: keep following it until it is "".
  /// Filtering (every tab, per caller): hidden posts (moderation) are dropped; posts by accounts the caller blocks,
  /// who block the caller, or whom the caller mutes are dropped, including a quote whose embedded author is one of
  /// them (ADR-0010 D6). Protected accounts (ADR-0025): a post by a protected account the caller is not and does not
  /// follow is dropped; a QUOTE of such a post is kept with embed_viewer_state = PROTECTED and its embed stripped. A
  /// caller whose blocked-by list overflowed sees only their own posts and posts by accounts they follow. A page may
  /// therefore be short. Whether next_page_token is set and how many rows come back depend only on the posts the caller
  /// can see and on whether the query window was full, never on how many were dropped (LATEST; MEDIA scans a fixed 30).
  /// Viewer flags (liked, reposted, bookmarked) follow FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS as on timelines.
  /// page_size 0 => 20, max 50 (clamped); TOP returns at most 20 whatever page_size says.
  /// page_token: opaque, sealed, bound to the caller, the tag and the tab, 24 h TTL. Expired, foreign, tampered, or
  /// sent with another query or tab => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "page_token", 0 reads: drop it
  /// and search again with no token.
  /// Staleness: the newest 30 posts per tag are cached per instance for 60 s and shared across callers (a new tagged
  /// post shows on Top, Latest page 1 and Media page 1 within 60 s); every filter above is applied per caller after the
  /// cache, so a takedown or a new block applies at once on that instance.
  /// Flag: "search". Rate limits: RATE_LIMIT_SEARCH_POSTS_PER_MIN 20/min/uid per instance (60/min at 3 instances) and
  /// the shared "search_daily" cap (see SearchPeople).
  /// Firestore: TOP, LATEST first page and MEDIA first page (page_size <= 30): reads 33 cold (interceptor 1, caller
  /// graph 1, userLikes 1, the tag entry 30), 0-3 warm; LATEST first page at page_size 31..50: 53; LATEST older page 23 / 53
  /// at page_size <= 20 / 21..50 (fixed windows of 20 / 50); a LATEST tail page 3 + the rows left (at most 32 after a page-1
  /// entry, 52 after a 50-row window); MEDIA older call 33 (scan cap 30). An unsupported query or a grammar rejection reads nothing
  /// beyond the interceptor. Writes 0.
  static const searchPosts = connect.Spec(
    '/$name/SearchPosts',
    connect.StreamType.unary,
    dzerothsearchv1search.SearchPostsRequest.new,
    dzerothsearchv1search.SearchPostsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Trending hashtags (ADR-0028 D6, founder defaults F1 and F6). A tag trends when at least TRENDS_MIN_AUTHORS (3)
  /// distinct accounts used it in the window; tags are ranked by distinct accounts, then posts, then tag. Hidden posts,
  /// reposts and posts by protected accounts are not counted; tags on the operator denylist (TRENDS_DENYLIST) or the
  /// operator hide list (opsctl trends hide) and the trends flag remove tags. Tags are matched by a folded key (NFKC,
  /// lower-case, U+200C, U+200D and '_' removed), so a spelling variant of a removed tag goes with it.
  /// The list is computed by a scheduled sweep (daily at Stage 0: "Trending today"); computed_at says when.
  /// limit 0 => 10, max 30 (clamped). prefix (optional; one leading '#' ignored; at most 50 code points after it; a control or
  /// bidi formatting character => VALIDATION "prefix") keeps only tags that start with it, in rank order, for typeahead
  /// hashtag suggestions at 0 extra reads. No list yet => an empty answer and computed_at unset.
  /// Staleness: the list is cached per instance for 10 min; a tag can be up to one sweep interval plus 10 min old. A tag
  /// hidden by an operator leaves every server within 10 min (the client copy lives 5 more).
  /// Flag: "trends". Rate limits: the 60/min/uid default bucket per instance (180/min at 3 instances) and TRENDS_CALLS_PER_DAY
  /// 400 calls/uid/IST day per instance (<= 1,200 at 3), its own cap apart from SearchPeople/SearchPosts => RATE_LIMITED,
  /// metadata["limit"] = "trends_daily".
  /// Firestore: reads 3 cold (interceptor 1, trends/current and trends/hidden 2 in one GetAll), 0-1 warm; at most one
  /// load (2 reads) per instance per 10 min (<= 864 a day at 3 instances, whatever the number of callers). Writes 0.
  static const getTrends = connect.Spec(
    '/$name/GetTrends',
    connect.StreamType.unary,
    dzerothsearchv1search.GetTrendsRequest.new,
    dzerothsearchv1search.GetTrendsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
