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
    this.inlineShowMore = false,
  });

  /// Clamp the text to this many lines with a "Show more" control when it is
  /// longer; null shows all of it (the post detail view).
  final int? maxLines;

  /// Put "... Show more" at the end of the last allowed line (the text is cut
  /// so the two fit) instead of on a row of its own below. Used for a post
  /// with media, where the text stays at two lines and the picture follows.
  final bool inlineShowMore;

  final String text;
  final List<pb.Mention> mentions;
  final TextStyle? style;
  final void Function(Uri uri) onOpenLink;
  final void Function(String userId, String handle) onOpenMention;

  /// Called with the tag body (no `#`, as written) when a hashtag is tapped.
  final void Function(String tag) onHashtagTap;

  /// Hashtags open search: the span reads as a link "Search #tag".
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
        if (widget.inlineShowMore) {
          return _inline(
            context,
            constraints.maxWidth,
            limit,
            children,
            tappableStyle,
          );
        }
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

  void _expand() => setState(() => _expanded = true);

  /// [children] cut to their first [count] characters (the last span may be
  /// partial; it loses its screen-reader label, which described all of it).
  List<InlineSpan> _take(List<InlineSpan> children, int count) {
    final out = <InlineSpan>[];
    var left = count;
    for (final child in children) {
      if (left <= 0) break;
      final span = child as TextSpan;
      final text = span.text ?? '';
      if (text.length <= left) {
        out.add(span);
        left -= text.length;
        continue;
      }
      var end = left;
      // Never split a surrogate pair.
      if (end > 0 && (text.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end--;
      out.add(
        TextSpan(
          text: text.substring(0, end),
          style: span.style,
          recognizer: span.recognizer,
        ),
      );
      break;
    }
    // Trailing blanks and newlines would push the ellipsis off the line.
    while (out.isNotEmpty) {
      final last = out.last as TextSpan;
      final trimmed = (last.text ?? '').trimRight();
      if (trimmed.isEmpty) {
        out.removeLast();
      } else {
        if (trimmed.length != last.text!.length) {
          out[out.length - 1] = TextSpan(
            text: trimmed,
            style: last.style,
            recognizer: last.recognizer,
            semanticsLabel: last.semanticsLabel,
          );
        }
        break;
      }
    }
    return out;
  }

  /// The text cut to the longest prefix that still fits [limit] lines with
  /// "... Show more" after it (found by bisection on the character count),
  /// the control tappable through a 48 dp target laid over it. At one-line
  /// heights the target reaches a few dp below the second line, so the block
  /// is that much taller (the target must be inside its parent to be hit).
  Widget _inline(
    BuildContext context,
    double maxWidth,
    int limit,
    List<InlineSpan> children,
    TextStyle tappableStyle,
  ) {
    final base = DefaultTextStyle.of(context).style.merge(widget.style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final more = TextSpan(
      text: 'Show more',
      style: tappableStyle,
      // The 48 dp overlay below takes the tap and is the screen-reader
      // button; the span itself stays out of the semantics tree.
      semanticsLabel: '',
    );
    TextSpan build(int count) => TextSpan(
      style: base,
      children: [
        ..._take(children, count),
        const TextSpan(text: '\u2026 '),
        more,
      ],
    );

    TextPainter paint(TextSpan s) =>
        TextPainter(text: s, textDirection: direction, textScaler: scaler)
          ..layout(maxWidth: maxWidth);

    var total = 0;
    for (final child in children) {
      total += ((child as TextSpan).text ?? '').length;
    }
    var lo = 0;
    var hi = total;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      final p = paint(build(mid));
      final fits = p.computeLineMetrics().length <= limit;
      p.dispose();
      if (fits) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final cut = build(lo);
    final painter = paint(cut);
    final cutLength = cut.toPlainText(includeSemanticsLabels: false).length;
    final boxes = painter.getBoxesForSelection(
      TextSelection(
        baseOffset: cutLength - 'Show more'.length,
        extentOffset: cutLength,
      ),
    );
    final size = painter.size;
    painter.dispose();
    var target = Rect.zero;
    var extra = 0.0;
    if (boxes.isNotEmpty) {
      final box = boxes
          .map((b) => b.toRect())
          .reduce((a, b) => a.expandToInclude(b));
      final width = math.max(box.width, AppSpacing.minTapTarget);
      final height = math.max(box.height, AppSpacing.minTapTarget);
      final left = (box.center.dx - width / 2)
          .clamp(0.0, math.max(0.0, maxWidth - width))
          .toDouble();
      // Ends at the bottom of the line, growing upwards over the line above;
      // only what still does not fit sticks out below.
      final top = math.max(0.0, box.bottom - height);
      target = Rect.fromLTWH(left, top, width, height);
      extra = math.max(0.0, target.bottom - size.height);
    }
    return SizedBox(
      height: size.height + extra,
      child: Stack(
        children: [
          Positioned(top: 0, left: 0, right: 0, child: Text.rich(cut)),
          if (!target.isEmpty)
            Positioned.fromRect(
              rect: target,
              child: Semantics(
                key: const ValueKey('post-text-show-more'),
                button: true,
                label: 'Show more',
                excludeSemantics: true,
                onTap: _expand,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _expand,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
