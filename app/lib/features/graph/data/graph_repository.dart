import '../../../core/network/api_client.dart';
import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;

/// One page of `UserListItem`s from any of the graph list RPCs
/// (ListFollowers, ListFollowing, ListBlockedUsers, ListMutedUsers), all of
/// which share the same page shape (ADR-0008 "List paging").
class GraphPage {
  const GraphPage({required this.items, required this.nextPageToken});

  final List<graph.UserListItem> items;
  final String nextPageToken;

  bool get hasMore => nextPageToken.isNotEmpty;
}

/// Fetches one page of graph list rows, given a page size and an opaque
/// cursor. Matches [GraphRepository.listFollowers] et al. so a single
/// `UserListCubit` (see `features/graph/presentation/bloc`) can drive any of
/// them.
typedef FetchGraphPage = Future<GraphPage> Function({
  required int pageSize,
  required String pageToken,
});

/// The most `GetRelationships` accepts per call (ADR-0008).
const _maxRelationshipsPerCall = 50;

/// Talks to `GraphService` and keeps a session-lifetime relationship cache,
/// so the client never re-asks "does the caller follow/block/mute this
/// user?" for an id it already knows this session (CLAUDE.md prime
/// directive: the client is our cheapest cache). Follow rows and list rows
/// prime this cache for free from data the server already sent
/// (`UserListItem.relationship`, ADR-0008 D4), so most profile/list views
/// cost 0 additional `GetRelationships` calls.
///
/// The caller's own `following` set also survives across app restarts in a
/// small drift table ([AppDatabase.cachedFollowingIds]), so `FollowButton`
/// can render "Following" instantly on a warm start before any network call
/// completes.
class GraphRepository {
  GraphRepository({required ApiClient apiClient, required AppDatabase database})
    : _apiClient = apiClient,
      _database = database;

  final ApiClient _apiClient;
  final AppDatabase _database;

  final Map<String, graph.Relationship> _relationships = {};

  /// Loads the caller's cached `following` set from disk into the in-memory
  /// relationship cache. Call once per session (after sign-in), before any
  /// profile/list screen renders, so warm starts show "Following" without
  /// waiting on the network.
  Future<void> primeFromDatabase() async {
    final epoch = _database.sessionEpoch.value;
    final ids = await _database.cachedFollowingIds();
    if (!_database.sessionEpoch.allows(epoch)) return;
    for (final id in ids) {
      _relationships.putIfAbsent(
        id,
        () => graph.Relationship(
          userId: id,
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );
    }
  }

  /// The cached relationship to [userId] this session, if any is known yet.
  graph.Relationship? cached(String userId) => _relationships[userId];

  void _cache(graph.Relationship relationship, int epoch) {
    if (relationship.userId.isEmpty) return;
    if (!_database.sessionEpoch.allows(epoch)) return;
    _relationships[relationship.userId] = relationship;
  }

  /// Primes the cache from a list row's `relationship` field (ADR-0008 D4):
  /// the server fills it from the caller's own graph at 0 extra reads, so
  /// followers/following/blocked/muted list rows never need a separate
  /// `GetRelationships` call.
  ///
  /// [epoch] is `sessionEpoch.value` read before the request started; a
  /// response landing after sign-out is dropped.
  void primeFromListItem(graph.UserListItem item, int epoch) {
    _cache(
      graph.Relationship(
        userId: item.user.userId,
        followState: item.relationship.followState,
        blocking: item.relationship.blocking,
        muting: item.relationship.muting,
      ),
      epoch,
    );
  }

  /// The caller's relationship to each of [userIds]. Ids already cached this
  /// session cost 0 network calls; only misses are sent, batched at most
  /// [_maxRelationshipsPerCall] per `GetRelationships` call.
  Future<Map<String, graph.Relationship>> relationshipsFor(
    List<String> userIds,
  ) async {
    final epoch = _database.sessionEpoch.value;
    final ids = userIds.toSet().toList();
    final misses = ids.where((id) => !_relationships.containsKey(id)).toList();
    for (var i = 0; i < misses.length; i += _maxRelationshipsPerCall) {
      final end = (i + _maxRelationshipsPerCall < misses.length)
          ? i + _maxRelationshipsPerCall
          : misses.length;
      final response = await guardApiCall(
        () => _apiClient.graph.getRelationships(
          graph.GetRelationshipsRequest(userIds: misses.sublist(i, end)),
        ),
      );
      for (final relationship in response.relationships) {
        _cache(relationship, epoch);
      }
    }
    return {
      for (final id in ids)
        id:
            _relationships[id] ??
            graph.Relationship(
              userId: id,
              followState: graph.FollowState.FOLLOW_STATE_NONE,
            ),
    };
  }

  /// Convenience for a single id; see [relationshipsFor].
  Future<graph.Relationship> relationshipFor(String userId) async {
    final map = await relationshipsFor([userId]);
    return map[userId]!;
  }

  Future<graph.Relationship> follow({
    required String userId,
    required String idempotencyKey,
  }) async {
    final epoch = _database.sessionEpoch.value;
    final response = await guardApiCall(
      () => _apiClient.graph.follow(
        graph.FollowRequest(userId: userId, idempotencyKey: idempotencyKey),
      ),
    );
    final relationship = _withUserId(response.relationship, userId);
    _cache(relationship, epoch);
    await _database.upsertFollowing(userId, epoch: epoch);
    return relationship;
  }

  Future<graph.Relationship> unfollow({
    required String userId,
    required String idempotencyKey,
  }) async {
    final epoch = _database.sessionEpoch.value;
    final response = await guardApiCall(
      () => _apiClient.graph.unfollow(
        graph.UnfollowRequest(userId: userId, idempotencyKey: idempotencyKey),
      ),
    );
    final relationship = _withUserId(response.relationship, userId);
    _cache(relationship, epoch);
    await _database.removeFollowing(userId, epoch: epoch);
    return relationship;
  }

  Future<graph.Relationship> block({
    required String userId,
    required String idempotencyKey,
  }) async {
    final epoch = _database.sessionEpoch.value;
    final response = await guardApiCall(
      () => _apiClient.graph.block(
        graph.BlockRequest(userId: userId, idempotencyKey: idempotencyKey),
      ),
    );
    final relationship = _withUserId(response.relationship, userId);
    _cache(relationship, epoch);
    // Block always cuts both follow directions (ADR-0008 D9): drop it from
    // the local following cache too so a warm start never shows "Following"
    // for someone the caller just blocked.
    await _database.removeFollowing(userId, epoch: epoch);
    return relationship;
  }

  Future<graph.Relationship> unblock({
    required String userId,
    required String idempotencyKey,
  }) async {
    final epoch = _database.sessionEpoch.value;
    final response = await guardApiCall(
      () => _apiClient.graph.unblock(
        graph.UnblockRequest(userId: userId, idempotencyKey: idempotencyKey),
      ),
    );
    final relationship = _withUserId(response.relationship, userId);
    _cache(relationship, epoch);
    return relationship;
  }

  Future<graph.Relationship> mute({
    required String userId,
    required String idempotencyKey,
  }) async {
    final epoch = _database.sessionEpoch.value;
    final response = await guardApiCall(
      () => _apiClient.graph.mute(
        graph.MuteRequest(userId: userId, idempotencyKey: idempotencyKey),
      ),
    );
    final relationship = _withUserId(response.relationship, userId);
    _cache(relationship, epoch);
    return relationship;
  }

  Future<graph.Relationship> unmute({
    required String userId,
    required String idempotencyKey,
  }) async {
    final epoch = _database.sessionEpoch.value;
    final response = await guardApiCall(
      () => _apiClient.graph.unmute(
        graph.UnmuteRequest(userId: userId, idempotencyKey: idempotencyKey),
      ),
    );
    final relationship = _withUserId(response.relationship, userId);
    _cache(relationship, epoch);
    return relationship;
  }

  /// Followers of [userId], newest first. Throws [NotFoundException] (via
  /// [guardApiCall]) if the target is missing, not active, or blocked the
  /// caller (ADR-0008 D9).
  Future<GraphPage> listFollowers({
    required String userId,
    required int pageSize,
    required String pageToken,
  }) {
    return _listUsers(
      () => _apiClient.graph.listFollowers(
        graph.ListFollowersRequest(
          userId: userId,
          pageSize: pageSize,
          pageToken: pageToken,
        ),
      ),
      (response) => (response.users, response.nextPageToken),
    );
  }

  /// Accounts [userId] follows, newest first. Same visibility rules as
  /// [listFollowers].
  Future<GraphPage> listFollowing({
    required String userId,
    required int pageSize,
    required String pageToken,
  }) {
    return _listUsers(
      () => _apiClient.graph.listFollowing(
        graph.ListFollowingRequest(
          userId: userId,
          pageSize: pageSize,
          pageToken: pageToken,
        ),
      ),
      (response) => (response.users, response.nextPageToken),
    );
  }

  /// The caller's own blocked accounts, newest first. Never includes users
  /// who blocked the caller back (ADR-0008 D9: showing them would leak the
  /// block to the caller before the caller's block is undone).
  Future<GraphPage> listBlockedUsers({
    required int pageSize,
    required String pageToken,
  }) {
    return _listUsers(
      () => _apiClient.graph.listBlockedUsers(
        graph.ListBlockedUsersRequest(pageSize: pageSize, pageToken: pageToken),
      ),
      (response) => (response.users, response.nextPageToken),
    );
  }

  /// The caller's own muted accounts, newest first.
  Future<GraphPage> listMutedUsers({
    required int pageSize,
    required String pageToken,
  }) {
    return _listUsers(
      () => _apiClient.graph.listMutedUsers(
        graph.ListMutedUsersRequest(pageSize: pageSize, pageToken: pageToken),
      ),
      (response) => (response.users, response.nextPageToken),
    );
  }

  Future<GraphPage> _listUsers<T>(
    Future<T> Function() call,
    (Iterable<graph.UserListItem>, String) Function(T) unwrap,
  ) async {
    final epoch = _database.sessionEpoch.value;
    final response = await guardApiCall(call);
    final (users, nextPageToken) = unwrap(response);
    final items = users.toList(growable: false);
    for (final item in items) {
      primeFromListItem(item, epoch);
    }
    return GraphPage(items: items, nextPageToken: nextPageToken);
  }

  graph.Relationship _withUserId(
    graph.Relationship relationship,
    String userId,
  ) {
    return graph.Relationship(
      userId: userId,
      followState: relationship.followState,
      blocking: relationship.blocking,
      muting: relationship.muting,
    );
  }

  /// Wipes the session cache. Call on sign-out so the next user on a shared
  /// device never sees a stale relationship (privacy: CLAUDE.md rule 10).
  void clearCache() => _relationships.clear();
}
