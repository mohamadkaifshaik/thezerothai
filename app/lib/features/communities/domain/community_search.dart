import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;

/// The most rows `SearchCommunityMembers` answers (F36; the server clamps
/// `limit` to 1..20).
const kCommunityMemberSearchLimit = 20;

/// How long the members field waits after the last keystroke before it asks
/// (F36: 300 ms).
const kCommunityMemberSearchDebounce = Duration(milliseconds: 300);

/// The directory and "mine" are one response of at most this many rows at
/// Stage 0 (`ListCommunities`, `ListMyCommunities`). A list this long may be
/// cut short, so a filter over it cannot say that nothing matches (F37).
const kCommunitiesLoadedCap = 50;

/// What the members search field holds (F36).
enum MemberSearchInput {
  /// Nothing typed (or only "@"): the page shows its list.
  blank,

  /// One character: too short to ask; the page shows its list.
  tooShort,

  /// Something a handle can never start with (a space, a dot, a symbol):
  /// no call, a hint.
  invalid,

  /// Handle characters, but more than 15 of them (a handle is at most 15):
  /// no call, its own hint.
  tooLong,

  /// A prefix the server accepts.
  ready,
}

final _prefixChars = RegExp(r'^[A-Za-z0-9_]+$');

/// The handle prefix of [raw] as `SearchCommunityMembers` takes it: one
/// optional leading "@", then 2-15 characters of `[A-Za-z0-9_]`, lower-cased.
/// Null for anything else (nothing is sent then).
String? memberSearchPrefix(String raw) =>
    memberSearchInputOf(raw) == MemberSearchInput.ready
    ? _strip(raw).toLowerCase()
    : null;

/// How [raw] reads as a members search ([MemberSearchInput]).
MemberSearchInput memberSearchInputOf(String raw) {
  final text = _strip(raw);
  if (text.isEmpty) return MemberSearchInput.blank;
  if (!_prefixChars.hasMatch(text)) return MemberSearchInput.invalid;
  if (text.length > 15) return MemberSearchInput.tooLong;
  if (text.length < 2) return MemberSearchInput.tooShort;
  return MemberSearchInput.ready;
}

String _strip(String raw) {
  final text = raw.trim();
  return text.startsWith('@') ? text.substring(1) : text;
}

/// The communities of [list] whose name or description contains [query]
/// (case-insensitive, trimmed); all of them for a blank query. F37 v1: a
/// filter over the rows already loaded, no call.
List<pb.Community> filterCommunities(List<pb.Community> list, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return list;
  return [
    for (final c in list)
      if (c.name.toLowerCase().contains(q) ||
          c.description.toLowerCase().contains(q))
        c,
  ];
}

/// Whether a loaded list of [count] rows may be missing rows (a next page,
/// or the Stage 0 cap reached): then "nothing matches" is not a fact.
bool communitiesMayBeCut({required int count, required bool hasMore}) =>
    hasMore || count >= kCommunitiesLoadedCap;
