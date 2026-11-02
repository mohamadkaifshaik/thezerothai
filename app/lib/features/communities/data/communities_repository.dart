import 'package:connectrpc/connect.dart' as connect;

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/storage/session_epoch.dart';
import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../domain/communities_feature_flag.dart';

/// One page of [CommunitiesRepository.listCommunities].
class CommunitiesPage {
  const CommunitiesPage({required this.communities, this.nextPageToken = ''});

  final List<pb.Community> communities;

  /// Always empty at Stage 0 (the directory is not paged); kept so a paged
  /// server needs no client change.
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
}

/// The caller's communities ([CommunitiesRepository.listMyCommunities]).
class MyCommunities {
  const MyCommunities({
    required this.communities,
    required this.canCreate,
    this.nextPageToken = '',
  });

  final List<pb.Community> communities;

  /// The caller is in the server's creators list (`COMMUNITY_CREATORS`); the
  /// owned cap is CreateCommunity's to answer.
  final bool canCreate;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
}

/// One page of [CommunitiesRepository.listMembers].
class CommunityMembersPage {
  const CommunityMembersPage({required this.members, this.nextPageToken = ''});

  final List<pb.CommunityMember> members;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
}

/// One page of [CommunitiesRepository.listModerationLog].
class ModerationLogPage {
  const ModerationLogPage({required this.entries, this.nextPageToken = ''});

  final List<pb.ModerationLogEntry> entries;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
}

/// The only caller of `CommunityService` (ADR-0031, plan W5-30).
///
/// - **Flag.** Every RPC needs `communities` in `GetMe.enabled_features`
///   ([ServiceFeatureGate]): with it off no request is sent and a
///   [FeatureDisabledException] (`feature=communities`) is thrown. A server
///   FEATURE_DISABLED is remembered by the gate until the next `GetMe`.
/// - **UNIMPLEMENTED** (an RPC the deployed server does not have) is read as
///   [FeatureDisabledException] `feature=communities` ("not available yet"):
///   not reported, gate not tripped.
/// - **Errors are typed** by the shared mapper: [CommunityForbiddenException]
///   (FORBIDDEN, by reason), [CommunityStateException] (COMMUNITY_STATE, by
///   reason), [NotFoundException] (one message for every cause),
///   [LimitReachedException] (`quota` = `communities_owned` /
///   `communities_joined` / `community_moderators`), [QuotaExceededException]
///   (`community_joins`, `community_posts`), [RateLimitedException],
///   [ProtectedAccountException] (CreatePost into a community).
/// - **Mutations** (the seven of ADR-0031 D8) take an `idempotencyKey` made
///   once per user action by the caller and reused on a retry (rule 4).
///   Nothing is retried here.
/// - **Roles** are the server's (`Community.viewer_role`,
///   `CommunityMember.role`, see `CommunityRole`); this class derives none.
/// - **Session cache (W5-34).** The caller's communities are kept in memory
///   for the session: every successful [listMyCommunities] fills it, a Join,
///   Leave or create keeps it current, and [myCommunities] reads it, so the
///   composer's audience picker costs 0 calls once the Communities screen (or
///   an earlier compose) has loaded the list. It ends with the shared
///   [SessionEpoch] (sign-out); nothing is persisted.
class CommunitiesRepository {
  CommunitiesRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    SessionEpoch? epoch,
  }) : _apiClient = apiClient,
       _gate = gate,
       _epoch = epoch,
       _seenEpoch = epoch?.value ?? 0;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final SessionEpoch? _epoch;
  int _seenEpoch;
  MyCommunities? _mine;
  Future<MyCommunities>? _mineInFlight;

  /// Drops the cache when the session ended since it was last looked at.
  void _sync() {
    final epoch = _epoch;
    if (epoch == null || epoch.value == _seenEpoch) return;
    _seenEpoch = epoch.value;
    _mine = null;
    _mineInFlight = null;
  }

  /// The caller's communities as last seen this session, or null (never
  /// loaded, or the session ended). Reads nothing from the network.
  MyCommunities? get cachedMine {
    _sync();
    return _mine;
  }

  /// The caller's communities: the session cache when there is one, else one
  /// ListMyCommunities (concurrent callers share it). Pass [refresh] to ask
  /// the server again.
  Future<MyCommunities> myCommunities({bool refresh = false}) {
    _sync();
    final cached = _mine;
    if (!refresh && cached != null) return Future.value(cached);
    return _mineInFlight ??= listMyCommunities(pageSize: 50)
        .whenComplete(() => _mineInFlight = null);
  }

  void _noteJoined(pb.Community community) {
    _sync();
    final mine = _mine;
    if (mine == null) return;
    final id = community.communityId;
    final known = mine.communities.any((c) => c.communityId == id);
    _mine = MyCommunities(
      communities: known
          ? [
              for (final c in mine.communities)
                c.communityId == id ? community : c,
            ]
          : [...mine.communities, community],
      canCreate: mine.canCreate,
      nextPageToken: mine.nextPageToken,
    );
  }

  /// Forgets [communityId] from the cache after the server said the caller
  /// cannot post there (not a member, banned).
  void forgetCommunity(String communityId) {
    _sync();
    final mine = _mine;
    if (mine == null) return;
    _mine = MyCommunities(
      communities: [
        for (final c in mine.communities)
          if (c.communityId != communityId) c,
      ],
      canCreate: mine.canCreate,
      nextPageToken: mine.nextPageToken,
    );
  }

  /// Whether communities RPCs may be sent at all right now.
  bool get enabled => _gate.enabled;

  /// Creates a community owned by the caller (FORBIDDEN `not_creator` outside
  /// the creators list; LIMIT_REACHED `communities_owned`).
  Future<pb.CreateCommunityResponse> createCommunity({
    required String idempotencyKey,
    required String name,
    String description = '',
    List<pb.CommunityRule> rules = const [],
  }) async {
    final r = await _call(
      () => _apiClient.communities.createCommunity(
        pb.CreateCommunityRequest(
          idempotencyKey: idempotencyKey,
          name: name,
          description: description,
          rules: rules,
        ),
      ),
    );
    // The owner is a member now: the next read asks the server.
    _mine = null;
    return r;
  }

  /// Field presence is the signal: a null argument leaves the field
  /// unchanged. [rules] replaces the whole set (an empty list removes every
  /// rule).
  Future<pb.UpdateCommunityResponse> updateCommunity({
    required String idempotencyKey,
    required String communityId,
    String? name,
    String? description,
    List<pb.CommunityRule>? rules,
  }) {
    final request = pb.UpdateCommunityRequest(
      idempotencyKey: idempotencyKey,
      communityId: communityId,
    );
    if (name != null) request.name = name;
    if (description != null) request.description = description;
    if (rules != null) request.rules = pb.CommunityRuleList(rules: rules);
    return _call(() => _apiClient.communities.updateCommunity(request));
  }

  Future<pb.GetCommunityResponse> getCommunity(String communityId) {
    return _call(
      () => _apiClient.communities.getCommunity(
        pb.GetCommunityRequest(communityId: communityId),
      ),
    );
  }

  /// The directory (at most 50, by member count; not paged at Stage 0).
  Future<CommunitiesPage> listCommunities({
    int pageSize = 0,
    String pageToken = '',
  }) async {
    final r = await _call(
      () => _apiClient.communities.listCommunities(
        pb.ListCommunitiesRequest(pageSize: pageSize, pageToken: pageToken),
      ),
    );
    return CommunitiesPage(
      communities: r.communities.toList(),
      nextPageToken: r.nextPageToken,
    );
  }

  Future<MyCommunities> listMyCommunities({
    int pageSize = 0,
    String pageToken = '',
  }) async {
    _sync();
    final startEpoch = _epoch?.value;
    final r = await _call(
      () => _apiClient.communities.listMyCommunities(
        pb.ListMyCommunitiesRequest(pageSize: pageSize, pageToken: pageToken),
      ),
    );
    final mine = MyCommunities(
      communities: r.communities.toList(),
      canCreate: r.canCreate,
      nextPageToken: r.nextPageToken,
    );
    // Only the first page is the whole list; a later page never replaces it.
    if (pageToken.isEmpty && _epoch?.value == startEpoch) _mine = mine;
    return mine;
  }

  /// Returns the community with the caller's new `viewer_role`.
  Future<pb.Community> joinCommunity({
    required String idempotencyKey,
    required String communityId,
  }) async {
    final r = await _call(
      () => _apiClient.communities.joinCommunity(
        pb.JoinCommunityRequest(
          idempotencyKey: idempotencyKey,
          communityId: communityId,
        ),
      ),
    );
    _noteJoined(r.community);
    return r.community;
  }

  Future<pb.Community> leaveCommunity({
    required String idempotencyKey,
    required String communityId,
  }) async {
    final r = await _call(
      () => _apiClient.communities.leaveCommunity(
        pb.LeaveCommunityRequest(
          idempotencyKey: idempotencyKey,
          communityId: communityId,
        ),
      ),
    );
    forgetCommunity(communityId);
    return r.community;
  }

  /// [filter] BANNED needs a moderator (FORBIDDEN `not_moderator`).
  Future<CommunityMembersPage> listMembers({
    required String communityId,
    pb.CommunityMemberFilter filter =
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
    int pageSize = 0,
    String pageToken = '',
  }) async {
    final r = await _call(
      () => _apiClient.communities.listCommunityMembers(
        pb.ListCommunityMembersRequest(
          communityId: communityId,
          filter: filter,
          pageSize: pageSize,
          pageToken: pageToken,
        ),
      ),
    );
    return CommunityMembersPage(
      members: r.members.toList(),
      nextPageToken: r.nextPageToken,
    );
  }

  Future<void> hidePost({
    required String idempotencyKey,
    required String communityId,
    required String postId,
  }) async {
    await _call(
      () => _apiClient.communities.hideCommunityPost(
        pb.HideCommunityPostRequest(
          idempotencyKey: idempotencyKey,
          communityId: communityId,
          postId: postId,
        ),
      ),
    );
  }

  Future<void> restorePost({
    required String idempotencyKey,
    required String communityId,
    required String postId,
  }) async {
    await _call(
      () => _apiClient.communities.restoreCommunityPost(
        pb.RestoreCommunityPostRequest(
          idempotencyKey: idempotencyKey,
          communityId: communityId,
          postId: postId,
        ),
      ),
    );
  }

  /// Ban, unban, make or remove a moderator. The answer carries the target's
  /// new `role` and the community header.
  Future<pb.SetMemberRoleResponse> setMemberRole({
    required String idempotencyKey,
    required String communityId,
    required String userId,
    required pb.MemberRoleAction action,
  }) {
    return _call(
      () => _apiClient.communities.setMemberRole(
        pb.SetMemberRoleRequest(
          idempotencyKey: idempotencyKey,
          communityId: communityId,
          userId: userId,
          action: action,
        ),
      ),
    );
  }

  /// Moderators only (FORBIDDEN `not_moderator`). `page_size` 0 means 25.
  Future<ModerationLogPage> listModerationLog({
    required String communityId,
    int pageSize = 0,
    String pageToken = '',
  }) async {
    final r = await _call(
      () => _apiClient.communities.listModerationLog(
        pb.ListModerationLogRequest(
          communityId: communityId,
          pageSize: pageSize,
          pageToken: pageToken,
        ),
      ),
    );
    return ModerationLogPage(
      entries: r.entries.toList(),
      nextPageToken: r.nextPageToken,
    );
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
        "Communities aren't available yet.",
        feature: kFeatureCommunities,
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
