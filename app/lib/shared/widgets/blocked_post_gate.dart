import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_theme.dart';
import '../../features/graph/data/graph_repository.dart';

/// ADR-0010 D6: a post of an author the viewer blocks sits behind a
/// "You blocked @x - Show post" banner until the viewer taps Show post.
///
/// Reads the block state from the local relationship cache
/// ([GraphRepository.cached]) on every build, so a block/unblock made from
/// the card's menu shows up as soon as the parent rebuilds. Without
/// [graphEnabled] the child is always shown. Used by the post and thread
/// screens (focal and context posts).
class BlockedPostGate extends StatefulWidget {
  const BlockedPostGate({
    super.key,
    required this.authorId,
    required this.handle,
    required this.graphEnabled,
    required this.child,
  });

  final String authorId;
  final String handle;
  final bool graphEnabled;
  final Widget child;

  @override
  State<BlockedPostGate> createState() => _BlockedPostGateState();
}

class _BlockedPostGateState extends State<BlockedPostGate> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final blocked =
        widget.graphEnabled &&
        (context.read<GraphRepository>().cached(widget.authorId)?.blocking ??
            false);
    // Unblocking forgets "Show post": a later re-block hides it again.
    if (!blocked) _revealed = false;
    if (!blocked || _revealed) return widget.child;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'You blocked @${widget.handle} ·',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: () => setState(() => _revealed = true),
            child: const Text('Show post'),
          ),
        ],
      ),
    );
  }
}
