import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/compose_gate.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../shared/widgets/app_tab_bar.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_state.dart';
import '../../posts/data/posts_repository.dart';
import '../../posts/domain/posts_feature_flag.dart';
import '../../posts/presentation/bloc/pending_posts_cubit.dart';
import '../../timeline/data/timeline_repository.dart';
import '../../timeline/domain/feed_key.dart';
import '../../timeline/presentation/bloc/timeline_cubit.dart';
import '../../timeline/presentation/timeline_feed_view.dart';
import 'widgets/home_composer_entry.dart';

/// The Home timeline (T17, ADR-0004 section 7): the cached feed renders at
/// once, then one throttled refresh with `since_token`; pull-to-refresh,
/// resume and a 60 s foreground auto-refresh bring new posts behind an
/// "N new posts" pill. With the posts flag off the Phase 0 placeholder stays.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeaturePosts)) {
      return const _HomePlaceholder();
    }
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    // The same rule as the shell's "New post" button.
    final canCompose = canComposeAt(context, AppRouter.homePath);
    return BlocProvider<TimelineCubit>(
      create: (context) => TimelineCubit(
        feed: const FeedKey.home(),
        timeline: context.read<TimelineRepository>(),
        posts: context.read<PostsRepository>(),
        viewerUserId: viewerUserId,
      )..load(),
      child: MultiBlocListener(
        listeners: [
          BlocListener<PendingPostsCubit, List<PendingPost>>(
            // A pending post left the list: it was stored (or rolled back), so
            // re-read the cache, with no RPC.
            listenWhen: (before, after) => after.length < before.length,
            listener: (context, _) =>
                context.read<TimelineCubit>().reloadFromCache(),
          ),
          BlocListener<OnboardingBloc, OnboardingState>(
            // The profile can load after the cubit was created: without the
            // viewer id the user's own new posts would be held behind the pill.
            listenWhen: (before, after) =>
                before.profile?.userId != after.profile?.userId,
            listener: (context, state) =>
                context.read<TimelineCubit>().viewerUserId =
                    state.profile?.userId,
          ),
        ],
        child: Scaffold(
          body: TimelineFeedView(
            viewerUserId: viewerUserId,
            // Under the two header rows (top bar + tab bar).
            newPostsPillTop: AppSize.headerRow * 2 + AppSpacing.sm,
            headerSlivers: [
              // 53dp top bar: the avatar button (narrow layouts, opens the
              // drawer) and the title, over the theme's bottom hairline.
              AppTopBar.sliver(title: 'Home'),
              // One tab for now: custom list tabs arrive with the Lists wave.
              SliverToBoxAdapter(
                child: AppTabBar(
                  semanticLabel: 'Home timelines',
                  selectedIndex: 0,
                  onChanged: (_) {},
                  tabs: const [AppTab(label: 'Following')],
                ),
              ),
              if (canCompose)
                const SliverToBoxAdapter(child: HomeComposerEntry()),
            ],
            emptyTitle: 'Your timeline is empty',
            emptySubtitle:
                'Follow people to see their posts here, or write your own '
                'with the New post button.',
          ),
        ),
      ),
    );
  }
}

class _HomePlaceholder extends StatelessWidget {
  const _HomePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.dynamic_feed_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Your timeline is coming soon.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
