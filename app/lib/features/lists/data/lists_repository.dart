import 'package:connectrpc/connect.dart' as connect;

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
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

/// The only caller of `ListService` (ADR-0030, plan W5-10).
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
///   [QuotaExceededException] (`quota` = `list_creates` / `list_adds`),
///   [ProtectedAccountException] (AddListMember), rate limits.
/// - **Mutations** take an `idempotencyKey` made once per user action by the
///   caller and reused on a retry (rule 4). Nothing is retried here.
/// - **Session.** No state is held, so nothing to clear on sign-out.
/// - [onListSeen] receives every `ListInfo` that comes back (the latest list
///   header), so `HomeTabsRepository` can keep its tab title current.
class ListsRepository {
  ListsRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    void Function(pb.ListInfo list)? onListSeen,
  }) : _apiClient = apiClient,
       _gate = gate,
       _onListSeen = onListSeen;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final void Function(pb.ListInfo list)? _onListSeen;

  /// Whether list RPCs may be sent at all right now.
  bool get enabled => _gate.enabled;

  /// Creates a list. A null [isPrivate] leaves the field out: the server
  /// creates it private (F3, fails closed).
  Future<pb.ListInfo> createList({
    required String idempotencyKey,
    required String name,
    String description = '',
    bool? isPrivate,
  }) async {
    final request = pb.CreateListRequest(
      idempotencyKey: idempotencyKey,
      name: name,
      description: description,
    );
    if (isPrivate != null) request.isPrivate = isPrivate;
    final r = await _call(() => _apiClient.lists.createList(request));
    return _seen(r.list);
  }

  /// Field presence is the signal: a null argument leaves the field unchanged.
  Future<pb.ListInfo> updateList({
    required String idempotencyKey,
    required String listId,
    String? name,
    String? description,
    bool? isPrivate,
  }) async {
    final request = pb.UpdateListRequest(
      idempotencyKey: idempotencyKey,
      listId: listId,
    );
    if (name != null) request.name = name;
    if (description != null) request.description = description;
    if (isPrivate != null) request.isPrivate = isPrivate;
    final r = await _call(() => _apiClient.lists.updateList(request));
    return _seen(r.list);
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
    final r = await _call(
      () => _apiClient.lists.getList(pb.GetListRequest(listId: listId)),
    );
    return _seen(r.list);
  }

  /// [ownerId] empty = the caller's own lists. [containsUserId] fills
  /// [ListsPage.containingListIds] (the "Add to Lists" checkboxes, W5-13).
  Future<ListsPage> listUserLists({
    String ownerId = '',
    String containsUserId = '',
    int pageSize = 0,
    String pageToken = '',
  }) async {
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
    r.lists.forEach(_seen);
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
    final r = await _call(
      () => _apiClient.lists.addListMember(
        pb.AddListMemberRequest(
          idempotencyKey: idempotencyKey,
          listId: listId,
          userId: userId,
        ),
      ),
    );
    return _seen(r.list);
  }

  Future<pb.ListInfo> removeMember({
    required String idempotencyKey,
    required String listId,
    required String userId,
  }) async {
    final r = await _call(
      () => _apiClient.lists.removeListMember(
        pb.RemoveListMemberRequest(
          idempotencyKey: idempotencyKey,
          listId: listId,
          userId: userId,
        ),
      ),
    );
    return _seen(r.list);
  }

  Future<ListMembersPage> listMembers({
    required String listId,
    int pageSize = 0,
    String pageToken = '',
  }) async {
    final r = await _call(
      () => _apiClient.lists.listListMembers(
        pb.ListListMembersRequest(
          listId: listId,
          pageSize: pageSize,
          pageToken: pageToken,
        ),
      ),
    );
    return ListMembersPage(
      users: r.users.toList(),
      nextPageToken: r.nextPageToken,
    );
  }

  pb.ListInfo _seen(pb.ListInfo list) {
    if (list.listId.isNotEmpty) _onListSeen?.call(list);
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
