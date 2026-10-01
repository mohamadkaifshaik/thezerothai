import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// What a run of post text is, for rendering (ADR-0010 D7/D8, T15).
enum PostSpanKind { plain, link, mention, hashtag }

/// One contiguous run of a post's text. Concatenating every span's [text]
/// gives back the original string exactly.
class PostSpan {
  const PostSpan(this.kind, this.text, {this.url, this.userId, this.handle});

  final PostSpanKind kind;
  final String text;

  /// The http(s) target of a [PostSpanKind.link].
  final Uri? url;

  /// The `mentions[].user_id` of a [PostSpanKind.mention]. Navigation is by
  /// this id, never by the text typed in the post.
  final String? userId;

  /// The `mentions[].handle` (lower-case) of a [PostSpanKind.mention].
  final String? handle;

  bool get isTappable => kind != PostSpanKind.plain;

  @override
  bool operator ==(Object other) =>
      other is PostSpan &&
      other.kind == kind &&
      other.text == text &&
      other.url == url &&
      other.userId == userId &&
      other.handle == handle;

  @override
  int get hashCode => Object.hash(kind, text, url, userId, handle);

  @override
  String toString() => 'PostSpan($kind, "$text")';
}

// `http://` or `https://` (any case) followed by a run of non-space,
// non-bracket characters. Nothing else is ever linkified: `javascript:`,
// `data:`, `ftp://`, bare `www.` are plain text.
final _urlRe = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

// A trailing run of sentence punctuation is not part of the link.
const _urlTrailing = '.,;:!?\'")]}';

// Mention candidate: `@` + 3-15 handle characters (identity's handleRe).
final _mentionRe = RegExp(r'@([A-Za-z0-9_]{3,15})(?![A-Za-z0-9_@])');

// Hashtag candidate (D8): first rune is a letter/number/underscore, the rest
// may also be marks and ZWJ/ZWNJ, at most 50 in all.
final _hashtagRe = RegExp(
  r'#([\p{L}\p{N}_][\p{L}\p{M}\p{N}_‌‍]{0,49})',
  unicode: true,
);
final _hashtagBodyRune = RegExp(r'[\p{L}\p{M}\p{N}_‌‍]', unicode: true);
final _letter = RegExp(r'\p{L}', unicode: true);
final _letterMarkNumber = RegExp(r'[\p{L}\p{M}\p{N}]', unicode: true);

bool _isBlockedBefore(String text, int index, String extra) {
  if (index == 0) return false;
  // The rune before [index] (a surrogate pair is two code units).
  var start = index - 1;
  final unit = text.codeUnitAt(start);
  if (unit >= 0xDC00 && unit <= 0xDFFF && start > 0) start--;
  final before = text.substring(start, index);
  return _letterMarkNumber.hasMatch(before) || extra.contains(before);
}

/// Splits [text] into plain, link, mention and hashtag spans.
///
/// - Links are only `http://` and `https://` URLs with a host.
/// - A mention is tappable only when its handle matches a `mentions[]` entry
///   **case-insensitively** (the server stores handles lower-case); an
///   unresolved `@carol` stays plain text.
/// - Hashtags follow ADR-0010 D8; tapping them is a placeholder until
///   Phase 2.
/// - `@` and `#` inside a link stay part of the link.
///
/// Pure and allocation-light; cheap enough to run per card build, but
/// callers cache the result (see `PostCard`).
List<PostSpan> parsePostText(String text, Iterable<pb.Mention> mentions) {
  final byHandle = <String, pb.Mention>{};
  for (final m in mentions) {
    byHandle.putIfAbsent(m.handle.toLowerCase(), () => m);
  }

  // (start, end, span) candidates, links first because they win overlaps.
  final found = <(int, int, PostSpan)>[];

  for (final match in _urlRe.allMatches(text)) {
    if (_isBlockedBefore(text, match.start, '')) continue;
    var end = match.end;
    while (end > match.start + 1 && _urlTrailing.contains(text[end - 1])) {
      end--;
    }
    final raw = text.substring(match.start, end);
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      continue;
    }
    found.add((match.start, end, PostSpan(PostSpanKind.link, raw, url: uri)));
  }

  bool overlapsLink(int start, int end) =>
      found.any((f) => start < f.$2 && end > f.$1);

  if (byHandle.isNotEmpty) {
    for (final match in _mentionRe.allMatches(text)) {
      if (overlapsLink(match.start, match.end)) continue;
      if (_isBlockedBefore(text, match.start, r'_@#/.:&$+-')) continue;
      final mention = byHandle[match.group(1)!.toLowerCase()];
      if (mention == null) continue;
      found.add((
        match.start,
        match.end,
        PostSpan(
          PostSpanKind.mention,
          match.group(0)!,
          userId: mention.userId,
          handle: mention.handle.toLowerCase(),
        ),
      ));
    }
  }

  for (final match in _hashtagRe.allMatches(text)) {
    if (overlapsLink(match.start, match.end)) continue;
    if (_isBlockedBefore(text, match.start, '_@#/&')) continue;
    final body = match.group(1)!;
    if (!_letter.hasMatch(body)) continue;
    // A run longer than 50 is not a hashtag (never truncated).
    if (match.end < text.length &&
        _hashtagBodyRune.hasMatch(text.substring(match.end, match.end + 1))) {
      continue;
    }
    found.add((
      match.start,
      match.end,
      PostSpan(PostSpanKind.hashtag, match.group(0)!),
    ));
  }

  found.sort((a, b) => a.$1.compareTo(b.$1));

  final spans = <PostSpan>[];
  var cursor = 0;
  for (final (start, end, span) in found) {
    if (start < cursor) continue;
    if (start > cursor) {
      spans.add(PostSpan(PostSpanKind.plain, text.substring(cursor, start)));
    }
    spans.add(span);
    cursor = end;
  }
  if (cursor < text.length) {
    spans.add(PostSpan(PostSpanKind.plain, text.substring(cursor)));
  }
  return spans;
}
