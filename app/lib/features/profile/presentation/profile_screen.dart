import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/graph_feature_flags.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../posts/data/posts_repository.dart';
import '../../posts/domain/posts_feature_flag.dart';
import '../../timeline/data/timeline_repository.dart';
import '../../timeline/domain/feed_key.dart';
import '../../timeline/presentation/bloc/timeline_cubit.dart';
import '../../timeline/presentation/timeline_feed_view.dart';
import 'bloc/profile_cubit.dart';
import 'bloc/profile_state.dart';
import 'widgets/profile_header.dart';

/// `GetProfile(handle | user_id)` + (when the graph flag is on) the viewer's
/// relationship, rendered as [ProfileHeader], then (posts flag on) the Posts
/// tab (T18, ADR-0008 D13: the posts plan owns the body below the header).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, this.handle, this.userId})
    : assert(
        (handle == null) != (userId == null),
        'ProfileScreen takes exactly one of handle or userId',
      );

  /// Opens the profile by `@handle` (typed links, own profile tab).
  final String? handle;

  /// Opens the profile by id (post cards, mentions): immune to handle
  /// changes, since ChangeHandle frees old handles for others to claim.
  final String? userId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ProfileCubit>(
      key: ValueKey('profile-cubit-${userId ?? handle}'),
      create: (context) => ProfileCubit(
        identityRepository: context.read<IdentityRepository>(),
        graphRepository: context.read<GraphRepository>(),
        handle: handle,
        userId: userId,
        graphEnabled: graphEnabledSnapshot(context),
        ownUserId: context.read<OnboardingBloc>().state.profile?.userId,
      )..load(),
      child: const _ProfileView(),
    );
  }
}

class _ProfileView extends StatelessWidget {
  const _ProfileView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: BlocBuilder<ProfileCubit, ProfileState>(
          buildWhen: (a, b) => a.profile?.handle != b.profile?.handle,
          builder: (context, state) {
            final handle =
                state.profile?.handle ??
                context.read<ProfileCubit>().requestedHandle;
            return Text(handle == null || handle.isEmpty ? '' : '@$handle');
          },
        ),
      ),
      body: SafeArea(
        child: BlocBuilder<ProfileCubit, ProfileState>(
          builder: (context, state) {
            return switch (state.status) {
              ProfileStatus.loading => const Center(
                child: CircularProgressIndicator(),
              ),
              ProfileStatus.notFound => const AppErrorView(
                error: NotFoundException("This account doesn't exist."),
              ),
              ProfileStatus.error => AppErrorView(
                error: state.error!,
                onRetry: () => context.read<ProfileCubit>().load(),
              ),
              ProfileStatus.ready => _ReadyProfile(state: state),
            };
          },
        ),
      ),
    );
  }
}

class _ReadyProfile extends StatelessWidget {
  const _ReadyProfile({required this.state});

  final ProfileState state;

  @override
  Widget build(BuildContext context) {
    if (isFeatureEnabled(context, kFeaturePosts)) {
      return _ProfilePosts(state: state);
    }
    // Posts flag off: the Phase 0 body.
    return _ScrollColumn(
      children: [
        _header(context, state, showPostsCount: false),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            "This profile's posts are coming soon.",
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

ProfileHeader _header(
  BuildContext context,
  ProfileState state, {
  required bool showPostsCount,
}) {
  return ProfileHeader(
    profile: state.profile!,
    isOwnProfile: state.isOwnProfile,
    graphEnabled: state.graphEnabled,
    relationship: state.relationship,
    showPostsCount: showPostsCount,
    onRelationshipChanged: (relationship) =>
        context.read<ProfileCubit>().relationshipChanged(relationship),
  );
}

/// A column that is centered and capped to the mobile width on wide screens,
/// so the header never stretches edge to edge on tablet/desktop
/// (`flutter-feature` skill: LayoutBuilder breakpoints).
class _ScrollColumn extends StatelessWidget {
  const _ScrollColumn({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppBreakpoints.mobile;
        return SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isWide ? AppBreakpoints.mobile : double.infinity,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Header + the Posts tab (the Replies tab stays hidden until P3). When the
/// viewer blocks the author the feed is not even requested: a banner offers
/// "Show posts" (ADR-0010 D6, computed from the local relationship).
class _ProfilePosts extends StatefulWidget {
  const _ProfilePosts({required this.state});

  final ProfileState state;

  @override
  State<_ProfilePosts> createState() => _ProfilePostsState();
}

class _ProfilePostsState extends State<_ProfilePosts> {
  bool _showBlockedPosts = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final profile = state.profile!;
    final viewerUserId = context.read<OnboardingBloc>().state.profile?.userId;
    final header = _header(context, state, showPostsCount: true);
    final blocked = state.relationship?.blocking ?? false;

    if (blocked && !_showBlockedPosts) {
      return _ScrollColumn(
        children: [
          header,
          const Divider(height: 1),
          const _PostsTabHeader(),
          _BlockedPostsBanner(
            handle: profile.handle,
            onShow: () => setState(() => _showBlockedPosts = true),
          ),
        ],
      );
    }

    final profileCubit = context.read<ProfileCubit>();
    return BlocProvider<TimelineCubit>(
      key: ValueKey('profile-posts-${profile.userId}'),
      create: (context) => TimelineCubit(
        feed: FeedKey.user(profile.userId),
        timeline: context.read<TimelineRepository>(),
        posts: context.read<PostsRepository>(),
        viewerUserId: viewerUserId,
        // The header's post count follows a delete at once (a deleted post
        // can only be the viewer's own).
        onPostDeleted: (_) {
          if (!profileCubit.isClosed) profileCubit.postDeleted();
        },
      )..load(),
      child: TimelineFeedView(
        viewerUserId: viewerUserId,
        emptyTitle: state.isOwnProfile
            ? "You haven't posted yet"
            : '@${profile.handle} hasn\'t posted yet',
        showPending: state.isOwnProfile,
        pendingAuthorId: viewerUserId,
        hideAuthorsOnRelationship: false,
        // The request can outlive this screen: guard the cubit, not context.
        onRelationshipChanged: (relationship) {
          if (!profileCubit.isClosed) {
            profileCubit.relationshipChanged(relationship);
          }
        },
        headerSlivers: [
          SliverToBoxAdapter(child: header),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          const SliverToBoxAdapter(child: _PostsTabHeader()),
        ],
      ),
    );
  }
}

/// The single "Posts" tab label with its selected underline.
class _PostsTabHeader extends StatelessWidget {
  const _PostsTabHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      selected: true,
      child: Container(
        height: AppSpacing.minTapTarget,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.primary, width: 2),
          ),
        ),
        child: Text('Posts', style: theme.textTheme.titleSmall),
      ),
    );
  }
}

/// "You blocked @x - Show posts": the posts stay unrequested until the user
/// asks.
class _BlockedPostsBanner extends StatelessWidget {
  const _BlockedPostsBanner({required this.handle, required this.onShow});

  final String handle;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'You blocked @$handle \u00B7',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: onShow,
            child: const Text('Show posts'),
          ),
        ],
      ),
    );
  }
}
