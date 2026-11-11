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
import '../data/communities_repository.dart';
import 'bloc/community_moderation_cubit.dart';
import 'bloc/community_moderation_log_cubit.dart';
import 'communities_error_messages.dart';
import 'widgets/community_unavailable_view.dart';
import 'widgets/moderation_log_about.dart';
import 'widgets/moderation_log_row.dart';

/// `/communities/:id/moderation-log`: what the moderators did, newest
/// first, 1 `ListModerationLog` per page. Only owner and moderators can read
/// it (the server answers FORBIDDEN `not_moderator`, shown as a sentence); a
/// hidden post can be restored from its HIDE entry. The log is as of the last
/// open: pull to refresh.
class CommunityModerationLogScreen extends StatefulWidget {
  const CommunityModerationLogScreen({
    super.key,
    required this.communityId,
    this.now,
  });

  final String communityId;

  /// Reference time of the relative times; the clock when null (tests pass one).
  final DateTime? now;

  @override
  State<CommunityModerationLogScreen> createState() =>
      _CommunityModerationLogScreenState();
}

class _CommunityModerationLogScreenState
    extends State<CommunityModerationLogScreen> {
  late final CommunityModerationCubit _moderation = CommunityModerationCubit(
    communityId: widget.communityId,
    communities: context.read<CommunitiesRepository>(),
  );
  late final CommunityModerationLogCubit _log = CommunityModerationLogCubit(
    communityId: widget.communityId,
    communities: context.read<CommunitiesRepository>(),
    moderation: _moderation,
  )..load();
  final _scroll = ScrollController();

  /// Band B's context pane: "About this log" over this page's [_log], only
  /// once it lists entries (the caller moderates), as band A's list; the
  /// placeholder while it loads; nothing when it is locked, gone, failed or
  /// empty (T8a polish).
  final _paneLease = ContextPaneLease();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _paneLease.attach(
      context,
      AppRouter.communityModerationLogPath(widget.communityId),
      {
        ContextSectionKind.moderationLogAbout: (context) =>
            BlocBuilder<CommunityModerationLogCubit, ModerationLogState>(
              bloc: _log,
              buildWhen: (a, b) =>
                  (a.status == ModerationLogStatus.loading) !=
                      (b.status == ModerationLogStatus.loading) ||
                  moderationLogListed(a) != moderationLogListed(b),
              builder: (context, state) =>
                  state.status == ModerationLogStatus.loading
                  ? const ModerationLogAboutPlaceholder()
                  : moderationLogListed(state)
                  ? const ModerationLogAbout()
                  : const SizedBox.shrink(),
            ),
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.maxScrollExtent > 0 && p.pixels >= p.maxScrollExtent * 0.7) {
        _log.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _paneLease.dispose();
    _scroll.dispose();
    _log.close();
    _moderation.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.communityPath(widget.communityId));
    }
  }

  Future<void> _restore(String postId) async {
    final error = await _log.restore(postId);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            error == null
                ? 'Restored to the Community.'
                : communitiesErrorMessage(error),
          ),
        ),
      );
  }

  Widget _centered(Widget child) =>
      Center(child: SingleChildScrollView(child: child));

  /// The log for [state]. [aboutInline] (tablet band A) puts "About this
  /// log" first in the list once there are entries, so it scrolls with
  /// them; the loading, empty, locked and not-found states go without it.
  Widget _body(ModerationLogState state, {required bool aboutInline}) {
    final error = state.error;
    if (state.status == ModerationLogStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ModerationLogStatus.error && error != null) {
      if (error is NotFoundException) {
        return _centered(const CommunityUnavailableView());
      }
      if (error is CommunityForbiddenException ||
          error is FeatureDisabledException) {
        return _centered(
          AppEmptyView(
            icon: Icons.lock_outline,
            title: communitiesErrorMessage(error),
          ),
        );
      }
      return _centered(AppErrorView(error: error, onRetry: _log.load));
    }
    if (state.entries.isEmpty) {
      return RefreshIndicator(
        onRefresh: _log.load,
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight),
              child: const Center(
                child: AppEmptyView(
                  icon: Icons.shield_outlined,
                  title: 'Nothing here yet',
                  subtitle:
                      'Removed posts, bans and role changes will be listed '
                      'here.',
                ),
              ),
            ),
          ),
        ),
      );
    }
    final now = widget.now ?? DateTime.now();
    final footer =
        state.status == ModerationLogStatus.loadingMore || state.loadMoreFailed;
    final lead = aboutInline ? 1 : 0;
    return RefreshIndicator(
      onRefresh: _log.load,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: lead + state.entries.length + (footer ? 1 : 0),
        itemBuilder: (context, index) {
          if (index < lead) {
            return const ModerationLogAbout(
              key: ValueKey('moderation-log-about'),
              margin: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm,
              ),
            );
          }
          final i = index - lead;
          if (i == state.entries.length) {
            if (state.loadMoreFailed) {
              return TextButton(
                onPressed: _log.loadMore,
                child: const Text("Couldn't load more. Retry"),
              );
            }
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final entry = state.entries[i];
          return BlocBuilder<
            CommunityModerationCubit,
            CommunityModerationState
          >(
            bloc: _moderation,
            buildWhen: (a, b) =>
                a.isBusy(entry.postId) != b.isBusy(entry.postId),
            builder: (context, mod) => ModerationLogRow(
              key: ValueKey('log-${entry.seq}'),
              entry: entry,
              now: now,
              restored: state.isRestored(entry),
              busy: mod.isBusy(entry.postId),
              onRestore: state.canRestore(entry)
                  ? () => _restore(entry.postId)
                  : null,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // "About this log" (tablet plan section 4.1, ModLog): the first item of
    // the loaded log in band A, in the context pane in band B. Only on the
    // tablet layout: phones and desktop keep today's page (ruling R-1).
    final tablet = ShellGeometry.maybeOf(context)?.tablet ?? false;
    final aboutInline =
        tablet &&
        !ContextPaneScope.shows(context, ContextSectionKind.moderationLogAbout);
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(title: 'Moderation log', onBack: _back),
              Expanded(
                child:
                    BlocBuilder<
                      CommunityModerationLogCubit,
                      ModerationLogState
                    >(
                      bloc: _log,
                      builder: (context, state) =>
                          _body(state, aboutInline: aboutInline),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
