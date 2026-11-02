import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/post/post_moderation_control.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_menu_item_row.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../lists/data/home_tabs_repository.dart';
import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart'
    show ReportTargetType;
import '../../moderation/domain/reports_feature_flag.dart';
import '../../moderation/presentation/report_sheet.dart';
import '../../messages/presentation/report_conversation.dart'
    show thankForReport;
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../posts/data/posts_repository.dart';
import '../../posts/domain/posts_feature_flag.dart';
import '../../timeline/data/timeline_repository.dart';
import '../../timeline/domain/feed_key.dart';
import '../../timeline/presentation/bloc/timeline_cubit.dart';
import '../../timeline/presentation/bloc/timeline_state.dart';
import '../../timeline/presentation/timeline_feed_view.dart';
import '../data/communities_repository.dart';
import '../domain/communities_feature_flag.dart';
import '../domain/community_role.dart';
import 'bloc/community_detail_cubit.dart';
import 'bloc/community_detail_state.dart';
import 'bloc/community_moderation_cubit.dart';
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
/// - "Post" in the header (W5-34) opens `/compose?community=<id>` with this
///   community preselected, only for a joined, not archived community, a
///   caller who may post (`posts` on) and who is not protected (the server
///   answers PROTECTED_ACCOUNT to a community post). The composer still
///   checks membership against the server's list.
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

  late final CommunityModerationCubit _moderation;

  /// "Remove from Community" for the post menus, only while the server's
  /// `viewer_role` says the caller moderates (W5-35); null otherwise. The
  /// post leaves the feed at once and comes back if the call fails; other
  /// devices follow at their next refresh (`removed_ids`).
  PostModerationControl? _moderationControl(CommunityDetailState state) {
    final community = state.community;
    if (community == null || !community.role.canModerate) return null;
    return PostModerationControl(
      communityId: widget.communityId,
      communityName: community.name,
      onHide: (postId) async {
        _timeline.hidePostLocally(postId);
        final error = await _moderation.hidePost(postId);
        if (error != null) {
          _timeline.showPostAgain(postId);
          throw error;
        }
      },
      onRestore: (postId) async {
        final error = await _moderation.restorePost(postId);
        if (error != null) throw error;
        _timeline.showPostAgain(postId);
      },
    );
  }

  /// 0 = Posts, 1 = About (ephemeral UI state).
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _moderation = CommunityModerationCubit(
      communityId: widget.communityId,
      communities: context.read<CommunitiesRepository>(),
    );
    _detail.load();
    _timeline.load();
  }

  @override
  void dispose() {
    _moderation.close();
    _timeline.close();
    _detail.close();
    super.dispose();
  }

  /// The "Post" entry: the header's own rule plus the caller's flags.
  bool _canCompose(BuildContext context, CommunityDetailState state) {
    final profile = context.read<OnboardingBloc>().state.profile;
    return CommunityHeader.communityComposeAllowed(state) &&
        isFeatureEnabled(context, kFeaturePosts) &&
        !(profile?.isPrivate ?? false);
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

  /// W5-35b: the shared report sheet with the Community target. The owner is
  /// refused by the server (VALIDATION `target_id`), so the entry is hidden
  /// for them; NOT_FOUND shows [kReportCommunityNotFound] in the sheet.
  Future<void> _report() async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await showReportSheet(
      context,
      targetType: ReportTargetType.REPORT_TARGET_TYPE_COMMUNITY,
      targetId: widget.communityId,
      subject: _detail.state.community?.name ?? 'this Community',
      notFoundMessage: kReportCommunityNotFound,
    );
    thankForReport(messenger, outcome);
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
                // Both flags, and a role from `viewer_role` that is not the
                // owner (the server answers VALIDATION to the owner).
                final showReport =
                    isFeatureEnabled(context, kFeatureReports) &&
                    isFeatureEnabled(context, kFeatureCommunities) &&
                    state.community != null &&
                    !state.community!.role.isOwner;
                final headerSlivers = <Widget>[
                  SliverToBoxAdapter(
                    child: AppBackHeader(
                      title: state.community?.name ?? 'Community',
                      onBack: _back,
                      actions: [
                        if (showReport)
                          PopupMenuButton<String>(
                            tooltip: 'Community options',
                            icon: const Icon(Icons.more_horiz),
                            style: IconButton.styleFrom(
                              minimumSize: const Size.square(
                                AppSpacing.minTapTarget,
                              ),
                            ),
                            onSelected: (_) => _report(),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'report',
                                child: AppMenuItemRow(
                                  icon: Icons.flag_outlined,
                                  label: 'Report Community',
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: CommunityHeader(
                      state: state,
                      onCompose: _canCompose(context, state)
                          ? () => context.push(
                              AppRouter.composeCommunityPath(
                                widget.communityId,
                              ),
                            )
                          : null,
                      onModerationLog: state.community?.role.canModerate == true
                          ? () => context.push(
                              AppRouter.communityModerationLogPath(
                                widget.communityId,
                              ),
                            )
                          : null,
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
                  moderationControl: _moderationControl(state),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
