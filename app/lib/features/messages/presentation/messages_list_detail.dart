import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../domain/messaging_feature_gate.dart';
import 'bloc/conversations_cubit.dart';
import 'bloc/conversations_session.dart';
import 'conversations_screen.dart';
import 'widgets/messaging_access_builder.dart';

/// Messages list–detail on the tablet layout from 840dp (band B; tablet plan
/// sections 3 and 5.3).
///
/// - On the shell's `/messages` and `/messages/requests`, `MainShell` shows a
///   [ConversationsListPane] of that folder beside the page and publishes it
///   with a [ConversationsMasterScope], so the route child draws the
///   [ConversationsDetailPlaceholder] instead of a second list.
/// - On the root thread routes (`/messages/:id`, `/messages/new/draft`),
///   `ThreadRoutePage` builds the split page: a `MainShell` whose list pane
///   is a [ConversationsListPane] with `split: true` beside the thread.
///
/// Every placement reads the app's hoisted [ConversationsSession], so the
/// list is loaded once. Everywhere else (phones, band A, desktop, either
/// shell flag off, no session) the scope says no and the pages are today's.
class ConversationsMasterScope extends InheritedWidget {
  const ConversationsMasterScope({
    super.key,
    required this.shown,
    required super.child,
  });

  /// The list pane is beside this page.
  final bool shown;

  /// Whether the Messages list pane is beside [context]'s page; false without
  /// a scope.
  static bool shownOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ConversationsMasterScope>()
          ?.shown ??
      false;

  @override
  bool updateShouldNotify(ConversationsMasterScope oldWidget) =>
      shown != oldWidget.shown;
}

/// Provides the hoisted cubit of [folder] to [builder], and rebinds when
/// the session drops it (an account reset, access hidden). [open] opens it
/// on mount (a route visit: cache, then one refresh); otherwise it only makes
/// sure it was loaded once (a list pane: crossing 840dp or switching
/// conversations sends nothing). It never closes the cubit.
class ConversationsSessionScope extends StatefulWidget {
  const ConversationsSessionScope({
    super.key,
    required this.session,
    required this.folder,
    required this.builder,
    this.open = false,
  });

  final ConversationsSession session;
  final Folder folder;
  final bool open;
  final WidgetBuilder builder;

  @override
  State<ConversationsSessionScope> createState() =>
      _ConversationsSessionScopeState();
}

class _ConversationsSessionScopeState extends State<ConversationsSessionScope> {
  late ConversationsCubit _cubit;

  @override
  void initState() {
    super.initState();
    widget.session.changes.addListener(_rebind);
    _cubit = _bind();
  }

  ConversationsCubit _bind() {
    final cubit = widget.session.cubitFor(widget.folder);
    unawaited(widget.open ? cubit.open() : cubit.ensureLoaded());
    return cubit;
  }

  void _rebind() {
    if (!mounted) return;
    // After the frame: the session may drop the cubits while the tree is
    // being built (a flag change), and a closed cubit is never read again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final next = widget.session.cubitFor(widget.folder);
      if (identical(next, _cubit)) return;
      setState(() => _cubit = _bind());
    });
  }

  @override
  void didUpdateWidget(ConversationsSessionScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.changes.removeListener(_rebind);
      widget.session.changes.addListener(_rebind);
    }
    if (!identical(oldWidget.session, widget.session) ||
        oldWidget.folder != widget.folder) {
      _cubit = _bind();
    }
  }

  @override
  void dispose() {
    widget.session.changes.removeListener(_rebind);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ConversationsCubit>.value(
      value: _cubit,
      child: Builder(builder: widget.builder),
    );
  }
}

/// Band B's Messages list pane: the inbox or the Requests folder over the
/// hoisted cubit, with the open conversation ([selectedId]) highlighted.
///
/// - On the shell (`split` false), a row `push`es the root thread route, as
///   the route list does; a Requests row passes `extra:
///   Folder.FOLDER_REQUESTS`, so the split page keeps the Requests list.
/// - In the split page (`split` true), a row replaces the thread
///   (`pushReplacement`, the stack stays one page deep, the Requests extra
///   passed again); the open row does nothing. The inbox's Requests row and
///   the Requests back go to the shell folder (`go`): a shell page is never
///   pushed over the root thread route. The scroll offset survives the
///   remount on every switch ([ConversationsSession.bucketFor]).
class ConversationsListPane extends StatelessWidget {
  const ConversationsListPane({
    super.key,
    required this.folder,
    this.selectedId,
    this.split = false,
  });

  final Folder folder;
  final String? selectedId;
  final bool split;

  bool get _requests => folder == Folder.FOLDER_REQUESTS;

  void _open(BuildContext context, String id) {
    final location = AppRouter.messagePath(id);
    final extra = _requests ? Folder.FOLDER_REQUESTS : null;
    if (!split) {
      unawaited(context.push<void>(location, extra: extra));
      return;
    }
    if (id == selectedId) return;
    unawaited(
      GoRouter.of(context).pushReplacement<void>(location, extra: extra),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<ConversationsSession>();
    return MessagingAccessBuilder(
      builder: (context, access) {
        if (access == MessagingAccess.hidden) return const SizedBox.shrink();
        final full = access == MessagingAccess.full;
        return ConversationsSessionScope(
          session: session,
          folder: folder,
          builder: (context) => ConversationsList(
            folder: folder,
            selectedId: selectedId,
            canCompose: full,
            onOpenConversation: (id) => _open(context, id),
            onNewMessage: full
                ? () => unawaited(context.push<void>(AppRouter.messageNewPath))
                : null,
            onOpenRequests: split
                ? () => context.go(AppRouter.messageRequestsPath)
                : null,
            onBack: split ? () => context.go(AppRouter.messagesPath) : null,
            storage: split ? session.bucketFor(folder) : null,
          ),
        );
      },
    );
  }
}

/// The band B detail of `/messages` and `/messages/requests` when no
/// conversation is open (tablet plan sections 3 and 6.8): icon, "Select a
/// conversation" and, for a caller who may send, New message.
class ConversationsDetailPlaceholder extends StatelessWidget {
  const ConversationsDetailPlaceholder({super.key, this.onNewMessage});

  final VoidCallback? onNewMessage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.mail_outline,
                    size: AppSpacing.xxl,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(kSelectAConversation, textAlign: TextAlign.center),
                if (onNewMessage != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    onPressed: onNewMessage,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text(kNewMessageLabel),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The placeholder's line (tablet plan sections 3 and 6.8).
const kSelectAConversation = 'Select a conversation';

/// The placeholder's action, as the inbox's header action is named.
const kNewMessageLabel = 'New message';
