part of 'post_card.dart';

/// The post body: [parsePostText] spans as tappable `TextSpan`s. Owns the
/// gesture recognizers (disposed with the widget) and re-parses only when
/// the text or mentions change.
class PostRichText extends StatefulWidget {
  const PostRichText({
    super.key,
    required this.text,
    required this.mentions,
    required this.onOpenLink,
    required this.onOpenMention,
    required this.onHashtagTap,
    this.hashtagSearch = false,
    this.style,
    this.maxLines,
  });

  /// Clamp the text to this many lines with a "Show more" control when it is
  /// longer; null shows all of it (the post detail view).
  final int? maxLines;

  final String text;
  final List<pb.Mention> mentions;
  final TextStyle? style;
  final void Function(Uri uri) onOpenLink;
  final void Function(String userId, String handle) onOpenMention;
  /// Called with the tag body (no `#`, as written) when a hashtag is tapped.
  final void Function(String tag) onHashtagTap;

  /// Hashtags open search (W4-16): the span reads as a link "Search #tag".
  final bool hashtagSearch;

  @override
  State<PostRichText> createState() => _PostRichTextState();
}

class _PostRichTextState extends State<PostRichText> {
  late List<PostSpan> _spans;
  bool _expanded = false;
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _spans = parsePostText(widget.text, widget.mentions);
  }

  @override
  void didUpdateWidget(PostRichText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text ||
        !_sameMentions(old.mentions, widget.mentions)) {
      _spans = parsePostText(widget.text, widget.mentions);
      _expanded = false;
    }
  }

  bool _sameMentions(List<pb.Mention> a, List<pb.Mention> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].handle != b[i].handle || a[i].userId != b[i].userId) {
        return false;
      }
    }
    return true;
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

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    // Mentions, hashtags and links are small accent text: the contrast-safe
    // accent text colour (darker blue on light), not the fill accent.
    final accentText = context.appColors.accentText;
    final tappableStyle = TextStyle(color: accentText);
    final linkStyle = tappableStyle.copyWith(
      decoration: TextDecoration.underline,
      decorationColor: accentText,
    );

    final children = <InlineSpan>[
      for (final span in _spans)
        switch (span.kind) {
          PostSpanKind.plain => TextSpan(text: span.text),
          PostSpanKind.link => TextSpan(
            text: span.text,
            style: linkStyle,
            semanticsLabel: 'Link: ${span.text}',
            recognizer: _tap(() => widget.onOpenLink(span.url!)),
          ),
          PostSpanKind.mention => TextSpan(
            text: span.text,
            style: tappableStyle,
            semanticsLabel: 'Mention ${span.text}',
            recognizer: _tap(
              () => widget.onOpenMention(span.userId!, span.handle!),
            ),
          ),
          PostSpanKind.hashtag => TextSpan(
            text: span.text,
            style: tappableStyle,
            semanticsLabel: widget.hashtagSearch
                ? 'Search ${span.text}'
                : 'Hashtag ${span.text}',
            recognizer: _tap(() => widget.onHashtagTap(span.text.substring(1))),
          ),
        },
    ];

    final span = TextSpan(style: widget.style, children: children);
    final limit = _expanded ? null : widget.maxLines;
    if (limit == null) return Text.rich(span);

    // Measure first: the control exists only when the text really overflows.
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style.merge(widget.style),
            children: children,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: limit,
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        if (!overflows) return Text.rich(span);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(span, maxLines: limit, overflow: TextOverflow.clip),
            Semantics(
              button: true,
              label: 'Show more',
              excludeSemantics: true,
              onTap: () => setState(() => _expanded = true),
              child: InkWell(
                onTap: () => setState(() => _expanded = true),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTapTarget,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1,
                    child: Text(
                      'Show more',
                      style: tappableStyle.merge(widget.style),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
