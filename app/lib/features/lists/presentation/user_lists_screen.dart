import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/context_pane.dart';
import '../../../core/widgets/context_pane_slots.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_section_header.dart';
import '../../../shared/widgets/post/protected_posts_view.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../data/lists_repository.dart';
import 'bloc/lists_cubit.dart';
import 'bloc/lists_state.dart';
import 'widgets/list_row.dart';
import 'widgets/lists_owner_card.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

/// `/u/:userId/lists`: another person's public Lists. 1 `ListUserLists`
/// per open. A row opens the list (`/lists/:id`). The `lists` flag gates
/// the route. A protected owner you do not follow answers PROTECTED_ACCOUNT
/// (the protected-account view). A person who is hidden from you
/// (blocked, gone) answers NOT_FOUND, shown as one fixed text that hints at no
/// cause.
///
/// On the tablet layout (T8b) the owner's card ([ListsOwnerCard], from the
/// owner snapshot the answer carries) heads the Lists in band A and sits in
/// the context pane in band B; it shows only once the Lists are loaded.
class UserListsScreen extends StatefulWidget {
  const UserListsScreen({super.key, required this.userId, this.handle});

  final String userId;

  /// For the header only (`@handle`); null when the link carried none.
  final String? handle;

  @override
  State<UserListsScreen> createState() => _UserListsScreenState();
}

class _UserListsScreenState extends State<UserListsScreen> {
  late final ListsCubit _cubit = ListsCubit(
    repository: context.read<ListsRepository>(),
    ownerId: widget.userId,
  )..load();

  /// Band B's context pane: the owner card over [_cubit] (T8b).
  final _paneLease = ContextPaneLease();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _paneLease.attach(context, AppRouter.userListsPath(widget.userId), {
      ContextSectionKind.listsOwner: (context) =>
          BlocBuilder<ListsCubit, ListsState>(
            bloc: _cubit,
            builder: (context, state) {
              if (state.status == ListsStatus.loading) {
                return const ListsOwnerCardPlaceholder();
              }
              final owner = _ownerOf(state);
              return owner == null
                  ? const SizedBox.shrink()
                  : ListsOwnerCard(owner: owner, onTap: _openOwner);
            },
          ),
    });
  }

  @override
  void dispose() {
    _paneLease.dispose();
    _cubit.close();
    super.dispose();
  }

  /// The owner snapshot of the loaded Lists, or null (loading, empty, an
  /// error): the card never sits over those states.
  common.AuthorSnapshot? _ownerOf(ListsState state) {
    if (state.status != ListsStatus.ready || state.lists.isEmpty) return null;
    final owner = state.lists.first.owner;
    return owner.userId.isEmpty || owner.handle.isEmpty ? null : owner;
  }

  /// The owner card leads back to the profile: the one this page was
  /// opened from when there is one ([_back] pops), else the owner's.
  void _openOwner() => _back();

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.profileByIdPath(widget.userId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final handle = widget.handle;
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(
                title: handle == null || handle.isEmpty
                    ? 'Lists'
                    : "@$handle's Lists",
                onBack: _back,
              ),
              Expanded(
                child: BlocBuilder<ListsCubit, ListsState>(
                  bloc: _cubit,
                  builder: _body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ListsState state) {
    switch (state.status) {
      case ListsStatus.loading:
        return const UserListSkeleton(semanticsLabel: 'Loading Lists');
      case ListsStatus.error:
        final error = state.error;
        if (error is FeatureDisabledException) {
          return const AppEmptyView(
            icon: Icons.list_alt_outlined,
            title: "Lists aren't available right now",
            subtitle: 'Please try again in a little while.',
          );
        }
        if (error is ProtectedAccountException) {
          // A protected owner's Lists are for approved followers only.
          return ProtectedPostsView(
            title: 'These Lists are protected',
            message: widget.handle == null || widget.handle!.isEmpty
                ? 'Only approved followers can see this account’s Lists. '
                      'To request access, follow the account.'
                : 'Only approved followers can see @${widget.handle}’s '
                      'Lists. To request access, follow the account.',
          );
        }
        if (error is NotFoundException) {
          return const AppEmptyView(
            icon: Icons.list_alt_outlined,
            title: 'These Lists are unavailable',
            subtitle: "They can't be shown right now.",
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
      case ListsStatus.ready:
        final lists = state.lists;
        if (lists.isEmpty) {
          return const AppEmptyView(
            icon: Icons.list_alt_outlined,
            title: 'No public Lists',
            subtitle: "This person hasn't shared any Lists.",
          );
        }
        // Band A of the tablet layout: the owner card heads the Lists. Band B
        // shows it in the context pane; phones and desktop keep today's page
        // (ruling R-1).
        final tablet = ShellGeometry.maybeOf(context)?.tablet ?? false;
        final owner = _ownerOf(state);
        final ownerInline =
            tablet &&
            owner != null &&
            !ContextPaneScope.shows(context, ContextSectionKind.listsOwner);
        return RefreshIndicator(
          onRefresh: _cubit.load,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: ownerInline
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          AppSpacing.md,
                          AppSpacing.md,
                          0,
                        ),
                        child: ListsOwnerCard(owner: owner, onTap: _openOwner),
                      )
                    : const SizedBox.shrink(),
              ),
              const SliverToBoxAdapter(child: AppSectionHeader(title: 'Lists')),
              SliverList.builder(
                itemCount: lists.length,
                itemBuilder: (context, i) {
                  final list = lists[i];
                  return ListRow(
                    key: ValueKey(list.listId),
                    list: list,
                    onTap: () => context.push(AppRouter.listPath(list.listId)),
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
