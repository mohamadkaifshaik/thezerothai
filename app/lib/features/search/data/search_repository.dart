import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/network/rate_limit_hold.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' show UserListItem;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' show PostView;
import '../../../gen/dzeroth/search/v1/search.pb.dart' as pb;
import '../../../gen/dzeroth/search/v1/search.pb.dart' show Trend;
import '../../../gen/dzeroth/search/v1/search.pbenum.dart' show SearchTab;

export '../../../gen/dzeroth/graph/v1/graph.pb.dart' show UserListItem;
export '../../../gen/dzeroth/posts/v1/posts.pb.dart' show PostView;
export '../../../gen/dzeroth/search/v1/search.pb.dart' show Trend;
export '../../../gen/dzeroth/search/v1/search.pbenum.dart' show SearchTab;

/// Search is off for this caller or for everyone (FAILED_PRECONDITION +
/// FEATURE_DISABLED, ADR-0028 D8). Hide the entry points; never retry.
class SearchUnavailableException implements Exception {
  const SearchUnavailableException([this.feature]);

  /// The server's `metadata["feature"]`: `search` or `trends`.
  final String? feature;

  @override
  String toString() => 'Search is not available.';
}

/// RATE_LIMITED (a per-minute bucket, the shared `search_daily` cap or the
/// per-uid read budget). Show a friendly message; offer retry after
/// [retryAfter] when known. [isDaily] limits reset at IST midnight.
class SearchRateLimitedException implements Exception {
  const SearchRateLimitedException({this.retryAfter, this.isDaily = false});

  final Duration? retryAfter;
  final bool isDaily;

  @override
  String toString() => 'Too many searches. Try again later.';
}

/// VALIDATION on `query` (or page_token, which a caller answers by searching
/// again with no token). [field] is the server's `metadata["field"]`.
class SearchInvalidQueryException implements Exception {
  const SearchInvalidQueryException({this.field});

  final String? field;

  @override
  String toString() => 'That search is not valid.';
}

/// Maps the typed transport errors to the search ones; everything else
/// (network, paused, unavailable, unknown) is passed through unchanged for
/// the shared error views.
Object mapSearchError(Object error) {
  if (error is FeatureDisabledException) {
    return SearchUnavailableException(error.feature);
  }
  if (error is RateLimitedException) {
    return SearchRateLimitedException(
      retryAfter: error.retryAfter,
      isDaily: error.isDaily,
    );
  }
  if (error is ValidationException) {
    return SearchInvalidQueryException(field: error.field);
  }
  return error;
}

class SearchPeopleResult {
  const SearchPeopleResult({
    this.users = const [],
    this.unsupportedQuery = false,
  });

  final List<UserListItem> users;
  final bool unsupportedQuery;
}

class SearchPostsPage {
  const SearchPostsPage({
    this.posts = const [],
    this.nextPageToken,
    this.normalizedTag = '',
    this.unsupportedQuery = false,
  });

  final List<PostView> posts;

  /// Null when there is no more; a MEDIA page can be empty while this is set.
  final String? nextPageToken;
  final String normalizedTag;
  final bool unsupportedQuery;
}

class TrendsResult {
  const TrendsResult({this.trends = const [], this.computedAt});

  final List<Trend> trends;

  /// When the server computed the list; null when there is no list yet.
  final DateTime? computedAt;
}

/// The only caller of SearchService (ADR-0028). Read-only: no idempotency
/// keys, no retries beyond the transport's.
abstract class SearchRepository {
  /// Handle-prefix people (`limit` 0 => 10 server side; no pagination).
  /// Throws [SearchUnavailableException], [SearchRateLimitedException],
  /// [SearchInvalidQueryException].
  Future<SearchPeopleResult> searchPeople(String query, {int limit = 5});

  /// Posts for one hashtag; pass the previous page's token for the next page.
  Future<SearchPostsPage> searchPosts(
    String query, {
    required SearchTab tab,
    String? pageToken,
    int pageSize = 20,
  });

  /// Trending hashtags; [prefix] filters for typeahead.
  Future<TrendsResult> getTrends({int limit = 10, String prefix = ''});
}

class ConnectSearchRepository implements SearchRepository {
  ConnectSearchRepository({
    required ApiClient apiClient,
    RateLimitHold? rateLimitHold,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _apiClient = apiClient,
       _hold = rateLimitHold ?? RateLimitHold(),
       _onUnexpectedError = onUnexpectedError;

  final ApiClient _apiClient;
  final RateLimitHold _hold;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  Future<T> _read<T>(Future<T> Function() call) async {
    final held = _hold.check();
    if (held != null) throw mapSearchError(held);
    try {
      return await guardApiCall(call);
    } on RateLimitedException catch (error) {
      _hold.record(error);
      throw mapSearchError(error);
    } on UnknownApiException catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      rethrow;
    } on AppException catch (error) {
      throw mapSearchError(error);
    }
  }

  @override
  Future<SearchPeopleResult> searchPeople(String query, {int limit = 5}) async {
    final response = await _read(
      () => _apiClient.search.searchPeople(
        pb.SearchPeopleRequest(query: query, limit: limit),
      ),
    );
    return SearchPeopleResult(
      users: response.users,
      unsupportedQuery: response.unsupportedQuery,
    );
  }

  @override
  Future<SearchPostsPage> searchPosts(
    String query, {
    required SearchTab tab,
    String? pageToken,
    int pageSize = 20,
  }) async {
    final response = await _read(
      () => _apiClient.search.searchPosts(
        pb.SearchPostsRequest(
          query: query,
          tab: tab,
          pageSize: pageSize,
          pageToken: pageToken ?? '',
        ),
      ),
    );
    return SearchPostsPage(
      posts: response.posts,
      nextPageToken: response.nextPageToken.isEmpty
          ? null
          : response.nextPageToken,
      normalizedTag: response.normalizedTag,
      unsupportedQuery: response.unsupportedQuery,
    );
  }

  @override
  Future<TrendsResult> getTrends({int limit = 10, String prefix = ''}) async {
    final response = await _read(
      () => _apiClient.search.getTrends(
        pb.GetTrendsRequest(limit: limit, prefix: prefix),
      ),
    );
    return TrendsResult(
      trends: response.trends,
      computedAt: response.hasComputedAt()
          ? response.computedAt.toDateTime()
          : null,
    );
  }
}
