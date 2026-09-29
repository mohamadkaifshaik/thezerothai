import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../data/graph_repository.dart';
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
        title: Text(_isBlocked ? 'Blocked accounts' : 'Muted accounts'),
      ),
      body: PagedUserList(
        cubit: _cubit,
        emptyMessage: _isBlocked
            ? "You haven't blocked anyone."
            : "You haven't muted anyone.",
        rowBuilder: (context, item) => UserListRow(
          item: item,
          trailing: TextButton(
            onPressed: () => _removeAction(item),
            child: Text(_isBlocked ? 'Unblock' : 'Unmute'),
          ),
        ),
      ),
    );
  }
}
