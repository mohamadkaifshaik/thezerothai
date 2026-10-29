import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../core/widgets/scroll_constants.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../shared/widgets/app_notice_banner.dart';
import '../../../../shared/widgets/post_card.dart';
import '../../../../shared/widgets/post_list_skeleton.dart';
import '../../../../shared/widgets/protected_post_box.dart';
import '../../../moderation/domain/reports_feature_flag.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../domain/engagement_entry.dart';
import '../../domain/engagement_feature_flag.dart';
import '../bloc/bookmarks_cubit.dart';
import '../bloc/engagement_cubit.dart';

/// The scrolling list of one History tab (plan W2-7 / W3-18): live
/// [PostCard] rows over a `CustomScrollView` with pull to refresh, a skeleton
/// while the first page loads, the error / not-available / empty states, a
/// banner for a failed refresh or page, and prefetching of the next page.
/// Display only: the Bookmarks and Likes tabs map their cubit's state onto it
/// and own everything else (the snackbars, the cubit).
///
/// - A scroll past [kPrefetchFraction] calls [onLoadMore]; so does every
///   rebuild whose rows do not fill the screen (a short page: there is nothing
///   to scroll), once laid out. The cubit guards concurrent calls.
/// - A failed refresh sits on top; a failed next page ([noticeFromPaging]) at
///   the end of the list, where the user is. The banner's Retry exists unless
///   a retry cannot help (`noticeCanRetry`).
/// - A row has a stable `ValueKey('<rowKeyPrefix>-<target id>')`, so a row
///   keeps its identity across a refresh and an unlike.
/// - [endNote] replaces the plain space under the last row once there is no
///   next page.
class HistoryPostList extends StatefulWidget {
  const HistoryPostList({
    super.key,
    required this.rows,
    required this.loading,
    required this.loadingMore,
    required this.hasMore,
    required this.rowKeyPrefix,
    required this.loadingLabel,
    required this.noticeMessage,
    required this.empty,
    required this.unavailable,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onReload,
    required this.onRetryNotice,
    required this.withheldAction,
    this.error,
    this.notice,
    this.noticeFromPaging = false,
    this.bookmarkEnabled,
    this.endNote,
  });

  /// The rows to draw, newest first.
  final List<pb.PostView> rows;

  /// The first page is on its way: the skeleton.
  final bool loading;

  /// A next page is on its way: the spinner under the rows.
  final bool loadingMore;

  /// More pages exist. With no row yet, the next page is on its way and the
  /// list does not claim to be empty.
  final bool hasMore;

  /// Why the first page failed; [unavailable] when it is a
  /// [FeatureDisabledException].
  final AppException? error;

  /// A refresh or page failed while rows are on screen.
  final AppException? notice;

  /// The failure behind [notice] was a next page.
  final bool noticeFromPaging;

  final String rowKeyPrefix;
  final String loadingLabel;

  /// The words of the banner for an error.
  final String Function(AppException error) noticeMessage;

  /// Shown when the list ends with no row.
  final Widget empty;

  /// Shown instead of the list when the feature is switched off for everyone.
  final Widget unavailable;

  /// Under the last row when there is no next page; null: plain space.
  final Widget? endNote;

  /// Whether the card shows the bookmark icon: null follows the `bookmarks`
  /// flag, true always (the Bookmarks tab: a caller dropped from the allowlist
  /// can still remove what they saved).
  final bool? bookmarkEnabled;

  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;

  /// The error view's Retry (the first page again).
  final VoidCallback onReload;

  /// The banner's Retry.
  final VoidCallback onRetryNotice;

  /// What a withheld row (`PostView.withheld`, W3-41b) offers: Unlike on the
  /// Likes tab, Remove bookmark on the Bookmarks tab.
  final WithheldAction withheldAction;

  @override
  State<HistoryPostList> createState() => _HistoryPostListState();
}

/// The one action of a withheld History row.
enum WithheldAction {
  /// The Likes tab: `EngagementCubit.setLiked(liked: false)`. Offered with the
  /// `engagement` flag, like the heart on a card.
  unlike('Unlike'),

  /// The Bookmarks tab: `BookmarksCubit.setBookmarked(saved: false)`. Always
  /// offered (a removal works while the flag is not globally off, ADR-0023 D5).
  removeBookmark('Remove bookmark');

  const WithheldAction(this.label);

  final String label;
}

/// A row of the caller's own Likes or Bookmarks whose post is by a protected
/// author the caller can no longer see (W3-41b): the author in a
/// [ProtectedPostBox] and one action. The server sent the post stripped to its
/// id, kind and author, with the viewer flag still true. The action only
/// dispatches to the session cubit; the list's cubit hides the row at once and
/// brings it back, with the failure's snackbar, if the request fails.
class _WithheldRow extends StatelessWidget {
  const _WithheldRow({
    required this.view,
    required this.action,
    required this.engagementEnabled,
  });

  final pb.PostView view;
  final WithheldAction action;
  final bool engagementEnabled;

  void _run(BuildContext context) {
    final target = engagementTargetId(view.post);
    if (target.isEmpty) return;
    switch (action) {
      case WithheldAction.unlike:
        unawaited(
          context.read<EngagementCubit>().setLiked(
            target,
            liked: false,
            shown: EngagementEntry.fromView(view),
          ),
        );
      case WithheldAction.removeBookmark:
        unawaited(
          context.read<BookmarksCubit>().setBookmarked(
            target,
            view,
            saved: false,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final offered =
        action == WithheldAction.removeBookmark || engagementEnabled;
    final handle = view.post.author.handle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.smd,
        AppSpacing.md,
        AppSpacing.smd,
      ),
      child: ProtectedPostBox(
        author: view.post.author,
        actionLabel: offered ? action.label : null,
        actionSemanticLabel: "${action.label}, @$handle's post",
        onAction: offered ? () => _run(context) : null,
      ),
    );
  }
}

class _HistoryPostListState extends State<HistoryPostList> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_maybeLoadMore);
  }

  @override
  void didUpdateWidget(HistoryPostList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // After every change of the rows, once laid out: fill a screen the rows
    // do not fill.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  /// Asks for the next page when the user is near the end, or when the rows
  /// do not fill the screen.
  void _maybeLoadMore() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final max = position.maxScrollExtent;
    if (max <= 0 || position.pixels >= kPrefetchFraction * max) {
      widget.onLoadMore();
    }
  }

  static String _targetOf(pb.PostView view) => engagementTargetId(view.post);

  String _rowKey(pb.PostView view) =>
      '${widget.rowKeyPrefix}-${_targetOf(view)}';

  @override
  Widget build(BuildContext context) {
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    final engagementEnabled = isFeatureEnabled(context, kFeatureEngagement);
    final reportsEnabled = isFeatureEnabled(context, kFeatureReports);
    final notice = widget.notice;
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: CustomScrollView(
        controller: _controller,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // A failed refresh sits on top; a failed next page at the end of
          // the list, where the user is.
          if (notice != null &&
              (!widget.noticeFromPaging || widget.rows.isEmpty))
            SliverToBoxAdapter(child: _notice(notice)),
          ..._body(viewerUserId, engagementEnabled, reportsEnabled),
        ],
      ),
    );
  }

  Widget _notice(AppException notice) {
    return AppNoticeBanner(
      message: widget.noticeMessage(notice),
      onRetry: noticeCanRetry(notice) ? widget.onRetryNotice : null,
    );
  }

  List<Widget> _body(
    String? viewerUserId,
    bool engagementEnabled,
    bool reportsEnabled,
  ) {
    if (widget.loading) {
      return [
        SliverToBoxAdapter(
          child: PostListSkeleton(
            rows: 4,
            mediaEvery: 0,
            semanticsLabel: widget.loadingLabel,
          ),
        ),
      ];
    }
    final error = widget.error;
    if (error != null) {
      if (error is FeatureDisabledException) {
        return [SliverToBoxAdapter(child: widget.unavailable)];
      }
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AppErrorView(error: error, onRetry: widget.onReload),
        ),
      ];
    }
    final rows = widget.rows;
    if (rows.isEmpty) {
      // No row yet but more pages (the server dropped a whole page): the next
      // page is on its way, so no "empty" claim.
      if (widget.hasMore) {
        return [SliverToBoxAdapter(child: _footer(pending: true))];
      }
      return [SliverToBoxAdapter(child: widget.empty)];
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
          // The server withheld this row: its post is by a protected author
          // the caller can no longer see (W3-41b). The box and its one undo
          // action; nothing opens, there is no card and no action row.
          if (view.withheld) {
            return Column(
              key: ValueKey(_rowKey(view)),
              mainAxisSize: MainAxisSize.min,
              children: [
                _WithheldRow(
                  view: view,
                  action: widget.withheldAction,
                  engagementEnabled: engagementEnabled,
                ),
                const Divider(height: 1),
              ],
            );
          }
          return Column(
            key: ValueKey(_rowKey(view)),
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () => context.push(AppRouter.postPath(_targetOf(view))),
                child: PostCard(
                  view: view,
                  viewerUserId: viewerUserId,
                  // Block / Mute / Delete have no place on a saved list.
                  graphActionsEnabled: false,
                  reportsEnabled: reportsEnabled,
                  engagementEnabled: engagementEnabled,
                  bookmarkEnabled: widget.bookmarkEnabled,
                ),
              ),
              const Divider(height: 1),
            ],
          );
        },
      ),
      SliverToBoxAdapter(child: _footer()),
    ];
  }

  /// Under the rows: a failed next page's banner, a spinner while a page is
  /// on its way ([pending]: there are no rows yet, more pages exist), the end
  /// note once there is no next page, else plain space.
  Widget _footer({bool pending = false}) {
    final notice = widget.notice;
    if (notice != null && widget.noticeFromPaging) {
      // With no row the banner already sits on top (see build): not twice.
      return pending ? const SizedBox.shrink() : _notice(notice);
    }
    if (widget.loadingMore || pending) {
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
    final note = widget.endNote;
    if (note != null && !widget.hasMore) return note;
    return const SizedBox(height: AppSpacing.lg);
  }
}
