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
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_section_header.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../data/communities_repository.dart';
import '../domain/community_role.dart';
import 'bloc/communities_cubit.dart';
import 'bloc/communities_state.dart';
import 'communities_error_messages.dart';
import 'widgets/community_join_control.dart';
import 'widgets/community_row.dart';
import 'widgets/explore_communities_pane.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

/// `/communities`: "My Communities" and "Explore Communities" (the
/// directory, top 50) with Join pills, and a Create entry for creators.
///
/// - 1 `ListMyCommunities` + 1 `ListCommunities` per open ([CommunitiesCubit]);
///   each section loads, fails and retries on its own.
/// - Create ("Create a Community", the header action) only when the server's
///   `can_create` is true; it fails closed while loading or after an error.
/// - Join is optimistic ("Joined" at once) and rolls back with a snackbar.
/// - The `communities` flag gates the route (the router redirects Home) and
///   every entry point. An RPC the deployed server does not have yet reads as
///   the calm "not available yet" text inside its section.
/// - Not built (founder F10): chips and search.
class CommunitiesScreen extends StatefulWidget {
  const CommunitiesScreen({super.key});

  @override
  State<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

class _CommunitiesScreenState extends State<CommunitiesScreen> {
  late final CommunitiesCubit _cubit = CommunitiesCubit(
    repository: context.read<CommunitiesRepository>(),
  )..load();

  /// Band B's context pane: "Explore Communities" over this page's [_cubit]
  /// (the same rows, Join and states; no call of its own; T8a).
  final _paneLease = ContextPaneLease();

  /// Whether the pane's directory shows every row, after "Show more". The
  /// pane is a sibling of this page, so its builder listens to this (the
  /// page's `setState` does not rebuild the slot).
  final _paneShowsAll = ValueNotifier(false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _paneLease.attach(context, AppRouter.communitiesPath, {
      ContextSectionKind.exploreCommunities: (context) =>
          BlocBuilder<CommunitiesCubit, CommunitiesState>(
            bloc: _cubit,
            builder: (context, state) => ContextPaneCard(
              title: _exploreTitle,
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                // The inline section's own states and rows, as boxes: the
                // pane is one scroll view, so it shows the first
                // [kExplorePaneRows] and "Show more" for the rest (at most
                // 50, the directory's one page).
                child:
                    _directoryStatus(state) ??
                    ValueListenableBuilder<bool>(
                      valueListenable: _paneShowsAll,
                      builder: (context, showsAll, _) {
                        final more =
                            !showsAll &&
                            state.directory.length > kExplorePaneRows;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final c
                                in more
                                    ? state.directory.take(kExplorePaneRows)
                                    : state.directory)
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
                                      semanticsLabel:
                                          'Show more Communities to explore',
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
              ),
            ),
          ),
    });
  }

  @override
  void dispose() {
    _paneLease.dispose();
    _paneShowsAll.dispose();
    _cubit.close();
    super.dispose();
  }

  static const _exploreTitle = kExploreCommunitiesTitle;

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
    // Band B's context pane shows "Explore Communities" (T8a): the inline
    // copy steps aside, its slivers kept in place so My Communities keeps
    // its scroll offset when the window crosses 840.
    final exploreInPane = ContextPaneScope.shows(
      context,
      ContextSectionKind.exploreCommunities,
    );
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
                        IconButton(
                          tooltip: 'Create a Community',
                          icon: const Icon(Icons.group_add_outlined),
                          onPressed: () =>
                              context.push(AppRouter.communityNewPath),
                        ),
                    ],
                  ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _cubit.load,
                      child: CustomScrollView(
                        slivers: [
                          const SliverToBoxAdapter(
                            child: AppSectionHeader(title: 'My Communities'),
                          ),
                          ..._mine(
                            context,
                            state,
                            exploreInPane: exploreInPane,
                          ),
                          SliverToBoxAdapter(
                            child: exploreInPane
                                ? const SizedBox.shrink()
                                : const AppSectionHeader(title: _exploreTitle),
                          ),
                          if (exploreInPane)
                            const SliverToBoxAdapter(child: SizedBox.shrink())
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

  List<Widget> _mine(
    BuildContext context,
    CommunitiesState state, {
    required bool exploreInPane,
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
          // In band B Explore Communities is beside the list, not below it.
          return [
            SliverToBoxAdapter(
              child: _SectionNote(
                exploreInPane
                    ? "You haven't joined any Communities yet. Join one from "
                          '$_exploreTitle to see its posts.'
                    : "You haven't joined any Communities yet. Join one below "
                          'to see its posts.',
              ),
            ),
          ];
        }
        return [
          SliverList.builder(
            itemCount: state.mine.length,
            itemBuilder: (context, i) {
              final community = state.mine[i];
              return CommunityRow(
                key: ValueKey('mine-${community.communityId}'),
                community: community,
                onTap: () => context.push(
                  AppRouter.communityPath(community.communityId),
                ),
              );
            },
          ),
        ];
    }
  }

  /// "Explore Communities" while it has no rows: the skeleton, the error or
  /// the empty note; null once there are rows. Inline and in the pane.
  Widget? _directoryStatus(CommunitiesState state) {
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
        return null;
    }
  }

  /// One directory row with its Join pill. Inline and in the pane
  /// ([inPane]).
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
    final control = CommunityJoinControl(
      state: joinState,
      name: community.name,
      compact: true,
      busy: joining,
      onJoin: () => _join(community),
    );
    return CommunityRow(
      key: ValueKey('explore-$id'),
      community: community,
      onTap: () => this.context.push(AppRouter.communityPath(id)),
      // The pane is 320 dp: the Join pill goes under the name there.
      trailingBelow: inPane,
      trailing: inPane
          // The compact pill is 36 dp inside its 48 dp box, and only the
          // pill takes a pointer. In the pane the whole box does; the pill
          // stays the one spoken button. Inline rows keep today's control.
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: joinState == CommunityJoinState.join && !joining
                  ? () => _join(community)
                  : null,
              child: control,
            )
          : control,
    );
  }

  List<Widget> _directory(BuildContext context, CommunitiesState state) {
    final status = _directoryStatus(state);
    if (status != null) return [SliverToBoxAdapter(child: status)];
    return [
      SliverList.builder(
        itemCount: state.directory.length,
        itemBuilder: (context, i) =>
            _exploreRow(context, state, state.directory[i]),
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
