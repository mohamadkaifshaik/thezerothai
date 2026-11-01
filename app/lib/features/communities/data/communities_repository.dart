import 'package:connectrpc/connect.dart' as connect;

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
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
/// - Holds no session state: nothing here outlives a sign-out.
class CommunitiesRepository {
  CommunitiesRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
  }) : _apiClient = apiClient,
       _gate = gate;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;

  /// Whether communities RPCs may be sent at all right now.
  bool get enabled => _gate.enabled;

  /// Creates a community owned by the caller (FORBIDDEN `not_creator` outside
  /// the creators list; LIMIT_REACHED `communities_owned`).
  Future<pb.CreateCommunityResponse> createCommunity({
    required String idempotencyKey,
    required String name,
    String description = '',
    List<pb.CommunityRule> rules = const [],
  }) {
    return _call(
      () => _apiClient.communities.createCommunity(
        pb.CreateCommunityRequest(
          idempotencyKey: idempotencyKey,
          name: name,
          description: description,
          rules: rules,
        ),
      ),
    );
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
    final r = await _call(
      () => _apiClient.communities.listMyCommunities(
        pb.ListMyCommunitiesRequest(pageSize: pageSize, pageToken: pageToken),
      ),
    );
    return MyCommunities(
      communities: r.communities.toList(),
      canCreate: r.canCreate,
      nextPageToken: r.nextPageToken,
    );
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
