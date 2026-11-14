import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/foundation.dart' show ValueListenable;
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
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_notice_banner.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../notifications/presentation/bloc/push_cubit.dart';
import '../data/messaging_repository.dart';
import '../domain/message_search.dart';
import '../domain/messaging_feature_gate.dart';
import 'bloc/conversations_cubit.dart';
import 'bloc/conversations_session.dart';
import 'bloc/messages_badge_cubit.dart';
import 'messaging_error_messages.dart';
import 'messages_list_detail.dart';
import 'widgets/conversation_row.dart';
import 'widgets/message_search_panel.dart';
import 'widgets/messaging_access_builder.dart';
import 'widgets/not_encrypted_note.dart';
import '../../settings/presentation/widgets/message_settings_action.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../core/widgets/shell_fab.dart';

/// `/messages` and `/messages/requests`: the inbox.
///
/// One screen, two folders: [Folder.FOLDER_INBOX] (title "Messages", the
/// "New message" action and the "Message requests" card) and
/// [Folder.FOLDER_REQUESTS] (a back header, the received requests).
///
/// The cached list renders at once; one `since` refresh follows on open and
/// another on resume (throttled to 60 s). There is no timer. A foreground
/// message push (`PushState.messagePushes`) calls
/// `ConversationsCubit.refreshIfStale`.
/// On desktop the list sits in the 600dp main column (no master-detail in v1).
///
/// - [onOpenConversation] opens `/messages/<id>`. The route belongs to another screen;
///   until it is wired the rows are drawn without a tap action.
/// - [onNewMessage] opens `/messages/new` (the people picker). Null
///   (a test, or a caller that cannot) shows the action disabled.
class ConversationsScreen extends StatelessWidget {
  const ConversationsScreen({
    super.key,
    this.folder = Folder.FOLDER_INBOX,
    this.onOpenConversation,
    this.onNewMessage,
    this.refreshClock,
  });

  final Folder folder;
  final void Function(String conversationId)? onOpenConversation;
  final VoidCallback? onNewMessage;

  /// Test seam: the clock behind the 60 s refresh throttle.
  final DateTime Function()? refreshClock;

  @override
  Widget build(BuildContext context) {
    // `readOnly` (messaging off for this caller only) keeps the list,
    // the requests and the clean-up, and drops the New message action.
    return MessagingAccessBuilder(
      builder: (context, access) {
        if (access == MessagingAccess.hidden) {
          return Scaffold(
            appBar: AppBar(title: const Text('Messages'), centerTitle: true),
            body: const Center(
              child: AppEmptyView(
                icon: Icons.mail_outline,
                title: "Messages aren't available yet",
              ),
            ),
          );
        }
        final newMessage = access == MessagingAccess.full ? onNewMessage : null;
        Widget list(BuildContext context) => ConversationsList(
          folder: folder,
          onOpenConversation: onOpenConversation,
          onNewMessage: newMessage,
          canCompose: access == MessagingAccess.full,
        );
        // The app's hoisted folders (tablet plan section 5.2): the same
        // cubit for this route, the band B list pane and the split page, so
        // crossing 840dp sends nothing. Without one (a screen test) the
        // screen owns its cubit, as before.
        final session = context.read<ConversationsSession?>();
        if (session != null) {
          return ConversationsSessionScope(
            session: session,
            folder: folder,
            // Every visit opens (cache, then one refresh), as a new screen
            // cubit did.
            open: true,
            builder: (context) =>
                // Band B with the list pane beside this page (`MainShell`
                // decides): the detail placeholder instead of the list.
                ConversationsMasterScope.shownOf(context)
                ? ConversationsDetailPlaceholder(onNewMessage: newMessage)
                : list(context),
          );
        }
        return BlocProvider<ConversationsCubit>(
          create: (context) => ConversationsCubit(
            repository: context.read<MessagingRepository>(),
            folder: folder,
            now: refreshClock,
            onUnexpectedError: context.read<UnexpectedErrorReporter>(),
            // A first Inbox page loaded: its rows are the server's unread
            // state, so the Messages badge re-syncs from them (0 extra reads,
            // D10).
            onInboxSynced: (rows, {required hasMore}) => context
                .read<MessagesBadgeCubit>()
                .resync(rows, hasMore: hasMore),
          )..load(),
          child: Builder(builder: list),
        );
      },
    );
  }
}

/// The list of one folder over the [ConversationsCubit] above it: the
/// `/messages` route's body, and the tablet list panes' (band B), which pass
/// [selectedId] and their own navigation.
///
/// - [onOpenConversation] opens a row; null draws the rows without a tap.
/// - [onOpenRequests] opens the Requests folder from the inbox's "Message
///   requests (N)" row; default `push('/messages/requests')`.
/// - [onBack] is the Requests folder's back; default pop, or `go('/messages')`
///   with nothing to pop.
/// - [storage] keeps the scroll offset across remounts (the split page's
///   list pane, one bucket per folder).
class ConversationsList extends StatefulWidget {
  const ConversationsList({
    super.key,
    required this.folder,
    required this.onOpenConversation,
    required this.onNewMessage,
    required this.canCompose,
    this.selectedId,
    this.onOpenRequests,
    this.onBack,
    this.storage,
  });

  final Folder folder;
  final void Function(String conversationId)? onOpenConversation;
  final VoidCallback? onNewMessage;

  /// False in read-only mode: no New message action.
  final bool canCompose;

  /// The conversation open beside the list (band B), highlighted.
  final String? selectedId;
  final VoidCallback? onOpenRequests;
  final VoidCallback? onBack;
  final PageStorageBucket? storage;

  @override
  State<ConversationsList> createState() => _ConversationsViewState();
}

class _ConversationsViewState extends State<ConversationsList>
    with WidgetsBindingObserver {
  final ScrollController _controller = ScrollController();
  late DateTime _now = DateTime.now();

  /// The in-place message search (flag `message_search`) is open: it swaps
  /// the list for results. Never in the URL; the query dies with the panel.
  bool _searching = false;

  /// Whether this screen is covered by a route above it (its tickers are off).
  /// Read without subscribing: the notifier tells when it is shown again.
  ValueListenable<TickerModeData>? _tickerMode;

  /// A message push arrived while covered: one refresh follows on return.
  bool _pushWhileCovered = false;

  bool get _isInbox => widget.folder == Folder.FOLDER_INBOX;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getValuesNotifier(context);
    if (notifier != _tickerMode) {
      _tickerMode?.removeListener(_onTickerMode);
      _tickerMode = notifier..addListener(_onTickerMode);
    }
  }

  void _onTickerMode() {
    if (_tickerMode?.value.enabled != true || !_pushWhileCovered) return;
    _pushWhileCovered = false;
    // After the frame: the notifier fires while the tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<ConversationsCubit>().refreshIfStale());
    });
  }

  /// A foreground message push. While this list is covered by a route
  /// (its tickers are off, e.g. a thread is open over it) nothing is requested:
  /// the push is remembered and one throttled refresh runs on return, so the
  /// row of the conversation that moved is fresh when the list is shown again.
  /// While it is on top, a push that names an open conversation is skipped
  /// (that thread polls); any other push refreshes (throttled).
  void _onMessagePush(String? conversationId) {
    if (_tickerMode?.value.enabled == false) {
      _pushWhileCovered = true;
      return;
    }
    if (conversationId != null &&
        context.read<MessagesBadgeCubit>().isOpen(conversationId)) {
      return;
    }
    unawaited(context.read<ConversationsCubit>().refreshIfStale());
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_onTickerMode);
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
    final onBack = widget.onBack;
    if (onBack != null) {
      onBack();
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.messagesPath);
    }
  }

  /// Whether the search action is offered: flag on, Inbox only. A missing
  /// flag source (a screen test without onboarding) means off.
  bool _searchOn(BuildContext context) {
    if (!_isInbox) return false;
    try {
      return isFeatureEnabled(context, kFeatureMessageSearch);
    } on ProviderNotFoundException {
      return false;
    }
  }

  void _openHit(MessageSearchHit hit) {
    final id = hit.conversation.id;
    final location = Uri(
      path: AppRouter.messagePath(id),
      queryParameters: {'m': hit.message.id},
    ).toString();
    unawaited(context.push<void>(location));
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ConversationsCubit>();
    final searchOn = _searchOn(context);
    if (searchOn && _searching) {
      return Scaffold(
        body: SafeArea(
          child: MessageSearchPanel(
            onClose: () => setState(() => _searching = false),
            onOpenHit: _openHit,
            onOpenConversation: widget.onOpenConversation,
          ),
        ),
      );
    }
    // A foreground message push refreshes the list: an
    // FCM nudge, throttled, never a timer.
    final view = BlocListener<PushCubit, PushState>(
      listenWhen: (a, b) => b.messagePushes > a.messagePushes,
      listener: (context, push) =>
          _onMessagePush(push.lastMessageConversationId),
      // The phone's floating button (the shell's) starts a new message.
      child: ShellFab(
        action: _isInbox && widget.canCompose && widget.onNewMessage != null
            ? ShellFabAction(
                tooltip: kNewMessageLabel,
                icon: Icons.mail_outline,
                onPressed: widget.onNewMessage!,
              )
            : null,
        child: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) {
              final inset = ShellGeometry.readableInset(
                context,
                constraints.maxWidth,
              );
              return BlocBuilder<ConversationsCubit, ConversationsState>(
                builder: (context, state) {
                  return RefreshIndicator(
                    onRefresh: cubit.refresh,
                    child: CustomScrollView(
                      key: widget.storage == null
                          ? null
                          : PageStorageKey<String>(
                              'conversations-${widget.folder.value}',
                            ),
                      controller: _controller,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (_isInbox)
                          AppTopBar.sliver(
                            title: 'Messages',
                            actions: [
                              if (widget.canCompose &&
                                  MediaQuery.sizeOf(context).width >=
                                      AppBreakpoints.mobile)
                                AppTopBarAction(
                                  icon: Icons.mail_outline,
                                  tooltip: kNewMessageLabel,
                                  onPressed: widget.onNewMessage,
                                ),
                              if (searchOn)
                                AppTopBarAction(
                                  icon: Icons.search,
                                  tooltip: kMessageSearchHint,
                                  onPressed: () =>
                                      setState(() => _searching = true),
                                ),
                              const MessageSettingsAction(),
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
                                message: conversationsNoticeMessage(
                                  state.notice!,
                                ),
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
                                onTap:
                                    widget.onOpenRequests ??
                                    () => context.push(
                                      AppRouter.messageRequestsPath,
                                    ),
                              ),
                            ),
                          ),
                        ..._body(context, cubit, state, inset),
                        const ShellBottomInsetSliver(),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
    // The Requests header's Back reaches the pane's edge (T8f).
    final region = AppBleedHitRegion(allowsScrollView: true, child: view);
    final storage = widget.storage;
    return storage == null
        ? region
        : PageStorage(bucket: storage, child: region);
  }

  /// [sliver] in the reading column. Its header's divider (the Requests
  /// folder's back header) spans the pane: the inset is its bleed (0
  /// wherever the column fills the pane).
  Widget _inset(double inset, Widget sliver) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: inset),
    sliver: AppMainColumnBleed(bleed: inset, child: sliver),
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
          action: NotEncryptedNote(textAlign: TextAlign.center),
        );
      } else {
        child = const AppEmptyView(
          icon: Icons.mark_email_unread_outlined,
          title: 'No message requests',
          subtitle:
              'When someone new wants to message you, it will show up '
              'here. '
              'Requests from accounts you blocked or muted are hidden.',
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
                  selected: conversation.id == widget.selectedId,
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

/// The "Message requests" card above the inbox (dzeroth-mobile Conversations):
/// a tinted rounded card with an envelope, the label, how many people want to
/// say hello and a chevron, in one 48dp+ tap target.
class _RequestsRow extends StatelessWidget {
  const _RequestsRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final radius = BorderRadius.circular(
      phone
          ? AppMessagesLayout.requestsRadiusPhone
          : AppMessagesLayout.requestsRadiusWide,
    );
    final inset = phone
        ? AppMessagesLayout.requestsInsetPhone
        : AppMessagesLayout.requestsInsetWide;
    final who = count == 1
        ? '1 person wants to say hello'
        : '$count people want to say hello';
    return Semantics(
      button: true,
      label: 'Message requests ($count)',
      excludeSemantics: true,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          inset,
          phone
              ? AppMessagesLayout.requestsTopPhone
              : AppMessagesLayout.requestsTopWide,
          inset,
          AppSpacing.xs,
        ),
        child: Material(
          color: AppPalette.tealElectric.withValues(
            alpha: AppMessagesLayout.requestsTint,
          ),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppMessagesLayout.requestsPaddingH,
                  vertical: AppMessagesLayout.requestsPaddingV,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.mark_email_unread_outlined,
                      size: AppIconSize.lg,
                      color: context.appColors.accentText,
                    ),
                    const SizedBox(width: AppMessagesLayout.rowGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Message requests',
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            who,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
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
        ),
      ),
    );
  }
}
