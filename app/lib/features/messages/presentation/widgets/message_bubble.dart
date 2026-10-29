import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/format/scheduled_time.dart';
import '../../../../shared/widgets/browser_context_menu_guard.dart';
import '../../../posts/domain/post_text_parser.dart';
import 'conversation_row.dart';

/// The words of a tombstone bubble (ADR-0027 D5), shared with the inbox row.
const kMessageDeletedText = kConversationDeletedSnippet;
const kMessageRemovedText = kConversationRemovedSnippet;

/// The label of the report action on a peer's bubble (menu item and the
/// assistive-technology action).
const kReportMessageLabel = 'Report message';

/// The bubble's share of the row width; the rest keeps the sides distinct.
const double kBubbleMaxWidthFraction = 0.8;

/// The text a message shows: its text, or the tombstone words for a message
/// whose text is gone.
String messageDisplayText(pb.Message message) => switch (message.state) {
  MessageState.MESSAGE_STATE_DELETED_ACCOUNT => kMessageDeletedText,
  MessageState.MESSAGE_STATE_REMOVED => kMessageRemovedText,
  _ => message.text,
};

bool _isTombstone(pb.Message message) =>
    message.state == MessageState.MESSAGE_STATE_DELETED_ACCOUNT ||
    message.state == MessageState.MESSAGE_STATE_REMOVED;

/// One message of a conversation (W7-15), presentational.
///
/// - The caller's own messages sit at the end on the accent with white text;
///   the peer's at the start on the raised surface. Tombstones are italic and
///   muted on the raised surface with a 1dp border (never white on accent).
/// - [lastOfGroup] puts the time under the bubble and gives the bubble its
///   small "tail" corner; [firstOfGroup] adds the gap above the group.
/// - Links come from [parsePostText] link spans only. Mentions and hashtags
///   stay plain text: a conversation has no mention list, and a `#tag` is not
///   a navigation target here.
/// - Semantics: one node, "You said ..." or "`name` said ..., `time`"; each
///   link is an "Open link" custom action, since the text children are
///   excluded.
/// - [onReport] (W7-18, only on a peer's visible message, only with `reports`
///   on) adds "Report message": a long press or a secondary click calls it
///   with the press point, and assistive technology gets a "Report message"
///   action (called with the bubble's rectangle). Null = no gesture, no action.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.peerName,
    required this.now,
    required this.firstOfGroup,
    required this.lastOfGroup,
    required this.onOpenLink,
    this.use24Hour = false,
    this.onReport,
  });

  final pb.Message message;

  /// The peer's display name (or `@handle`): the "name said" of the label.
  final String peerName;

  /// The clock the spoken relative time is drawn against (injected).
  final DateTime now;
  final bool firstOfGroup;
  final bool lastOfGroup;
  final void Function(Uri uri) onOpenLink;
  final bool use24Hour;

  /// Opens the "Report message" menu at [anchor] (null = not reportable).
  final void Function(Rect anchor)? onReport;

  /// Key of the time text under the last bubble of a group.
  static const timeKey = ValueKey('message-time');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final own = message.fromSelf;
    final tombstone = _isTombstone(message);
    final text = messageDisplayText(message);
    final at = message.hasCreatedAt() ? message.createdAt.toDateTime() : null;
    final spoken = at == null ? '' : formatRelativeTimeSpoken(at, now);
    final clock = at == null
        ? ''
        : formatScheduledClock(at, use24Hour: use24Hour);
    final label = own
        ? (tombstone ? text : 'You said $text')
        : [
            if (tombstone) text else '$peerName said $text',
            if (spoken.isNotEmpty) spoken,
          ].join(', ');

    final onAccent = own && !tombstone;
    final background = onAccent ? colors.primary : colors.surfaceContainerHigh;
    final foreground = onAccent ? colors.onPrimary : colors.onSurface;
    final linkColor = onAccent
        ? colors.onPrimary
        : context.appColors.accentText;
    const radius = Radius.circular(AppRadius.lg);
    const tail = Radius.circular(AppSpacing.xs);
    final shape = BorderRadiusDirectional.only(
      topStart: radius,
      topEnd: radius,
      bottomStart: own || !lastOfGroup ? radius : tail,
      bottomEnd: !own || !lastOfGroup ? radius : tail,
    );
    final links = tombstone
        ? const <PostSpan>[]
        : [
            for (final s in parsePostText(text, const []))
              if (s.kind == PostSpanKind.link && s.url != null) s,
          ];

    Widget bubble = DecoratedBox(
      key: ValueKey('bubble-${message.id}'),
      decoration: BoxDecoration(
        color: background,
        borderRadius: shape,
        border: tombstone ? Border.all(color: colors.outlineVariant) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.smd,
          vertical: AppSpacing.sm,
        ),
        child: tombstone
            ? Text(
                text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: colors.onSurfaceVariant,
                ),
              )
            : MessageText(
                text: text,
                style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
                linkColor: linkColor,
                onOpenLink: onOpenLink,
              ),
      ),
    );
    final report = onReport;
    if (report != null) {
      bubble = _ReportableBubble(onReport: report, shape: shape, child: bubble);
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
                    label: label,
                    container: true,
                    excludeSemantics: true,
                    customSemanticsActions: links.isEmpty && report == null
                        ? null
                        : {
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
                    child: bubble,
                  ),
                  if (lastOfGroup && clock.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      // The peer's time is already in the bubble's label.
                      child: ExcludeSemantics(
                        excluding: !own,
                        child: Text(
                          clock,
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

Rect _globalRect(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return Rect.zero;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _ReportIntent extends Intent {
  const _ReportIntent();
}

/// The ways to ask for the report menu on a peer's bubble (W7-18): a long press
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
  });

  final String text;
  final TextStyle? style;
  final Color linkColor;
  final void Function(Uri uri) onOpenLink;

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
        if (span.kind == PostSpanKind.link && span.url != null)
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
