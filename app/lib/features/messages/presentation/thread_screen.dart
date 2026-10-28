import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
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
import '../../graph/data/graph_repository.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../graph/presentation/bloc/relationship_cubit.dart';
import '../../graph/presentation/graph_error_messages.dart';
import '../../profile/presentation/widgets/block_confirmation_dialog.dart';
import '../data/messaging_repository.dart';
import '../data/timer_thread_poller.dart';
import '../domain/messaging_feature_flag.dart';
import '../domain/thread_poller.dart';
import 'bloc/thread_cubit.dart';
import 'messaging_error_messages.dart';
import 'thread_items.dart';
import 'widgets/message_bubble.dart';

/// The line that replaces the composer on a read-only conversation.
const kThreadReadOnlyText = "You can't reply to this conversation";

/// Shown for a malformed id, NOT_FOUND, a non-participant and a deleted
/// conversation alike.
const kThreadUnavailableText = "This conversation isn't available";

/// How close to the newest message (dp) still counts as "at the bottom".
const double kThreadAtBottomSlack = 24;

/// Builds the poller of a conversation. [pull] is the cubit's poll; the
/// default is a [TimerThreadPoller] on the repository's shared read hold.
typedef ThreadPollerBuilder = ThreadPoller Function(
  Future<PollResult> Function() pull,
  MessagingRepository repository,
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
///   disabled until it is wired) and Delete conversation.
/// - Read-only (`can_reply` false): no composer, the line
///   [kThreadReadOnlyText].
///
/// Seams for later tickets:
/// - [composerBuilder] (W7-16) draws the composer under the list when the
///   conversation can be replied to.
/// - [bannerBuilder] (W7-18) draws the request banner between the header and
///   the list.
/// - [onReport] (W7-18) opens the report sheet.
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

  /// W7-18: the request banner above the list (null for none).
  final Widget? Function(BuildContext context, pb.Conversation conversation)?
  bannerBuilder;

  /// W7-18: opens the report flow for the peer. Null leaves "Report" in the
  /// menu disabled.
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
    return BlocProvider<ThreadCubit>(
      create: (context) {
        final repository = context.read<MessagingRepository>();
        final report = context.read<UnexpectedErrorReporter>();
        late final ThreadCubit cubit;
        Future<PollResult> pull() => cubit.pull();
        final poller = pollerBuilder != null
            ? pollerBuilder!(pull, repository)
            : TimerThreadPoller(
                pull: pull,
                rateLimitHold: repository.rateLimitHold,
                onError: report,
              );
        cubit = ThreadCubit(
          repository: repository,
          poller: poller,
          conversationId: conversationId,
          onUnexpectedError: report,
        )..load();
        return cubit;
      },
      child: _ThreadView(
        composerBuilder: composerBuilder,
        bannerBuilder: bannerBuilder,
        onReport: onReport,
        onOpenLink: onOpenLink,
        now: now,
      ),
    );
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
  final Widget? Function(BuildContext, pb.Conversation)? bannerBuilder;
  final void Function(BuildContext, pb.Conversation)? onReport;
  final void Function(Uri)? onOpenLink;
  final DateTime? now;

  @override
  State<_ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<_ThreadView> with WidgetsBindingObserver {
  final ScrollController _controller = ScrollController();
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
        await _delete(cubit);
    }
  }

  Future<void> _block(ThreadCubit cubit, common.AuthorSnapshot peer) async {
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
    await relationship.block();
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

  Future<void> _delete(ThreadCubit cubit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this conversation?'),
        content: const Text(
          'It only removes the conversation for you. The other person keeps '
          'their copy.',
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
      const SnackBar(content: Text('Conversation deleted')),
    );
    if (mounted) _back();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ThreadCubit>();
    // Read here: `select` is only allowed in `build`, not in a builder.
    final graphEnabled = isFeatureEnabled(context, kFeatureGraph);
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocListener<ThreadCubit, ThreadState>(
            listenWhen: (a, b) =>
                a.messages != b.messages || a.hasMore != b.hasMore,
            listener: (context, state) {
              if (widget.now == null) _now = DateTime.now();
              WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFill());
            },
            child: Column(
              children: [
                BlocBuilder<ThreadCubit, ThreadState>(
                  buildWhen: (a, b) =>
                      a.conversation != b.conversation ||
                      a.status != b.status ||
                      a.deleting != b.deleting ||
                      a.peerBlocked != b.peerBlocked,
                  builder: (context, state) =>
                      _header(cubit, state, graphEnabled),
                ),
                Expanded(
                  child: BlocBuilder<ThreadCubit, ThreadState>(
                    builder: (context, state) => _content(cubit, state),
                  ),
                ),
                BlocBuilder<ThreadCubit, ThreadState>(
                  buildWhen: (a, b) =>
                      a.status != b.status ||
                      a.conversation != b.conversation ||
                      a.peerBlocked != b.peerBlocked,
                  builder: (context, state) => _bottom(state),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThreadCubit cubit, ThreadState state, bool graphEnabled) {
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
      titleContent: _PeerHeader(peer: peer),
      actions: [
        if (state.status == ThreadStatus.ready)
          _InfoMenu(
            enabled: !state.deleting,
            canBlock:
                graphEnabled && peer.userId.isNotEmpty && !state.peerBlocked,
            peerHandle: peer.handle,
            canReport: widget.onReport != null,
            onSelected: (action) => _onMenu(action, cubit, conversation),
          ),
      ],
    );
  }

  Widget _content(ThreadCubit cubit, ThreadState state) {
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
    final conversation = state.conversation;
    final banner = conversation == null
        ? null
        : widget.bannerBuilder?.call(context, conversation);
    return Column(
      children: [
        if (state.notice != null)
          AppNoticeBanner(
            message: conversationsNoticeMessage(state.notice!),
            onRetry: noticeCanRetry(state.notice!) ? cubit.refresh : null,
          ),
        ?banner,
        Expanded(
          child: state.hasMessages
              ? _messages(cubit, state)
              : state.refreshing
              ? const _ThreadSkeleton()
              : const Center(
                  child: AppEmptyView(
                    icon: Icons.chat_bubble_outline,
                    title: 'No messages yet',
                    subtitle: 'Messages in this conversation will show here.',
                  ),
                ),
        ),
      ],
    );
  }

  Widget _messages(ThreadCubit cubit, ThreadState state) {
    final items = buildThreadItems(state.messages);
    final peer = state.conversation?.peer;
    final peerName = peer == null || peer.displayName.isEmpty
        ? '@${peer?.handle ?? ''}'
        : peer.displayName;
    final use24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
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
                  itemCount: items.length,
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<String>) return null;
                    final index = items.indexWhere((i) => i.key == key.value);
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (context, index) {
                    final item = items[index];
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

  Widget _bottom(ThreadState state) {
    if (state.status != ThreadStatus.ready) return const SizedBox.shrink();
    if (state.readOnly) return const _ReadOnlyLine();
    // TODO(W7-16): the composer. Until it is wired there is no input.
    final builder = widget.composerBuilder;
    return builder == null
        ? const SizedBox.shrink()
        : builder(context, state.conversation);
  }
}

/// Avatar, name and handle in the header; one button to the profile.
class _PeerHeader extends StatelessWidget {
  const _PeerHeader({required this.peer});

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
    required this.canReport,
    required this.onSelected,
  });

  final bool enabled;
  final bool canBlock;
  final String peerHandle;

  /// False until W7-18 wires the report flow: the item stays, disabled.
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
        // TODO(W7-18): enabled once the report-message sheet exists.
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

/// Replaces the composer on a conversation nobody can reply to.
class _ReadOnlyLine extends StatelessWidget {
  const _ReadOnlyLine();

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
