import 'package:flutter/material.dart';

import 'app_empty_view.dart';

/// What a stranger sees in place of a protected account's posts (ADR-0025 D4,
/// X's own wording): a lock, "These posts are protected" and how to get access.
/// The same view stands in for every tab, so the tab bar is not shown with it.
/// Also used by the Followers / Following lists, whose members are protected too
/// ([title] / [message] differ there).
class ProtectedPostsView extends StatelessWidget {
  const ProtectedPostsView({
    super.key,
    this.handle,
    this.title = 'These posts are protected',
    this.message,
  });

  final String? handle;
  final String title;

  /// Replaces the default "Only approved followers can see @handle's posts.
  /// To request access, tap Follow."
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: AppEmptyView(
        icon: Icons.lock_outline,
        title: title,
        subtitle:
            message ??
            "Only approved followers can see ${handle == null ? "this account's" : "@$handle's"} "
                'posts. To request access, tap Follow.',
      ),
    );
  }
}
