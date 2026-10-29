import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_tab_bar.dart';
import '../data/bookmarks_repository.dart';
import '../data/likes_repository.dart';
import '../domain/likes_list_feature_flag.dart';
import 'bloc/bookmarks_list_cubit.dart';
import 'bloc/bookmarks_list_state.dart';
import 'bloc/engagement_state.dart' show EngagementAction;
import 'engagement_error_messages.dart';
import 'likes_tab.dart';
import 'widgets/history_post_list.dart';

/// Empty list: a heading and one line of guidance (our own wording).
const kBookmarksEmptyTitle = 'Save posts for later';
const kBookmarksEmptyBody = 'Tap the bookmark on a post to keep it here.';

/// Shown instead of the list when the server answers FEATURE_DISABLED
/// (bookmarks are switched off for everyone): no Retry, pull down to check
/// again.
const kBookmarksUnavailableBody = 'Please check back later.';

/// The tabs of the History screen. The URL names the Likes tab with
/// `?tab=likes`; any other value (or none) is Bookmarks.
enum HistoryTab {
  bookmarks,
  likes;

  /// The tab a `/bookmarks?tab=<value>` link opens.
  static HistoryTab fromQuery(String? value) =>
      value == 'likes' ? HistoryTab.likes : HistoryTab.bookmarks;
}

/// `/bookmarks` (W2-7, ADR-0023; W3-18, ADR-0024 D6): the caller's History,
/// titled "History". The Bookmarks tab is their saved posts, newest bookmark
/// first; the Likes tab (only with the `likes_list` flag) is their most recent
/// likes. Both are live post cards (current counts and the engagement row,
/// not snapshots). Reached from the drawer row and the rail destination (both
/// need the `bookmarks` flag) and from the "View" action of the bookmark toast.
///
/// - The route needs only the `posts` flag: listing and removing work while
///   `bookmarks` is not globally off (D5), so the bookmark icon is always
///   offered here, even to a caller dropped from the allowlist. Without the
///   `engagement` flag there is no action row and so no way to un-bookmark.
/// - **Tabs.** With `likes_list` on for the caller (and the server not having
///   said otherwise) a tab bar Bookmarks | Likes shows; with it off there is
///   no tab bar at all and `?tab=likes` is ignored. A tab's cubit is created,
///   and asks the server, the first time the tab is selected; both tabs then
///   keep their rows and scroll position while the other is in front. If the
///   Likes list turns out to be unavailable the tab goes away and Bookmarks
///   shows.
/// - Every open asks the server for page 1 (no cache, no `since`); a scroll
///   past `kPrefetchFraction` asks for the next page. Pages can be short or
///   empty while a token exists, so the list also asks again whenever the
///   rows do not fill it.
/// - Un-bookmarking a row removes it with an "Removed from Bookmarks" Undo
///   snackbar; a failure puts it back with the reason.
/// - Display only: the rows come from [BookmarksListCubit] and
///   `LikesListCubit`.
class BookmarksScreen extends StatefulWidget {
  const BookmarksScreen({super.key, this.initialTab = HistoryTab.bookmarks});

  /// The tab a link asked for (`?tab=likes`); honoured only while the Likes
  /// tab is offered.
  final HistoryTab initialTab;

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  late HistoryTab _selected = widget.initialTab;

  /// The server refused the Likes list for good this visit: no Likes tab.
  bool _likesGone = false;

  /// The tabs the user has looked at: only those exist (and have asked the
  /// server for anything).
  final Set<HistoryTab> _opened = {};

  @override
  void didUpdateWidget(BookmarksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The same screen asked for another tab (the link changed only its query).
    if (oldWidget.initialTab != widget.initialTab) {
      _selected = widget.initialTab;
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

  void _likesUnavailable() {
    if (!mounted || _likesGone) return;
    setState(() {
      _likesGone = true;
      _selected = HistoryTab.bookmarks;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The repository is read only once the flag is on: the Likes machinery
    // does not exist for a caller without it.
    final likesOffered =
        isFeatureEnabled(context, kFeatureLikesList) &&
        !_likesGone &&
        context.read<LikesRepository>().available;
    final current = likesOffered ? _selected : HistoryTab.bookmarks;
    _opened.add(current);
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(title: 'History', onBack: _back),
              if (likesOffered)
                AppTabBar(
                  semanticLabel: 'History',
                  selectedIndex: current.index,
                  onChanged: (index) =>
                      setState(() => _selected = HistoryTab.values[index]),
                  tabs: const [
                    AppTab(label: 'Bookmarks'),
                    AppTab(label: 'Likes'),
                  ],
                ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_opened.contains(HistoryTab.bookmarks))
                      _TabSlot(
                        key: const ValueKey('history-bookmarks'),
                        visible: current == HistoryTab.bookmarks,
                        child: _BookmarksTab(
                          active: current == HistoryTab.bookmarks,
                        ),
                      ),
                    if (likesOffered && _opened.contains(HistoryTab.likes))
                      _TabSlot(
                        key: const ValueKey('history-likes'),
                        visible: current == HistoryTab.likes,
                        child: LikesTab(
                          active: current == HistoryTab.likes,
                          onUnavailable: _likesUnavailable,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tab's body: kept alive (state, scroll position) while out of sight, but
/// not painted, not hit-testable, not in the reading order and with its
/// animations stopped.
class _TabSlot extends StatelessWidget {
  const _TabSlot({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !visible,
      child: TickerMode(enabled: visible, child: child),
    );
  }
}

/// The Bookmarks tab: provides [BookmarksListCubit] (page 1 asked for as the
/// tab is first built) and words its one-shot removal / failure snackbars.
class _BookmarksTab extends StatelessWidget {
  const _BookmarksTab({required this.active});

  /// Whether this tab is the one the user is looking at. Out of sight it
  /// stays quiet: a bookmark toggled on a card of the Likes tab is worded by
  /// that card, not twice.
  final bool active;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<BookmarksListCubit>(
      create: (context) => BookmarksListCubit(
        repository: context.read<BookmarksRepository>(),
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      )..load(),
      child: _BookmarksTabView(active: active),
    );
  }
}

class _BookmarksTabView extends StatefulWidget {
  const _BookmarksTabView({required this.active});

  final bool active;

  @override
  State<_BookmarksTabView> createState() => _BookmarksTabViewState();
}

class _BookmarksTabViewState extends State<_BookmarksTabView> {
  // The "Removed from Bookmarks" snackbar while it is up. Its Undo belongs to
  // this screen's cubit (closed on leave), so leaving takes the bar with it.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _removalBar;
  ScaffoldMessengerState? _messenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    final bar = _removalBar;
    final messenger = _messenger;
    if (bar != null && messenger != null) {
      // After this frame: the messenger is rebuilt outside the unmount (and
      // may be gone itself, with the whole app).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (messenger.mounted) bar.close();
      });
    }
    super.dispose();
  }

  void _showRemoval(BuildContext context, BookmarkRemoval removal) {
    final cubit = context.read<BookmarksListCubit>();
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final bar = messenger.showSnackBar(
      SnackBar(
        content: const Text('Removed from Bookmarks'),
        // An Undo has no use after a few seconds: do not keep it.
        persist: false,
        // A withheld row (W3-41b) has no Undo: AddBookmark of a post the caller
        // can no longer see answers NOT_FOUND, so it could only fail.
        action: removal.view.withheld
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () => unawaited(cubit.restore(removal)),
              ),
      ),
    );
    _removalBar = bar;
    unawaited(
      bar.closed.then((_) {
        if (identical(_removalBar, bar)) _removalBar = null;
      }),
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
    return MultiBlocListener(
      listeners: [
        BlocListener<BookmarksListCubit, BookmarksListState>(
          listenWhen: (before, after) =>
              after.removal != null &&
              before.removal?.serial != after.removal!.serial,
          // Out of sight: clear it unshown (its Undo is for a row not on view).
          listener: (context, state) => widget.active
              ? _showRemoval(context, state.removal!)
              : cubit.removalShown(),
        ),
        BlocListener<BookmarksListCubit, BookmarksListState>(
          listenWhen: (before, after) =>
              after.failure != null &&
              before.failure?.serial != after.failure!.serial,
          listener: (context, state) => widget.active
              ? _showFailure(context, state.failure!)
              : cubit.failureShown(),
        ),
      ],
      child: BlocBuilder<BookmarksListCubit, BookmarksListState>(
        builder: (context, state) => HistoryPostList(
          rows: state.visibleItems,
          loading: state.status == BookmarksListStatus.loading,
          loadingMore: state.status == BookmarksListStatus.loadingMore,
          hasMore: state.hasMore,
          error: state.status == BookmarksListStatus.error ? state.error : null,
          notice: state.notice,
          noticeFromPaging: cubit.noticeFromPaging,
          rowKeyPrefix: 'bookmark',
          withheldAction: WithheldAction.removeBookmark,
          loadingLabel: 'Loading bookmarks',
          noticeMessage: bookmarksListNoticeMessage,
          empty: const AppEmptyView(
            icon: Icons.bookmark_border,
            title: kBookmarksEmptyTitle,
            subtitle: kBookmarksEmptyBody,
          ),
          unavailable: const AppEmptyView(
            icon: Icons.bookmark_border,
            title: kBookmarksUnavailableTitle,
            subtitle: kBookmarksUnavailableBody,
          ),
          // Remove works while the flag is not globally off.
          bookmarkEnabled: true,
          onRefresh: cubit.refresh,
          onLoadMore: () => unawaited(cubit.loadMore()),
          onReload: cubit.load,
          onRetryNotice: cubit.retry,
        ),
      ),
    );
  }
}
