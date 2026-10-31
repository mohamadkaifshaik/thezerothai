import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_top_bar.dart';
import '../../../lists/domain/home_tab_entry.dart';
import '../../../lists/presentation/bloc/home_tabs_cubit.dart';
import '../../../lists/presentation/bloc/home_tabs_state.dart';
import '../../../lists/presentation/lists_error_messages.dart';
import '../../../lists/presentation/widgets/list_unavailable_view.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../posts/data/posts_repository.dart';
import '../../../timeline/data/timeline_repository.dart';
import '../../../timeline/domain/feed_key.dart';
import '../../../timeline/presentation/bloc/timeline_cubit.dart';
import '../../../timeline/presentation/timeline_feed_view.dart';
import 'home_tab_bar.dart';

/// One pinned List as a Home tab (W5-14): its own `TimelineCubit`
/// (`FeedKey.list`), created when the tab is first shown and closed with it,
/// over the same [TimelineFeedView] as Following. `HomeTabsView` keeps it
/// alive (scroll and cache) while another tab is shown; [active] stops its
/// refresh tick meanwhile.
///
/// A List the server answers NOT_FOUND shows the calm unavailable state with
/// "Unpin from Home" (ADR-0030 D6).
class HomeListTab extends StatefulWidget {
  const HomeListTab({super.key, required this.tab, required this.active});

  final HomeTabEntry tab;
  final bool active;

  @override
  State<HomeListTab> createState() => _HomeListTabState();
}

class _HomeListTabState extends State<HomeListTab> {
  late final TimelineCubit _timeline = TimelineCubit(
    feed: FeedKey.list(widget.tab.id),
    timeline: context.read<TimelineRepository>(),
    posts: context.read<PostsRepository>(),
    viewerUserId: context.read<OnboardingBloc>().state.profile?.userId,
  )..load();

  @override
  void dispose() {
    _timeline.close();
    super.dispose();
  }

  Future<void> _unpin() async {
    final error = await context.read<HomeTabsCubit>().unpin(widget.tab);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(listsErrorMessage(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    _timeline.viewerUserId = viewerUserId;
    return BlocProvider<TimelineCubit>.value(
      value: _timeline,
      child: TimelineFeedView(
        viewerUserId: viewerUserId,
        active: widget.active,
        emptyTitle: 'No posts yet',
        emptySubtitle: 'Posts from people on this List will show up here.',
        fillViewport: true,
        showPending: false,
        newPostsPillTop: AppSize.headerRow * 2 + AppSpacing.sm,
        unavailableView: BlocSelector<HomeTabsCubit, HomeTabsState, bool>(
          selector: (state) => state.saving,
          builder: (context, saving) =>
              ListUnavailableView(onUnpin: _unpin, busy: saving),
        ),
        headerSlivers: [
          AppTopBar.sliver(title: 'Home'),
          const SliverToBoxAdapter(child: HomeTabBar()),
        ],
      ),
    );
  }
}
