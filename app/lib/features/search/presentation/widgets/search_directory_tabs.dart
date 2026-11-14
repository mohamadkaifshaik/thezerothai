import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../../core/network/app_exception.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../../shared/widgets/primitives/app_chip.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../../shared/widgets/user/user_list_skeleton.dart';
import '../../../communities/presentation/widgets/community_row.dart';
import '../../../lists/data/lists_repository.dart';
import '../../../lists/domain/list_follow_rules.dart';
import '../../../lists/presentation/bloc/list_feed_cubit.dart';
import '../../../lists/presentation/bloc/list_feed_state.dart';
import '../../../lists/presentation/lists_error_messages.dart';
import '../../../lists/presentation/widgets/list_follow_button.dart';
import '../../../lists/presentation/widgets/list_row.dart';
import '../../../lists/presentation/widgets/lists_page_chrome.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../data/search_repository.dart';
import '../bloc/search_communities_cubit.dart';
import '../bloc/search_results_cubit.dart' show searchErrorToApp;
import 'search_status_views.dart';

/// Spoken name of the posts filter row.
const kSearchFollowingFilterLabel = 'Filter posts by author';

/// The two choices of the posts filter (the desktop mock's "Search filters":
/// People: From anyone / People you follow).
const kSearchFromAnyoneLabel = 'From anyone';
const kSearchFromFollowingLabel = 'People you follow';

/// "People you follow" filter of the Latest and Media tabs (`search_filters`):
/// a row of two [AppFilterPill]s that scrolls sideways when it does not fit.
/// One state for the screen; both post tabs show the same choice.
class SearchFollowingFilter extends StatelessWidget {
  const SearchFollowingFilter({
    super.key,
    required this.fromFollowing,
    required this.onChanged,
  });

  final bool fromFollowing;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: kSearchFollowingFilterLabel,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            AppFilterPill(
              label: kSearchFromAnyoneLabel,
              selected: !fromFollowing,
              onPressed: () => onChanged(false),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppFilterPill(
              label: kSearchFromFollowingLabel,
              selected: fromFollowing,
              onPressed: () => onChanged(true),
            ),
          ],
        ),
      ),
    );
  }
}

/// Words for a directory tab that has no query to send.
Widget _noQuery(String what) => AppEmptyView(
  icon: Icons.search_off,
  title: "That search isn't valid",
  subtitle: 'Search $what by the start of a name, up to 30 characters.',
);

Widget _failure(AppException error, VoidCallback onRetry) => switch (error) {
  FeatureDisabledException() => searchUnavailableView,
  final RateLimitedException e => SearchRateLimitedView(
    error: e,
    onRetry: onRetry,
  ),
  _ => AppErrorView(error: error, onRetry: onRetry),
};

Widget _scrollable(Widget child) =>
    Center(child: SingleChildScrollView(child: child));

/// The end of a paged directory: a spinner that asks for the next page once
/// built, or Retry after a failed one.
class _PagingTail extends StatefulWidget {
  const _PagingTail({super.key, required this.failed, required this.onMore});

  final bool failed;
  final VoidCallback onMore;

  @override
  State<_PagingTail> createState() => _PagingTailState();
}

class _PagingTailState extends State<_PagingTail> {
  @override
  void initState() {
    super.initState();
    if (!widget.failed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onMore();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.failed) {
      return Center(
        child: TextButton(
          onPressed: widget.onMore,
          child: const Text("Couldn't load more. Retry"),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.all(AppSpacing.md),
      child: Center(
        child: SizedBox.square(
          dimension: AppSpacing.lg,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

/// How many empty server pages one client page follows before it shows what
/// it has (the tail asks again while a token is left).
const kSearchListsFollowPages = 5;

/// The Lists tab (`SearchLists`, F20): public Lists whose name starts with
/// the query, as the Lists page's rows ([ListRow]) with Follow / Following
/// when `list_follows` is on and the List is not the viewer's own (the
/// [ListFeedCubit] of Discover does the paging and the optimistic follow).
/// A row opens the List. Short or empty pages are followed through their
/// token (up to [kSearchListsFollowPages] per page).
class SearchListsBody extends StatefulWidget {
  const SearchListsBody({
    super.key,
    required this.query,
    required this.followsEnabled,
  });

  /// `SearchQuery.directoryQuery`; null: words instead of a call.
  final String? query;
  final bool followsEnabled;

  @override
  State<SearchListsBody> createState() => _SearchListsBodyState();
}

class _SearchListsBodyState extends State<SearchListsBody> {
  ListFeedCubit? _cubit;

  @override
  void initState() {
    super.initState();
    final query = widget.query;
    if (query == null) return;
    final search = context.read<SearchRepository>();
    final report = context.read<UnexpectedErrorReporter>();
    _cubit = ListFeedCubit(
      repository: context.read<ListsRepository>(),
      fetch: (token) async {
        try {
          String? next = token.isEmpty ? null : token;
          for (var i = 1; ; i++) {
            final page = await search.searchLists(query, pageToken: next);
            next = page.nextPageToken;
            if (page.lists.isNotEmpty ||
                next == null ||
                i >= kSearchListsFollowPages) {
              return ListsPage(lists: page.lists, nextPageToken: next ?? '');
            }
          }
        } catch (error, stack) {
          final mapped = searchErrorToApp(error);
          if (mapped is UnknownApiException) report(error, stack);
          throw mapped;
        }
      },
    )..load();
  }

  @override
  void dispose() {
    unawaited(_cubit?.close());
    super.dispose();
  }

  Future<void> _toggle(String listId) async {
    final error = await _cubit!.toggleFollow(listId);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(listsErrorMessage(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = _cubit;
    if (cubit == null) return _noQuery('Lists');
    final viewer = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    return BlocBuilder<ListFeedCubit, ListFeedState>(
      bloc: cubit,
      builder: (context, state) => _body(context, cubit, state, viewer),
    );
  }

  Widget _body(
    BuildContext context,
    ListFeedCubit cubit,
    ListFeedState state,
    String? viewer,
  ) {
    switch (state.status) {
      case ListFeedStatus.loading:
        return const UserListSkeleton(semanticsLabel: 'Loading Lists');
      case ListFeedStatus.error:
        return _scrollable(
          _failure(
            state.error ?? const UnknownApiException('Failed to load'),
            cubit.load,
          ),
        );
      case ListFeedStatus.ready:
        if (state.lists.isEmpty && !state.hasMore) {
          return _scrollable(
            AppEmptyView(
              icon: Icons.list_alt_outlined,
              title: 'No Lists found for "${widget.query}"',
              subtitle: 'Try another search.',
            ),
          );
        }
        final style = listsPageRowStyle(context);
        final gutter = style == ListRowStyle.wide
            ? AppListsLayout.wideGutter
            : AppListsLayout.phoneGutter;
        final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
        final tail = state.hasMore || state.loadMoreFailed ? 1 : 0;
        return RefreshIndicator(
          onRefresh: cubit.load,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverList.builder(
                itemCount: state.lists.length + tail,
                itemBuilder: (context, i) {
                  if (i >= state.lists.length) {
                    return _PagingTail(
                      key: ValueKey('lists-tail-${state.nextPageToken}'),
                      failed: state.loadMoreFailed,
                      onMore: () => unawaited(cubit.loadMore()),
                    );
                  }
                  final list = state.lists[i];
                  final follow =
                      widget.followsEnabled && canFollowList(list, viewer)
                      ? ListFollowButton(
                          listName: list.name,
                          following: list.followedByViewer,
                          busy: state.busyIds.contains(list.listId),
                          onToggle: () => _toggle(list.listId),
                        )
                      : null;
                  return ListRow(
                    key: ValueKey('search-list-${list.listId}'),
                    list: list,
                    style: style,
                    followers: widget.followsEnabled,
                    onTap: () => context.push(AppRouter.listPath(list.listId)),
                    trailing: follow == null || stacked
                        ? null
                        : Padding(
                            padding: EdgeInsetsDirectional.only(end: gutter),
                            child: follow,
                          ),
                    footer: stacked ? follow : null,
                  );
                },
              ),
              const ShellBottomInsetSliver(),
            ],
          ),
        );
    }
  }
}

/// The Communities tab (`SearchCommunities`, F21): [CommunityRow] cards with
/// the member count and the viewer's role badge; a row opens the community.
/// Joining happens on the community's own page.
class SearchCommunitiesBody extends StatefulWidget {
  const SearchCommunitiesBody({super.key, required this.query});

  /// `SearchQuery.directoryQuery`; null: words instead of a call.
  final String? query;

  @override
  State<SearchCommunitiesBody> createState() => _SearchCommunitiesBodyState();
}

class _SearchCommunitiesBodyState extends State<SearchCommunitiesBody> {
  SearchCommunitiesCubit? _cubit;

  @override
  void initState() {
    super.initState();
    final query = widget.query;
    if (query == null) return;
    _cubit = SearchCommunitiesCubit(
      repository: context.read<SearchRepository>(),
      query: query,
      onUnexpectedError: context.read<UnexpectedErrorReporter>(),
    )..load();
  }

  @override
  void dispose() {
    unawaited(_cubit?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = _cubit;
    if (cubit == null) return _noQuery('Communities');
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
    return BlocBuilder<SearchCommunitiesCubit, SearchCommunitiesState>(
      bloc: cubit,
      builder: (context, state) {
        switch (state.status) {
          case SearchCommunitiesStatus.loading:
            return const UserListSkeleton(
              semanticsLabel: 'Loading Communities',
            );
          case SearchCommunitiesStatus.error:
            return _scrollable(
              _failure(
                state.error ?? const UnknownApiException('Failed to load'),
                cubit.load,
              ),
            );
          case SearchCommunitiesStatus.ready:
            if (state.communities.isEmpty && !state.hasMore) {
              return _scrollable(
                AppEmptyView(
                  icon: Icons.groups_outlined,
                  title: 'No Communities found for "${cubit.query}"',
                  subtitle: 'Try another search.',
                ),
              );
            }
            final tail = state.hasMore || state.loadMoreFailed ? 1 : 0;
            return RefreshIndicator(
              onRefresh: cubit.load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverList.builder(
                    itemCount: state.communities.length + tail,
                    itemBuilder: (context, i) {
                      if (i >= state.communities.length) {
                        return _PagingTail(
                          key: ValueKey(
                            'communities-tail-${state.nextPageToken}',
                          ),
                          failed: state.loadMoreFailed,
                          onMore: () => unawaited(cubit.loadMore()),
                        );
                      }
                      final community = state.communities[i];
                      return CommunityRow(
                        key: ValueKey(
                          'search-community-${community.communityId}',
                        ),
                        community: community,
                        card: true,
                        wide: wide,
                        onTap: () => context.push(
                          AppRouter.communityPath(community.communityId),
                        ),
                      );
                    },
                  ),
                  const ShellBottomInsetSliver(),
                ],
              ),
            );
        }
      },
    );
  }
}
