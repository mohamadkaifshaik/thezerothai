import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
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

  @override
  void dispose() {
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
                          ..._mine(context, state),
                          const SliverToBoxAdapter(
                            child: AppSectionHeader(
                              title: 'Explore Communities',
                            ),
                          ),
                          ..._directory(context, state),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: AppSpacing.lg),
                          ),
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

  List<Widget> _mine(BuildContext context, CommunitiesState state) {
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
            SliverToBoxAdapter(
              child: _SectionNote(
                "You haven't joined any Communities yet. Join one below to "
                'see its posts.',
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

  List<Widget> _directory(BuildContext context, CommunitiesState state) {
    switch (state.directoryStatus) {
      case CommunitiesLoad.loading:
        return const [
          SliverToBoxAdapter(
            child: UserListSkeleton(
              rows: 3,
              semanticsLabel: 'Loading Communities to explore',
            ),
          ),
        ];
      case CommunitiesLoad.error:
        return [
          SliverToBoxAdapter(
            child: _SectionError(
              error: state.directoryError,
              onRetry: _cubit.load,
            ),
          ),
        ];
      case CommunitiesLoad.ready:
        if (state.directory.isEmpty) {
          return const [
            SliverToBoxAdapter(
              child: _SectionNote('No Communities to explore yet.'),
            ),
          ];
        }
        return [
          SliverList.builder(
            itemCount: state.directory.length,
            itemBuilder: (context, i) {
              final community = state.directory[i];
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
                onTap: () => context.push(AppRouter.communityPath(id)),
                trailing: CommunityJoinControl(
                  state: joinState,
                  name: community.name,
                  compact: true,
                  busy: joining,
                  onJoin: () => _join(community),
                ),
              );
            },
          ),
        ];
    }
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
