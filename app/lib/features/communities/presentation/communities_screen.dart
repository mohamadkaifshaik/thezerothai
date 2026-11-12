import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_icon_button.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../data/communities_repository.dart';
import '../domain/community_role.dart';
import '../domain/community_search.dart';
import 'bloc/communities_cubit.dart';
import 'bloc/communities_state.dart';
import 'communities_error_messages.dart';
import 'widgets/community_join_control.dart';
import 'widgets/community_row.dart';
import 'widgets/community_search_field.dart';
import 'widgets/community_tabs.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

/// The first tab (F23).
const kMyCommunitiesTitle = 'My communities';

/// My communities is empty: one sentence in every layout (the Explore tab;
/// review item 10).
const kEmptyMineTabs =
    "You haven't joined any Communities yet. Join one from Explore to see "
    'its posts.';

/// The filter matched nothing in a list that is whole (F37 v1).
const kNoCommunitiesMatch = 'No Communities match.';

/// The filter matched nothing in a list that may be cut short (50 rows, or
/// a next page): it never claims that nothing exists (F37 v1).
const kNoLoadedCommunitiesMatch = 'No matches among the Communities shown.';

/// The polite count line over a filtered list (F37, review item 8).
String communitiesMatchLine(int n, String query) => n == 1
    ? '1 Community matches "${query.trim()}"'
    : '$n Communities match "${query.trim()}"';

/// `/communities`: "My communities" and "Explore" (the directory, top 50)
/// with Join pills, a "Search communities" filter and a Create entry for
/// creators (R10).
///
/// - 1 `ListMyCommunities` + 1 `ListCommunities` per open ([CommunitiesCubit]);
///   each list loads, fails and retries on its own. Both load on open,
///   whichever tab shows.
/// - The filter, then the "My communities" / "Explore" tabs (F23), at every
///   width. Tablet and desktop lead with the title alone (a rail destination
///   has no Back).
/// - The filter (F37 v1) narrows both loaded lists by name and description,
///   with no call. Over a list that may be cut short (50 rows, or a next
///   page) it never says that nothing exists.
/// - Create ("Create a community", the header action) only when the
///   server's `can_create` is true; it fails closed while loading or after an
///   error.
/// - Join is optimistic ("Joined" at once) and rolls back with a snackbar.
/// - The `communities` flag gates the route (the router redirects Home) and
///   every entry point. An RPC the deployed server does not have yet reads as
///   the calm "not available yet" text inside its list.
class CommunitiesScreen extends StatefulWidget {
  const CommunitiesScreen({super.key});

  @override
  State<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

/// The tabs (F23).
enum _Tab { mine, explore }

class _CommunitiesScreenState extends State<CommunitiesScreen> {
  late final CommunitiesCubit _cubit = CommunitiesCubit(
    repository: context.read<CommunitiesRepository>(),
  )..load();

  /// The filter's text (F37); the page rebuilds on it.
  final _query = TextEditingController();
  String _shownQuery = '';

  _Tab _tab = _Tab.mine;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQuery);
  }

  void _onQuery() {
    if (_query.text == _shownQuery || !mounted) return;
    setState(() => _shownQuery = _query.text);
  }

  @override
  void dispose() {
    _query
      ..removeListener(_onQuery)
      ..dispose();
    _cubit.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  Future<void> _join(pb.Community community) async {
    final error = await _cubit.join(community);
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(communitiesErrorMessage(error))));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocBuilder<CommunitiesCubit, CommunitiesState>(
            bloc: _cubit,
            builder: (context, state) {
              return Column(
                children: [
                  AppBackHeader(
                    title: 'Communities',
                    onBack: _back,
                    // Tablet and desktop: the rail is the way out.
                    leading: wide ? const SizedBox(width: AppSpacing.sm) : null,
                    actions: [
                      if (state.canCreate)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            end: AppSpacing.sm,
                          ),
                          child: AppIconButton(
                            tooltip: 'Create a community',
                            icon: Icons.add,
                            raised: true,
                            onPressed: () =>
                                context.push(AppRouter.communityNewPath),
                          ),
                        ),
                    ],
                  ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _cubit.load,
                      child: CustomScrollView(
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                AppSpacing.md,
                                AppSpacing.smd,
                                AppSpacing.md,
                                AppSpacing.xs,
                              ),
                              child: CommunitySearchField(
                                hint: kSearchCommunitiesHint,
                                controller: _query,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: CommunityTabBar(
                              labels: const [kMyCommunitiesTitle, 'Explore'],
                              selectedIndex: _tab.index,
                              semanticLabel: 'Community lists',
                              onChanged: (i) =>
                                  setState(() => _tab = _Tab.values[i]),
                            ),
                          ),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: AppSpacing.sm),
                          ),
                          if (_tab == _Tab.mine)
                            ..._mine(context, state, wide: wide)
                          else
                            ..._directory(context, state, wide: wide),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: AppSpacing.lg),
                          ),
                          const ShellBottomInsetSliver(),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The filter found nothing (F37 v1). Over a list that may be cut short
  /// it says only that nothing shown matches. With matches in the other tab
  /// ([other]: that tab and its count), a 48 dp "See N in ..." switches to
  /// it (review item 9).
  Widget _noMatch({required bool mayBeCut, required (_Tab, int) other}) {
    final note = _SectionNote(
      mayBeCut ? kNoLoadedCommunitiesMatch : kNoCommunitiesMatch,
    );
    if (other.$2 == 0) return note;
    final (tab, n) = other;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        note,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(
                AppSpacing.minTapTarget,
                AppSpacing.minTapTarget,
              ),
            ),
            onPressed: () => setState(() => _tab = tab),
            child: Text(
              tab == _Tab.explore
                  ? 'See $n in Explore'
                  : 'See $n in $kMyCommunitiesTitle',
            ),
          ),
        ),
      ],
    );
  }

  /// The filtered count of the list not showing (for [_noMatch]); 0 while it
  /// is not loaded.
  int _otherCount(CommunitiesState state, _Tab other) {
    final ready = other == _Tab.explore
        ? state.directoryStatus == CommunitiesLoad.ready
        : state.mineStatus == CommunitiesLoad.ready;
    if (!ready) return 0;
    return filterCommunities(
      other == _Tab.explore ? state.directory : state.mine,
      _query.text,
    ).length;
  }

  List<Widget> _mine(
    BuildContext context,
    CommunitiesState state, {
    required bool wide,
  }) {
    switch (state.mineStatus) {
      case CommunitiesLoad.loading:
        return const [
          SliverToBoxAdapter(
            child: UserListSkeleton(
              rows: 2,
              semanticsLabel: 'Loading your Communities',
            ),
          ),
        ];
      case CommunitiesLoad.error:
        return [
          SliverToBoxAdapter(
            child: _SectionError(error: state.mineError, onRetry: _cubit.load),
          ),
        ];
      case CommunitiesLoad.ready:
        if (state.mine.isEmpty) {
          return const [
            SliverToBoxAdapter(child: _SectionNote(kEmptyMineTabs)),
          ];
        }
        final rows = filterCommunities(state.mine, _query.text);
        if (rows.isEmpty) {
          return [
            SliverToBoxAdapter(
              child: _noMatch(
                mayBeCut: communitiesMayBeCut(
                  count: state.mine.length,
                  hasMore: state.mineHasMore,
                ),
                other: (_Tab.explore, _otherCount(state, _Tab.explore)),
              ),
            ),
          ];
        }
        return [
          if (_query.text.trim().isNotEmpty)
            SliverToBoxAdapter(
              child: _CountLine(communitiesMatchLine(rows.length, _query.text)),
            ),
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final community = rows[i];
              return CommunityRow(
                key: ValueKey('mine-${community.communityId}'),
                community: community,
                card: true,
                wide: wide,
                onTap: () => this.context.push(
                  AppRouter.communityPath(community.communityId),
                ),
                // Every row here is one the viewer joined: the design's
                // outlined "Joined" (inert; Leave is on the community's
                // page).
                trailing: CommunityJoinControl(
                  state: CommunityJoinState.joined,
                  name: community.name,
                  compact: true,
                ),
              );
            },
          ),
        ];
    }
  }

  /// "Explore" while it has no row to show: the skeleton, the error, the
  /// empty note or the filter's no-match; null once there are rows.
  Widget? _directoryStatus(BuildContext context, CommunitiesState state) {
    switch (state.directoryStatus) {
      case CommunitiesLoad.loading:
        return const UserListSkeleton(
          rows: 3,
          semanticsLabel: 'Loading Communities to explore',
        );
      case CommunitiesLoad.error:
        return _SectionError(error: state.directoryError, onRetry: _cubit.load);
      case CommunitiesLoad.ready:
        if (state.directory.isEmpty) {
          return const _SectionNote('No Communities to explore yet.');
        }
        if (filterCommunities(state.directory, _query.text).isEmpty) {
          return _noMatch(
            mayBeCut: communitiesMayBeCut(
              count: state.directory.length,
              hasMore: state.directoryHasMore,
            ),
            other: (_Tab.mine, _otherCount(state, _Tab.mine)),
          );
        }
        return null;
    }
  }

  /// One directory row with its Join pill.
  Widget _exploreRow(
    BuildContext context,
    CommunitiesState state,
    pb.Community community, {
    required bool wide,
  }) {
    final id = community.communityId;
    final joining = state.joining.contains(id);
    final joinState = state.banned.contains(id)
        ? CommunityJoinState.banned
        : community.role == CommunityRole.banned
        ? CommunityJoinState.banned
        : (joining || community.role.isMember)
        ? CommunityJoinState.joined
        : CommunityJoinState.join;
    return CommunityRow(
      key: ValueKey('explore-$id'),
      community: community,
      card: true,
      wide: wide,
      onTap: () => this.context.push(AppRouter.communityPath(id)),
      trailing: CommunityJoinControl(
        state: joinState,
        name: community.name,
        compact: true,
        busy: joining,
        onJoin: () => _join(community),
      ),
    );
  }

  List<Widget> _directory(
    BuildContext context,
    CommunitiesState state, {
    required bool wide,
  }) {
    final status = _directoryStatus(context, state);
    if (status != null) return [SliverToBoxAdapter(child: status)];
    final rows = filterCommunities(state.directory, _query.text);
    return [
      if (_query.text.trim().isNotEmpty)
        SliverToBoxAdapter(
          child: _CountLine(communitiesMatchLine(rows.length, _query.text)),
        ),
      SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) =>
            _exploreRow(context, state, rows[i], wide: wide),
      ),
    ];
  }
}

/// A muted sentence under a section header (empty section).
class _SectionNote extends StatelessWidget {
  const _SectionNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The polite count line over a filtered list (F37, review item 8): muted,
/// announced when it changes.
class _CountLine extends StatelessWidget {
  const _CountLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.sm,
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

/// One section's failure: the calm "not available yet" note when the server
/// does not serve it (yet), otherwise the shared error view with Retry.
class _SectionError extends StatelessWidget {
  const _SectionError({required this.error, required this.onRetry});

  final AppException? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final error = this.error ?? const UnknownApiException('Failed to load');
    if (error is FeatureDisabledException) {
      return const _SectionNote(
        "This isn't available right now. Please try again in a little while.",
      );
    }
    return AppErrorView(error: error, onRetry: onRetry);
  }
}
