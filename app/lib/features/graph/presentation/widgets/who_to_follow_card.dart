import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_surface.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../bloc/suggestions_cubit.dart';
import '../bloc/suggestions_state.dart';
import '../graph_feature_flags.dart';
import 'user_list_row.dart';

/// How many rows the card shows before "Show more".
const kWhoToFollowCollapsedRows = 3;

/// The "Who to follow" card (W3-19, ADR-0024 D8): an [AppSurface] with a
/// [title], up to [kWhoToFollowCollapsedRows] [UserListRow]s (each with a
/// follow button and a local "x"), and "Show more" opening the full 5. Used
/// twice with one list behind it: titled "Who to follow" in Home's
/// `headerSlivers`, and "You might like" in the desktop right column.
///
/// Renders nothing (and asks for nothing) unless `follow_suggestions` and
/// `graph` are both on and the viewer is known; nothing too while the list is
/// loading, empty, or unavailable (a limit, a failure, FEATURE_DISABLED): it
/// never explains itself. A followed row disappears once the server confirms
/// the follow, and when that was the last visible row the list is asked for
/// again, once per session ([SuggestionsCubit.followed]); the "x" hides a row
/// for the session only and never asks again. A row the server
/// says is gone (NOT_FOUND: it blocked the viewer, was suspended or deleted)
/// is dropped silently, from the cached list too (W3-22 L-1). Not a sliver:
/// wrap it in a `SliverToBoxAdapter`. Needs [SuggestionsCubit] and
/// `GraphRepository` in scope (only once the flag check passes).
class WhoToFollowCard extends StatelessWidget {
  const WhoToFollowCard({
    super.key,
    this.title = 'Who to follow',
    this.margin = EdgeInsets.zero,
  });

  final String title;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    if (!isFollowSuggestionsEnabled(context)) return const SizedBox.shrink();
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    if (viewerUserId == null || viewerUserId.isEmpty) {
      return const SizedBox.shrink();
    }
    return _Loader(
      key: ValueKey(viewerUserId),
      viewerUserId: viewerUserId,
      child: _Card(title: title, margin: margin),
    );
  }
}

/// Asks the shared cubit for the list once per mount (a warm call is memory
/// only: the repository holds the 48 h answer).
class _Loader extends StatefulWidget {
  const _Loader({super.key, required this.viewerUserId, required this.child});

  final String viewerUserId;
  final Widget child;

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: an emit while the tree is building would mark
    // the other surface dirty mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SuggestionsCubit>().ensureLoaded(widget.viewerUserId);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A card that stays mounted for days (a desktop tab, a resumed phone) asks
  /// again on resume. Free while the entry is fresh (memory only, 0 RPCs); past
  /// its lifetime it is one call, shared by every surface in flight, and the
  /// stale rows go (ADR-0024 Amendment 2: up to 48 h). No timer, no polling.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    unawaited(
      context.read<SuggestionsCubit>().ensureLoaded(widget.viewerUserId),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Card extends StatefulWidget {
  const _Card({required this.title, required this.margin});

  final String title;
  final EdgeInsetsGeometry margin;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SuggestionsCubit, SuggestionsState>(
      builder: (context, state) {
        final items = state.items;
        if (items.isEmpty) return const SizedBox.shrink();
        final collapsed =
            !_expanded && items.length > kWhoToFollowCollapsedRows;
        final shown = collapsed
            ? items.take(kWhoToFollowCollapsedRows).toList()
            : items;
        final cubit = context.read<SuggestionsCubit>();
        final theme = Theme.of(context);
        return AppSurface(
          margin: widget.margin,
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.xs,
                ),
                child: Semantics(
                  header: true,
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              // A stable key per account: each row owns the cubit of its
              // follow button, so removing one row must not hand its cubit to
              // the account that moved up.
              for (var i = 0; i < shown.length; i++)
                UserListRow(
                  key: ValueKey(shown[i].user.userId),
                  item: shown[i],
                  showDivider: collapsed || i < shown.length - 1,
                  onFollowed: () =>
                      unawaited(cubit.followed(shown[i].user.userId)),
                  onGone: () => cubit.drop(shown[i].user.userId),
                  onDismiss: () => cubit.hide(shown[i].user.userId),
                ),
              if (collapsed)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, AppSpacing.minTapTarget),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                    ),
                    onPressed: () => setState(() => _expanded = true),
                    child: const Text('Show more'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
