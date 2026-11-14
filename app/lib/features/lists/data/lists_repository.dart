import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:uuid/uuid.dart';

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/storage/session_epoch.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph_pb;
import '../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../domain/lists_feature_flag.dart';

/// One page of [ListsRepository.listUserLists].
class ListsPage {
  const ListsPage({
    required this.lists,
    this.containingListIds = const {},
    this.nextPageToken = '',
  });

  final List<pb.ListInfo> lists;

  /// Of the `contains_user_id` asked for: which of [lists] hold that user.
  final Set<String> containingListIds;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
}

/// One page of [ListsRepository.listMembers].
class ListMembersPage {
  const ListMembersPage({required this.users, this.nextPageToken = ''});

  final List<graph_pb.UserListItem> users;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
}

/// 1 page of [ListsRepository.listFollowedLists] / [ListsRepository.discoverLists].
typedef ListFollowsPage = ListsPage;

/// The only caller of `ListService`.
///
/// - **Flag.** Every RPC needs `lists` in `GetMe.enabled_features`
///   ([ServiceFeatureGate]): with it off no request is sent and a
///   [FeatureDisabledException] (`feature=lists`) is thrown. A server
///   FEATURE_DISABLED is remembered by the gate until the next `GetMe`.
/// - **UNIMPLEMENTED** (an RPC the deployed server does not have yet) is read
///   as [FeatureDisabledException] `feature=lists` ("not available yet"), not
///   as an unexpected error: nothing is reported and the gate is not tripped,
///   so the RPCs that do exist keep working.
/// - **Errors are typed** by the shared mapper: [NotFoundException] (one
///   fixed message for every cause: never hint at private/hidden/blocked),
///   [LimitReachedException] (`quota` = `lists_per_user` / `list_members`),
///   [ProtectedAccountException] (AddListMember), rate limits.
/// - **Mutations** take an `idempotencyKey` made once per user action by the
///   caller and reused on a retry (rule 4). Nothing is retried here.
/// - **Headers.** The latest `ListInfo` seen for each list is kept in
///   session memory ([header], [headerChanges]); the list timeline repository
///   feeds it too ([noteListInfo]), so the list detail never costs a `GetList`
///   it does not need. [clearSession] ends it on sign-out.
/// - [onListSeen] receives every `ListInfo` that comes back (the latest list
///   header), so `HomeTabsRepository` can keep its tab title current.
class ListsRepository {
  ListsRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    required SessionEpoch epoch,
    void Function(pb.ListInfo list)? onListSeen,
  }) : _apiClient = apiClient,
       _gate = gate,
       _epoch = epoch,
       _seenEpoch = epoch.value,
       _onListSeen = onListSeen;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final void Function(pb.ListInfo list)? _onListSeen;
  final SessionEpoch _epoch;
  int _seenEpoch;
  final Map<String, pb.ListInfo> _headers = {};
  final StreamController<pb.ListInfo> _headerChanges =
      StreamController<pb.ListInfo>.broadcast(sync: true);

  /// Whether list RPCs may be sent at all right now.
  bool get enabled => _gate.enabled;

  /// The latest header of [listId] this session has seen, or null.
  pb.ListInfo? header(String listId) {
    _sync();
    return _headers[listId];
  }

  /// Emits every header seen (a list screen filters by id).
  Stream<pb.ListInfo> get headerChanges => _headerChanges.stream;

  /// Records a list header from any source (this repository, the list
  /// timeline) and tells `onListSeen` (the Home tab title).
  void noteListInfo(pb.ListInfo list) {
    if (list.listId.isEmpty) return;
    _sync();
    _headers[list.listId] = list;
    _onListSeen?.call(list);
    if (!_headerChanges.isClosed) _headerChanges.add(list);
  }

  /// Forgets every header now (sign-out or a switch of account), whichever of
  /// this and the epoch end comes first.
  void clearSession() {
    _seenEpoch = _epoch.value;
    _headers.clear();
  }

  /// Drops every header when the session ended since last looked.
  void _sync() {
    if (_epoch.value == _seenEpoch) return;
    _seenEpoch = _epoch.value;
    _headers.clear();
  }

  /// Creates a list. A null [isPrivate] leaves the field out: the server
  /// creates it private (F3, fails closed).
  Future<pb.ListInfo> createList({
    required String idempotencyKey,
    required String name,
    String description = '',
    bool? isPrivate,
  }) async {
    final epoch = _epoch.value;
    final request = pb.CreateListRequest(
      idempotencyKey: idempotencyKey,
      name: name,
      description: description,
    );
    if (isPrivate != null) request.isPrivate = isPrivate;
    final r = await _call(() => _apiClient.lists.createList(request));
    return _seen(r.list, epoch);
  }

  /// Field presence is the signal: a null argument leaves the field unchanged.
  Future<pb.ListInfo> updateList({
    required String idempotencyKey,
    required String listId,
    String? name,
    String? description,
    bool? isPrivate,
  }) async {
    final epoch = _epoch.value;
    final request = pb.UpdateListRequest(
      idempotencyKey: idempotencyKey,
      listId: listId,
    );
    if (name != null) request.name = name;
    if (description != null) request.description = description;
    if (isPrivate != null) request.isPrivate = isPrivate;
    final r = await _call(() => _apiClient.lists.updateList(request));
    return _seen(r.list, epoch);
  }

  Future<void> deleteList({
    required String idempotencyKey,
    required String listId,
  }) async {
    await _call(
      () => _apiClient.lists.deleteList(
        pb.DeleteListRequest(idempotencyKey: idempotencyKey, listId: listId),
      ),
    );
  }

  Future<pb.ListInfo> getList(String listId) async {
    final epoch = _epoch.value;
    final r = await _call(
      () => _apiClient.lists.getList(pb.GetListRequest(listId: listId)),
    );
    return _seen(r.list, epoch);
  }

  /// [ownerId] empty = the caller's own lists. [containsUserId] fills
  /// [ListsPage.containingListIds] (the "Add to Lists" checkboxes).
  Future<ListsPage> listUserLists({
    String ownerId = '',
    String containsUserId = '',
    int pageSize = 0,
    String pageToken = '',
  }) async {
    final epoch = _epoch.value;
    final r = await _call(
      () => _apiClient.lists.listUserLists(
        pb.ListUserListsRequest(
          ownerId: ownerId,
          containsUserId: containsUserId,
          pageSize: pageSize,
          pageToken: pageToken,
        ),
      ),
    );
    for (final l in r.lists) {
      _seen(l, epoch);
    }
    return ListsPage(
      lists: r.lists.toList(),
      containingListIds: r.containingListIds.toSet(),
      nextPageToken: r.nextPageToken,
    );
  }

  Future<pb.ListInfo> addMember({
    required String idempotencyKey,
    required String listId,
    required String userId,
  }) async {
    final epoch = _epoch.value;
    final r = await _call(
      () => _apiClient.lists.addListMember(
        pb.AddListMemberRequest(
          idempotencyKey: idempotencyKey,
          listId: listId,
          userId: userId,
        ),
      ),
    );
    return _seen(r.list, epoch);
  }

  Future<pb.ListInfo> removeMember({
    required String idempotencyKey,
    required String listId,
    required String userId,
  }) async {
    final epoch = _epoch.value;
    final r = await _call(
      () => _apiClient.lists.removeListMember(
        pb.RemoveListMemberRequest(
          idempotencyKey: idempotencyKey,
          listId: listId,
          userId: userId,
        ),
      ),
    );
    return _seen(r.list, epoch);
  }

  /// A page can be short, or empty with a token still set (members the viewer
  /// may not see are dropped). With [maxEmptyPages] above 0 an EMPTY page that
  /// still has a token is followed, at most that many times, before the page
  /// is returned; the token goes back unchanged.
  Future<ListMembersPage> listMembers({
    required String listId,
    int pageSize = 0,
    String pageToken = '',
    int maxEmptyPages = 0,
  }) async {
    var token = pageToken;
    for (var attempt = 0; ; attempt++) {
      final r = await _call(
        () => _apiClient.lists.listListMembers(
          pb.ListListMembersRequest(
            listId: listId,
            pageSize: pageSize,
            pageToken: token,
          ),
        ),
      );
      final page = ListMembersPage(
        users: r.users.toList(),
        nextPageToken: r.nextPageToken,
      );
      if (page.users.isNotEmpty || !page.hasMore || attempt >= maxEmptyPages) {
        return page;
      }
      token = page.nextPageToken;
    }
  }

  // ---- list follows and suggestions (flags `list_follows`, `list_suggestions`)
  //
  // These go around the `lists` gate's FEATURE_DISABLED memory: a server that
  // has only these two flags off must not switch every other Lists RPC off
  // until the next GetMe. The UI checks the flag first; a server
  // FEATURE_DISABLED or UNIMPLEMENTED comes back as a
  // [FeatureDisabledException] carrying the flag name.

  static const _uuid = Uuid();

  /// A fresh idempotency key (36 chars of [A-Za-z0-9-], within 16-64).
  static String newIdempotencyKey() => _uuid.v4();

  /// Follows a public List. Returns its header (count and
  /// `followed_by_viewer` updated), also noted for the detail screen.
  Future<pb.ListInfo> followList({
    required String idempotencyKey,
    required String listId,
  }) async {
    final epoch = _epoch.value;
    final r = await _followCall(
      () => _apiClient.lists.followList(
        pb.FollowListRequest(idempotencyKey: idempotencyKey, listId: listId),
      ),
    );
    return _seen(r.list, epoch);
  }

  /// Unfollows a List. The response is empty, so the new header is the last
  /// one seen with the viewer's follow removed (count floored at 0); null
  /// when none is known.
  Future<pb.ListInfo?> unfollowList({
    required String idempotencyKey,
    required String listId,
    pb.ListInfo? current,
  }) async {
    final epoch = _epoch.value;
    await _followCall(
      () => _apiClient.lists.unfollowList(
        pb.UnfollowListRequest(idempotencyKey: idempotencyKey, listId: listId),
      ),
    );
    final base = current ?? header(listId);
    if (base == null) return null;
    final next = base.deepCopy()
      ..followedByViewer = false
      ..followerCount = base.followerCount > 0 ? base.followerCount - 1 : 0;
    return _seen(next, epoch);
  }

  Future<ListsPage> listFollowedLists({
    int pageSize = kListFollowsPageSize,
    String pageToken = '',
  }) async {
    final epoch = _epoch.value;
    final r = await _followCall(
      () => _apiClient.lists.listFollowedLists(
        pb.ListFollowedListsRequest(pageSize: pageSize, pageToken: pageToken),
      ),
    );
    for (final l in r.lists) {
      _seen(l, epoch);
    }
    return ListsPage(lists: r.lists.toList(), nextPageToken: r.nextPageToken);
  }

  /// Public Lists, most followed first.
  Future<ListsPage> discoverLists({
    int pageSize = kListFollowsPageSize,
    String pageToken = '',
  }) async {
    final epoch = _epoch.value;
    final r = await _followCall(
      () => _apiClient.lists.discoverLists(
        pb.DiscoverListsRequest(pageSize: pageSize, pageToken: pageToken),
      ),
    );
    for (final l in r.lists) {
      _seen(l, epoch);
    }
    return ListsPage(lists: r.lists.toList(), nextPageToken: r.nextPageToken);
  }

  /// Up to [maxResults] people who may fit the List (owner only; the server
  /// answers NOT_FOUND otherwise).
  Future<List<graph_pb.UserListItem>> listSuggestedMembers({
    required String listId,
    int maxResults = kListSuggestionsMax,
  }) async {
    final r = await _followCall(
      () => _apiClient.lists.listSuggestedMembers(
        pb.ListSuggestedMembersRequest(listId: listId, maxResults: maxResults),
      ),
      feature: kFeatureListSuggestions,
    );
    return r.users.toList();
  }

  Future<T> _followCall<T>(
    Future<T> Function() call, {
    String feature = kFeatureListFollows,
  }) async {
    if (!_gate.enabled) {
      throw const FeatureDisabledException(
        "Lists aren't available yet.",
        feature: kFeatureLists,
      );
    }
    try {
      return await guardApiCall(() async {
        try {
          return await call();
        } on connect.ConnectException catch (error) {
          if (error.code == connect.Code.unimplemented) {
            throw FeatureDisabledException(
              "This isn't available yet.",
              feature: feature,
            );
          }
          rethrow;
        }
      });
    } on FeatureDisabledException catch (error) {
      // Never remembered by the `lists` gate; name the flag that is off.
      throw FeatureDisabledException(error.message, feature: feature);
    }
  }

  /// Keeps [list] unless the session ended since the request started under
  /// [epoch] (privacy: a late answer never lands in the next account).
  pb.ListInfo _seen(pb.ListInfo list, int epoch) {
    if (_epoch.allows(epoch)) noteListInfo(list);
    return list;
  }

  /// Gate + typed errors; UNIMPLEMENTED becomes "not available yet" after the
  /// gate, so it neither reaches the crash reporter nor trips the gate.
  Future<T> _call<T>(Future<T> Function() call) async {
    final out = await _gate.run<_Out<T>>(() async {
      try {
        return _Out<T>(await call());
      } on connect.ConnectException catch (error) {
        if (error.code == connect.Code.unimplemented) return _Out<T>.notYet();
        rethrow;
      }
    });
    if (out.notYet) {
      throw const FeatureDisabledException(
        "Lists aren't available yet.",
        feature: kFeatureLists,
      );
    }
    return out.value as T;
  }
}

class _Out<T> {
  _Out(T this.value) : notYet = false;
  _Out.notYet() : value = null, notYet = true;
  final T? value;
  final bool notYet;
}
