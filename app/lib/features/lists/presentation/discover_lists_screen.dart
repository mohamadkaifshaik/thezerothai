import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../gen/dzeroth/lists/v1/lists.pb.dart' show ListInfo;
import '../data/lists_repository.dart';
import '../domain/list_follow_rules.dart';
import '../domain/lists_feature_flag.dart';
import 'bloc/list_feed_cubit.dart';
import 'bloc/list_feed_state.dart';
import 'lists_error_messages.dart';
import 'widgets/list_follow_button.dart';
import 'widgets/list_row.dart';
import 'widgets/lists_page_chrome.dart';

/// `/lists/discover`: public Lists to follow, most followed first.
///
/// - Behind `lists` and `list_follows` (the router redirects Home otherwise).
/// - 1 `DiscoverLists` per page of 20, paged on scroll by `next_page_token`
///   (a failed page shows "Couldn't load more. Retry").
/// - Each row shows the owner, the member and follower counts and a Follow /
///   Following toggle (not on the viewer's own List); a row opens the List.
///   Follow errors (the 100-follow limit, a List that is gone) show a
///   snackbar; a List that is gone also leaves the page.
/// - Mock gap: no mock draws this page; it reuses the Lists page rows, header
///   and section look at every width.
class DiscoverListsScreen extends StatefulWidget {
  const DiscoverListsScreen({super.key});

  @override
  State<DiscoverListsScreen> createState() => _DiscoverListsScreenState();
}

class _DiscoverListsScreenState extends State<DiscoverListsScreen> {
  late final ListsRepository _repository = context.read<ListsRepository>();
  late final ListFeedCubit _cubit = ListFeedCubit(
    repository: _repository,
    fetch: (token) => _repository.discoverLists(
      pageSize: kListFollowsPageSize,
      pageToken: token,
    ),
  )..load();

  @override
  void dispose() {
    _cubit.close();
    _search.dispose();
    super.dispose();
  }

  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// The query as typed, trimmed and lower-cased; empty shows every List.
  void _onQuery(String text) => setState(() => _query = text.trim());

  /// Client-side filter over the Lists loaded so far: there is no List
  /// search RPC (the Lists service has Discover, not search), so Lists on
  /// pages not yet loaded are matched as the next pages arrive.
  List<ListInfo> _filter(List<ListInfo> all) {
    final q = _query.toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final l in all)
        if (l.name.toLowerCase().contains(q) ||
            l.description.toLowerCase().contains(q) ||
            l.owner.handle.toLowerCase().contains(q) ||
            l.owner.displayName.toLowerCase().contains(q))
          l,
    ];
  }

  Widget _searchField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      borderSide: BorderSide(color: c),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: TextField(
        key: const ValueKey('discover-lists-search'),
        controller: _search,
        onChanged: _onQuery,
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyLarge,
        decoration: InputDecoration(
          hintText: 'Search Lists',
          isDense: true,
          prefixIcon: Icon(
            Icons.search,
            size: AppIconSize.md,
            color: context.appColors.secondaryOnRaised,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: AppSpacing.xxl,
            minHeight: AppSpacing.xxl,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.cancel, size: 20),
                  constraints: const BoxConstraints(
                    minWidth: AppSpacing.minTapTarget,
                    minHeight: AppSpacing.minTapTarget,
                  ),
                  onPressed: () {
                    _search.clear();
                    _onQuery('');
                  },
                ),
          border: border(scheme.outlineVariant),
          enabledBorder: border(scheme.outlineVariant),
          focusedBorder: border(scheme.primary),
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.smd),
        ),
      ),
    );
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.listsPath);
    }
  }

  Future<void> _toggle(String listId) async {
    final error = await _cubit.toggleFollow(listId);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(listsErrorMessage(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    final phone = isListsPhone(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(
                title: 'Discover Lists',
                titleContent: const ListsHeaderTitle(title: 'Discover Lists'),
                onBack: _back,
                leading: phone ? null : const SizedBox(width: AppSpacing.sm),
              ),
              Expanded(
                child: BlocBuilder<ListFeedCubit, ListFeedState>(
                  bloc: _cubit,
                  builder: (context, state) {
                    final searchable =
                        state.status == ListFeedStatus.ready &&
                        (state.lists.isNotEmpty || _query.isNotEmpty);
                    return Column(
                      children: [
                        if (searchable) _searchField(context),
                        Expanded(child: _body(context, state, viewerUserId)),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ListFeedState state, String? viewer) {
    switch (state.status) {
      case ListFeedStatus.loading:
        return const UserListSkeleton(semanticsLabel: 'Loading Lists');
      case ListFeedStatus.error:
        final error = state.error;
        if (error is FeatureDisabledException) {
          return const Center(
            child: SingleChildScrollView(
              child: AppEmptyView(
                icon: Icons.explore_outlined,
                title: "Discover isn't available right now",
                subtitle: 'Please try again in a little while.',
              ),
            ),
          );
        }
        return Center(
          child: SingleChildScrollView(
            child: AppErrorView(
              error: error ?? const UnknownApiException('Failed to load'),
              onRetry: _cubit.load,
            ),
          ),
        );
      case ListFeedStatus.ready:
        if (state.lists.isEmpty) {
          return const Center(
            child: SingleChildScrollView(
              child: AppEmptyView(
                icon: Icons.explore_outlined,
                title: 'No Lists to discover yet',
                subtitle: 'Public Lists that people follow will show up here.',
              ),
            ),
          );
        }
        final shown = _filter(state.lists);
        final tail = state.hasMore || state.loadMoreFailed ? 1 : 0;
        if (shown.isEmpty && tail == 0) {
          return const Center(
            child: SingleChildScrollView(
              child: AppEmptyView(
                icon: Icons.search_off,
                title: 'No Lists match your search',
                subtitle: 'Try a different word.',
              ),
            ),
          );
        }
        final style = listsPageRowStyle(context);
        final gutter = style == ListRowStyle.wide
            ? AppListsLayout.wideGutter
            : AppListsLayout.phoneGutter;
        final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
        return RefreshIndicator(
          onRefresh: _cubit.load,
          child: CustomScrollView(
            slivers: [
              SliverList.builder(
                itemCount: shown.length + tail,
                itemBuilder: (context, i) {
                  if (i >= shown.length) return _tail(context, state);
                  final list = shown[i];
                  final follow = canFollowList(list, viewer)
                      ? ListFollowButton(
                          listName: list.name,
                          following: list.followedByViewer,
                          busy: state.busyIds.contains(list.listId),
                          onToggle: () => _toggle(list.listId),
                        )
                      : null;
                  return ListRow(
                    key: ValueKey(list.listId),
                    list: list,
                    style: style,
                    followers: true,
                    onTap: () => context.push(AppRouter.listPath(list.listId)),
                    // Beside the row; under it when the text is large and the
                    // button no longer fits.
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

  /// The end of the page: a spinner that asks for the next page when it is
  /// built, or Retry after a failed one.
  Widget _tail(BuildContext context, ListFeedState state) {
    if (state.loadMoreFailed) {
      return Center(
        child: TextButton(
          onPressed: _cubit.loadMore,
          child: const Text("Couldn't load more. Retry"),
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cubit.loadMore();
    });
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
