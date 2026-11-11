import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/context_pane.dart';
import '../../../core/widgets/context_pane_slots.dart';
import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_icon_button.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_section_header.dart';
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
import 'widgets/explore_communities_pane.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

/// The first tab, and the page's list in band B (F23).
const kMyCommunitiesTitle = 'My communities';

/// My communities is empty: one sentence in every layout (the Explore tab,
/// or band B's Explore communities card; review item 10).
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
/// - Phones, tablet band A and desktop: the filter, then the "My
///   communities" / "Explore" tabs (F23). Band B: no tabs; the page is My
///   communities and the context pane has the filter over Explore
///   communities (T8a).
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

/// The tabs of phones, band A and desktop (F23).
enum _Tab { mine, explore }

class _CommunitiesScreenState extends State<CommunitiesScreen> {
  late final CommunitiesCubit _cubit = CommunitiesCubit(
    repository: context.read<CommunitiesRepository>(),
  )..load();

  /// Band B's context pane: the filter over "Explore communities", over this
  /// page's [_cubit] (the same rows, Join and states; no call of its own;
  /// T8a).
  final _paneLease = ContextPaneLease();

  /// Whether the pane's directory shows every row, after "Show more". The
  /// pane is a sibling of this page, so its builder listens to this (the
  /// page's `setState` does not rebuild the slot).
  final _paneShowsAll = ValueNotifier(false);

  /// The filter's text (F37), shared by the inline field and the pane's:
  /// the pane's builder listens to it, and the page rebuilds on it.
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _paneLease.attach(context, AppRouter.communitiesPath, {
      ContextSectionKind.exploreCommunities: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CommunitySearchField(
            hint: kSearchCommunitiesHint,
            controller: _query,
          ),
          BlocBuilder<CommunitiesCubit, CommunitiesState>(
            bloc: _cubit,
            builder: (context, state) =>
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _query,
                  builder: (context, query, _) =>
                      _explorePaneCard(context, state, query.text),
                ),
          ),
        ],
      ),
    });
  }

  /// Band B's "Explore communities" card: the inline list's own states and
  /// rows, as boxes. The pane is one scroll view, so it shows the first
  /// [kExplorePaneRows] matches and "Show more" for the rest (at most 50,
  /// the directory's one page).
  Widget _explorePaneCard(
    BuildContext context,
    CommunitiesState state,
    String query,
  ) => ContextPaneCard(
    title: kExploreCommunitiesTitle,
    child: Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child:
          _directoryStatus(context, state, query) ??
          ValueListenableBuilder<bool>(
            valueListenable: _paneShowsAll,
            builder: (context, showsAll, _) {
              final rows = filterCommunities(state.directory, query);
              final more = !showsAll && rows.length > kExplorePaneRows;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (query.trim().isNotEmpty)
                    _CountLine(communitiesMatchLine(rows.length, query)),
                  for (final c in more ? rows.take(kExplorePaneRows) : rows)
                    _exploreRow(context, state, c, inPane: true),
                  if (more)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(
                              AppSpacing.minTapTarget,
                              AppSpacing.minTapTarget,
                            ),
                          ),
                          onPressed: () => _paneShowsAll.value = true,
                          child: const Text(
                            'Show more',
                            semanticsLabel: 'Show more Communities to explore',
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
    ),
  );

  @override
  void dispose() {
    _paneLease.dispose();
    _paneShowsAll.dispose();
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
    // Band B's context pane shows the filter and "Explore communities"
    // (T8a): the inline field and the tabs step aside, their slivers kept
    // in place so My communities keeps its scroll offset when the window
    // crosses 840.
    final exploreInPane = ContextPaneScope.shows(
      context,
      ContextSectionKind.exploreCommunities,
    );
    final tab = exploreInPane ? _Tab.mine : _tab;
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
                            child: exploreInPane
                                ? const SizedBox.shrink()
                                : Padding(
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
                            child: exploreInPane
                                ? const AppSectionHeader(
                                    title: kMyCommunitiesTitle,
                                  )
                                : CommunityTabBar(
                                    labels: const [
                                      kMyCommunitiesTitle,
                                      'Explore',
                                    ],
                                    selectedIndex: tab.index,
                                    semanticLabel: 'Community lists',
                                    onChanged: (i) =>
                                        setState(() => _tab = _Tab.values[i]),
                                  ),
                          ),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: AppSpacing.sm),
                          ),
                          if (tab == _Tab.mine)
                            ..._mine(context, state, tabs: !exploreInPane)
                          else
                            ..._directory(context, state),
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
  /// it says only that nothing shown matches. With the tabs showing and
  /// matches in the other tab ([other]: that tab and its count), a 48 dp
  /// "See N in ..." switches to it (review item 9).
  Widget _noMatch({required bool mayBeCut, (_Tab, int)? other}) {
    final note = _SectionNote(
      mayBeCut ? kNoLoadedCommunitiesMatch : kNoCommunitiesMatch,
    );
    if (other == null || other.$2 == 0) return note;
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

  /// [tabs]: the page shows the tabs (not band B).
  List<Widget> _mine(
    BuildContext context,
    CommunitiesState state, {
    required bool tabs,
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
                other: tabs
                    ? (_Tab.explore, _otherCount(state, _Tab.explore))
                    : null,
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
                onTap: () => this.context.push(
                  AppRouter.communityPath(community.communityId),
                ),
              );
            },
          ),
        ];
    }
  }

  /// "Explore" while it has no row to show: the skeleton, the error, the
  /// empty note or the filter's no-match; null once there are rows. Inline
  /// and in the pane.
  Widget? _directoryStatus(
    BuildContext context,
    CommunitiesState state,
    String query, {
    bool tabs = false,
  }) {
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
        if (filterCommunities(state.directory, query).isEmpty) {
          return _noMatch(
            mayBeCut: communitiesMayBeCut(
              count: state.directory.length,
              hasMore: state.directoryHasMore,
            ),
            other: tabs ? (_Tab.mine, _otherCount(state, _Tab.mine)) : null,
          );
        }
        return null;
    }
  }

  /// One directory row with its Join pill: a card inline, a plain row in
  /// the pane ([inPane]).
  Widget _exploreRow(
    BuildContext context,
    CommunitiesState state,
    pb.Community community, {
    bool inPane = false,
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
      card: !inPane,
      onTap: () => this.context.push(AppRouter.communityPath(id)),
      // The pane is 320 dp: the Join pill goes under the name there.
      trailingBelow: inPane,
      trailing: CommunityJoinControl(
        state: joinState,
        name: community.name,
        compact: true,
        busy: joining,
        onJoin: () => _join(community),
      ),
    );
  }

  List<Widget> _directory(BuildContext context, CommunitiesState state) {
    final status = _directoryStatus(context, state, _query.text, tabs: true);
    if (status != null) return [SliverToBoxAdapter(child: status)];
    final rows = filterCommunities(state.directory, _query.text);
    return [
      if (_query.text.trim().isNotEmpty)
        SliverToBoxAdapter(
          child: _CountLine(communitiesMatchLine(rows.length, _query.text)),
        ),
      SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) => _exploreRow(context, state, rows[i]),
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
