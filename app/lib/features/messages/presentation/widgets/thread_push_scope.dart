import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../notifications/presentation/bloc/push_cubit.dart';
import '../bloc/messages_badge_cubit.dart';
import '../bloc/thread_cubit.dart';

/// Ties one open conversation to the app-wide push and badge state (W7-19,
/// ADR-0027 D7, D10). It sits under the `ThreadCubit` provider.
///
/// - While it is mounted the Messages badge knows the conversation is open, so
///   a foreground push for it is not counted as unread.
/// - A foreground direct-message push for this conversation calls
///   `ThreadCubit.onPush`, an immediate pull when the thread is visible (the
///   poller ignores it when hidden). No banner is drawn: the message just
///   appears in the open thread. Pushes for other conversations are ignored
///   here (the badge counts them).
class ThreadPushScope extends StatefulWidget {
  const ThreadPushScope({
    super.key,
    required this.conversationId,
    required this.child,
  });

  final String conversationId;
  final Widget child;

  @override
  State<ThreadPushScope> createState() => _ThreadPushScopeState();
}

class _ThreadPushScopeState extends State<ThreadPushScope> {
  late final MessagesBadgeCubit _badge = context.read<MessagesBadgeCubit>();
  bool _registered = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: clearing a pushed conversation emits, and a
    // cubit must not emit to the shell while the tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _registered = true;
      _badge.opened(widget.conversationId);
    });
  }

  @override
  void dispose() {
    if (_registered) _badge.closed(widget.conversationId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<PushCubit, PushState>(
      listenWhen: (a, b) =>
          b.messagePushes > a.messagePushes &&
          b.lastMessageConversationId == widget.conversationId,
      listener: (context, _) => context.read<ThreadCubit>().onPush(),
      child: widget.child,
    );
  }
}
