import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../posts/domain/post_text_parser.dart';

/// What the user typed, as far as the search box can tell.
enum SearchQueryKind {
  /// `@bob`: people only (handle prefix).
  handle,

  /// `#launch`: posts tagged with exactly this tag (plus the People tab).
  tag,

  /// `launch`: people by handle prefix and posts tagged `#launch` (plan F4).
  word,
}

/// Why a query makes no call. [none] means it can be sent.
enum SearchQueryIssue {
  none,

  /// Nothing left after trimming.
  empty,

  /// A handle or word shorter than [SearchQuery.minLength].
  tooShort,

  /// More than [SearchQuery.maxCodePoints] code points, or a handle prefix
  /// longer than [SearchQuery.maxHandleLength].
  tooLong,

  /// Control or bidi characters, or a `@handle` / `#tag` whose body is not in
  /// the grammar.
  invalid,

  /// A plain query that is neither a handle prefix nor a tag body (a phrase,
  /// an accented word longer than 15, ...). Stage 0 has no full-text search:
  /// the UI says "Search posts by #hashtag" and sends nothing.
  unsupported,
}

/// A search-box query, classified with the server's grammar (W4 plan, "Query
/// grammar"; the server validates again and is the source of truth):
///
/// - normalise: NFC, trim, lower-case;
/// - at most [maxCodePoints] code points (the marker counts), no control or
///   bidi formatting characters (ADR-0010 D9);
/// - people: `@?[a-z0-9_]{2,15}`;
/// - posts: `#?` + one hashtag body, judged by [parsePostText], the same
///   grammar the shared `testdata/post_text_grammar.json` fixtures pin on
///   both sides (ADR-0010 D8).
///
/// Pure: no I/O, no clock. Nothing here is ever sent to a server unless
/// [canSearchPeople] or [canSearchPosts] is true.
class SearchQuery {
  const SearchQuery._({
    required this.kind,
    required this.body,
    required this.issue,
    this.peopleQuery,
    this.tagBody,
  });

  /// Shortest handle prefix or plain word that is searched (1-character
  /// prefixes are refused by the server: enumeration guard).
  static const minLength = 2;

  /// Longest handle prefix (the longest handle).
  static const maxHandleLength = 15;

  /// Longest normalised query, counting `@` or `#`.
  static const maxCodePoints = 50;

  final SearchQueryKind kind;

  /// The normalised query without its `@` / `#` marker, e.g. `launch`.
  final String body;

  final SearchQueryIssue issue;

  /// The handle prefix to send to SearchPeople, or null when this query
  /// cannot search people (a `#tag`, or a word that is not a handle prefix).
  final String? peopleQuery;

  /// The tag body (no `#`) to send to SearchPosts, or null when the query
  /// cannot search posts (a `@handle`, or a body outside the tag grammar).
  final String? tagBody;

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

  // Control characters (\p{Cc}) and the bidi formatting controls the post
  // grammar also refuses (ADR-0010 D9). ZWJ/ZWNJ stay: tag bodies may hold them.
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

    if (text.isEmpty) return fail(SearchQueryIssue.empty);
    if (text.runes.length > maxCodePoints) {
      return fail(SearchQueryIssue.tooLong);
    }
    if (text.runes.any(_isForbidden)) return fail(SearchQueryIssue.invalid);

    switch (kind) {
      case SearchQueryKind.handle:
        if (body.isEmpty) return fail(SearchQueryIssue.tooShort);
        if (!_handleChars.hasMatch(body)) {
          return fail(SearchQueryIssue.invalid);
        }
        if (body.length < minLength) return fail(SearchQueryIssue.tooShort);
        if (body.length > maxHandleLength) {
          return fail(SearchQueryIssue.tooLong);
        }
        return SearchQuery._(
          kind: kind,
          body: body,
          issue: SearchQueryIssue.none,
          peopleQuery: body,
        );
      case SearchQueryKind.tag:
        if (body.isEmpty) return fail(SearchQueryIssue.tooShort);
        if (!_isTagBody(body)) return fail(SearchQueryIssue.invalid);
        return SearchQuery._(
          kind: kind,
          body: body,
          issue: SearchQueryIssue.none,
          tagBody: body,
        );
      case SearchQueryKind.word:
        if (body.runes.length < minLength) {
          return fail(SearchQueryIssue.tooShort);
        }
        final people =
            body.length <= maxHandleLength && _handleChars.hasMatch(body)
            ? body
            : null;
        final tag = _isTagBody(body) ? body : null;
        if (people == null && tag == null) {
          return fail(SearchQueryIssue.unsupported);
        }
        return SearchQuery._(
          kind: kind,
          body: body,
          issue: SearchQueryIssue.none,
          peopleQuery: people,
          tagBody: tag,
        );
    }
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
