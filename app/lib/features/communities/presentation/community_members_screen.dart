import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/bloc/user_list_cubit.dart';
import '../../graph/presentation/bloc/user_list_state.dart';
import '../../graph/presentation/widgets/paged_user_list.dart';
import '../../graph/presentation/widgets/user_list_row.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/communities_repository.dart';
import '../domain/community_role.dart';
import 'bloc/community_moderation_cubit.dart';
import 'communities_error_messages.dart';
import 'widgets/community_member_actions.dart';
import 'widgets/community_row.dart';
import 'widgets/community_unavailable_view.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';

/// `/communities/:id/members`: the joined members, 1
/// `ListCommunityMembers` per page, each with a Follow button; the owner and
/// moderators carry a role badge. NOT_FOUND shows the same "This Community is
/// unavailable" as the page; FEATURE_DISABLED / UNIMPLEMENTED shows "not
/// available yet".
///
/// **Moderation.** One `GetCommunity` on open gives the viewer's
/// `viewer_role` (the only source of authority; if it fails there are simply
/// no moderator rows). Owner and moderators then get a Members / Banned switch
/// (the BANNED page is moderator-only) and a "more" menu per row from
/// [communityMemberActions]: Ban and Unban, and for the owner Make and Remove
/// moderator, each after a confirm. Ban and Unban remove the row at once and
/// put it back if the call fails; a role change waits for the answer and shows
/// the role the server returned.
class CommunityMembersScreen extends StatefulWidget {
  const CommunityMembersScreen({super.key, required this.communityId});

  final String communityId;

  @override
  State<CommunityMembersScreen> createState() => _CommunityMembersScreenState();
}

class _CommunityMembersScreenState extends State<CommunityMembersScreen> {
  late final CommunitiesRepository _communities = context
      .read<CommunitiesRepository>();
  late final UserListCubit _joined = UserListCubit(
    fetchPage: _fetch(pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED),
  )..loadFirstPage();
  UserListCubit? _bannedCubit;
  late final CommunityModerationCubit _moderation = CommunityModerationCubit(
    communityId: widget.communityId,
    communities: _communities,
  );

  /// Role of each member seen so far (the badge), by user id.
  final Map<String, CommunityRole> _roles = {};

  /// The viewer's role from `GetCommunity.viewer_role`; none until it answers
  /// (and for good if that call fails).
  CommunityRole _viewerRole = CommunityRole.none;

  /// 0 = Members, 1 = Banned (moderators only).
  int _tab = 0;

  FetchGraphPage _fetch(pb.CommunityMemberFilter filter) =>
      ({required int pageSize, required String pageToken}) async {
        final page = await _communities.listMembers(
          communityId: widget.communityId,
          filter: filter,
          pageSize: pageSize,
          pageToken: pageToken,
        );
        for (final m in page.members) {
          _roles[m.user.user.userId] = m.memberRole;
        }
        return GraphPage(
          items: page.members.map((m) => m.user).toList(),
          nextPageToken: page.nextPageToken,
        );
      };

  UserListCubit get _banned => _bannedCubit ??= UserListCubit(
    fetchPage: _fetch(pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED),
  )..loadFirstPage();

  UserListCubit get _current => _tab == 1 ? _banned : _joined;

  @override
  void initState() {
    super.initState();
    _loadViewerRole();
  }

  Future<void> _loadViewerRole() async {
    try {
      final r = await _communities.getCommunity(widget.communityId);
      if (!mounted) return;
      setState(() => _viewerRole = r.community.role);
    } on AppException {
      // No role, no moderator rows; the list itself reports its own errors.
    }
  }

  @override
  void dispose() {
    _joined.close();
    _bannedCubit?.close();
    _moderation.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.communityPath(widget.communityId));
    }
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final confirmed = await showAppMaterialDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  Future<void> _act(
    CommunityMemberAction action,
    UserListCubit list,
    graph.UserListItem item,
  ) async {
    final handle = item.user.handle;
    final userId = item.user.userId;
    final (title, body, button, wire, done) = switch (action) {
      CommunityMemberAction.ban => (
        'Ban @$handle?',
        "They can read this Community but can't join, post or reply. Their "
            'earlier posts stay.',
        'Ban',
        pb.MemberRoleAction.MEMBER_ROLE_ACTION_BAN,
        'Banned @$handle.',
      ),
      CommunityMemberAction.unban => (
        'Unban @$handle?',
        'They can join this Community again.',
        'Unban',
        pb.MemberRoleAction.MEMBER_ROLE_ACTION_UNBAN,
        'Unbanned @$handle.',
      ),
      CommunityMemberAction.makeModerator => (
        'Make @$handle a moderator?',
        'Moderators can remove posts, ban and unban members and read the '
            'moderation log.',
        'Make moderator',
        pb.MemberRoleAction.MEMBER_ROLE_ACTION_MAKE_MODERATOR,
        '@$handle is now a moderator.',
      ),
      CommunityMemberAction.removeModerator => (
        'Remove @$handle as moderator?',
        'They stay a member of this Community.',
        'Remove',
        pb.MemberRoleAction.MEMBER_ROLE_ACTION_REMOVE_MODERATOR,
        '@$handle is no longer a moderator.',
      ),
    };
    if (!await _confirm(title: title, body: body, action: button)) return;
    final leavesList =
        action == CommunityMemberAction.ban ||
        action == CommunityMemberAction.unban;
    final removed = leavesList ? list.removeUser(userId) : null;
    final result = await _moderation.setRole(userId, wire);
    final error = result.error;
    if (error != null) {
      if (removed != null) list.restoreItem(removed.$1, removed.$2);
      if (mounted) _say(communitiesErrorMessage(error));
      return;
    }
    if (!mounted) return;
    setState(() => _roles[userId] = result.change!.role);
    // The other page is stale now: a ban or unban moves a person across.
    if (leavesList) {
      (identical(list, _joined) ? _bannedCubit : _joined)?.loadFirstPage();
    }
    _say(done);
  }

  @override
  Widget build(BuildContext context) {
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    final moderates = _viewerRole.canModerate;
    final list = _current;
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(title: 'Members', onBack: _back),
              if (moderates)
                AppTabBar(
                  tabs: const [
                    AppTab(label: 'Members'),
                    AppTab(label: 'Banned'),
                  ],
                  selectedIndex: _tab,
                  equalWidth: true,
                  semanticLabel: 'Member lists',
                  onChanged: (i) => setState(() => _tab = i),
                ),
              Expanded(
                child: BlocBuilder<UserListCubit, UserListState>(
                  key: ValueKey('members-tab-$_tab'),
                  bloc: list,
                  buildWhen: (a, b) =>
                      a.error.runtimeType != b.error.runtimeType,
                  builder: (context, state) {
                    final error = state.error;
                    if (error is NotFoundException) {
                      return const Center(
                        child: SingleChildScrollView(
                          child: CommunityUnavailableView(),
                        ),
                      );
                    }
                    if (error is FeatureDisabledException) {
                      return const Center(
                        child: SingleChildScrollView(
                          child: AppEmptyView(
                            icon: Icons.groups_outlined,
                            title: "Communities aren't available right now",
                            subtitle: 'Please try again in a little while.',
                          ),
                        ),
                      );
                    }
                    if (error is CommunityForbiddenException) {
                      return Center(
                        child: SingleChildScrollView(
                          child: AppEmptyView(
                            icon: Icons.lock_outline,
                            title: communitiesErrorMessage(error),
                          ),
                        ),
                      );
                    }
                    return PagedUserList(
                      cubit: list,
                      emptyMessage: _tab == 1
                          ? 'No one is banned'
                          : 'No members yet',
                      emptyIcon: Icons.groups_outlined,
                      rowBuilder: (context, item) {
                        final userId = item.user.userId;
                        final role =
                            _roles[userId] ??
                            (_tab == 1
                                ? CommunityRole.banned
                                : CommunityRole.none);
                        final badge = communityRoleBadge(role);
                        final actions = communityMemberActions(
                          viewer: _viewerRole,
                          target: role,
                          isSelf: userId == viewerUserId,
                        );
                        return UserListRow(
                          key: ValueKey(userId),
                          item: item,
                          extraAction: badge == null && actions.isEmpty
                              ? null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (badge != null)
                                      AppStatusPill(label: badge),
                                    BlocBuilder<
                                      CommunityModerationCubit,
                                      CommunityModerationState
                                    >(
                                      bloc: _moderation,
                                      buildWhen: (a, b) =>
                                          a.isBusy(userId) != b.isBusy(userId),
                                      builder: (context, s) =>
                                          CommunityMemberActionsMenu(
                                            handle: item.user.handle,
                                            actions: actions,
                                            busy: s.isBusy(userId),
                                            onSelected: (a) =>
                                                _act(a, list, item),
                                          ),
                                    ),
                                  ],
                                ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
