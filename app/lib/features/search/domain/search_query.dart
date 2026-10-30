import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../posts/domain/post_text_parser.dart';

/// What the user typed, as far as the search box can tell.
enum SearchQueryKind {
  /// `@bob`: people only (handle prefix).
  handle,

  /// `#launch`: posts tagged with exactly this tag (no people).
  tag,

  /// `launch`: people by handle prefix and posts tagged `#launch` (plan F4).
  word,
}

/// Why a query is not searched at all. [none] means at least one search can
/// be sent (see [SearchQuery.canSearchPeople] / [SearchQuery.canSearchPosts]).
enum SearchQueryIssue {
  none,

  /// Nothing left after trimming and removing the sigil (`''`, `@`, `#`).
  empty,

  /// Too short for people and no tag to search instead (`@a`, `1`).
  tooShort,

  /// More than [SearchQuery.maxCodePoints] code points after the sigil.
  tooLong,

  /// A control or bidi formatting character anywhere.
  invalid,

  /// Neither a handle prefix nor one tag body (a phrase, `#123`, `#go!`).
  /// Stage 0 has no full-text search: the UI says "Search posts by #hashtag".
  unsupported,
}

/// A search-box query, classified with ADR-0028 D1 (client and server apply
/// the same rules in the same order; the server validates again):
///
/// 1. NFC, trim, lower-case;
/// 2. at most one leading sigil, `@` or `#`, is removed **before** the length
///    check, so it does not count: `#` + a 50-code-point tag is valid;
/// 3. empty rest, more than [maxCodePoints] code points, or a control / bidi
///    character: no call;
/// 4. people: not for a `#` sigil; the rest must be `[a-z0-9_]{1,15}`, where
///    1 character is too short ([peopleTooShort]) and 2 to 15 is a prefix;
/// 5. posts: not for an `@` sigil; the rest must be exactly one hashtag body,
///    judged by [parsePostText] (ADR-0010 D8), including a 1-character body:
///    `a` and `#a` both search the tag `a`.
///
/// Pure: no I/O, no clock. Nothing is sent unless [canSearchPeople] or
/// [canSearchPosts] is true; the UI runs only the searches that are allowed.
class SearchQuery {
  const SearchQuery._({
    required this.kind,
    required this.body,
    required this.issue,
    this.peopleQuery,
    this.tagBody,
    this.peopleTooShort = false,
  });

  /// Shortest handle prefix (1-character prefixes are refused: enumeration
  /// guard). Typeahead also makes no call below this (it suggests people).
  static const minLength = 2;

  /// Longest handle prefix (the longest handle).
  static const maxHandleLength = 15;

  /// Longest rest of the query, not counting the sigil.
  static const maxCodePoints = 50;

  final SearchQueryKind kind;

  /// The normalised query without its sigil, e.g. `launch`.
  final String body;

  final SearchQueryIssue issue;

  /// The handle prefix for SearchPeople, or null when people are not searched
  /// (a `#tag`, a rest outside the handle class, or [peopleTooShort]).
  final String? peopleQuery;

  /// The tag body (no `#`) for SearchPosts, or null when posts are not
  /// searched (a `@handle`, or a rest that is not one tag body).
  final String? tagBody;

  /// People are skipped because the rest is one character (`a`, `@a`, `#a`
  /// has no people at all). The People tab shows the "too short" hint while
  /// the post tabs may still search tag `a`.
  final bool peopleTooShort;

  bool get isValid => issue == SearchQueryIssue.none;
  bool get canSearchPeople => peopleQuery != null;
  bool get canSearchPosts => tagBody != null;

  /// The text to send as the posts RPC `query`: `#` + body.
  String? get postsRequest => tagBody == null ? null : '#$tagBody';

  /// The normalised query as the user would type it (`@bob`, `#launch`,
  /// `launch`). The key of a recent search and the `q` of `/search?q=`.
  String get canonical => switch (kind) {
    SearchQueryKind.handle => '@$body',
    SearchQueryKind.tag => '#$body',
    SearchQueryKind.word => body,
  };

  /// NFC, trim, lower-case: the form every other rule works on.
  static String normalize(String raw) => unorm.nfc(raw).trim().toLowerCase();

  static final _handleChars = RegExp(r'^[a-z0-9_]+$');

  // Control characters and the bidi formatting controls the post grammar also
  // refuses (ADR-0010 D9). ZWJ/ZWNJ stay: tag bodies may hold them.
  static bool _isForbidden(int r) =>
      r < 0x20 ||
      (r >= 0x7F && r <= 0x9F) ||
      r == 0x061C ||
      r == 0x200E ||
      r == 0x200F ||
      (r >= 0x202A && r <= 0x202E) ||
      (r >= 0x2066 && r <= 0x2069);

  /// Classifies [raw]. Never throws.
  static SearchQuery parse(String raw) {
    final text = normalize(raw);
    final kind = text.startsWith('@')
        ? SearchQueryKind.handle
        : text.startsWith('#')
        ? SearchQueryKind.tag
        : SearchQueryKind.word;
    final body = kind == SearchQueryKind.word ? text : text.substring(1);

    SearchQuery fail(SearchQueryIssue issue) =>
        SearchQuery._(kind: kind, body: body, issue: issue);

    if (text.runes.any(_isForbidden)) return fail(SearchQueryIssue.invalid);
    if (body.isEmpty) return fail(SearchQueryIssue.empty);
    final length = body.runes.length;
    if (length > maxCodePoints) return fail(SearchQueryIssue.tooLong);

    final handleShaped =
        length <= maxHandleLength && _handleChars.hasMatch(body);
    final tooShortForPeople =
        kind != SearchQueryKind.tag && handleShaped && length < minLength;
    final people =
        kind != SearchQueryKind.tag && handleShaped && length >= minLength
        ? body
        : null;
    final tag = kind != SearchQueryKind.handle && _isTagBody(body)
        ? body
        : null;

    if (people == null && tag == null) {
      return SearchQuery._(
        kind: kind,
        body: body,
        issue: tooShortForPeople
            ? SearchQueryIssue.tooShort
            : SearchQueryIssue.unsupported,
        peopleTooShort: tooShortForPeople,
      );
    }
    return SearchQuery._(
      kind: kind,
      body: body,
      issue: SearchQueryIssue.none,
      peopleQuery: people,
      tagBody: tag,
      peopleTooShort: tooShortForPeople,
    );
  }

  /// Whether `#[body]` is exactly one hashtag under the post grammar: the one
  /// rule set that decides what the server stores as a tag (ADR-0010 D8).
  static bool _isTagBody(String body) {
    final spans = parsePostText('#$body', const []);
    return spans.length == 1 && spans.single.kind == PostSpanKind.hashtag;
  }

  @override
  bool operator ==(Object other) =>
      other is SearchQuery &&
      other.kind == kind &&
      other.body == body &&
      other.issue == issue;

  @override
  int get hashCode => Object.hash(kind, body, issue);

  @override
  String toString() => 'SearchQuery($kind, "$body", $issue)';
}
