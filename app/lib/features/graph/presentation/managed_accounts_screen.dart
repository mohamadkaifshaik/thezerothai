import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../data/graph_repository.dart';
import '../../settings/presentation/settings_up.dart';
import 'bloc/user_list_cubit.dart';
import 'graph_error_messages.dart';
import 'widgets/paged_user_list.dart';
import 'widgets/user_list_row.dart';

enum _ManagedAccountsKind { blocked, muted }

/// Settings → Blocked accounts (only shown when the graph flag is on, see
/// `SettingsScreen`). Unblocking is optimistic with an "Undo" snackbar
/// (undo = Block again, with a fresh idempotency key).
class BlockedAccountsScreen extends StatelessWidget {
  const BlockedAccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ManagedAccountsScreen(kind: _ManagedAccountsKind.blocked);
  }
}

/// Settings → Muted accounts. Same shape as [BlockedAccountsScreen].
class MutedAccountsScreen extends StatelessWidget {
  const MutedAccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ManagedAccountsScreen(kind: _ManagedAccountsKind.muted);
  }
}

class _ManagedAccountsScreen extends StatefulWidget {
  const _ManagedAccountsScreen({required this.kind});

  final _ManagedAccountsKind kind;

  @override
  State<_ManagedAccountsScreen> createState() => _ManagedAccountsScreenState();
}

class _ManagedAccountsScreenState extends State<_ManagedAccountsScreen> {
  static const _uuid = Uuid();

  late final GraphRepository _graphRepository = context.read<GraphRepository>();
  late final UserListCubit _cubit = UserListCubit(
    fetchPage: widget.kind == _ManagedAccountsKind.blocked
        ? _graphRepository.listBlockedUsers
        : _graphRepository.listMutedUsers,
  )..loadFirstPage();

  bool get _isBlocked => widget.kind == _ManagedAccountsKind.blocked;

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  Future<void> _removeAction(graph.UserListItem item) async {
    final userId = item.user.userId;
    final removed = _cubit.removeUser(userId);
    if (removed == null) return;
    final (removedItem, index) = removed;
    try {
      if (_isBlocked) {
        await _graphRepository.unblock(
          userId: userId,
          idempotencyKey: _uuid.v4(),
        );
      } else {
        await _graphRepository.unmute(
          userId: userId,
          idempotencyKey: _uuid.v4(),
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              _isBlocked
                  ? 'Unblocked @${removedItem.user.handle}'
                  : 'Unmuted @${removedItem.user.handle}',
            ),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => _undo(removedItem, index),
            ),
          ),
        );
    } on AppException catch (e) {
      // The unblock/unmute call itself failed: put the row back.
      _cubit.restoreItem(removedItem, index);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(relationshipErrorMessage(e))));
    }
  }

  Future<void> _undo(graph.UserListItem item, int index) async {
    try {
      if (_isBlocked) {
        await _graphRepository.block(
          userId: item.user.userId,
          idempotencyKey: _uuid.v4(),
        );
      } else {
        await _graphRepository.mute(
          userId: item.user.userId,
          idempotencyKey: _uuid.v4(),
        );
      }
      _cubit.restoreItem(item, index);
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(relationshipErrorMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // The tablet layout with nothing to pop: up to Privacy & safety.
        leading: settingsUpButton(
          context,
          settingsUpLocation(
            _isBlocked
                ? AppRouter.blockedAccountsPath
                : AppRouter.mutedAccountsPath,
          ),
        ),
        title: Text(_isBlocked ? 'Blocked accounts' : 'Muted accounts'),
      ),
      // The readable column on the tablet layout (at most 680, centred; the
      // bar above spans the pane). No cap anywhere else, as before.
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: ShellGeometry.readableMaxWidth(
              context,
              otherwise: double.infinity,
            ),
          ),
          // Tight, as the body was: the list fills the column, under the
          // design's one-line explanation (ManagedAccounts.dc.html).
          child: SizedBox.expand(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Intro(blocked: _isBlocked),
                Expanded(
                  child: PagedUserList(
                    cubit: _cubit,
                    emptyMessage: _isBlocked
                        ? "You haven't blocked anyone."
                        : "You haven't muted anyone.",
                    rowBuilder: (context, item) => UserListRow(
                      item: item,
                      // ManagedAccounts.dc.html: the 36 dp outline pill in a 48 dp
                      // target.
                      trailing: AppPillButton(
                        label: _isBlocked ? 'Unblock' : 'Unmute',
                        variant: AppButtonVariant.outline,
                        compact: true,
                        onPressed: () => _removeAction(item),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What blocking or muting does, above the list (the design's line). Muted
/// has no design of its own: the same line, in its words.
class _Intro extends StatelessWidget {
  const _Intro({required this.blocked});

  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.lg - AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.lg - AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Text(
        blocked
            ? "They can't see your plans or message you. They aren't told "
                  'you blocked them.'
            : "You won't see their posts in your timelines. They aren't told "
                  'you muted them.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
