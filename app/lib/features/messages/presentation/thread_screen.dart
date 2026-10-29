import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_menu_item_row.dart';
import '../../../shared/widgets/app_notice_banner.dart';
import '../../../shared/widgets/post_card.dart' show launchPostLink;
import '../../moderation/domain/reports_feature_flag.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../graph/presentation/bloc/relationship_cubit.dart';
import '../../graph/presentation/graph_error_messages.dart';
import '../../notifications/domain/notifications_feature_flag.dart';
import '../../notifications/presentation/bloc/push_cubit.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../profile/presentation/widgets/block_confirmation_dialog.dart';
import '../data/messaging_repository.dart';
import '../data/timer_thread_poller.dart';
import '../domain/messaging_feature_flag.dart';
import '../domain/thread_poller.dart';
import '../domain/thread_push_coverage.dart';
import 'bloc/message_composer_cubit.dart';
import 'bloc/messages_badge_cubit.dart';
import 'bloc/thread_cubit.dart';
import 'messaging_error_messages.dart';
import 'report_conversation.dart';
import 'thread_items.dart';
import 'widgets/message_bubble.dart';
import 'widgets/outgoing_bubble.dart';
import 'widgets/request_banner.dart';
import 'widgets/thread_push_scope.dart';

/// The line that replaces the composer on a read-only conversation.
const kThreadReadOnlyText = "You can't reply to this conversation";

/// Shown for a malformed id, NOT_FOUND, a non-participant and a deleted
/// conversation alike.
const kThreadUnavailableText = "This conversation isn't available";

/// The toast after a request was deleted (W7-18), as W7-15's "Conversation
/// deleted". Accept has none: the composer appearing is the answer.
const kRequestDeletedText = 'Request deleted';

/// What the "Delete this request?" dialog says (founder-approved wording): the
/// sender is not told, and a sender who can still send may message again.
const kDeleteRequestDetail =
    "They won't be told. If they still can, they may message you again.";

/// How close to the newest message (dp) still counts as "at the bottom".
const double kThreadAtBottomSlack = 24;

/// Builds the poller of a conversation. [pull] is the cubit's poll; the
/// default is a [TimerThreadPoller] on the repository's shared read hold.
typedef ThreadPollerBuilder = ThreadPoller Function(
  Future<PollResult> Function() pull,
  MessagingRepository repository,
);

/// Builds the request area at the bottom of a conversation (W7-18): the
/// received-request banner (it replaces the composer), the sender's waiting
/// note (above the composer), or null for none. [actions] is what its buttons
/// call.
typedef ThreadBannerBuilder = Widget? Function(
  BuildContext context,
  pb.Conversation conversation,
  ThreadRequestActions actions,
);

/// `/messages/:id` (W7-15, ADR-0027 D7, D11, D14): one conversation.
///
/// - A reversed message list (newest at the bottom): own bubbles on the
///   accent, the peer's on the raised surface, grouped by sender with the time
///   under the last of a group and a separator per day. Cache first, one
///   refresh on open, older pages on scroll up.
/// - [ThreadPoller] runs while the app is in the foreground and this route is
///   on top (the `setVisible` feed below); a tap or scroll calls `noteInput`.
///   Nothing is live: delivery is bounded by the poll interval.
/// - New messages while the reader is at the bottom just appear; otherwise a
///   "New messages" pill. MarkConversationRead runs on open and when messages
///   arrive while visible, only with unread above 0.
/// - Info menu: Block (the graph flow), Report (the [onReport] seam, W7-18;
///   hidden with `reports` off, disabled until it is wired) and Delete
///   conversation.
/// - A long press on a peer's visible bubble offers "Report message" (W7-18,
///   `reports` on): the shared report sheet with the message target; the
///   thread does not change.
/// - Read-only (`can_reply` false, or a send answered CANNOT_MESSAGE): no
///   composer, the line [kThreadReadOnlyText].
/// - Sends (W7-16): a [MessageComposerCubit] is provided next to the
///   `ThreadCubit`. Its outgoing rows draw at the bottom of the list as
///   [OutgoingBubble]s, hidden once the thread holds the server's message (deduped
///   by id); a send scrolls to the newest.
///
/// Seams for later tickets:
/// - [composerBuilder] (W7-16) draws the composer under the list when the
///   conversation can be replied to (the router passes a `MessageComposer`).
/// - [bannerBuilder] (W7-18) draws the request area at the bottom: the
///   "`name` wants to message you" banner with Accept, Delete and Block
///   replaces the composer of a received request; the sender's waiting note
///   sits above the composer. Accept moves the conversation to the Inbox and
///   the composer appears.
/// - [onReport] (W7-18) opens the report sheet for the peer's account.
/// - The cubit is provided above [ThreadScreen]'s view, so `ThreadCubit`
///   methods (`onPush` for W7-19) can be reached with `context.read`.
class ThreadScreen extends StatelessWidget {
  const ThreadScreen({
    super.key,
    required this.conversationId,
    this.pollerBuilder,
    this.composerBuilder,
    this.bannerBuilder,
    this.onReport,
    this.onOpenLink,
    this.now,
  });

  final String conversationId;

  /// Test seam: the poller. Defaults to a [TimerThreadPoller].
  final ThreadPollerBuilder? pollerBuilder;

  /// W7-16: the composer, shown only when the conversation can be replied to.
  final Widget Function(BuildContext context, pb.Conversation? conversation)?
  composerBuilder;

  /// W7-18: the request banner or note at the bottom (null for none).
  final ThreadBannerBuilder? bannerBuilder;

  /// W7-18: opens the report flow for the peer's account. Null leaves "Report"
  /// in the menu disabled (with `reports` off the item is not shown at all).
  final void Function(BuildContext context, pb.Conversation conversation)?
  onReport;

  /// Opens an `http(s)` link; defaults to the external browser.
  final void Function(Uri uri)? onOpenLink;

  /// Test seam: the clock relative times are drawn against.
  final DateTime? now;

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
    return MultiBlocProvider(
      providers: [
        BlocProvider<ThreadCubit>(create: _createThreadCubit),
        BlocProvider<MessageComposerCubit>(
          create: (context) {
            final thread = context.read<ThreadCubit>();
            return MessageComposerCubit(
              repository: context.read<MessagingRepository>(),
              conversationId: conversationId,
              onActivity: thread.noteInput,
              onSent: thread.noteSent,
              onCannotMessage: thread.markCannotMessage,
              onUnexpectedError: context.read<UnexpectedErrorReporter>(),
            );
          },
        ),
      ],
      // W7-19: the badge knows this conversation is open; a foreground push
      // for it pulls the thread.
      child: ThreadPushScope(
        conversationId: conversationId,
        child: _ThreadView(
          composerBuilder: composerBuilder,
          bannerBuilder: bannerBuilder,
          onReport: onReport,
          onOpenLink: onOpenLink,
          now: now,
        ),
      ),
    );
  }

  ThreadCubit _createThreadCubit(BuildContext context) {
    final repository = context.read<MessagingRepository>();
    final report = context.read<UnexpectedErrorReporter>();
    final push = context.read<PushCubit>();
    final onboarding = context.read<OnboardingBloc>();
    late final ThreadCubit cubit;
    Future<PollResult> pull() => cubit.pull();
    final poller = pollerBuilder != null
        ? pollerBuilder!(pull, repository)
        : TimerThreadPoller(
            pull: pull,
            rateLimitHold: repository.rateLimitHold,
            // Android with push that can reach this thread: the hot interval
            // is 30 s (D7). Asked at every schedule, so a muted or request
            // conversation, the flag off, or a registration that is not (or
            // no longer) answered polls at 15 s.
            pushCoverage: () => pushCoversThread(
              deviceRegistered: push.pushCoversThreads,
              notificationsEnabled: onboarding.state.enabledFeatures.contains(
                kFeatureNotifications,
              ),
              conversation: cubit.state.conversation,
            ),
            onError: report,
          );
    cubit = ThreadCubit(
      repository: repository,
      poller: poller,
      conversationId: conversationId,
      onUnexpectedError: report,
      onOpenedUnread: context.read<MessagesBadgeCubit>().clearUnread,
    )..load();
    return cubit;
  }
}

enum _MenuAction { block, report, delete }

class _ThreadView extends StatefulWidget {
  const _ThreadView({
    required this.composerBuilder,
    required this.bannerBuilder,
    required this.onReport,
    required this.onOpenLink,
    required this.now,
  });

  final Widget Function(BuildContext, pb.Conversation?)? composerBuilder;
  final ThreadBannerBuilder? bannerBuilder;
  final void Function(BuildContext, pb.Conversation)? onReport;
  final void Function(Uri)? onOpenLink;
  final DateTime? now;

  @override
  State<_ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<_ThreadView> with WidgetsBindingObserver {
  final ScrollController _controller = ScrollController();
  bool _blocking = false;
  late DateTime _now = widget.now ?? DateTime.now();
  bool _appVisible = true;
  bool _routeVisible = true;
  RelationshipCubit? _relationship;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Covered by another page (the peer's profile): not visible, no polling.
    _routeVisible = TickerMode.valuesOf(context).enabled;
    _syncVisible();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_relationship?.close());
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` is a system sheet or an unfocused desktop window: still on
    // screen. Hidden (tab hidden on the web, app in the background) is not.
    switch (state) {
      case AppLifecycleState.resumed:
        _appVisible = true;
        if (mounted && widget.now == null) _now = DateTime.now();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _appVisible = false;
      case AppLifecycleState.inactive:
        break;
    }
    if (mounted) {
      setState(() {});
      _syncVisible();
    }
  }

  void _syncVisible() {
    context.read<ThreadCubit>().setVisible(_appVisible && _routeVisible);
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final cubit = context.read<ThreadCubit>();
    final position = _controller.position;
    cubit.setAtBottom(position.pixels <= kThreadAtBottomSlack);
    if (position.maxScrollExtent > 0 &&
        position.pixels >= kPrefetchFraction * position.maxScrollExtent) {
      unawaited(cubit.loadMore());
    }
  }

  /// A short thread that does not fill the screen can never be scrolled up:
  /// ask for the older page right away.
  void _maybeFill() {
    if (!mounted || !_controller.hasClients) return;
    if (_controller.position.maxScrollExtent <= 0) {
      unawaited(context.read<ThreadCubit>().loadMore());
    }
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.messagesPath);
    }
  }

  Future<void> _openLink(Uri uri) async {
    final handler = widget.onOpenLink;
    if (handler != null) {
      handler(uri);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (!await launchPostLink(uri)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("Couldn't open link.")));
    }
  }

  void _jumpToNewest(ThreadCubit cubit) {
    cubit.showNew();
    if (!_controller.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpTo(0);
    } else {
      unawaited(
        _controller.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  Future<void> _onMenu(
    _MenuAction action,
    ThreadCubit cubit,
    pb.Conversation conversation,
  ) async {
    switch (action) {
      case _MenuAction.block:
        await _block(cubit, conversation.peer);
      case _MenuAction.report:
        widget.onReport?.call(context, conversation);
      case _MenuAction.delete:
        await _delete(cubit, request: isReceivedRequest(conversation));
    }
  }

  Future<void> _block(ThreadCubit cubit, common.AuthorSnapshot peer) async {
    if (_blocking) return;
    final confirmed = await showBlockConfirmationDialog(context);
    if (!confirmed || !mounted) return;
    final repository = context.read<GraphRepository>();
    final messenger = ScaffoldMessenger.of(context);
    // Kept for the screen's life: a retry after a failed block reuses the
    // cubit's idempotency key.
    final relationship = _relationship ??= RelationshipCubit(
      graphRepository: repository,
      userId: peer.userId,
      initial:
          repository.cached(peer.userId) ??
          graph.Relationship(userId: peer.userId),
    );
    setState(() => _blocking = true);
    await relationship.block();
    if (mounted) setState(() => _blocking = false);
    final error = relationship.state.error;
    messenger.hideCurrentSnackBar();
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(relationshipErrorMessage(error))),
      );
      return;
    }
    cubit.markPeerBlocked();
    messenger.showSnackBar(SnackBar(content: Text('Blocked @${peer.handle}')));
  }

  Future<void> _accept(ThreadCubit cubit) async {
    if (cubit.state.accepting || cubit.state.deleting || _blocking) return;
    final messenger = ScaffoldMessenger.of(context);
    final error = await cubit.acceptRequest();
    messenger.hideCurrentSnackBar();
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(messagingErrorMessage(error))),
      );
    }
  }

  Future<void> _delete(ThreadCubit cubit, {bool request = false}) async {
    if (cubit.state.accepting || cubit.state.deleting || _blocking) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          request ? 'Delete this request?' : 'Delete this conversation?',
        ),
        content: Text(
          request
              ? kDeleteRequestDetail
              : 'It only removes the conversation for you. The other person '
                    'keeps their copy.',
        ),
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
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final error = await cubit.deleteConversation();
    messenger.hideCurrentSnackBar();
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(messagingErrorMessage(error))),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(request ? kRequestDeletedText : 'Conversation deleted'),
      ),
    );
    if (mounted) _back();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ThreadCubit>();
    // Read here: `select` is only allowed in `build`, not in a builder.
    final graphEnabled = isFeatureEnabled(context, kFeatureGraph);
    final reportsEnabled = isFeatureEnabled(context, kFeatureReports);
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: MultiBlocListener(
            listeners: [
              BlocListener<ThreadCubit, ThreadState>(
                listenWhen: (a, b) =>
                    a.messages != b.messages || a.hasMore != b.hasMore,
                listener: (context, state) {
                  if (widget.now == null) _now = DateTime.now();
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _maybeFill(),
                  );
                },
              ),
              // CANNOT_MESSAGE: the thread went read-only; say why once.
              BlocListener<ThreadCubit, ThreadState>(
                listenWhen: (a, b) => !a.cannotMessage && b.cannotMessage,
                listener: (context, state) => ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text(CannotMessageException.userMessage),
                    ),
                  ),
              ),
              // A new send scrolls to the newest message.
              BlocListener<MessageComposerCubit, MessageComposerState>(
                listenWhen: (a, b) => b.outgoing.length > a.outgoing.length,
                listener: (context, state) => _jumpToNewest(cubit),
              ),
            ],
            child: Column(
              children: [
                BlocBuilder<ThreadCubit, ThreadState>(
                  buildWhen: (a, b) =>
                      a.conversation != b.conversation ||
                      a.status != b.status ||
                      a.deleting != b.deleting ||
                      a.accepting != b.accepting ||
                      a.peerBlocked != b.peerBlocked,
                  builder: (context, state) =>
                      _header(cubit, state, graphEnabled, reportsEnabled),
                ),
                Expanded(
                  child: BlocBuilder<ThreadCubit, ThreadState>(
                    builder: (context, state) =>
                        _content(cubit, state, reportsEnabled),
                  ),
                ),
                BlocBuilder<ThreadCubit, ThreadState>(
                  buildWhen: (a, b) =>
                      a.status != b.status ||
                      a.conversation != b.conversation ||
                      a.peerBlocked != b.peerBlocked ||
                      a.cannotMessage != b.cannotMessage ||
                      a.accepting != b.accepting ||
                      a.deleting != b.deleting,
                  builder: (context, state) =>
                      _bottom(cubit, state, graphEnabled),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(
    ThreadCubit cubit,
    ThreadState state,
    bool graphEnabled,
    bool reportsEnabled,
  ) {
    final conversation = state.conversation;
    if (state.status == ThreadStatus.unavailable || conversation == null) {
      return AppBackHeader(title: 'Conversation', onBack: _back);
    }
    final peer = conversation.peer;
    final name = peer.displayName.isEmpty
        ? '@${peer.handle}'
        : peer.displayName;
    return AppBackHeader(
      title: name,
      onBack: _back,
      titleContent: ThreadPeerHeader(peer: peer),
      actions: [
        if (state.status == ThreadStatus.ready)
          _InfoMenu(
            enabled: !state.deleting && !state.accepting && !_blocking,
            canBlock:
                graphEnabled && peer.userId.isNotEmpty && !state.peerBlocked,
            peerHandle: peer.handle,
            showReport: reportsEnabled,
            // A deleted-account peer has no user id to report.
            canReport: widget.onReport != null && peer.userId.isNotEmpty,
            onSelected: (action) => _onMenu(action, cubit, conversation),
          ),
      ],
    );
  }

  Widget _content(ThreadCubit cubit, ThreadState state, bool reportsEnabled) {
    switch (state.status) {
      case ThreadStatus.unavailable:
        return const Center(
          child: AppEmptyView(
            icon: Icons.chat_bubble_outline,
            title: kThreadUnavailableText,
          ),
        );
      case ThreadStatus.loading:
        return const _ThreadSkeleton();
      case ThreadStatus.error:
        final error = state.error;
        return Center(
          child: AppEmptyView(
            icon: Icons.error_outline,
            title: error == null
                ? "Couldn't load this conversation."
                : messagingErrorMessage(error),
            action: error == null || noticeCanRetry(error)
                ? FilledButton.tonal(
                    onPressed: cubit.refresh,
                    child: const Text('Retry'),
                  )
                : null,
          ),
        );
      case ThreadStatus.ready:
        break;
    }
    return Column(
      children: [
        if (state.notice != null)
          AppNoticeBanner(
            message: conversationsNoticeMessage(state.notice!),
            onRetry: noticeCanRetry(state.notice!) ? cubit.refresh : null,
          ),
        Expanded(
          child: BlocBuilder<MessageComposerCubit, MessageComposerState>(
            buildWhen: (a, b) => a.outgoing != b.outgoing,
            builder: (context, composer) {
              final outgoing = _visibleOutgoing(composer, state);
              return state.hasMessages || outgoing.isNotEmpty
                  ? _messages(cubit, state, outgoing, reportsEnabled)
                  : _noMessages(state);
            },
          ),
        ),
      ],
    );
  }

  /// The rows still on their way, newest first: those the thread does not
  /// hold yet (a sent row hides once its id is in the list, deduped by id).
  List<OutgoingMessage> _visibleOutgoing(
    MessageComposerState composer,
    ThreadState state,
  ) {
    if (composer.outgoing.isEmpty) return const [];
    final held = {for (final m in state.messages) m.id};
    return [
      for (final m in composer.outgoing.reversed)
        if (m.sent == null || !held.contains(m.sent!.id)) m,
    ];
  }

  Widget _noMessages(ThreadState state) {
    return state.refreshing
        ? const _ThreadSkeleton()
        : const Center(
            child: AppEmptyView(
              icon: Icons.chat_bubble_outline,
              title: 'No messages yet',
              subtitle: 'Messages in this conversation will show here.',
            ),
          );
  }

  Widget _messages(
    ThreadCubit cubit,
    ThreadState state,
    List<OutgoingMessage> outgoing,
    bool reportsEnabled,
  ) {
    final items = buildThreadItems(state.messages);
    final conversation = state.conversation;
    final peer = conversation?.peer;
    final peerName = peer == null || peer.displayName.isEmpty
        ? '@${peer?.handle ?? ''}'
        : peer.displayName;
    final use24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    final keys = [
      for (final m in outgoing) 'outgoing-${m.localId}',
      for (final i in items) i.key,
    ];
    return Stack(
      children: [
        // Taps and scrolls start with a pointer down: the thread stays hot.
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => cubit.noteInput(),
          onPointerSignal: (_) => cubit.noteInput(),
          child: CustomScrollView(
            reverse: true,
            controller: _controller,
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.sm)),
              SliverSemantics(
                role: SemanticsRole.list,
                label: 'Messages',
                sliver: SliverList.builder(
                  itemCount: outgoing.length + items.length,
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<String>) return null;
                    final index = keys.indexOf(key.value);
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (context, index) {
                    if (index < outgoing.length) {
                      final row = outgoing[index];
                      // Own messages stack: the gap shows only above the
                      // first of a run.
                      final olderIsOwn = index + 1 < outgoing.length
                          ? true
                          : items.isNotEmpty &&
                                items.first is MessageItem &&
                                (items.first as MessageItem).message.fromSelf;
                      return Semantics(
                        key: ValueKey(keys[index]),
                        role: SemanticsRole.listItem,
                        container: true,
                        child: OutgoingBubble(
                          message: row,
                          onRetry: (id) => unawaited(
                            context.read<MessageComposerCubit>().retry(id),
                          ),
                          topGap: olderIsOwn ? AppSpacing.xs : AppSpacing.sm,
                        ),
                      );
                    }
                    final item = items[index - outgoing.length];
                    // One list item per row, so the list node does not
                    // absorb the times and day labels.
                    return Semantics(
                      key: ValueKey(item.key),
                      role: SemanticsRole.listItem,
                      container: true,
                      child: switch (item) {
                        MessageItem() => MessageBubble(
                          message: item.message,
                          peerName: peerName,
                          now: _now,
                          firstOfGroup: item.firstOfGroup,
                          lastOfGroup: item.lastOfGroup,
                          use24Hour: use24Hour,
                          onOpenLink: _openLink,
                          onReport:
                              reportsEnabled &&
                                  conversation != null &&
                                  canReportMessage(item.message)
                              ? (anchor) => unawaited(
                                  _messageMenu(
                                    anchor,
                                    cubit,
                                    conversation,
                                    item.message,
                                  ),
                                )
                              : null,
                        ),
                        DaySeparatorItem() => _DaySeparator(
                          label: formatDaySeparator(item.day, _now),
                        ),
                      },
                    );
                  },
                ),
              ),
              SliverToBoxAdapter(child: _olderFooter(cubit, state)),
            ],
          ),
        ),
        if (state.pendingNew > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: AppSpacing.sm,
            child: Center(
              child: Semantics(
                liveRegion: true,
                child: FilledButton.icon(
                  onPressed: () => _jumpToNewest(cubit),
                  icon: const Icon(Icons.arrow_downward, size: AppIconSize.md),
                  label: const Text('New messages'),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _olderFooter(ThreadCubit cubit, ThreadState state) {
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
            child: const Text("Couldn't load earlier messages. Retry"),
          ),
        ),
      );
    }
    return const SizedBox(height: AppSpacing.md);
  }

  /// The bottom of a ready thread: the read-only line, or the request area
  /// and the composer. A received request shows the banner INSTEAD of the
  /// composer (Accept brings the composer); the sender's note sits above it.
  Widget _bottom(ThreadCubit cubit, ThreadState state, bool graphEnabled) {
    if (state.status != ThreadStatus.ready) return const SizedBox.shrink();
    if (state.readOnly) return const ThreadReadOnlyLine();
    final conversation = state.conversation;
    final composerBuilder = widget.composerBuilder;
    final composer = composerBuilder == null
        ? const SizedBox.shrink()
        : composerBuilder(context, conversation);
    final bannerBuilder = widget.bannerBuilder;
    final banner = conversation == null || bannerBuilder == null
        ? null
        : bannerBuilder(
            context,
            conversation,
            _requestActions(cubit, state, conversation, graphEnabled),
          );
    if (banner == null) return composer;
    if (conversation != null && isReceivedRequest(conversation)) return banner;
    return Column(mainAxisSize: MainAxisSize.min, children: [banner, composer]);
  }

  ThreadRequestActions _requestActions(
    ThreadCubit cubit,
    ThreadState state,
    pb.Conversation conversation,
    bool graphEnabled,
  ) {
    final peer = conversation.peer;
    // Block stays visible while it runs (the banner turns every button off).
    final canBlock =
        graphEnabled && peer.userId.isNotEmpty && !state.peerBlocked;
    return ThreadRequestActions(
      accept: () => unawaited(_accept(cubit)),
      delete: () => unawaited(_delete(cubit, request: true)),
      block: canBlock ? () => unawaited(_block(cubit, peer)) : null,
      accepting: state.accepting,
      deleting: state.deleting,
      blocking: _blocking,
    );
  }

  /// A long press on a peer's bubble: a one-item menu "Report message" at the
  /// press point, then the shared report sheet.
  Future<void> _messageMenu(
    Rect anchor,
    ThreadCubit cubit,
    pb.Conversation conversation,
    pb.Message message,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(
          value: true,
          child: AppMenuItemRow(
            icon: Icons.flag_outlined,
            label: kReportMessageLabel,
          ),
        ),
      ],
    );
    if (choice != true || !mounted) return;
    await reportPeerMessage(
      context,
      conversationId: cubit.conversationId,
      message: message,
      peerHandle: conversation.peer.handle,
    );
  }
}

/// Avatar, name and handle in the header; one button to the profile. Public
/// since W7-17: the draft thread draws the same header.
class ThreadPeerHeader extends StatelessWidget {
  const ThreadPeerHeader({super.key, required this.peer});

  final common.AuthorSnapshot peer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasName = peer.displayName.isNotEmpty;
    final name = hasName ? peer.displayName : '@${peer.handle}';
    final canOpen = peer.handle.isNotEmpty;
    final label = [
      name,
      if (hasName && peer.handle.isNotEmpty) '@${peer.handle}',
      if (canOpen) 'View profile',
    ].join(', ');
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
      child: Row(
        children: [
          AppAvatar(url: peer.avatarUrl, radius: AppSpacing.md),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (hasName && peer.handle.isNotEmpty)
                  Text(
                    '@${peer.handle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: canOpen,
      label: label,
      excludeSemantics: true,
      onTap: canOpen ? () => _open(context) : null,
      child: canOpen
          ? InkWell(onTap: () => _open(context), child: content)
          : content,
    );
  }

  void _open(BuildContext context) =>
      context.push(AppRouter.profilePath(peer.handle));
}

/// The "Conversation info" overflow menu: Block, Report, Delete.
class _InfoMenu extends StatelessWidget {
  const _InfoMenu({
    required this.enabled,
    required this.canBlock,
    required this.peerHandle,
    required this.showReport,
    required this.canReport,
    required this.onSelected,
  });

  final bool enabled;
  final bool canBlock;
  final String peerHandle;

  /// The `reports` flag: with it off there is no Report item at all.
  final bool showReport;

  /// False when no report flow is wired: the item stays, disabled.
  final bool canReport;
  final ValueChanged<_MenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final handle = peerHandle.isEmpty ? '' : ' @$peerHandle';
    return PopupMenuButton<_MenuAction>(
      tooltip: 'Conversation info',
      enabled: enabled,
      icon: const Icon(Icons.info_outline),
      onSelected: onSelected,
      itemBuilder: (context) => [
        if (canBlock)
          PopupMenuItem(
            value: _MenuAction.block,
            child: AppMenuItemRow(icon: Icons.block, label: 'Block$handle'),
          ),
        if (showReport)
          PopupMenuItem(
            value: _MenuAction.report,
            enabled: canReport,
            child: AppMenuItemRow(
              icon: Icons.flag_outlined,
              label: 'Report$handle',
            ),
          ),
        const PopupMenuItem(
          value: _MenuAction.delete,
          child: AppMenuItemRow(
            icon: Icons.delete_outline,
            label: 'Delete conversation',
            destructive: true,
          ),
        ),
      ],
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Replaces the composer on a conversation nobody can reply to (public since
/// W7-17: the draft thread uses it too).
class ThreadReadOnlyLine extends StatelessWidget {
  const ThreadReadOnlyLine({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Text(
          kThreadReadOnlyText,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Placeholder bubbles while the first fetch runs (nothing cached).
class _ThreadSkeleton extends StatelessWidget {
  const _ThreadSkeleton();

  @override
  Widget build(BuildContext context) {
    final fill = Theme.of(context).colorScheme.surfaceContainerHigh;
    Widget bar(double fraction, {required bool own}) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Align(
        alignment: own
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: FractionallySizedBox(
          widthFactor: fraction,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: const SizedBox(height: AppSpacing.xl + AppSpacing.xs),
          ),
        ),
      ),
    );
    return Semantics(
      label: 'Loading messages',
      liveRegion: true,
      excludeSemantics: true,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          bar(0.5, own: false),
          bar(0.65, own: true),
          bar(0.4, own: false),
          bar(0.55, own: true),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}
