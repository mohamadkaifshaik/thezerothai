import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_notice_banner.dart';
import '../../../shared/widgets/user_list_skeleton.dart';
import '../data/messaging_repository.dart';
import '../domain/messaging_feature_flag.dart';
import 'bloc/conversations_cubit.dart';
import 'messaging_error_messages.dart';
import 'widgets/conversation_row.dart';

/// `/messages` and `/messages/requests` (W7-14, ADR-0027 D7, D14): the inbox.
///
/// One screen, two folders: [Folder.FOLDER_INBOX] (title "Messages", the
/// "New message" action and the "Message requests (N)" row) and
/// [Folder.FOLDER_REQUESTS] (a back header, the received requests).
///
/// The cached list renders at once; one `since` refresh follows on open and
/// another on resume (throttled to 60 s). There is no timer. A message push
/// is routed by the shell (W7-19), which calls `ConversationsCubit.refresh`.
/// On desktop the list sits in the 600dp main column (no master-detail in v1).
///
/// - [onOpenConversation] opens `/messages/<id>`. The route belongs to W7-15;
///   until it is wired the rows are drawn without a tap action.
/// - [onNewMessage] opens `/messages/new`. The route belongs to W7-17; until
///   it is wired the action is shown disabled.
class ConversationsScreen extends StatelessWidget {
  const ConversationsScreen({
    super.key,
    this.folder = Folder.FOLDER_INBOX,
    this.onOpenConversation,
    this.onNewMessage,
  });

  final Folder folder;
  final void Function(String conversationId)? onOpenConversation;
  final VoidCallback? onNewMessage;

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeatureMessaging)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: const Center(
          child: AppEmptyView(
            icon: Icons.mail_outline,
            title: "Messages aren't available yet",
          ),
        ),
      );
    }
    return BlocProvider<ConversationsCubit>(
      create: (context) => ConversationsCubit(
        repository: context.read<MessagingRepository>(),
        folder: folder,
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      )..load(),
      child: _ConversationsView(
        folder: folder,
        onOpenConversation: onOpenConversation,
        onNewMessage: onNewMessage,
      ),
    );
  }
}

class _ConversationsView extends StatefulWidget {
  const _ConversationsView({
    required this.folder,
    required this.onOpenConversation,
    required this.onNewMessage,
  });

  final Folder folder;
  final void Function(String conversationId)? onOpenConversation;
  final VoidCallback? onNewMessage;

  @override
  State<_ConversationsView> createState() => _ConversationsViewState();
}

class _ConversationsViewState extends State<_ConversationsView>
    with WidgetsBindingObserver {
  final ScrollController _controller = ScrollController();
  late DateTime _now = DateTime.now();

  bool get _isInbox => widget.folder == Folder.FOLDER_INBOX;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume only: never poll in the background or on a timer.
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() => _now = DateTime.now());
      unawaited(context.read<ConversationsCubit>().refreshIfStale());
    }
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.maxScrollExtent > 0 &&
        position.pixels >= kPrefetchFraction * position.maxScrollExtent) {
      unawaited(context.read<ConversationsCubit>().loadMore());
    }
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.messagesPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ConversationsCubit>();
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final inset = math.max(
            0.0,
            (constraints.maxWidth - AppBreakpoints.mobile) / 2,
          );
          return BlocBuilder<ConversationsCubit, ConversationsState>(
            builder: (context, state) {
              return RefreshIndicator(
                onRefresh: cubit.refresh,
                child: CustomScrollView(
                  controller: _controller,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    if (_isInbox)
                      AppTopBar.sliver(
                        title: 'Messages',
                        actions: [
                          IconButton(
                            tooltip: 'New message',
                            // TODO(W7-17): /messages/new is not built yet;
                            // the router passes the callback then.
                            onPressed: widget.onNewMessage,
                            icon: const Icon(Icons.mail_outline),
                          ),
                        ],
                      )
                    else
                      _inset(
                        inset,
                        SliverToBoxAdapter(
                          child: AppBackHeader(
                            title: 'Message requests',
                            onBack: _back,
                          ),
                        ),
                      ),
                    if (state.notice != null)
                      _inset(
                        inset,
                        SliverToBoxAdapter(
                          child: AppNoticeBanner(
                            message: conversationsNoticeMessage(state.notice!),
                            onRetry: noticeCanRetry(state.notice!)
                                ? cubit.refresh
                                : null,
                          ),
                        ),
                      ),
                    if (_isInbox && (state.requestCount ?? 0) > 0)
                      _inset(
                        inset,
                        SliverToBoxAdapter(
                          child: _RequestsRow(
                            count: state.requestCount!,
                            onTap: () =>
                                context.push(AppRouter.messageRequestsPath),
                          ),
                        ),
                      ),
                    ..._body(context, cubit, state, inset),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _inset(double inset, Widget sliver) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: inset),
    sliver: sliver,
  );

  List<Widget> _body(
    BuildContext context,
    ConversationsCubit cubit,
    ConversationsState state,
    double inset,
  ) {
    if (!state.hasConversations) {
      final Widget child;
      if (state.status == ConversationsStatus.error && state.error != null) {
        child = AppEmptyView(
          icon: Icons.error_outline,
          title: messagingErrorMessage(state.error!),
          action: noticeCanRetry(state.error!)
              ? FilledButton.tonal(
                  onPressed: cubit.refresh,
                  child: const Text('Retry'),
                )
              : null,
        );
      } else if (state.status == ConversationsStatus.loading ||
          state.refreshing) {
        child = const UserListSkeleton(semanticsLabel: 'Loading conversations');
      } else if (_isInbox) {
        child = const AppEmptyView(
          icon: Icons.mail_outline,
          title: 'Welcome to your inbox',
          subtitle: 'Start a conversation',
        );
      } else {
        child = const AppEmptyView(
          icon: Icons.mark_email_unread_outlined,
          title: 'No message requests',
          subtitle:
              'When someone new wants to message you, it will show up '
              'here.',
        );
      }
      return [_inset(inset, SliverToBoxAdapter(child: child))];
    }
    final conversations = state.conversations;
    final open = widget.onOpenConversation;
    return [
      _inset(
        inset,
        SliverSemantics(
          role: SemanticsRole.list,
          label: _isInbox ? 'Conversations' : 'Message requests',
          sliver: SliverList.builder(
            itemCount: conversations.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final index = conversations.indexWhere(
                (c) => 'conversation-${c.id}' == key.value,
              );
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) {
              final conversation = conversations[index];
              return Semantics(
                key: ValueKey('conversation-${conversation.id}'),
                role: SemanticsRole.listItem,
                child: ConversationRow(
                  conversation: conversation,
                  now: _now,
                  onTap: open == null ? null : () => open(conversation.id),
                ),
              );
            },
          ),
        ),
      ),
      _inset(inset, SliverToBoxAdapter(child: _footer(cubit, state))),
    ];
  }

  Widget _footer(ConversationsCubit cubit, ConversationsState state) {
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (state.loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Center(
          child: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: cubit.retryLoadMore,
            child: const Text("Couldn't load more. Retry"),
          ),
        ),
      );
    }
    return const SizedBox(height: AppSpacing.lg);
  }
}

/// The "Message requests (N)" row above the inbox: an envelope, the label and
/// a chevron in one 48dp+ tap target.
class _RequestsRow extends StatelessWidget {
  const _RequestsRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = 'Message requests ($count)';
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.listRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.smd,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: AppSpacing.xxl,
                  child: Icon(
                    Icons.mark_email_unread_outlined,
                    size: AppIconSize.lg,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Directionality.of(context) == TextDirection.rtl
                      ? Icons.chevron_left
                      : Icons.chevron_right,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
