import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/format/scheduled_time.dart';
import '../../../../shared/widgets/post/embedded_post_card.dart';
import '../../../../shared/widgets/primitives/browser_context_menu_guard.dart';
import '../../../posts/domain/post_text_parser.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../e2ee/encrypted_thread_items.dart';
import '../e2ee/encryption_copy.dart';
import '../e2ee/encryption_error_messages.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import 'conversation_row.dart';

/// The words of a tombstone bubble, shared with the inbox row.
const kMessageDeletedText = kConversationDeletedSnippet;
const kMessageRemovedText = kConversationRemovedSnippet;

/// The label of the report action on a peer's bubble (menu item and the
/// assistive-technology action).
const kReportMessageLabel = 'Report message';

/// Key of the shared post's card inside a bubble.
const kSharedPostCardKey = ValueKey('shared-post-card');

/// The assistive-technology action that opens a bubble's shared post.
const kOpenSharedPostLabel = 'Open shared post';

/// The bubble's share of the row width; the rest keeps the sides distinct.
const double kBubbleMaxWidthFraction = 0.8;

/// The text a message shows: its text, or the tombstone words for a message
/// whose text is gone.
///
/// In a thread known to be encrypted ([isMls]) on a device that cannot read it
/// every message that is not a tombstone reads [kEncryptedPlaceholderText],
/// whatever its fields hold: a server can send plaintext there (security read
/// M2), and it is never drawn.
String messageDisplayText(pb.Message message, {bool isMls = false}) =>
    switch (message.state) {
      MessageState.MESSAGE_STATE_DELETED_ACCOUNT => kMessageDeletedText,
      MessageState.MESSAGE_STATE_REMOVED => kMessageRemovedText,
      _ => isMls ? kEncryptedPlaceholderText : message.text,
    };

/// The post a message shares, drawn as a card: only a visible message that
/// carries one. Decided from the message alone, never from a flag: a recipient
/// outside the `dm_post_share` rollout still gets the card the server built.
posts.EmbeddedPost? messageSharedPost(
  pb.Message message, {
  bool isMls = false,
}) => message.hasSharedPost() && !_isTombstone(message) && !isMls
    ? message.sharedPost
    : null;

/// Whether [text] is only the link of the post [postId], which is what a
/// share without a caption carries (a client that predates the card shows it
/// as a link). Matches on the path, so it holds for any origin; a caption
/// (anything with a space or more) never matches.
bool messageTextIsPostLink(String text, String postId) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(trimmed);
  return uri != null &&
      uri.hasScheme &&
      uri.hasAuthority &&
      uri.path == AppRouter.postPath(postId);
}

/// The text a bubble shows above the shared post's card: the caption, or
/// nothing when the text is the post's own link.
String messageCaption(pb.Message message, {bool isMls = false}) {
  final text = messageDisplayText(message, isMls: isMls);
  final shared = messageSharedPost(message, isMls: isMls);
  if (shared == null) return text;
  return messageTextIsPostLink(text, shared.postId) ? '' : text;
}

bool _isTombstone(pb.Message message) =>
    message.state == MessageState.MESSAGE_STATE_DELETED_ACCOUNT ||
    message.state == MessageState.MESSAGE_STATE_REMOVED;

/// The corners of a bubble (dzeroth-mobile Chat): 22 dp, with the 6 dp "tail"
/// corner at the bottom of the sender's side on the last bubble of a group.
BorderRadiusGeometry messageBubbleShape({
  required bool own,
  required bool lastOfGroup,
}) {
  const radius = Radius.circular(AppMessagesLayout.bubbleRadius);
  const tail = Radius.circular(AppMessagesLayout.bubbleTail);
  return BorderRadiusDirectional.only(
    topStart: radius,
    topEnd: radius,
    bottomStart: own || !lastOfGroup ? radius : tail,
    bottomEnd: !own || !lastOfGroup ? radius : tail,
  );
}

/// The fill of a bubble: the caller's own on the brand gradient with its glow,
/// the peer's on the light bubble gradient (the raised surface on dark), a
/// tombstone on the raised surface with a hairline.
BoxDecoration messageBubbleDecoration(
  BuildContext context, {
  required bool own,
  required bool tombstone,
  required BorderRadiusGeometry shape,
}) {
  final colors = Theme.of(context).colorScheme;
  if (tombstone) {
    return BoxDecoration(
      color: colors.surfaceContainerHigh,
      borderRadius: shape,
      border: Border.all(color: colors.outlineVariant),
    );
  }
  if (own) {
    return BoxDecoration(
      gradient: context.appColors.primaryFillGradient,
      borderRadius: shape,
      boxShadow: AppMessagesLayout.mineShadow,
    );
  }
  final light = Theme.of(context).brightness == Brightness.light;
  return BoxDecoration(
    color: light ? null : colors.surfaceContainerHigh,
    gradient: light ? AppGradients.lightBubble : null,
    borderRadius: shape,
    boxShadow: light ? AppMessagesLayout.theirsShadow : null,
  );
}

/// The text colour on a bubble made by [messageBubbleDecoration].
Color messageBubbleForeground(BuildContext context, {required bool own}) => own
    ? context.appColors.primaryFillLabel
    : Theme.of(context).colorScheme.onSurface;

/// One message of a conversation, presentational.
///
/// - The caller's own messages sit at the end on the brand gradient with navy
///   text; the peer's at the start on the light bubble (the raised surface on
///   dark). Tombstones are italic and muted on the raised surface with a 1dp
///   border. [seenAt] adds "Seen 8:02 PM" under the caller's newest message the
///   peer has read.
/// - [lastOfGroup] puts the time under the bubble and gives the bubble its
///   small "tail" corner; [firstOfGroup] adds the gap above the group.
/// - Links come from [parsePostText] link spans only. Mentions and hashtags
///   stay plain text: a conversation has no mention list, and a `#tag` is not
///   a navigation target here.
/// - Semantics: one node, "You said ..." or "`name` said ..., `time`"; each
///   link is an "Open link" custom action, since the text children are
///   excluded.
/// - [onReport] (only on a peer's visible message, only with `reports`
///   on) adds "Report message": a long press or a secondary click calls it
///   with the press point, and assistive technology gets a "Report message"
///   action (called with the bubble's rectangle). Null = no gesture, no action.
class MessageBubble extends StatelessWidget {
  MessageBubble({
    super.key,
    required pb.Message message,
    required this.peerName,
    required this.now,
    required this.firstOfGroup,
    required this.lastOfGroup,
    required this.onOpenLink,
    this.use24Hour = false,
    this.linksEnabled = true,
    this.onReport,
    this.seenAt,
    this.onOpenPost,
    bool isMls = false,
  }) : _data = _BubbleData.fromProto(message, isMls: isMls),
       onRetry = null;

  /// A decrypted message of an encrypted thread. Its side is `entry.mine`
  /// (never the server's `from_self`), except for an `undecryptable` row, which
  /// is drawn as a tombstone at the start with no tail whatever `mine` says.
  /// A placeholder (anything but visible and verified) reads its fixed words.
  /// An own row that is not delivered is dimmed while it is on its way, shows
  /// its status under the bubble and, only when the problem is retryable, is a
  /// button calling [onRetry] with the row id. [onReport] is honoured only for
  /// a peer's visible message with `canReport`. A shared post is drawn from its
  /// id alone (nothing is fetched); [onOpenPost] is what opens it.
  MessageBubble.encrypted({
    super.key,
    required DecryptedMessage entry,
    required this.peerName,
    required this.now,
    required this.firstOfGroup,
    required this.lastOfGroup,
    required this.onOpenLink,
    this.use24Hour = false,
    this.linksEnabled = true,
    this.onReport,
    this.onOpenPost,
    this.onRetry,
  }) : _data = _BubbleData.fromEntry(entry),
       seenAt = null;

  /// What the build reads, from either source. Holds readable text: no
  /// `toString`.
  final _BubbleData _data;

  /// Called with the row id when a retryable not-sent row is tapped.
  final void Function(String localId)? onRetry;

  /// Opens the post a message shares (`/post/<id>`, in the app: it works in a
  /// request that is not accepted too, unlike a link). Null: the card is not
  /// tappable.
  final void Function(String postId)? onOpenPost;

  /// The peer's display name (or `@handle`): the "name said" of the label.
  final String peerName;

  /// The clock the spoken relative time is drawn against (injected).
  final DateTime now;
  final bool firstOfGroup;
  final bool lastOfGroup;
  final void Function(Uri uri) onOpenLink;
  final bool use24Hour;

  /// False in a REQUEST thread for a stranger's message (L-9): its links
  /// are shown as plain text, with no tap and no "Open link" action, until the
  /// request is accepted. The raw text is never hidden.
  final bool linksEnabled;

  /// Opens the "Report message" menu at [anchor] (null = not reportable).
  final void Function(Rect anchor)? onReport;

  /// When the peer read up to this message (the caller's newest read message,
  /// with read receipts on both sides): "Seen 8:02 PM" under the bubble.
  final DateTime? seenAt;

  /// Key of the time text under the last bubble of a group.
  static const timeKey = ValueKey('message-time');

  /// Key of the status line under an own row that is not delivered.
  static const statusKey = ValueKey('message-status');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final data = _data;
    final own = data.own;
    final tombstone = data.tombstone;
    final shared = data.shared;
    // With a card the bubble's text is the caption: empty when the sender
    // typed none and the text is the post's link (hidden behind the card).
    final text = data.text;
    final at = data.at;
    final spoken = at == null ? '' : formatRelativeTimeSpoken(at, now);
    final clock = at == null
        ? ''
        : formatScheduledClock(at, use24Hour: use24Hour);
    final cardLabel = shared == null ? '' : _sharedPostLabel(shared);
    final label = data.hasCard
        ? [
            own ? 'You shared a post' : '$peerName shared a post',
            if (text.isNotEmpty) text,
            if (cardLabel.isNotEmpty) cardLabel,
            if (!own && spoken.isNotEmpty) spoken,
          ].join(', ')
        : own
        ? (tombstone ? text : 'You said $text')
        : [
            if (tombstone) text else '$peerName said $text',
            if (spoken.isNotEmpty) spoken,
          ].join(', ');
    final postId = data.postId;
    final openPost =
        postId != null && !data.postUnavailable && onOpenPost != null
        ? () => onOpenPost!(postId)
        : null;

    final onAccent = own && !tombstone;
    final foreground = onAccent
        ? messageBubbleForeground(context, own: true)
        : colors.onSurface;
    final linkColor = onAccent ? foreground : context.appColors.accentText;
    final shape = messageBubbleShape(
      own: own,
      lastOfGroup: lastOfGroup && data.tail,
    );
    final links = tombstone || !linksEnabled
        ? const <PostSpan>[]
        : [
            for (final s in parsePostText(text, const []))
              if (s.kind == PostSpanKind.link && s.url != null) s,
          ];

    final decoration = messageBubbleDecoration(
      context,
      own: own,
      tombstone: tombstone,
      shape: shape,
    );
    Widget bubble = DecoratedBox(
      key: ValueKey('bubble-${data.id}'),
      decoration: data.failed
          ? decoration.copyWith(border: Border.all(color: colors.error))
          : decoration,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppMessagesLayout.bubblePaddingH,
          vertical: AppMessagesLayout.bubblePaddingV,
        ),
        child: tombstone
            ? Text(
                text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: colors.onSurfaceVariant,
                ),
              )
            : _content(
                context,
                text: text.isEmpty
                    ? null
                    : MessageText(
                        text: text,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: foreground,
                          fontWeight: onAccent ? FontWeight.w600 : null,
                        ),
                        linkColor: linkColor,
                        linksEnabled: linksEnabled,
                        onOpenLink: onOpenLink,
                      ),
                shared: shared,
                idCard: data.idCard,
                openPost: openPost,
              ),
      ),
    );
    final report = data.reportable ? onReport : null;
    if (report != null) {
      bubble = _ReportableBubble(onReport: report, shape: shape, child: bubble);
    }
    if (data.dimmed) {
      bubble = Opacity(
        opacity: AppMessagesLayout.pendingOpacity,
        child: bubble,
      );
    }
    final status = data.status;
    final retryId = data.retryId;
    final retry = retryId != null && onRetry != null
        ? () => onRetry!(retryId)
        : null;
    final semanticsLabel = status.isEmpty ? label : '$label. $status';
    Widget core = bubble;
    if (status.isNotEmpty) {
      final column = Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          ConstrainedBox(
            constraints: retry != null
                ? const BoxConstraints(minHeight: AppSpacing.minTapTarget)
                : const BoxConstraints(),
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                status,
                key: statusKey,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: data.failed ? colors.error : colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      );
      core = retry != null
          ? InkWell(
              borderRadius: BorderRadius.circular(
                AppMessagesLayout.bubbleRadius,
              ),
              onTap: retry,
              child: column,
            )
          : column;
    }

    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.md,
        top: firstOfGroup ? AppSpacing.sm : AppSpacing.xs,
      ),
      child: Align(
        alignment: own
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * kBubbleMaxWidthFraction,
              ),
              child: Column(
                crossAxisAlignment: own
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: semanticsLabel,
                    container: true,
                    excludeSemantics: true,
                    button: status.isNotEmpty ? retry != null : null,
                    onTap: retry,
                    customSemanticsActions:
                        links.isEmpty && report == null && openPost == null
                        ? null
                        : {
                            const CustomSemanticsAction(
                              label: kOpenSharedPostLabel,
                            ): ?openPost,
                            for (final link in links)
                              CustomSemanticsAction(
                                label: 'Open link ${link.url!.host}',
                              ): () =>
                                  onOpenLink(link.url!),
                            if (report != null)
                              const CustomSemanticsAction(
                                label: kReportMessageLabel,
                              ): () =>
                                  report(_globalRect(context)),
                          },
                    child: core,
                  ),
                  if (status.isEmpty &&
                      (seenAt != null || (lastOfGroup && clock.isNotEmpty)))
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      // The peer's time is already in the bubble's label.
                      child: ExcludeSemantics(
                        excluding: !own,
                        child: Text(
                          seenAt == null
                              ? clock
                              : 'Seen ${formatScheduledClock(seenAt!, use24Hour: use24Hour)}',
                          key: timeKey,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The inside of a visible bubble: the text, and for a share the card under
/// it. The card is drawn on its own surface, not on the bubble's fill, so it
/// reads the same on the caller's gradient, the peer's bubble and dark mode.
Widget _content(
  BuildContext context, {
  required Widget? text,
  required posts.EmbeddedPost? shared,
  required bool idCard,
  required VoidCallback? openPost,
}) {
  final theme = Theme.of(context);
  if (shared == null && !idCard) return text ?? const SizedBox.shrink();
  final card = DecoratedBox(
    key: kSharedPostCardKey,
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.cardSmall),
    ),
    child: shared != null
        ? EmbeddedPostCard(
            embedded: shared,
            placeholder: shared.unavailable
                ? EmbedPlaceholder.unavailable
                : null,
            onTap: openPost,
            maxTextLines: 4,
          )
        : _SharedPostIdCard(openPost: openPost),
  );
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (text != null) ...[text, const SizedBox(height: AppSpacing.sm)],
      card,
    ],
  );
}

/// The compact card of a post shared inside an encrypted message: only its
/// label and the "View post" action. The post is not fetched to draw it; opening
/// it is what loads it.
class _SharedPostIdCard extends StatelessWidget {
  const _SharedPostIdCard({required this.openPost});

  final VoidCallback? openPost;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            kConversationSharedPostSnippet,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          if (openPost != null)
            AppPillButton(
              label: kViewSharedPostLabel,
              variant: AppButtonVariant.text,
              compact: true,
              onPressed: openPost,
            ),
        ],
      ),
    );
  }
}

/// Everything the bubble's build reads, whichever source made it: the proto
/// message of a plaintext thread or the decrypted entry of an encrypted one.
/// Immutable; holds readable text, so it defines no `toString`.
class _BubbleData {
  const _BubbleData({
    required this.id,
    required this.own,
    required this.tombstone,
    required this.text,
    required this.at,
    this.shared,
    this.idCard = false,
    this.postId,
    this.postUnavailable = false,
    this.tail = true,
    this.reportable = true,
    this.status = '',
    this.dimmed = false,
    this.failed = false,
    this.retryId,
  });

  /// The plaintext path, exactly as the bubble always drew a message.
  factory _BubbleData.fromProto(pb.Message message, {bool isMls = false}) {
    final shared = messageSharedPost(message, isMls: isMls);
    return _BubbleData(
      id: message.id,
      own: message.fromSelf,
      // A placeholder is drawn like a tombstone: words, no content.
      tombstone: _isTombstone(message) || isMls,
      text: messageCaption(message, isMls: isMls),
      at: message.hasCreatedAt() ? message.createdAt.toDateTime() : null,
      shared: shared,
      postId: shared?.postId,
      postUnavailable: shared?.unavailable ?? false,
    );
  }

  /// The encrypted path. Every state, check, progress and problem maps to a
  /// value here through exhaustive switches in `encryptedDisplayText` and
  /// `sendStatusText`.
  factory _BubbleData.fromEntry(DecryptedMessage entry) {
    final placeholder = encryptedIsPlaceholder(entry);
    final undecryptable = entry.state == EncryptedMessageState.undecryptable;
    final shared = !placeholder && entry.sharedPostId.isNotEmpty;
    final text = encryptedDisplayText(entry);
    final own = entry.mine && !undecryptable;
    final notDelivered = entry.progress != SendProgress.delivered;
    return _BubbleData(
      id: entry.id,
      own: own,
      tombstone: placeholder,
      text: shared && messageTextIsPostLink(text, entry.sharedPostId)
          ? ''
          : text,
      at: entry.at,
      idCard: shared,
      postId: shared ? entry.sharedPostId : null,
      tail: !undecryptable,
      reportable:
          entry.canReport &&
          entry.state == EncryptedMessageState.visible &&
          !entry.mine,
      status: own
          ? sendStatusText(entry.progress, entry.problem, entry.error)
          : '',
      dimmed:
          own &&
          (entry.progress == SendProgress.sending ||
              entry.progress == SendProgress.waiting),
      failed: own && entry.progress == SendProgress.notSent,
      retryId: own && notDelivered && entry.problem == SendProblem.retryable
          ? entry.id
          : null,
    );
  }

  final String id;

  /// Drawn at the end on the own decoration.
  final bool own;

  /// Italic and muted on the raised surface with a hairline.
  final bool tombstone;

  /// The caption of a card, the text, or the placeholder.
  final String text;
  final DateTime? at;
  final posts.EmbeddedPost? shared;

  /// A shared post known by its id alone (encrypted path).
  final bool idCard;
  final String? postId;
  final bool postUnavailable;

  /// Whether the last bubble of a group gets the tail corner.
  final bool tail;

  /// Whether a report handler is honoured.
  final bool reportable;
  final String status;
  final bool dimmed;
  final bool failed;
  final String? retryId;

  bool get hasCard => shared != null || idCard;
}

/// What a screen reader says of a card: who wrote it and what it says, or
/// that it is unavailable. Never the post's link.
String _sharedPostLabel(posts.EmbeddedPost post) {
  if (post.unavailable) return 'Post unavailable';
  final author = post.author;
  final name = author.displayName.isEmpty
      ? '@${author.handle}'
      : author.displayName;
  return [
    'by $name',
    if (author.displayName.isNotEmpty) '@${author.handle}',
    if (post.text.isNotEmpty) post.text,
    if (post.media.isNotEmpty) 'with ${post.media.length} photos',
  ].join(', ');
}

Rect _globalRect(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return Rect.zero;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _ReportIntent extends Intent {
  const _ReportIntent();
}

/// The ways to ask for the report menu on a peer's bubble: a long press
/// or a secondary click anywhere on it, and from the keyboard Shift+F10, the
/// context-menu key or Enter while the bubble has focus.
///
/// - Focus: the bubble is a tab stop only while it is reportable (this widget
///   exists only then, so a caller's own messages and tombstones never take
///   focus); a 2dp ring in the accent shows keyboard focus and nothing shows on
///   a pointer press.
/// - The browser's own right-click menu is switched off while the pointer is
///   over the bubble ([BrowserContextMenuGuard]) so it does not open on top of
///   ours; the page's text fields keep it.
class _ReportableBubble extends StatefulWidget {
  const _ReportableBubble({
    required this.onReport,
    required this.shape,
    required this.child,
  });

  final void Function(Rect anchor) onReport;
  final BorderRadiusGeometry shape;
  final Widget child;

  @override
  State<_ReportableBubble> createState() => _ReportableBubbleState();
}

class _ReportableBubbleState extends State<_ReportableBubble> {
  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.f10, shift: true): _ReportIntent(),
    SingleActivator(LogicalKeyboardKey.contextMenu): _ReportIntent(),
    SingleActivator(LogicalKeyboardKey.enter): _ReportIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): _ReportIntent(),
  };

  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final report = widget.onReport;
    return BrowserContextMenuGuard(
      child: FocusableActionDetector(
        shortcuts: _shortcuts,
        actions: {
          _ReportIntent: CallbackAction<_ReportIntent>(
            onInvoke: (_) {
              report(_globalRect(context));
              return null;
            },
          ),
        },
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: GestureDetector(
          onLongPressStart: (d) => report(d.globalPosition & Size.zero),
          onSecondaryTapUp: (d) => report(d.globalPosition & Size.zero),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: widget.shape,
              border: _focused
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    )
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// A message body: [parsePostText] spans where only links are tappable (the
/// recognizers are owned and disposed here); mentions and hashtags are
/// plain text.
class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.text,
    required this.style,
    required this.linkColor,
    required this.onOpenLink,
    this.linksEnabled = true,
  });

  final String text;
  final TextStyle? style;
  final Color linkColor;
  final void Function(Uri uri) onOpenLink;

  /// False = every link renders as plain text (no style, no tap).
  final bool linksEnabled;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  late List<PostSpan> _spans;
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _spans = parsePostText(widget.text, const []);
  }

  @override
  void didUpdateWidget(MessageText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _spans = parsePostText(widget.text, const []);
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final children = <InlineSpan>[
      for (final span in _spans)
        if (widget.linksEnabled &&
            span.kind == PostSpanKind.link &&
            span.url != null)
          TextSpan(
            text: span.text,
            style: TextStyle(
              color: widget.linkColor,
              decoration: TextDecoration.underline,
              decorationColor: widget.linkColor,
            ),
            recognizer: _tap(span.url!),
          )
        else
          TextSpan(text: span.text),
    ];
    return Text.rich(TextSpan(style: widget.style, children: children));
  }

  TapGestureRecognizer _tap(Uri url) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onOpenLink(url);
    _recognizers.add(recognizer);
    return recognizer;
  }
}
