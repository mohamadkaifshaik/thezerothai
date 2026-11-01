import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../lists/data/home_tabs_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../posts/data/posts_repository.dart';
import '../../timeline/data/timeline_repository.dart';
import '../../timeline/domain/feed_key.dart';
import '../../timeline/presentation/bloc/timeline_cubit.dart';
import '../../timeline/presentation/bloc/timeline_state.dart';
import '../../timeline/presentation/timeline_feed_view.dart';
import '../data/communities_repository.dart';
import 'bloc/community_detail_cubit.dart';
import 'bloc/community_detail_state.dart';
import 'communities_error_messages.dart';
import 'widgets/community_about.dart';
import 'widgets/community_header.dart';
import 'widgets/community_unavailable_view.dart';

/// `/communities/:id` (W5-32): header, then Posts and About tabs.
///
/// - Posts is the shared [TimelineFeedView] over
///   `TimelineCubit(FeedKey.community(id))` (cache first, `since_token`
///   refreshes, "new posts" pill, `removed_ids`); no polling. About shows the
///   description, the numbered rules and the moderators from the one
///   `GetCommunity` of the open.
/// - Join and Leave are optimistic with a rollback snackbar; Pin / Unpin is
///   one `SetHomeTabs`.
/// - NOT_FOUND from either RPC replaces the screen with "This Community is
///   unavailable"; one text for every cause.
/// - There is no compose-to-community entry here: the composer's audience
///   picker (W5-34) owns posting into a community.
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key, required this.communityId});

  final String communityId;

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  late final CommunityDetailCubit _detail = CommunityDetailCubit(
    communityId: widget.communityId,
    communities: context.read<CommunitiesRepository>(),
    tabs: context.read<HomeTabsRepository>(),
  );
  late final TimelineCubit _timeline = TimelineCubit(
    feed: FeedKey.community(widget.communityId),
    timeline: context.read<TimelineRepository>(),
    posts: context.read<PostsRepository>(),
    viewerUserId: context.read<OnboardingBloc>().state.profile?.userId,
  );

  /// 0 = Posts, 1 = About (ephemeral UI state).
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _detail.load();
    _timeline.load();
  }

  @override
  void dispose() {
    _timeline.close();
    _detail.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.communitiesPath);
    }
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _join() async {
    final error = await _detail.join();
    if (error != null && mounted) _say(communitiesErrorMessage(error));
  }

  Future<void> _leave() async {
    final name = _detail.state.community?.name ?? 'this Community';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Leave $name?'),
        content: const Text(
          'Its posts will stop showing up in your Communities.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await _detail.leave();
    if (error != null && mounted) _say(communitiesErrorMessage(error));
  }

  Future<void> _togglePin() async {
    final error = await _detail.togglePin();
    if (error != null && mounted) _say(communitiesErrorMessage(error));
  }

  @override
  Widget build(BuildContext context) {
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    _timeline.viewerUserId = viewerUserId;
    return MultiBlocProvider(
      providers: [
        BlocProvider<TimelineCubit>.value(value: _timeline),
        BlocProvider<CommunityDetailCubit>.value(value: _detail),
      ],
      child: BlocListener<TimelineCubit, TimelineState>(
        listenWhen: (before, after) => after.unavailable && !before.unavailable,
        listener: (context, _) => _detail.markUnavailable(),
        child: Scaffold(
          body: SafeArea(
            child: BlocBuilder<CommunityDetailCubit, CommunityDetailState>(
              builder: (context, state) {
                if (state.status == CommunityDetailStatus.unavailable) {
                  return AppMainColumn(
                    child: Column(
                      children: [
                        AppBackHeader(title: 'Community', onBack: _back),
                        Expanded(
                          child: Center(
                            child: SingleChildScrollView(
                              child: CommunityUnavailableView(
                                onUnpin: state.pinned ? _togglePin : null,
                                busy: state.pinBusy,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                if (state.status == CommunityDetailStatus.error &&
                    state.community == null &&
                    state.error != null) {
                  return AppMainColumn(
                    child: Column(
                      children: [
                        AppBackHeader(title: 'Community', onBack: _back),
                        Expanded(
                          child: Center(
                            child: SingleChildScrollView(
                              child: AppErrorView(
                                error: state.error!,
                                onRetry: () {
                                  _detail.load();
                                  _timeline.load();
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                final headerSlivers = <Widget>[
                  SliverToBoxAdapter(
                    child: AppBackHeader(
                      title: state.community?.name ?? 'Community',
                      onBack: _back,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: CommunityHeader(
                      state: state,
                      onMembers: () => context.push(
                        AppRouter.communityMembersPath(widget.communityId),
                      ),
                      onJoin: _join,
                      onLeave: _leave,
                      onTogglePin: _togglePin,
                      onRetry: _detail.load,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: AppTabBar(
                      tabs: const [
                        AppTab(label: 'Posts'),
                        AppTab(label: 'About'),
                      ],
                      selectedIndex: _tab,
                      equalWidth: true,
                      semanticLabel: 'Community sections',
                      onChanged: (i) => setState(() => _tab = i),
                    ),
                  ),
                ];
                if (_tab == 1) {
                  return AppMainColumn(
                    child: RefreshIndicator(
                      onRefresh: _detail.load,
                      child: CustomScrollView(
                        slivers: [
                          ...headerSlivers,
                          ...communityAboutSlivers(context, state),
                        ],
                      ),
                    ),
                  );
                }
                return TimelineFeedView(
                  viewerUserId: viewerUserId,
                  emptyTitle: 'No posts yet',
                  emptySubtitle:
                      'Posts in this Community will show up here. Counts and '
                      'posts update when you refresh.',
                  fillViewport: true,
                  showPending: false,
                  newPostsPillTop: AppSize.headerRow + AppSpacing.sm,
                  unavailableView: const CommunityUnavailableView(),
                  headerSlivers: headerSlivers,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
