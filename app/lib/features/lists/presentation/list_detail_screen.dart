import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../messages/presentation/report_conversation.dart'
    show thankForReport;
import '../../moderation/domain/reports_feature_flag.dart';
import '../../moderation/presentation/report_sheet.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../posts/data/posts_repository.dart';
import '../../timeline/data/timeline_repository.dart';
import '../../timeline/domain/feed_key.dart';
import '../../timeline/presentation/bloc/timeline_cubit.dart';
import '../../timeline/presentation/bloc/timeline_state.dart';
import '../../timeline/presentation/timeline_feed_view.dart';
import '../data/home_tabs_repository.dart';
import '../data/lists_repository.dart';
import '../domain/lists_feature_flag.dart';
import 'bloc/list_detail_cubit.dart';
import 'bloc/list_detail_state.dart';
import '../../../shared/widgets/app_menu_item_row.dart';
import 'lists_error_messages.dart';
import 'widgets/list_detail_header.dart';
import 'widgets/list_editor_sheet.dart';
import 'widgets/list_unavailable_view.dart';

/// `/lists/:id` (W5-12): the List's header and its timeline.
///
/// - The timeline is the shared [TimelineFeedView] over a
///   `TimelineCubit(FeedKey.list(id))`: cache first, `since_token` refreshes,
///   the "new posts" pill, gaps, `removed_ids`. Short pages that still carry a
///   token are followed (`fillViewport`). Refreshes are throttled to one per
///   minute by the cubit; there is no polling.
/// - The header comes from the timeline's answer (it carries the List's
///   header), with one `GetList` only when none is known.
/// - NOT_FOUND from either RPC replaces the screen with "This List is
///   unavailable" (and Unpin when pinned); one text for every cause.
/// - Edit is the owner's; Pin / Unpin is saved with one `SetHomeTabs`.
class ListDetailScreen extends StatefulWidget {
  const ListDetailScreen({super.key, required this.listId});

  final String listId;

  @override
  State<ListDetailScreen> createState() => _ListDetailScreenState();
}

class _ListDetailScreenState extends State<ListDetailScreen> {
  late final ListsRepository _lists = context.read<ListsRepository>();
  late final ListDetailCubit _detail = ListDetailCubit(
    listId: widget.listId,
    lists: _lists,
    tabs: context.read<HomeTabsRepository>(),
  );
  late final TimelineCubit _timeline = TimelineCubit(
    feed: FeedKey.list(widget.listId),
    timeline: context.read<TimelineRepository>(),
    posts: context.read<PostsRepository>(),
    viewerUserId: context.read<OnboardingBloc>().state.profile?.userId,
  );

  @override
  void initState() {
    super.initState();
    // `load` returns after its refresh, which brings the header; only when it
    // did not, make the one `GetList`.
    _timeline.load().then((_) => _detail.ensureHeader());
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
      context.go(AppRouter.listsPath);
    }
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _togglePin() async {
    final error = await _detail.togglePin();
    if (error != null && mounted) _say(listsErrorMessage(error));
  }

  Future<void> _edit() async {
    final header = _detail.state.header;
    if (header == null) return;
    final outcome = await showListEditor(
      context,
      repository: _lists,
      existing: header,
    );
    if (outcome?.deletedId != null && mounted) _back();
  }

  /// W5-48: the shared report sheet with the List target. NOT_FOUND (a List
  /// the viewer cannot see), the reports quota and VALIDATION `target_id`
  /// (own List) are mapped inside the sheet (`reportErrorMessage`).
  Future<void> _report() async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await showReportSheet(
      context,
      targetType: ReportTargetType.REPORT_TARGET_TYPE_LIST,
      targetId: widget.listId,
      subject: 'this List',
    );
    thankForReport(messenger, outcome);
  }

  @override
  Widget build(BuildContext context) {
    final canReport =
        isFeatureEnabled(context, kFeatureReports) &&
        isFeatureEnabled(context, kFeatureLists);
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    _timeline.viewerUserId = viewerUserId;
    return MultiBlocProvider(
      providers: [
        BlocProvider<TimelineCubit>.value(value: _timeline),
        BlocProvider<ListDetailCubit>.value(value: _detail),
      ],
      child: BlocListener<TimelineCubit, TimelineState>(
        listenWhen: (before, after) => after.unavailable && !before.unavailable,
        listener: (context, _) => _detail.markUnavailable(),
        child: Scaffold(
          body: SafeArea(
            child: BlocBuilder<ListDetailCubit, ListDetailState>(
              builder: (context, state) {
                if (state.status == ListDetailStatus.unavailable) {
                  return AppMainColumn(
                    child: Column(
                      children: [
                        AppBackHeader(title: 'List', onBack: _back),
                        Expanded(
                          child: Center(
                            child: SingleChildScrollView(
                              child: ListUnavailableView(
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
                final header = state.header;
                final isOwner =
                    header != null &&
                    viewerUserId != null &&
                    header.owner.userId == viewerUserId;
                // Not the owner's own List (the server answers VALIDATION);
                // without a known viewer the entry stays hidden.
                final showReport =
                    canReport &&
                    header != null &&
                    viewerUserId != null &&
                    !isOwner;
                return TimelineFeedView(
                  viewerUserId: viewerUserId,
                  emptyTitle: 'No posts yet',
                  emptySubtitle:
                      'Posts from people on this List will show up here.',
                  fillViewport: true,
                  showPending: false,
                  newPostsPillTop: AppSize.headerRow + AppSpacing.sm,
                  headerSlivers: [
                    SliverToBoxAdapter(
                      child: AppBackHeader(
                        title: header?.name ?? 'List',
                        onBack: _back,
                        actions: [
                          if (showReport)
                            PopupMenuButton<String>(
                              tooltip: 'More options',
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
                                    label: 'Report List',
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: ListDetailHeader(
                        state: state,
                        isOwner: isOwner,
                        onMembers: () => context.push(
                          AppRouter.listMembersPath(widget.listId),
                        ),
                        onOwner: () => context.push(
                          AppRouter.profilePath(header!.owner.handle),
                        ),
                        onTogglePin: _togglePin,
                        onEdit: _edit,
                        onRetry: _detail.ensureHeader,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
