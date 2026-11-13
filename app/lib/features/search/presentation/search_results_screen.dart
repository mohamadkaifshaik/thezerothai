import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/telemetry/analytics_event.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_notice_banner.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../engagement/presentation/widgets/history_post_list.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/user/follow_button.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/bloc/relationship_cubit.dart';
import '../../graph/presentation/widgets/user_list_row.dart';
import '../data/search_repository.dart';
import '../domain/search_query.dart';
import '../domain/search_results_tab.dart';
import '../domain/search_routes.dart';
import 'bloc/search_results_cubit.dart';
import 'bloc/search_results_state.dart';
import 'widgets/app_search_field.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

/// Copy of the results screen (our own wording).
const kSearchPostsHintTitle = 'Search posts by #hashtag';
const kSearchPostsHintBody =
    'Search for words is not available yet. Try a hashtag like #name for '
    'posts, or a handle like @name for people.';
const kSearchPeopleTooShortTitle = 'Type at least 2 characters';
const kSearchPeopleTooShortBody = 'People are found by the start of a handle.';
const kSearchInvalidTitle = "That search isn't valid";
const kSearchInvalidBody = 'Try a handle like @name or a hashtag like #name.';
const kSearchUnavailableTitle = "Search isn't available right now";
const kSearchUnavailableBody = 'Please check back later.';

/// The note under the Top rows: a way to the newest posts.
const kSeeLatestLabel = 'See latest';

/// Rows of Top's people preview (the mocks show two or three).
const kSearchPeoplePreviewRows = 3;

/// `/search?q=<query>&tab=top|latest|people|media`: the
/// results of one query in four tabs. Display only: every tab owns a
/// [SearchResultsCubit].
///
/// - **Tabs.** Top · Latest · People · Media in an [AppTabBar]; the default is
///   Top, or People for an `@handle` query (`SearchResultsTab.fromQuery`).
///   A tab asks the server the first time it is selected and then keeps its
///   rows and scroll position while another is in front (session memory,
///   nothing persisted).
/// - **Posts** (Top, Latest, Media) are live `PostCard` rows through
///   [HistoryPostList], with the engagement row when `engagement` is on, 70 %
///   prefetch paging on Latest and Media (short pages are followed) and a
///   "See latest" footer on Top, which is one page.
/// - **People** are [UserListRow]s (Follow with the `graph` flag), one page.
/// - **Words instead of a call** for a query that cannot be searched: "Search
///   posts by #hashtag" on the post tabs, "Type at least 2 characters" on
///   People for a one-letter query.
/// - **Errors.** FEATURE_DISABLED is "not available" (no Retry), a
///   rate limit says so and offers Retry unless the limit is daily, anything
///   else gets the shared error view with Retry.
class SearchResultsScreen extends StatefulWidget {
  const SearchResultsScreen({
    super.key,
    required this.query,
    this.initialTab = SearchResultsTab.top,
  });

  /// The raw query of the URL (`#launch`, `@bob`, `launch`).
  final String query;
  final SearchResultsTab initialTab;

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  late SearchResultsTab _selected = widget.initialTab;
  late SearchQuery _query = SearchQuery.parse(widget.query);

  /// Tabs the user has looked at: only those exist (and have asked anything).
  final Set<SearchResultsTab> _opened = {};

  /// One SearchPeople for the query, shared by the People tab and Top's
  /// people preview: created the first time either needs it, so neither
  /// asks twice.
  SearchResultsCubit? _people;

  /// One follow state per account, shared by the preview row and the People
  /// tab row of the same account (a follow in one shows in the other).
  final Map<String, RelationshipCubit> _follows = {};

  @override
  void didUpdateWidget(SearchResultsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      // Another query: every tab starts again.
      _query = SearchQuery.parse(widget.query);
      _opened.clear();
      _selected = widget.initialTab;
      _closeShared();
    } else if (oldWidget.initialTab != widget.initialTab) {
      _selected = widget.initialTab;
    }
  }

  @override
  void dispose() {
    _closeShared();
    super.dispose();
  }

  void _closeShared() {
    unawaited(_people?.close());
    _people = null;
    for (final cubit in _follows.values) {
      unawaited(cubit.close());
    }
    _follows.clear();
  }

  SearchResultsCubit _peopleCubit() => _people ??= SearchResultsCubit(
    repository: context.read<SearchRepository>(),
    tab: SearchResultsTab.people,
    query: _query,
    onUnexpectedError: context.read<UnexpectedErrorReporter>(),
  )..load();

  /// The Follow control of [item]'s rows, over the shared follow state.
  Widget _follow(graph.UserListItem item) {
    final userId = item.user.userId;
    final cubit = _follows[userId] ??= RelationshipCubit(
      graphRepository: context.read<GraphRepository>(),
      userId: userId,
      initial: graph.Relationship(
        userId: userId,
        followState: item.relationship.followState,
        blocking: item.relationship.blocking,
        muting: item.relationship.muting,
      ),
    );
    return BlocProvider.value(
      value: cubit,
      child: const FollowButton(source: FollowSource.search),
    );
  }

  /// Back to where the user came from; with no history (a deep link) Home.
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  void _select(SearchResultsTab tab) => setState(() => _selected = tab);

  @override
  Widget build(BuildContext context) {
    _opened.add(_selected);
    // Top previews people only for a query People can search (never a
    // #tag): no SearchPeople is spent otherwise.
    final previewPeople =
        _opened.contains(SearchResultsTab.top) && _query.canSearchPeople;
    final people = previewPeople || _opened.contains(SearchResultsTab.people)
        ? _peopleCubit()
        : null;
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    return Scaffold(
      body: SafeArea(
        // The floating bar overlays the page: the scroll view runs behind it
        // and ends with the bar's inset (ShellBottomInsetSliver).
        bottom: false,
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(
                title: 'Search',
                onBack: _back,
                // Editable in place; a new search replaces this page, so the
                // stack never grows with every edit.
                titleContent: AppSearchField(
                  key: ValueKey(widget.query),
                  initialText: widget.query,
                  // The phone mock's raised pill; tablet and desktop keep
                  // the flat one (`.search`).
                  raised: phone,
                  onSubmitted: (context, canonical) =>
                      context.pushReplacement(searchResultsLocation(canonical)),
                ),
              ),
              AppTabBar(
                semanticLabel: 'Search results',
                selectedIndex: _selected.index,
                onChanged: (index) => _select(SearchResultsTab.values[index]),
                tabs: [
                  for (final tab in SearchResultsTab.values)
                    AppTab(label: tab.label),
                ],
              ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final tab in SearchResultsTab.values)
                      if (_opened.contains(tab))
                        _TabSlot(
                          key: ValueKey('${widget.query}|${tab.name}'),
                          visible: tab == _selected,
                          child: _ResultsTab(
                            tab: tab,
                            query: _query,
                            people: people,
                            previewPeople: previewPeople,
                            follow: _follow,
                            onSeeLatest: () => _select(SearchResultsTab.latest),
                            onViewAllPeople: () =>
                                _select(SearchResultsTab.people),
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

/// One tab's body: kept alive (state, scroll position) while out of sight,
/// but not painted, not hit-testable, not in the reading order and with its
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

class _ResultsTab extends StatelessWidget {
  const _ResultsTab({
    required this.tab,
    required this.query,
    required this.people,
    required this.previewPeople,
    required this.follow,
    required this.onSeeLatest,
    required this.onViewAllPeople,
  });

  final SearchResultsTab tab;
  final SearchQuery query;

  /// The shared people results; set whenever People or Top's preview is
  /// shown.
  final SearchResultsCubit? people;
  final bool previewPeople;
  final Widget Function(graph.UserListItem item) follow;
  final VoidCallback onSeeLatest;
  final VoidCallback onViewAllPeople;

  @override
  Widget build(BuildContext context) {
    final people = this.people;
    if (tab == SearchResultsTab.people && people != null) {
      return BlocProvider<SearchResultsCubit>.value(
        value: people,
        child: _PeopleBody(follow: follow),
      );
    }
    return BlocProvider<SearchResultsCubit>(
      create: (context) => SearchResultsCubit(
        repository: context.read<SearchRepository>(),
        tab: tab,
        query: query,
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      )..load(),
      child: _PostsBody(
        tab: tab,
        query: query,
        onSeeLatest: onSeeLatest,
        header: tab == SearchResultsTab.top && previewPeople && people != null
            ? _PeoplePreview(
                people: people,
                follow: follow,
                onViewAll: onViewAllPeople,
              )
            : null,
      ),
    );
  }
}

/// Top's "People" section (SearchResults mocks): the first
/// [kSearchPeoplePreviewRows] of the shared people results and "View all",
/// which opens People. Nothing while they load, when there are none or when
/// the call failed: the posts are never held up, and People shows the state.
class _PeoplePreview extends StatelessWidget {
  const _PeoplePreview({
    required this.people,
    required this.follow,
    required this.onViewAll,
  });

  final SearchResultsCubit people;
  final Widget Function(graph.UserListItem item) follow;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final graphOn = isFeatureEnabled(context, kFeatureGraph);
    final theme = Theme.of(context);
    return BlocBuilder<SearchResultsCubit, SearchResultsState>(
      bloc: people,
      builder: (context, state) {
        if (state.status != SearchResultsStatus.ready || state.people.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.md,
                AppSpacing.smd,
                AppSpacing.xs,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text('People', style: theme.textTheme.titleLarge),
                    ),
                  ),
                  Semantics(
                    label: 'View all people',
                    button: true,
                    excludeSemantics: true,
                    onTap: onViewAll,
                    child: TextButton(
                      onPressed: onViewAll,
                      child: const Text('View all'),
                    ),
                  ),
                ],
              ),
            ),
            for (final item in state.people.take(kSearchPeoplePreviewRows))
              UserListRow(
                key: ValueKey('search-preview-${item.user.userId}'),
                item: item,
                followSource: FollowSource.search,
                showDivider: false,
                trailing: graphOn ? follow(item) : const SizedBox.shrink(),
              ),
            const SizedBox(height: AppSpacing.sm),
            const Divider(height: 1),
          ],
        );
      },
    );
  }
}

/// The empty state for "nothing to show": words for a [SearchResultsNote], or
/// "No results for ...".
Widget _noteView(SearchResultsNote note, {required String emptyTitle}) {
  return switch (note) {
    SearchResultsNote.unsupported => const AppEmptyView(
      icon: Icons.tag,
      title: kSearchPostsHintTitle,
      subtitle: kSearchPostsHintBody,
    ),
    SearchResultsNote.peopleTooShort => const AppEmptyView(
      icon: Icons.person_search_outlined,
      title: kSearchPeopleTooShortTitle,
      subtitle: kSearchPeopleTooShortBody,
    ),
    SearchResultsNote.invalid => const AppEmptyView(
      icon: Icons.search_off,
      title: kSearchInvalidTitle,
      subtitle: kSearchInvalidBody,
    ),
    SearchResultsNote.none => AppEmptyView(
      icon: Icons.search_off,
      title: emptyTitle,
      subtitle: 'Try another search.',
    ),
  };
}

const _unavailable = AppEmptyView(
  icon: Icons.search_off,
  title: kSearchUnavailableTitle,
  subtitle: kSearchUnavailableBody,
);

String _noticeMessage(AppException error) => switch (error) {
  RateLimitedException() => rateLimitedMessage(error),
  NetworkException() => "You're offline. Showing what was found.",
  _ => "Couldn't refresh the results.",
};

/// A first-page rate limit: friendly words, and Retry unless it is daily.
class _RateLimitedView extends StatelessWidget {
  const _RateLimitedView({required this.error, required this.onRetry});

  final RateLimitedException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppEmptyView(
      icon: error.isDaily ? Icons.hourglass_bottom_outlined : Icons.speed,
      title: 'Too many searches',
      subtitle: rateLimitedMessage(error),
      action: error.isDaily
          ? null
          : AppPillButton(
              label: 'Try again',
              compact: true,
              onPressed: onRetry,
            ),
    );
  }
}

class _PostsBody extends StatelessWidget {
  const _PostsBody({
    required this.tab,
    required this.query,
    required this.onSeeLatest,
    this.header,
  });

  final SearchResultsTab tab;
  final SearchQuery query;
  final VoidCallback onSeeLatest;

  /// Top's people preview, above the posts (and above their empty state).
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SearchResultsCubit>();
    return BlocBuilder<SearchResultsCubit, SearchResultsState>(
      builder: (context, state) {
        final error = state.error;
        // A rate limit on page 1 keeps its Retry (the shared error view has
        // none for it).
        if (state.status == SearchResultsStatus.error &&
            error is RateLimitedException) {
          return _RateLimitedView(error: error, onRetry: cubit.load);
        }
        // Pull to refresh asks for the posts only: the preview keeps its
        // rows (People's own refresh asks SearchPeople again).
        final emptyTitle = 'No results for "${query.canonical}"';
        final isTop = tab == SearchResultsTab.top;
        return HistoryPostList(
          rows: state.posts,
          loading:
              state.status == SearchResultsStatus.loading ||
              state.status == SearchResultsStatus.idle,
          loadingMore: state.status == SearchResultsStatus.loadingMore,
          hasMore: state.hasMore,
          error: state.status == SearchResultsStatus.error ? error : null,
          notice: state.notice,
          noticeFromPaging: cubit.noticeFromPaging,
          rowKeyPrefix: 'search-${tab.name}',
          // Search never returns withheld rows; this is the inert fallback.
          withheldAction: WithheldAction.unlike,
          loadingLabel: 'Loading results',
          noticeMessage: _noticeMessage,
          empty: _noteView(state.note, emptyTitle: emptyTitle),
          unavailable: _unavailable,
          header: header,
          endNote: isTop && state.posts.isNotEmpty
              ? _SeeLatest(onPressed: onSeeLatest)
              : null,
          onRefresh: cubit.refresh,
          onLoadMore: () => unawaited(cubit.loadMore()),
          onReload: cubit.load,
          onRetryNotice: cubit.retry,
        );
      },
    );
  }
}

/// The footer of Top: a text button to the Latest tab (48dp target).
class _SeeLatest extends StatelessWidget {
  const _SeeLatest({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: TextButton(
          onPressed: onPressed,
          child: const Text(kSeeLatestLabel),
        ),
      ),
    );
  }
}

class _PeopleBody extends StatefulWidget {
  const _PeopleBody({required this.follow});

  final Widget Function(graph.UserListItem item) follow;

  @override
  State<_PeopleBody> createState() => _PeopleBodyState();
}

class _PeopleBodyState extends State<_PeopleBody> {
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SearchResultsCubit>();
    final graphOn = isFeatureEnabled(context, kFeatureGraph);
    return BlocBuilder<SearchResultsCubit, SearchResultsState>(
      builder: (context, state) {
        return RefreshIndicator(
          onRefresh: cubit.refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              ..._slivers(context, cubit, state, graphOn),
              const ShellBottomInsetSliver(),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _slivers(
    BuildContext context,
    SearchResultsCubit cubit,
    SearchResultsState state,
    bool graphOn,
  ) {
    final notice = state.notice;
    if (state.status == SearchResultsStatus.loading ||
        state.status == SearchResultsStatus.idle) {
      return const [
        SliverToBoxAdapter(
          child: UserListSkeleton(semanticsLabel: 'Loading people'),
        ),
      ];
    }
    final error = state.error;
    if (state.status == SearchResultsStatus.error && error != null) {
      return [
        SliverToBoxAdapter(
          child: switch (error) {
            FeatureDisabledException() => _unavailable,
            final RateLimitedException e => _RateLimitedView(
              error: e,
              onRetry: cubit.load,
            ),
            _ => AppErrorView(error: error, onRetry: cubit.load),
          },
        ),
      ];
    }
    if (state.people.isEmpty) {
      final query = cubit.query;
      return [
        SliverToBoxAdapter(
          child: _noteView(
            state.note,
            emptyTitle: 'No people found for "${query.canonical}"',
          ),
        ),
      ];
    }
    return [
      if (notice != null)
        SliverToBoxAdapter(
          child: AppNoticeBanner(
            message: _noticeMessage(notice),
            onRetry: noticeCanRetry(notice) ? cubit.retry : null,
          ),
        ),
      SliverList.builder(
        itemCount: state.people.length,
        itemBuilder: (context, index) {
          final item = state.people[index];
          return UserListRow(
            key: ValueKey('search-person-${item.user.userId}'),
            item: item,
            followSource: FollowSource.search,
            // The follow state the preview shares; without the graph flag
            // there is no Follow control to offer.
            trailing: graphOn ? widget.follow(item) : const SizedBox.shrink(),
          );
        },
      ),
      const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
    ];
  }
}
