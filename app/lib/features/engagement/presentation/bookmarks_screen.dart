import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_notice_banner.dart';
import '../../../shared/widgets/app_tab_bar.dart';
import '../../../shared/widgets/post_card.dart';
import '../../../shared/widgets/post_list_skeleton.dart';
import '../../moderation/domain/reports_feature_flag.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../data/bookmarks_repository.dart';
import '../domain/engagement_entry.dart';
import '../domain/engagement_feature_flag.dart';
import 'bloc/bookmarks_list_cubit.dart';
import 'bloc/bookmarks_list_state.dart';
import 'bloc/engagement_state.dart' show EngagementAction;
import 'engagement_error_messages.dart';

/// Empty list: a heading and one line of guidance (our own wording).
const kBookmarksEmptyTitle = 'Save posts for later';
const kBookmarksEmptyBody = 'Tap the bookmark on a post to keep it here.';

/// Shown instead of the list when the server answers FEATURE_DISABLED
/// (bookmarks are switched off for everyone): no Retry, pull down to check
/// again.
const kBookmarksUnavailableBody = 'Please check back later.';

/// `/bookmarks` (W2-7, ADR-0023): the caller's saved posts, newest bookmark
/// first, as live post cards (current counts and the engagement row, not
/// snapshots). Reached from the drawer row and the rail destination (both need
/// the `bookmarks` flag) and from the "View" action of the bookmark toast.
///
/// - The route needs only the `posts` flag: listing and removing work while
///   `bookmarks` is not globally off (D5), so the bookmark icon is always
///   offered here, even to a caller dropped from the allowlist. Without the
///   `engagement` flag there is no action row and so no way to un-bookmark.
/// - Every open asks the server for page 1 (no cache, no `since`); a scroll
///   past [kPrefetchFraction] asks for the next page. Pages can be short or
///   empty while a token exists, so the screen also asks again whenever the
///   rows do not fill it.
/// - Un-bookmarking a row removes it with an "Removed from Bookmarks" Undo
///   snackbar; a failure puts it back with the reason.
/// - Display only: the rows come from [BookmarksListCubit].
class BookmarksScreen extends StatelessWidget {
  const BookmarksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<BookmarksListCubit>(
      create: (context) => BookmarksListCubit(
        repository: context.read<BookmarksRepository>(),
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      )..load(),
      child: const _BookmarksView(),
    );
  }
}

class _BookmarksView extends StatefulWidget {
  const _BookmarksView();

  @override
  State<_BookmarksView> createState() => _BookmarksViewState();
}

class _BookmarksViewState extends State<_BookmarksView> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  /// Asks for the next page when the user is near the end, or when the rows
  /// do not fill the screen (a short page: there is nothing to scroll).
  void _maybeLoadMore() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final max = position.maxScrollExtent;
    if (max <= 0 || position.pixels >= kPrefetchFraction * max) {
      unawaited(context.read<BookmarksListCubit>().loadMore());
    }
  }

  /// Back to where the user came from; with no history (a deep link) Home.
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  void _showRemoval(BuildContext context, BookmarkRemoval removal) {
    final cubit = context.read<BookmarksListCubit>();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Removed from Bookmarks'),
          // An Undo has no use after a few seconds: do not keep it.
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(cubit.restore(removal.view)),
          ),
        ),
      );
    cubit.removalShown();
  }

  void _showFailure(BuildContext context, BookmarkListFailure failure) {
    final cubit = context.read<BookmarksListCubit>();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            engagementErrorMessage(
              failure.error,
              action: failure.saving
                  ? EngagementAction.bookmark
                  : EngagementAction.unbookmark,
            ),
          ),
        ),
      );
    cubit.failureShown();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<BookmarksListCubit>();
    final cards = _CardSettings(
      viewerUserId: context.select(
        (OnboardingBloc bloc) => bloc.state.profile?.userId,
      ),
      engagementEnabled: isFeatureEnabled(context, kFeatureEngagement),
      reportsEnabled: isFeatureEnabled(context, kFeatureReports),
    );
    return MultiBlocListener(
      listeners: [
        BlocListener<BookmarksListCubit, BookmarksListState>(
          listenWhen: (before, after) =>
              after.removal != null &&
              before.removal?.serial != after.removal!.serial,
          listener: (context, state) => _showRemoval(context, state.removal!),
        ),
        BlocListener<BookmarksListCubit, BookmarksListState>(
          listenWhen: (before, after) =>
              after.failure != null &&
              before.failure?.serial != after.failure!.serial,
          listener: (context, state) => _showFailure(context, state.failure!),
        ),
        // After every change of the rows, once laid out: fill a screen the
        // rows do not fill.
        BlocListener<BookmarksListCubit, BookmarksListState>(
          listener: (context, state) => WidgetsBinding.instance
              .addPostFrameCallback((_) => _maybeLoadMore()),
        ),
      ],
      child: Scaffold(
        body: SafeArea(
          child: AppMainColumn(
            child: Column(
              children: [
                AppBackHeader(title: 'Bookmarks', onBack: _back),
                AppTabBar(
                  semanticLabel: 'Bookmarks',
                  selectedIndex: 0,
                  onChanged: (_) {},
                  tabs: const [
                    AppTab(label: 'Bookmarks', icon: Icons.bookmark_border),
                  ],
                ),
                Expanded(
                  child: BlocBuilder<BookmarksListCubit, BookmarksListState>(
                    builder: (context, state) => RefreshIndicator(
                      onRefresh: cubit.refresh,
                      child: CustomScrollView(
                        controller: _controller,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          // A failed refresh sits on top; a failed next page
                          // at the end of the list, where the user is.
                          if (state.notice != null &&
                              (!cubit.noticeFromPaging ||
                                  state.visibleItems.isEmpty))
                            SliverToBoxAdapter(child: _notice(state, cubit)),
                          ..._body(state, cubit, cards),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _notice(BookmarksListState state, BookmarksListCubit cubit) {
    return AppNoticeBanner(
      message: bookmarksListNoticeMessage(state.notice!),
      onRetry: noticeCanRetry(state.notice!) ? cubit.retry : null,
    );
  }

  List<Widget> _body(
    BookmarksListState state,
    BookmarksListCubit cubit,
    _CardSettings cards,
  ) {
    switch (state.status) {
      case BookmarksListStatus.loading:
        return const [
          SliverToBoxAdapter(
            child: PostListSkeleton(
              rows: 4,
              mediaEvery: 0,
              semanticsLabel: 'Loading bookmarks',
            ),
          ),
        ];
      case BookmarksListStatus.error:
        final error = state.error!;
        if (error is FeatureDisabledException) {
          return const [
            SliverToBoxAdapter(
              child: AppEmptyView(
                icon: Icons.bookmark_border,
                title: kBookmarksUnavailableTitle,
                subtitle: kBookmarksUnavailableBody,
              ),
            ),
          ];
        }
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: AppErrorView(error: error, onRetry: cubit.load),
          ),
        ];
      case BookmarksListStatus.ready:
      case BookmarksListStatus.loadingMore:
        final rows = state.visibleItems;
        if (rows.isEmpty) {
          // No row yet but more pages (the server dropped a whole page): the
          // next page is on its way, so no "empty" claim.
          if (state.hasMore) {
            return [
              SliverToBoxAdapter(child: _footer(state, cubit, pending: true)),
            ];
          }
          return const [
            SliverToBoxAdapter(
              child: AppEmptyView(
                icon: Icons.bookmark_border,
                title: kBookmarksEmptyTitle,
                subtitle: kBookmarksEmptyBody,
              ),
            ),
          ];
        }
        return [
          SliverList.builder(
            itemCount: rows.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final index = rows.indexWhere((v) => _rowKey(v) == key.value);
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) {
              final view = rows[index];
              return Column(
                key: ValueKey(_rowKey(view)),
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: () =>
                        context.push(AppRouter.postPath(_targetOf(view))),
                    child: PostCard(
                      view: view,
                      viewerUserId: cards.viewerUserId,
                      // Block / Mute / Delete have no place on a saved list.
                      graphActionsEnabled: false,
                      reportsEnabled: cards.reportsEnabled,
                      engagementEnabled: cards.engagementEnabled,
                      // Remove works while the flag is not globally off.
                      bookmarkEnabled: true,
                    ),
                  ),
                  const Divider(height: 1),
                ],
              );
            },
          ),
          SliverToBoxAdapter(child: _footer(state, cubit)),
        ];
    }
  }

  static String _targetOf(pb.PostView view) => engagementTargetId(view.post);

  static String _rowKey(pb.PostView view) => 'bookmark-${_targetOf(view)}';

  /// Under the rows: a failed next page's banner, a spinner while a page is
  /// on its way ([pending]: there are no rows yet, more pages exist), else
  /// plain space.
  Widget _footer(
    BookmarksListState state,
    BookmarksListCubit cubit, {
    bool pending = false,
  }) {
    if (state.notice != null && cubit.noticeFromPaging) {
      // With no row the banner already sits on top (see build): not twice.
      return pending ? const SizedBox.shrink() : _notice(state, cubit);
    }
    if (state.status == BookmarksListStatus.loadingMore || pending) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(
          child: SizedBox(
            width: AppIconSize.md,
            height: AppIconSize.md,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return const SizedBox(height: AppSpacing.lg);
  }
}

/// What the cards need from the session's flags and profile, read once per
/// build.
class _CardSettings {
  const _CardSettings({
    required this.viewerUserId,
    required this.engagementEnabled,
    required this.reportsEnabled,
  });

  final String? viewerUserId;
  final bool engagementEnabled;
  final bool reportsEnabled;
}
