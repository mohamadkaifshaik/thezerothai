import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../../shared/widgets/follow_button.dart';
import '../../../graph/data/graph_repository.dart';
import '../../../graph/presentation/bloc/relationship_cubit.dart';
import '../../../graph/presentation/bloc/relationship_state.dart';
import '../../../graph/presentation/graph_error_messages.dart';
import 'block_confirmation_dialog.dart';

/// The profile header: avatar, display name, `@handle`, bio, follower/
/// following counts, and (for other users, when the graph flag is on) a
/// [FollowButton] plus a block/mute overflow menu.
///
/// Owned by the graph plan (ADR-0008 D13); the posts/profile-timeline plan
/// adds the tabs and body below it — this widget never grows to include
/// them, so the two plans don't edit the same widget at once.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.profile,
    required this.isOwnProfile,
    required this.graphEnabled,
    this.relationship,
    this.onRelationshipChanged,
  });

  final identity.Profile profile;
  final bool isOwnProfile;
  final bool graphEnabled;

  /// The viewer's relationship to [profile], if known. Null for the
  /// viewer's own profile, when the graph flag is off, or if the fetch
  /// failed — in every case, no follow/block/mute affordance is shown.
  final graph.Relationship? relationship;
  final ValueChanged<graph.Relationship>? onRelationshipChanged;

  bool get _showGraphActions =>
      !isOwnProfile && graphEnabled && relationship != null;

  @override
  Widget build(BuildContext context) {
    if (!_showGraphActions) {
      return _ProfileHeaderBody(profile: profile, showActions: false);
    }
    return BlocProvider(
      create: (context) => RelationshipCubit(
        graphRepository: context.read<GraphRepository>(),
        userId: profile.userId,
        initial: relationship!,
      ),
      child: BlocListener<RelationshipCubit, RelationshipState>(
        listener: (context, state) {
          onRelationshipChanged?.call(state.relationship);
          final error = state.error;
          if (error != null) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(content: Text(relationshipErrorMessage(error))),
              );
          }
        },
        child: _ProfileHeaderBody(profile: profile, showActions: true),
      ),
    );
  }
}

class _ProfileHeaderBody extends StatelessWidget {
  const _ProfileHeaderBody({required this.profile, required this.showActions});

  final identity.Profile profile;
  final bool showActions;

  @override
  Widget build(BuildContext context) {
    final isBlocking =
        showActions &&
        context.select((RelationshipCubit c) => c.state.relationship.blocking);

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundImage: profile.avatarUrl.isEmpty
                    ? null
                    : NetworkImage(profile.avatarUrl),
                child: profile.avatarUrl.isEmpty
                    ? const Icon(Icons.person_outline, size: 32)
                    : null,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.displayName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '@${profile.handle}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (showActions && !isBlocking) ...[
                Column(
                  children: [
                    const FollowButton(),
                    const SizedBox(height: AppSpacing.xs),
                    const _OverflowMenu(),
                  ],
                ),
              ] else if (showActions) ...[
                const _OverflowMenu(),
              ],
            ],
          ),
          if (profile.bio.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(profile.bio),
          ],
          const SizedBox(height: AppSpacing.md),
          if (isBlocking)
            _BlockedBanner(handle: profile.handle)
          else
            _CountsRow(profile: profile),
        ],
      ),
    );
  }
}

class _CountsRow extends StatelessWidget {
  const _CountsRow({required this.profile});

  final identity.Profile profile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _CountLink(
          count: profile.followingCount.toInt(),
          label: 'Following',
          onTap: () => context.push(
            AppRouter.followingPath(profile.handle),
            extra: profile.userId,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        _CountLink(
          count: profile.followersCount.toInt(),
          label: 'Followers',
          onTap: () => context.push(
            AppRouter.followersPath(profile.handle),
            extra: profile.userId,
          ),
        ),
      ],
    );
  }
}

class _CountLink extends StatelessWidget {
  const _CountLink({
    required this.count,
    required this.label,
    required this.onTap,
  });

  final int count;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: '$count $label',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$count ',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: label),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the counts row when the viewer blocks this profile
/// (ADR-0008: "hides counts links"). The overflow menu (Mute/Unmute,
/// Block/Unblock) stays available up in the header row regardless.
class _BlockedBanner extends StatelessWidget {
  const _BlockedBanner({required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RelationshipCubit, RelationshipState>(
      builder: (context, state) {
        return Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'You blocked @$handle',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: state.isUpdating
                    ? null
                    : () => context.read<RelationshipCubit>().unblock(),
                child: const Text('Unblock'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RelationshipCubit, RelationshipState>(
      builder: (context, state) {
        final cubit = context.read<RelationshipCubit>();
        final relationship = state.relationship;
        return Semantics(
          button: true,
          label: 'More options',
          child: PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'mute':
                  await cubit.mute();
                case 'unmute':
                  await cubit.unmute();
                case 'block':
                  final confirmed = await showBlockConfirmationDialog(context);
                  if (confirmed) await cubit.block();
                case 'unblock':
                  await cubit.unblock();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: relationship.muting ? 'unmute' : 'mute',
                child: Text(relationship.muting ? 'Unmute' : 'Mute'),
              ),
              PopupMenuItem(
                value: relationship.blocking ? 'unblock' : 'block',
                child: Text(relationship.blocking ? 'Unblock' : 'Block'),
              ),
            ],
          ),
        );
      },
    );
  }
}
