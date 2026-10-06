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

// URL-span candidate (ADR-0010 D7 "URL spans", D21 G1): `http://` or
// `https://` (any case) followed by one or more non-terminator runes. The
// terminator set is ECMAScript `\s` plus `<`, `>` and `"`, which is exactly
// what `[^\s<>"]` already means in Dart. It must equal the server's explicit
// list (backend/internal/posts/text) - do not "simplify" it. Every candidate
// is a span for `@`/`#` exclusion; only safe ones are tappable. Nothing else
// is ever linkified: `javascript:`, `data:`, `ftp://`, bare `www.` are plain.
final _urlRe = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

// Sentence punctuation after a link is not part of it; a closing bracket is
// only stripped when unbalanced (so `.../Foo_(bar)` keeps its `)`).
const _urlTrailing = '.,;:!?\'"';
const _urlClosers = {')': '(', ']': '[', '}': '{'};

// Only a plain ASCII hostname is linkified: no userinfo, percent-escapes,
// IDN/homograph (non-ASCII) hosts or IP-literal brackets.
final _asciiHostRe = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$');

// Invisible/bidi controls that can disguise a link's real target.
final _spoofingRe = RegExp(
  '[\u061C\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]',
);

// Bidi embedding/override/isolate controls anywhere in a post can reorder
// the text around a link (`<RLO>https://evil.com/?moc.elgoog//:sptth` renders
// as google.com). Such a post gets no tappable links at all.
final _bidiControlRe = RegExp('[\u061C\u202A-\u202E\u2066-\u2069]');

String _trimUrl(String text, int start, int end) {
  while (end > start + 1) {
    final c = text[end - 1];
    if (_urlTrailing.contains(c)) {
      end--;
      continue;
    }
    final opener = _urlClosers[c];
    if (opener != null) {
      final body = text.substring(start, end);
      if (c.allMatches(body).length > opener.allMatches(body).length) {
        end--;
        continue;
      }
    }
    break;
  }
  return text.substring(start, end);
}

bool _isSafeLink(Uri uri, String raw) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.userInfo.isNotEmpty || !_asciiHostRe.hasMatch(uri.host)) {
    return false;
  }
  // `Uri.host` decodes percent-escapes; judge the authority as typed.
  final afterScheme = raw.substring(raw.indexOf('://') + 3);
  final authority = afterScheme.split(RegExp(r'[/?#]')).first;
  return !authority.contains('%') && !authority.contains('@');
}

// Mention candidate: `@` + 3-15 handle characters (identity's handleRe).
final _mentionRe = RegExp(r'@([A-Za-z0-9_]{3,15})(?![A-Za-z0-9_@])');

// Hashtag candidate (D8): first rune is a letter/number/underscore, the rest
// may also be marks and ZWJ/ZWNJ, at most 50 in all.
final _hashtagRe = RegExp(
  r'#([\p{L}\p{N}_][\p{L}\p{M}\p{N}_\u200c\u200d]{0,49})',
  unicode: true,
);
final _hashtagBodyRune = RegExp(r'[\p{L}\p{M}\p{N}_\u200c\u200d]', unicode: true);
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
/// - `@` and `#` inside any URL span (even one rendered as plain text) are
///   never a mention or hashtag (D7/D8, D21 G1).
///
/// Pure and allocation-light; cheap enough to run per card build, but
/// callers cache the result (see `PostCard`).
List<PostSpan> parsePostText(String text, Iterable<pb.Mention> mentions) {
  final byHandle = <String, pb.Mention>{};
  for (final m in mentions) {
    byHandle.putIfAbsent(m.handle.toLowerCase(), () => m);
  }

  // (start, end, span) candidates; links are found first and win overlaps.
  final found = <(int, int, PostSpan)>[];
  final linkRanges = <(int, int)>[];

  // D7 step 5: a span is syntactic. Mention/hashtag candidates inside *any*
  // span are excluded, even when the span is rendered as plain text (unsafe
  // host, spoofing characters, or a post with bidi controls).
  final allowLinks = !_bidiControlRe.hasMatch(text);
  for (final match in _urlRe.allMatches(text)) {
    if (_isBlockedBefore(text, match.start, '')) continue;
    final raw = _trimUrl(text, match.start, match.end);
    final end = match.start + raw.length;
    linkRanges.add((match.start, end));
    if (!allowLinks || _spoofingRe.hasMatch(raw)) continue;
    final uri = Uri.tryParse(raw);
    if (uri == null || !_isSafeLink(uri, raw)) continue;
    found.add((match.start, end, PostSpan(PostSpanKind.link, raw, url: uri)));
  }

  bool overlapsLink(int start, int end) =>
      linkRanges.any((r) => start < r.$2 && end > r.$1);

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
    if (match.end < text.length) {
      // Read the whole next rune (an astral letter is two code units).
      final unit = text.codeUnitAt(match.end);
      final isHigh = unit >= 0xD800 && unit <= 0xDBFF;
      final nextEnd = isHigh && match.end + 2 <= text.length
          ? match.end + 2
          : match.end + 1;
      if (_hashtagBodyRune.hasMatch(text.substring(match.end, nextEnd))) {
        continue;
      }
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
