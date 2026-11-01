part of 'post_card.dart';

enum _MenuAction { delete, block, mute, report, pin }

/// Closes [cubit] now, or once its in-flight Block/Mute settles, so the
/// awaiting `_run` still sees the real outcome (never an optimistic state).
void _closeWhenSettled(RelationshipCubit cubit) {
  if (cubit.isClosed) return;
  if (cubit.state.isUpdating) {
    cubit.stream
        .firstWhere((s) => !s.isUpdating)
        .then((_) => cubit.close(), onError: (_) => cubit.close());
  } else {
    cubit.close();
  }
}

/// Whether a post of this [kind] can be pinned: the server accepts the
/// caller's own POST, QUOTE or REPLY, never a REPOST (ADR-0024 D3).
bool _isPinnable(PostKind kind) =>
    kind == PostKind.POST_KIND_POST ||
    kind == PostKind.POST_KIND_QUOTE ||
    kind == PostKind.POST_KIND_REPLY;

/// Who Report / Block / Mute act on (see [PostCard._menuTarget]).
class _MenuTarget {
  const _MenuTarget({
    required this.userId,
    required this.handle,
    required this.postId,
    required this.isOwn,
    required this.reportLabel,
    required this.subject,
  });

  final String userId;
  final String handle;
  final String postId;

  /// The viewer is this target's author (no Report / Block / Mute).
  final bool isOwn;
  final String reportLabel;
  final String subject;
}

/// The overflow menu. For another author it holds ONE [RelationshipCubit]
/// for the card's lifetime (created on first open), so a retry after a
/// failed Block/Mute reuses the same idempotency key (CLAUDE.md rule 4).
class _PostMenu extends StatefulWidget {
  const _PostMenu({
    required this.post,
    required this.isOwn,
    required this.target,
    required this.graphActionsEnabled,
    required this.reportsEnabled,
    required this.onDelete,
    required this.onRelationshipChanged,
    this.pinControl,
  });

  /// The row's own post: Delete acts on it (a repost's id for a repost).
  final pb.Post post;

  /// The viewer authored [post] (gates Delete).
  final bool isOwn;
  final _MenuTarget target;
  final bool graphActionsEnabled;
  final bool reportsEnabled;
  final Future<void> Function(String postId)? onDelete;
  final ValueChanged<graph.Relationship>? onRelationshipChanged;

  /// Pin / Unpin rows for [post], or null for none.
  final PostPinControl? pinControl;

  @override
  State<_PostMenu> createState() => _PostMenuState();
}

class _PostMenuState extends State<_PostMenu> {
  RelationshipCubit? _cubit;

  RelationshipCubit _cubitFor(BuildContext context) {
    final existing = _cubit;
    if (existing != null && existing.userId == widget.target.userId) {
      return existing;
    }
    if (existing != null) _closeWhenSettled(existing);
    final repository = context.read<GraphRepository>();
    final userId = widget.target.userId;
    return _cubit = RelationshipCubit(
      graphRepository: repository,
      userId: userId,
      initial: repository.cached(userId) ?? graph.Relationship(userId: userId),
    );
  }

  @override
  void dispose() {
    // A Block/Mute still in flight keeps its cubit until it settles, so
    // `_run` can still report the result (the server applied it).
    final cubit = _cubit;
    if (cubit != null) _closeWhenSettled(cubit);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    final handle = target.handle;
    final canDelete = widget.isOwn && widget.onDelete != null;
    final canGraph =
        !target.isOwn && widget.graphActionsEnabled && target.userId.isNotEmpty;
    final canReport =
        !target.isOwn &&
        widget.reportsEnabled &&
        target.userId.isNotEmpty &&
        target.postId.isNotEmpty;
    final pin = widget.pinControl;
    // Unpin is a clear, so it is on offer on the pinned post whatever the
    // flag; Pin is a set and follows [PostPinControl.canPin].
    final showPin =
        pin != null &&
        widget.isOwn &&
        _isPinnable(widget.post.kind) &&
        pin.offersRowFor(widget.post.postId);
    if (!canDelete && !canGraph && !canReport && !showPin) {
      return const SizedBox.shrink();
    }

    return PopupMenuButton<_MenuAction>(
      tooltip: 'More options',
      icon: Icon(
        Icons.more_horiz,
        size: AppIconSize.lg,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      padding: const EdgeInsets.all(AppSpacing.md - AppSpacing.xs),
      onSelected: (action) => _onSelected(context, action),
      itemBuilder: (context) {
        final relationship = canGraph
            ? _cubitFor(context).state.relationship
            : null;
        return [
          if (canDelete)
            const PopupMenuItem(
              value: _MenuAction.delete,
              child: AppMenuItemRow(
                icon: Icons.delete_outline,
                label: 'Delete',
                destructive: true,
              ),
            ),
          if (showPin)
            PopupMenuItem(
              value: _MenuAction.pin,
              child: AppMenuItemRow(
                icon: Icons.push_pin_outlined,
                label: pin.isPinned(widget.post.postId)
                    ? 'Unpin from profile'
                    : 'Pin to your profile',
              ),
            ),
          if (canReport)
            PopupMenuItem(
              value: _MenuAction.report,
              child: AppMenuItemRow(
                icon: Icons.flag_outlined,
                label: target.reportLabel,
              ),
            ),
          if (relationship != null) ...[
            PopupMenuItem(
              value: _MenuAction.block,
              child: AppMenuItemRow(
                icon: relationship.blocking
                    ? Icons.lock_open_outlined
                    : Icons.block,
                label: relationship.blocking
                    ? 'Unblock @$handle'
                    : 'Block @$handle',
              ),
            ),
            PopupMenuItem(
              value: _MenuAction.mute,
              child: AppMenuItemRow(
                icon: relationship.muting
                    ? Icons.volume_up_outlined
                    : Icons.volume_off_outlined,
                label: relationship.muting
                    ? 'Unmute @$handle'
                    : 'Mute @$handle',
              ),
            ),
          ],
        ];
      },
    );
  }

  Future<void> _onSelected(BuildContext context, _MenuAction action) async {
    switch (action) {
      case _MenuAction.delete:
        await _delete(context);
      case _MenuAction.block:
        await _blockFlow(context);
      case _MenuAction.report:
        await _report(context);
      case _MenuAction.pin:
        await _pin(context);
      case _MenuAction.mute:
        final cubit = _cubitFor(context);
        if (cubit.state.relationship.muting) {
          await _run(context, cubit.unmute, 'Unmuted');
        } else {
          await _run(context, cubit.mute, 'Muted');
        }
    }
  }

  Future<void> _blockFlow(BuildContext context) async {
    final cubit = _cubitFor(context);
    if (cubit.state.relationship.blocking) {
      await _run(context, cubit.unblock, 'Unblocked');
    } else {
      final confirmed = await showBlockConfirmationDialog(context);
      if (confirmed && context.mounted) {
        await _run(context, cubit.block, 'Blocked');
      }
    }
  }

  /// Report sheet; after a successful report it can hand over to the same
  /// block flow as the menu's Block item (confirmation included).
  Future<void> _report(BuildContext context) async {
    final target = widget.target;
    final handle = target.handle;
    final canBlock =
        widget.graphActionsEnabled &&
        !_cubitFor(context).state.relationship.blocking;
    final outcome = await showReportSheet(
      context,
      targetType: ReportTargetType.REPORT_TARGET_TYPE_POST,
      targetId: target.postId,
      subject: target.subject,
      blockLabel: canBlock ? 'Block @$handle' : null,
    );
    if (outcome == ReportOutcome.blockRequested && context.mounted) {
      await _blockFlow(context);
    }
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String done,
  ) async {
    final cubit = _cubit!;
    final messenger = ScaffoldMessenger.of(context);
    // Captured now: the card may be disposed while the request is in flight.
    final onChanged = widget.onRelationshipChanged;
    final handle = widget.target.handle;
    await action();
    final error = cubit.state.error;
    // The snackbar only makes sense while the card is still on screen; the
    // callback fires either way because the server applied the change.
    void say(String text) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    if (error != null) {
      say(relationshipErrorMessage(error));
      return;
    }
    say('$done @$handle.');
    onChanged?.call(cubit.state.relationship);
  }

  /// Pin / Unpin the row's own post through [PostPinControl]. Replacing an
  /// existing pin asks first. A failure is a typed snackbar (Retry reuses the
  /// control's idempotency key, so it is the same intent). The snackbars go
  /// through the messenger captured now: pinning moves the card out of the
  /// feed, so this widget may be gone when the answer arrives.
  Future<void> _pin(BuildContext context) async {
    final control = widget.pinControl!;
    final messenger = ScaffoldMessenger.of(context);
    final postId = widget.post.postId;
    if (control.isPinned(postId)) {
      await _runPin(messenger, control.onUnpin, 'Unpinned from your profile.');
      return;
    }
    if (control.pinnedPostId.isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace your pinned post?'),
          content: const Text(
            'This post will be pinned instead of the one pinned now.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    await _runPin(
      messenger,
      () => control.onPin(postId),
      'Pinned to your profile.',
    );
  }

  Future<void> _runPin(
    ScaffoldMessengerState messenger,
    Future<void> Function() action,
    String done,
  ) async {
    void say(String text, {VoidCallback? retry}) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(text),
            action: retry == null
                ? null
                : SnackBarAction(label: 'Retry', onPressed: retry),
          ),
        );
    }

    try {
      await action();
      say(done);
    } on AppException catch (error) {
      say(
        pinErrorMessage(error),
        retry: pinErrorCanRetry(error)
            ? () => unawaited(_runPin(messenger, action, done))
            : null,
      );
    } catch (_) {
      say(
        "Couldn't update your pinned post. Please try again.",
        retry: () => unawaited(_runPin(messenger, action, done)),
      );
    }
  }

  Future<void> _delete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this post?'),
        content: const Text("This can't be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.onDelete!(widget.post.postId);
    } catch (_) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text("Couldn't delete the post. Please try again."),
          ),
        );
    }
  }
}
