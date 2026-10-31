import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_tab_bar.dart';
import '../../../shared/widgets/headline_message.dart';
import '../../../shared/widgets/post_list_skeleton.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_state.dart';
import '../data/drafts_repository.dart';
import '../data/posts_repository.dart';
import 'bloc/drafts_cubit.dart';
import 'bloc/scheduled_posts_cubit.dart';
import 'scheduled_posts_screen.dart';
import 'widgets/draft_dialogs.dart';
import 'widgets/draft_row.dart';

/// Empty Unsent posts tab: our own words.
const kDraftsEmptyTitle = 'No unsent posts';
const kDraftsEmptyBody =
    'Save a post from the composer and it will wait here, on this device, '
    'until you send it.';

/// Retention note on the Unsent tab (W6-45, L-5): drafts are device-local and
/// expire 30 days after the last edit (`kDraftExpiry`). Scheduled posts are
/// server-side, not drafts, and are not affected.
const kDraftsRetentionNote =
    'Unsent posts are kept on this device for 30 days after you last edit them.';

/// Tab labels.
const kDraftsTabUnsent = 'Unsent posts';
const kDraftsTabScheduled = 'Scheduled';

/// `/drafts` (W6-15, ADR-0029): the Unsent posts tab (drafts kept on this
/// device, 0 RPCs) and the Scheduled tab (the CMP-D6 list, unchanged). `/scheduled`
/// is an alias that opens the Scheduled tab while `drafts` is on.
///
/// - [scheduledTab] opens on Scheduled.
/// - [pickMode]: the screen was pushed from the composer. Opening a draft then
///   pops with its id, so the composer loads it in place instead of stacking a
///   second composer. Otherwise it opens `/compose?draft=<id>`.
/// - [now] is the clock for the relative times (a test seam).
class DraftsScreen extends StatelessWidget {
  const DraftsScreen({
    super.key,
    this.scheduledTab = false,
    this.pickMode = false,
    this.now,
  });

  final bool scheduledTab;
  final bool pickMode;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<DraftsCubit>(
          create: (context) => DraftsCubit(
            repository: context.read<DraftsRepository>(),
            uid: context.read<AuthBloc>().state.user?.uid,
            onUnexpectedError: context.read<UnexpectedErrorReporter>(),
          ),
        ),
        // Created (and loaded) when the Scheduled tab is first shown: the
        // Unsent tab costs no RPC.
        BlocProvider<ScheduledPostsCubit>(
          create: (context) => ScheduledPostsCubit(
            repository: context.read<PostsRepository>(),
            onUnexpectedError: context.read<UnexpectedErrorReporter>(),
          )..load(),
        ),
      ],
      // Another account on this device never sees these rows.
      child: BlocListener<AuthBloc, AuthState>(
        listenWhen: (prev, curr) => prev.user?.uid != curr.user?.uid,
        listener: (context, state) =>
            context.read<DraftsCubit>().watchUid(state.user?.uid),
        child: _DraftsView(
          initialTab: scheduledTab ? 1 : 0,
          pickMode: pickMode,
          now: now ?? DateTime.now,
        ),
      ),
    );
  }
}

class _DraftsView extends StatefulWidget {
  const _DraftsView({
    required this.initialTab,
    required this.pickMode,
    required this.now,
  });

  final int initialTab;
  final bool pickMode;
  final DateTime Function() now;

  @override
  State<_DraftsView> createState() => _DraftsViewState();
}

class _DraftsViewState extends State<_DraftsView> {
  late int _tab = widget.initialTab;

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  void _selectTab(int index) {
    if (index == _tab) return;
    // Edit mode belongs to the Unsent tab.
    context.read<DraftsCubit>().editFinished();
    setState(() => _tab = index);
  }

  void _open(String draftId) {
    if (widget.pickMode) {
      context.pop(draftId);
    } else {
      context.push(AppRouter.composeDraftPath(draftId));
    }
  }

  Future<void> _deleteSelected() async {
    final cubit = context.read<DraftsCubit>();
    final count = cubit.state.selected.length;
    if (count == 0) return;
    final ok = await showDiscardDraftsDialog(context, count: count);
    if (!ok || !mounted) return;
    final removed = await cubit.deleteSelected();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            removed == 0
                ? "Couldn't delete. Please try again."
                : removed == 1
                ? 'Unsent post discarded.'
                : '$removed unsent posts discarded.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final unsent = _tab == 0;
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              BlocBuilder<DraftsCubit, DraftsViewState>(
                buildWhen: (a, b) =>
                    a.editing != b.editing ||
                    a.drafts.isEmpty != b.drafts.isEmpty,
                builder: (context, state) => AppBackHeader(
                  title: 'Drafts',
                  onBack: _back,
                  actions: [
                    if (unsent && state.drafts.isNotEmpty)
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(
                            AppSpacing.minTapTarget,
                            AppSpacing.minTapTarget,
                          ),
                        ),
                        onPressed: state.editing
                            ? context.read<DraftsCubit>().editFinished
                            : context.read<DraftsCubit>().editStarted,
                        child: Text(state.editing ? 'Done' : 'Edit'),
                      ),
                  ],
                ),
              ),
              AppTabBar(
                tabs: const [
                  AppTab(label: kDraftsTabUnsent),
                  AppTab(label: kDraftsTabScheduled),
                ],
                selectedIndex: _tab,
                onChanged: _selectTab,
                equalWidth: true,
                semanticLabel: 'Drafts',
              ),
              Expanded(
                child: unsent
                    ? _UnsentTab(
                        now: widget.now,
                        onOpen: _open,
                        onDelete: _deleteSelected,
                      )
                    : const ScheduledPostsBody(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 30-day note above the list.
class _RetentionNote extends StatelessWidget {
  const _RetentionNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Text(
        kDraftsRetentionNote,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _UnsentTab extends StatelessWidget {
  const _UnsentTab({
    required this.now,
    required this.onOpen,
    required this.onDelete,
  });

  final DateTime Function() now;
  final ValueChanged<String> onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DraftsCubit>();
    return BlocBuilder<DraftsCubit, DraftsViewState>(
      builder: (context, state) {
        switch (state.status) {
          case DraftsStatus.loading:
            return const SingleChildScrollView(
              physics: NeverScrollableScrollPhysics(),
              child: PostListSkeleton(
                rows: 3,
                mediaEvery: 0,
                semanticsLabel: 'Loading unsent posts',
              ),
            );
          case DraftsStatus.error:
            return AppErrorView(
              error: const UnknownApiException(
                "Your unsent posts couldn't be loaded.",
              ),
              onRetry: cubit.retry,
            );
          case DraftsStatus.ready:
            break;
        }
        if (state.drafts.isEmpty) {
          return const SingleChildScrollView(
            child: HeadlineMessage(
              title: kDraftsEmptyTitle,
              body: kDraftsEmptyBody,
            ),
          );
        }
        final clock = now();
        return Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  const SliverToBoxAdapter(child: _RetentionNote()),
                  SliverList.builder(
                    itemCount: state.drafts.length,
                    findChildIndexCallback: (key) {
                      if (key is! ValueKey<String>) return null;
                      final index = state.drafts.indexWhere(
                        (d) => 'draft-${d.id}' == key.value,
                      );
                      return index < 0 ? null : index;
                    },
                    itemBuilder: (context, index) {
                      final draft = state.drafts[index];
                      return Column(
                        key: ValueKey('draft-${draft.id}'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DraftRow(
                            draft: draft,
                            now: clock,
                            editing: state.editing,
                            selected: state.selected.contains(draft.id),
                            onTap: () => state.editing
                                ? cubit.toggled(draft.id)
                                : onOpen(draft.id),
                          ),
                          const Divider(height: 1),
                        ],
                      );
                    },
                  ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: AppSpacing.lg),
                  ),
                ],
              ),
            ),
            if (state.editing)
              _EditBar(
                allSelected: state.allSelected,
                anySelected: state.selected.isNotEmpty,
                onSelectAll: state.allSelected
                    ? cubit.clearSelection
                    : cubit.selectAll,
                onDelete: onDelete,
              ),
          ],
        );
      },
    );
  }
}

/// Edit mode's bottom bar: "Select all" at the start, a red "Delete" at the
/// end (off until something is selected). Both are 48dp targets.
class _EditBar extends StatelessWidget {
  const _EditBar({
    required this.allSelected,
    required this.anySelected,
    required this.onSelectAll,
    required this.onDelete,
  });

  final bool allSelected;
  final bool anySelected;
  final VoidCallback onSelectAll;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const size = Size(AppSpacing.minTapTarget, AppSpacing.minTapTarget);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Flexible(
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: size),
                  onPressed: onSelectAll,
                  child: Text(
                    allSelected ? 'Deselect all' : 'Select all',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const Spacer(),
              Flexible(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                    minimumSize: size,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: anySelected ? onDelete : null,
                  child: const Text(
                    'Delete',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
