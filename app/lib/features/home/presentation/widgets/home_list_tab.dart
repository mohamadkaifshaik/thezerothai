import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/widgets/home_retap_signal.dart';
import '../../../communities/presentation/widgets/community_unavailable_view.dart';
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
import '../../../../shared/widgets/primitives/app_tab_bar.dart';
import 'home_tab_bar.dart';
import 'home_top_bar.dart';
import '../../../../core/session/user_ids.dart';

/// One pinned List or community as a Home tab: its own `TimelineCubit`
/// (`FeedKey.list` or `FeedKey.community`, by the tab's kind), created when the tab is first shown and closed with it,
/// over the same [TimelineFeedView] as Following. `HomeTabsView` keeps it
/// alive (scroll and cache) while another tab is shown; [active] stops its
/// refresh tick meanwhile.
///
/// A List or community the server answers NOT_FOUND shows the calm unavailable
/// state with "Unpin from Home".
class HomeListTab extends StatefulWidget {
  const HomeListTab({super.key, required this.tab, required this.active});

  final HomeTabEntry tab;
  final bool active;

  @override
  State<HomeListTab> createState() => _HomeListTabState();
}

class _HomeListTabState extends State<HomeListTab> {
  bool get _isCommunity => widget.tab.kind == HomeTabKind.community;

  late final TimelineCubit _timeline = TimelineCubit(
    feed: _isCommunity
        ? FeedKey.community(widget.tab.id)
        : FeedKey.list(widget.tab.id),
    timeline: context.read<TimelineRepository>(),
    posts: context.read<PostsRepository>(),
    viewerUserId: context.read<OnboardingBloc>().state.myUserId,
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
      (OnboardingBloc bloc) => bloc.state.myUserId,
    );
    _timeline.viewerUserId = viewerUserId;
    return BlocProvider<TimelineCubit>.value(
      value: _timeline,
      child: TimelineFeedView(
        viewerUserId: viewerUserId,
        active: widget.active,
        retapSignal: context.read<HomeRetapSignal?>(),
        emptyTitle: 'No posts yet',
        emptySubtitle: _isCommunity
            ? 'Posts in this community will show up here.'
            : 'Posts from people on this List will show up here.',
        fillViewport: true,
        showPending: false,
        newPostsPillTop: HomeTopBar.belowHeaders(context),
        unavailableView: BlocSelector<HomeTabsCubit, HomeTabsState, bool>(
          selector: (state) => state.saving,
          builder: (context, saving) => _isCommunity
              ? CommunityUnavailableView(onUnpin: _unpin, busy: saving)
              : ListUnavailableView(onUnpin: _unpin, busy: saving),
        ),
        headerSlivers: [
          HomeTopBar.sliver(context, phoneTitle: 'Home', pinned: true),
          const AppPinnedTabBarSliver(child: HomeTabBar()),
        ],
      ),
    );
  }
}
