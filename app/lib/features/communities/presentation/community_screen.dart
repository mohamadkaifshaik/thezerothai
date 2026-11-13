import 'widgets/community_side_boxes.dart';
import '../../../core/widgets/shell_side_column.dart';

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
import 'widgets/community_cover_band.dart';
import 'widgets/community_header.dart';
import 'widgets/community_hero.dart';
import 'widgets/community_unavailable_view.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../core/widgets/shell_fab.dart';

/// `/communities/:id`: header, then Posts and About tabs.
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
/// - "Post" in the header opens `/compose?community=<id>` with this
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
  /// `viewer_role` says the caller moderates; null otherwise. The
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

  /// Whether the cover band has scrolled up past the status bar (see
  /// [_withStatusScrim]).
  final _bandGone = ValueNotifier<bool>(false);

  /// Under the status bar the band is the page's top. Once it scrolls away,
  /// the posts would pass under the status icons: a page-colour strip as tall
  /// as the top inset (none without an inset) takes the place of the band
  /// there. It is not a sliver of the scroll view (a pinned one would sit in
  /// the flow under the band): a listener on the page's own vertical scroll
  /// shows it.
  Widget _withStatusScrim(BuildContext context, Widget page) {
    final top = MediaQuery.paddingOf(context).top;
    if (top <= 0) return page;
    return Stack(
      children: [
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.depth == 0 &&
                  n.metrics.axis == Axis.vertical &&
                  (n is ScrollUpdateNotification ||
                      n is ScrollEndNotification)) {
                _bandGone.value = n.metrics.pixels > kCommunityCoverBandHeight;
              }
              return false;
            },
            child: page,
          ),
        ),
        PositionedDirectional(
          top: 0,
          start: 0,
          end: 0,
          height: top,
          child: ValueListenableBuilder<bool>(
            valueListenable: _bandGone,
            builder: (context, gone, _) => gone
                ? IgnorePointer(
                    child: ColoredBox(
                      key: const ValueKey('community-status-scrim'),
                      color: Theme.of(context).colorScheme.surface,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
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
    _sideColumn.dispose();
    _bandGone.dispose();
    _moderation.close();
    _timeline.close();
    _detail.close();
    super.dispose();
  }

  void _openModerationLog() =>
      context.push(AppRouter.communityModerationLogPath(widget.communityId));

  /// The "Post" entry: the header's own rule plus the caller's flags.
  bool _canCompose(BuildContext context, CommunityDetailState state) {
    final profile = context.read<OnboardingBloc>().state.profile;
    return CommunityHeader.communityComposeAllowed(state) &&
        isFeatureEnabled(context, kFeaturePosts) &&
        !(profile?.isPrivate ?? false);
  }

  void _composeHere() =>
      context.push(AppRouter.composeCommunityPath(widget.communityId));

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
    final confirmed = await showAppMaterialDialog<bool>(
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

  /// The shared report sheet with the Community target. The owner is
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

  /// The desktop Community mock's Rules and Moderators boxes, in the shell's
  /// side column.
  final _sideColumn = ShellSideColumnLease();

  @override
  Widget build(BuildContext context) {
    _sideColumn.set(
      context,
      active: true,
      builder: (_) => CommunitySideBoxes(detail: _detail),
    );
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
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
        // The phone's floating button posts into this community.
        child: BlocBuilder<CommunityDetailCubit, CommunityDetailState>(
          builder: (context, state) => ShellFab(
            action: _canCompose(context, state)
                ? ShellFabAction(
                    tooltip:
                        'Post in ${state.community?.name ?? 'this Community'}',
                    icon: Icons.edit_outlined,
                    onPressed: _composeHere,
                  )
                : null,
            child: Scaffold(
              // The cover band draws under the status bar, so the page does not
              // pad the top itself; the plain states below do.
              body: SafeArea(
                top: false,
                // The floating bar overlays the page: the scroll view runs
                // behind it and ends with the bar's inset.
                bottom: false,
                child: BlocBuilder<CommunityDetailCubit, CommunityDetailState>(
                  builder: (context, state) {
                    if (state.status == CommunityDetailStatus.unavailable) {
                      return SafeArea(
                        bottom: false,
                        child: AppMainColumn(
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
                        ),
                      );
                    }
                    if (state.status == CommunityDetailStatus.error &&
                        state.community == null &&
                        state.error != null) {
                      return SafeArea(
                        bottom: false,
                        child: AppMainColumn(
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
                    // The options menu: on the cover band's navy a pearl circle,
                    // on the tablet and desktop bar a plain icon.
                    Widget? options({required bool onBand}) => showReport
                        ? PopupMenuButton<String>(
                            tooltip: 'Community options',
                            padding: EdgeInsets.zero,
                            // As an icon button, so it keeps the button role.
                            icon: onBand
                                ? CommunityBandAction.circle(Icons.more_horiz)
                                : const Icon(Icons.more_horiz),
                            style: onBand
                                ? IconButton.styleFrom(
                                    foregroundColor: AppPalette.pearl,
                                  )
                                : null,
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
                          )
                        : null;
                    final headerSlivers = <Widget>[
                      SliverToBoxAdapter(
                        // Spans the pane on the tablet layout (as the bar's divider
                        // did).
                        child: wide
                            ? CommunityTopBar(
                                onBack: _back,
                                action: options(onBand: false),
                              )
                            : AppFullBleed(
                                child: CommunityCoverBand(
                                  onBack: _back,
                                  action: options(onBand: true),
                                ),
                              ),
                      ),
                      SliverToBoxAdapter(
                        child: CommunityHeader(
                          state: state,
                          wide: wide,
                          onCompose: _canCompose(context, state)
                              ? _composeHere
                              : null,
                          onModerationLog:
                              state.community?.role.canModerate == true
                              ? _openModerationLog
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
                          onChanged: (i) {
                            _bandGone.value = false;
                            setState(() => _tab = i);
                          },
                        ),
                      ),
                    ];
                    final Widget page;
                    if (_tab == 1) {
                      page = AppMainColumn(
                        // On the tablet layout the scroll view spans the pane,
                        // as on the Posts tab (`TimelineFeedView`): a drag, a
                        // wheel or the scrollbar beside the column reach it,
                        // and the header's divider and the tab hairline reach
                        // the pane's edges. Its slivers keep to the column.
                        // Elsewhere this is today's column.
                        scrollsAcrossPane: true,
                        child: Builder(
                          builder: (context) {
                            final inset = AppMainColumnBleed.of(context);
                            Widget centred(Widget sliver) => SliverPadding(
                              padding: EdgeInsets.symmetric(horizontal: inset),
                              sliver: AppMainColumnBleed(
                                bleed: inset,
                                child: sliver,
                              ),
                            );
                            return RefreshIndicator(
                              onRefresh: _detail.load,
                              child: CustomScrollView(
                                slivers: [
                                  for (final sliver in [
                                    ...headerSlivers,
                                    ...communityAboutSlivers(context, state),
                                  ])
                                    centred(sliver),
                                  const ShellBottomInsetSliver(),
                                ],
                              ),
                            );
                          },
                        ),
                      );
                    } else {
                      page = TimelineFeedView(
                        viewerUserId: viewerUserId,
                        emptyTitle: 'No posts yet',
                        emptySubtitle:
                            'Posts in this Community will show up here. Counts and '
                            'posts update when you refresh.',
                        fillViewport: true,
                        showPending: false,
                        newPostsPillTop:
                            MediaQuery.paddingOf(context).top +
                            AppSpacing.sm +
                            4,
                        unavailableView: const CommunityUnavailableView(),
                        headerSlivers: headerSlivers,
                        moderationControl: _moderationControl(state),
                      );
                    }
                    return _withStatusScrim(context, page);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
