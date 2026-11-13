import '../../../core/widgets/shell_side_column.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/bloc/user_list_cubit.dart';
import '../../graph/presentation/bloc/user_list_state.dart';
import '../../graph/presentation/widgets/paged_user_list.dart';
import '../../graph/presentation/widgets/user_list_row.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/communities_repository.dart';
import '../domain/communities_feature_flag.dart';
import '../domain/community_role.dart';
import '../domain/community_search.dart';
import 'bloc/community_member_search_cubit.dart';
import 'bloc/community_moderation_cubit.dart';
import 'communities_error_messages.dart';
import 'widgets/community_member_actions.dart';
import 'widgets/community_row.dart';
import 'widgets/community_search_field.dart';
import 'widgets/community_tabs.dart';
import 'widgets/community_unavailable_view.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';

/// The members search found no one (F36: the search reads only the top 20
/// handles of the whole platform, so it never says "not a member"). One
/// title per tab (R10 review item 6).
const kNoMembersFoundTitle = 'No members found for that handle.';
const kNoModeratorsFoundTitle = 'No moderators found for that handle.';
const kNoBannedFoundTitle = 'No banned people found for that handle.';
const kNoMembersFoundHint = 'Try more of their handle.';

/// The members search text can't start a handle (F36).
const kMemberSearchInvalidHint =
    'Search by handle: letters, numbers and underscores.';

/// The members search text is longer than any handle (F36, review item 4).
const kMemberSearchTooLongHint =
    'Search by handle: up to 15 letters, numbers or underscores.';

/// The tabs of a moderator (F24): Members, Moderators, Banned. Everyone
/// else sees Members only, with no tab bar.
enum _Tab { members, moderators, banned }

/// The polite count line over a members search's rows (review item 8).
String _matchLine(_Tab tab, int n, String prefix) => switch (tab) {
  _Tab.members =>
    n == 1 ? '1 member matches @$prefix' : '$n members match @$prefix',
  _Tab.moderators =>
    n == 1 ? '1 moderator matches @$prefix' : '$n moderators match @$prefix',
  _Tab.banned =>
    n == 1
        ? '1 banned person matches @$prefix'
        : '$n banned people match @$prefix',
};

/// A muted count line, announced politely when it changes.
class _MatchLine extends StatelessWidget {
  const _MatchLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Semantics(
        liveRegion: true,
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// The members page's link to the moderation log (owner and moderators):
/// dz `.more`, a teal 15 w600 line.
class _ModerationLogLink extends StatelessWidget {
  const _ModerationLogLink({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: context.appColors.accentText,
          minimumSize: const Size(0, AppSpacing.minTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          textStyle: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        child: const Text('View moderation log'),
      ),
    );
  }
}

/// `/communities/:id/members`: the joined members, 1
/// `ListCommunityMembers` per page, each with a Follow button; the owner and
/// moderators carry a role badge. NOT_FOUND shows the same "This Community is
/// unavailable" as the page; FEATURE_DISABLED / UNIMPLEMENTED shows "not
/// available yet". The header names the community once `GetCommunity`
/// answers.
///
/// **Moderation.** One `GetCommunity` on open gives the viewer's
/// `viewer_role` (the only source of authority; if it fails there are simply
/// no moderator rows). Owner and moderators then get Members / Moderators /
/// Banned tabs (F24; the MODERATORS and BANNED pages are moderator-only,
/// each loaded when first shown) and a "more" menu per row from
/// [communityMemberActions]: Ban and Unban, and for the owner Make and Remove
/// moderator, each after a confirm. Ban and Unban remove the row at once and
/// put it back if the call fails; a role change waits for the answer and shows
/// the role the server returned. The other loaded pages are refreshed after.
///
/// **Search (F36).** With `communities` and `community_member_search` on, a
/// "Search members" field (above the tabs) searches the active tab by handle prefix ([CommunityMemberSearchCubit]):
/// 300 ms after typing, from 2 characters, at most 20 rows, which replace the
/// tab's list while the field holds a search. A FEATURE_DISABLED for the
/// search (or a server without it) hides the field for this page.
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
  UserListCubit? _moderatorsCubit;
  UserListCubit? _bannedCubit;
  late final CommunityModerationCubit _moderation = CommunityModerationCubit(
    communityId: widget.communityId,
    communities: _communities,
  );
  late final CommunityMemberSearchCubit _search = CommunityMemberSearchCubit(
    search: ({required prefix, required filter}) async {
      final rows = await _communities.searchMembers(
        communityId: widget.communityId,
        prefix: prefix,
        filter: filter,
      );
      for (final m in rows) {
        _roles[m.user.user.userId] = m.memberRole;
      }
      return rows;
    },
  );

  /// The search field's text.
  final _searchText = TextEditingController();

  /// Role of each member seen so far (the badge), by user id.
  final Map<String, CommunityRole> _roles = {};

  /// The viewer's role from `GetCommunity.viewer_role`; none until it answers
  /// (and for good if that call fails).
  CommunityRole _viewerRole = CommunityRole.none;

  /// The community's name for the header's second line; empty until known.
  String _communityName = '';

  _Tab _tab = _Tab.members;

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

  UserListCubit get _moderators => _moderatorsCubit ??= UserListCubit(
    fetchPage: _fetch(
      pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_MODERATORS,
    ),
  )..loadFirstPage();

  UserListCubit get _banned => _bannedCubit ??= UserListCubit(
    fetchPage: _fetch(pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED),
  )..loadFirstPage();

  /// The active tab; a viewer who does not moderate has Members only.
  _Tab get _shownTab => _viewerRole.canModerate ? _tab : _Tab.members;

  UserListCubit _listOf(_Tab tab) => switch (tab) {
    _Tab.members => _joined,
    _Tab.moderators => _moderators,
    _Tab.banned => _banned,
  };

  static MemberSearchScope _scopeOf(_Tab tab) => switch (tab) {
    _Tab.members => MemberSearchScope.members,
    _Tab.moderators => MemberSearchScope.moderators,
    _Tab.banned => MemberSearchScope.banned,
  };

  @override
  void initState() {
    super.initState();
    _loadViewerRole();
  }

  Future<void> _loadViewerRole() async {
    try {
      final r = await _communities.getCommunity(widget.communityId);
      if (!mounted) return;
      setState(() {
        _viewerRole = r.community.role;
        _communityName = r.community.name;
      });
    } on AppException {
      // No role, no moderator rows; the list itself reports its own errors.
    }
  }

  @override
  void dispose() {
    _sideColumn.dispose();
    _searchText.dispose();
    _search.close();
    _joined.close();
    _moderatorsCubit?.close();
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

  void _selectTab(int i) {
    final tab = _Tab.values[i];
    setState(() => _tab = tab);
    _search.setScope(_scopeOf(tab));
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

  /// [action] on [item], from the tab list [list], or from the search
  /// results when [list] is null.
  Future<void> _act(
    CommunityMemberAction action,
    graph.UserListItem item, {
    UserListCubit? list,
  }) async {
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
    final removedRow = leavesList ? list?.removeUser(userId) : null;
    final removedResult = leavesList && list == null
        ? _search.removeUser(userId)
        : null;
    final result = await _moderation.setRole(userId, wire);
    final error = result.error;
    if (error != null) {
      if (removedRow != null) list?.restoreItem(removedRow.$1, removedRow.$2);
      if (removedResult != null) {
        _search.restore(removedResult.$1, removedResult.$2);
      }
      if (mounted) _say(communitiesErrorMessage(error));
      return;
    }
    if (!mounted) return;
    setState(() => _roles[userId] = result.change!.role);
    // The other loaded pages are stale now: a ban or unban moves a person
    // across Members, Moderators and Banned; a role change moves them in or
    // out of Moderators.
    for (final other in [_joined, _moderatorsCubit, _bannedCubit]) {
      if (other == null || identical(other, list)) continue;
      if (leavesList || identical(other, _moderatorsCubit)) {
        other.loadFirstPage();
      }
    }
    if (action == CommunityMemberAction.removeModerator &&
        identical(list, _moderatorsCubit)) {
      list?.removeUser(userId);
    }
    _say(done);
  }

  /// The search field. Once the server said the search is off, nothing.
  Widget _searchField() =>
      BlocBuilder<CommunityMemberSearchCubit, MemberSearchState>(
        bloc: _search,
        buildWhen: (a, b) => a.unavailable != b.unavailable,
        builder: (context, state) => state.unavailable
            ? const SizedBox.shrink()
            : CommunitySearchField(
                hint: kSearchMembersHint,
                label: kSearchMembersLabel,
                helperFor: (text) =>
                    memberSearchInputOf(text) == MemberSearchInput.tooShort
                    ? kMemberSearchTooShortHelper
                    : null,
                controller: _searchText,
                onChanged: _search.textChanged,
                margin: EdgeInsets.zero,
              ),
      );

  Widget _row(
    BuildContext context,
    graph.UserListItem item, {
    required _Tab tab,
    required String? viewerUserId,
    UserListCubit? list,
  }) {
    final userId = item.user.userId;
    final role =
        _roles[userId] ??
        (tab == _Tab.banned ? CommunityRole.banned : CommunityRole.none);
    final badge = communityRoleBadge(role);
    final actions = communityMemberActions(
      viewer: _viewerRole,
      target: role,
      isSelf: userId == viewerUserId,
    );
    return UserListRow(
      key: ValueKey(userId),
      item: item,
      // dz: a 44 dp avatar, 12 dp above and below and 20 dp at the sides.
      avatarRadius: 22,
      horizontalInset: 20,
      verticalInset: AppSpacing.smd,
      // dz: a 13 sp handle; no hairline under the rows on a phone (the tablet
      // and desktop designs have one).
      handleStyle: Theme.of(context).textTheme.bodySmall,
      showDivider: MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile,
      extraAction: badge == null && actions.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (badge != null)
                  AppStatusPill(label: badge, tone: AppStatusTone.info),
                BlocBuilder<CommunityModerationCubit, CommunityModerationState>(
                  bloc: _moderation,
                  buildWhen: (a, b) => a.isBusy(userId) != b.isBusy(userId),
                  builder: (context, s) => CommunityMemberActionsMenu(
                    handle: item.user.handle,
                    actions: actions,
                    busy: s.isBusy(userId),
                    onSelected: (a) => _act(a, item, list: list),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _centered(Widget child) =>
      Center(child: SingleChildScrollView(child: child));

  /// The tab's own list. With [prefix] (the Moderators tab while the field
  /// holds a search) it shows only the loaded rows whose handle starts with
  /// it, under their count line, with no call (review item 7).
  Widget _list(
    BuildContext context,
    _Tab tab,
    String? viewerUserId, {
    String? prefix,
  }) {
    final list = _listOf(tab);
    bool matches(graph.UserListItem item) =>
        item.user.handle.toLowerCase().startsWith(prefix!);
    final paged = BlocBuilder<UserListCubit, UserListState>(
      key: ValueKey('members-tab-${tab.name}'),
      bloc: list,
      buildWhen: (a, b) => a.error.runtimeType != b.error.runtimeType,
      builder: (context, state) {
        final error = state.error;
        if (error is NotFoundException) {
          return _centered(const CommunityUnavailableView());
        }
        if (error is FeatureDisabledException) {
          return _centered(
            const AppEmptyView(
              icon: Icons.groups_outlined,
              title: "Communities aren't available right now",
              subtitle: 'Please try again in a little while.',
            ),
          );
        }
        if (error is CommunityForbiddenException) {
          return _centered(
            AppEmptyView(
              icon: Icons.lock_outline,
              title: communitiesErrorMessage(error),
            ),
          );
        }
        return PagedUserList(
          cubit: list,
          itemFilter: prefix == null ? null : matches,
          emptyMessage: prefix != null
              ? kNoModeratorsFoundTitle
              : switch (tab) {
                  _Tab.members => 'No members yet',
                  _Tab.moderators => 'No moderators yet',
                  _Tab.banned => 'No one is banned',
                },
          emptyIcon: prefix == null
              ? Icons.groups_outlined
              : Icons.person_search_outlined,
          rowBuilder: (context, item) => _row(
            context,
            item,
            tab: tab,
            viewerUserId: viewerUserId,
            list: list,
          ),
        );
      },
    );
    if (prefix == null) return paged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BlocBuilder<UserListCubit, UserListState>(
          bloc: list,
          builder: (context, state) {
            final n = state.items.where(matches).length;
            return n == 0
                ? const SizedBox.shrink()
                : _MatchLine(_matchLine(tab, n, prefix));
          },
        ),
        Expanded(child: paged),
      ],
    );
  }

  /// The search's answer in place of the tab's list.
  Widget _results(
    BuildContext context,
    MemberSearchState state,
    _Tab tab,
    String? viewerUserId,
  ) {
    Widget rows(List<pb.CommunityMember> results, String prefix) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MatchLine(_matchLine(tab, results.length, prefix)),
        Expanded(
          child: ListView.builder(
            key: ValueKey('members-search-${tab.name}'),
            itemCount: results.length,
            itemBuilder: (context, i) => _row(
              context,
              results[i].user,
              tab: tab,
              viewerUserId: viewerUserId,
            ),
          ),
        ),
      ],
    );
    switch (state.status) {
      case MemberSearchStatus.local:
        return _list(context, tab, viewerUserId, prefix: state.prefix);
      case MemberSearchStatus.idle:
      case MemberSearchStatus.loading:
        // The last answer stays while the next one loads (no flash).
        if (state.results.isNotEmpty) {
          return rows(state.results, state.resultsPrefix);
        }
        return const SingleChildScrollView(
          child: UserListSkeleton(rows: 3, semanticsLabel: 'Searching members'),
        );
      case MemberSearchStatus.invalid:
      case MemberSearchStatus.tooLong:
        return _centered(
          AppEmptyView(
            icon: Icons.person_search_outlined,
            title: state.status == MemberSearchStatus.tooLong
                ? kMemberSearchTooLongHint
                : kMemberSearchInvalidHint,
          ),
        );
      case MemberSearchStatus.error:
        final error =
            state.error ?? const UnknownApiException('Failed to search');
        if (error is NotFoundException) {
          return _centered(const CommunityUnavailableView());
        }
        if (error is CommunityForbiddenException) {
          return _centered(
            AppEmptyView(
              icon: Icons.lock_outline,
              title: communitiesErrorMessage(error),
            ),
          );
        }
        return _centered(AppErrorView(error: error, onRetry: _search.retry));
      case MemberSearchStatus.ready:
        if (state.results.isEmpty) {
          return _centered(
            AppEmptyView(
              icon: Icons.person_search_outlined,
              title: tab == _Tab.banned
                  ? kNoBannedFoundTitle
                  : kNoMembersFoundTitle,
              subtitle: kNoMembersFoundHint,
            ),
          );
        }
        return rows(state.results, state.resultsPrefix);
    }
  }

  final _sideColumn = ShellSideColumnLease();

  @override
  Widget build(BuildContext context) {
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    final moderates = _viewerRole.canModerate;
    final tab = _shownTab;
    final searchOn =
        isFeatureEnabled(context, kFeatureCommunities) &&
        isFeatureEnabled(context, kFeatureCommunityMemberSearch);
    final theme = Theme.of(context);
    // Inside the desktop shell the search is the side column's (the
    // CommunityMembers mock); the controller is the page's, so the text is
    // the same wherever the field is.
    final searchBeside = shellSideColumnBeside(context);
    _sideColumn.set(
      context,
      active: searchOn && searchBeside,
      builder: (_) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: _searchField(),
      ),
    );
    return Scaffold(
      body: SafeArea(
        // The floating bar overlays the page: the scroll view runs behind it
        // and ends with the bar's inset.
        bottom: false,
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(
                title: 'Members',
                onBack: _back,
                // The name's line is kept from the first frame (an empty,
                // unspoken line until GetCommunity answers), so the page does
                // not move down when it arrives (review item 12).
                titleContent: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Members',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge,
                    ),
                    ExcludeSemantics(
                      excluding: _communityName.isEmpty,
                      child: Text(
                        _communityName.isEmpty ? ' ' : _communityName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // dz: 12 w600, muted.
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: context.appColors.secondaryOnRaised,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (searchOn && !searchBeside)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.smd,
                    AppSpacing.md,
                    AppSpacing.xs,
                  ),
                  child: _searchField(),
                ),
              if (moderates)
                CommunityTabBar(
                  labels: const ['Members', 'Moderators', 'Banned'],
                  selectedIndex: tab.index,
                  semanticLabel: 'Member lists',
                  onChanged: _selectTab,
                ),
              Expanded(
                child:
                    BlocBuilder<CommunityMemberSearchCubit, MemberSearchState>(
                      bloc: _search,
                      builder: (context, search) => searchOn && search.active
                          ? _results(context, search, tab, viewerUserId)
                          : _list(context, tab, viewerUserId),
                    ),
              ),
              if (moderates)
                // The mocks end the list on "View moderation log"; it stays
                // in view under it, whatever is loaded.
                _ModerationLogLink(
                  onPressed: () => context.push(
                    AppRouter.communityModerationLogPath(widget.communityId),
                  ),
                ),
              // The last thing on the page clears the floating bar.
              if (moderates) const ShellBottomInsetBox(),
            ],
          ),
        ),
      ),
    );
  }
}
