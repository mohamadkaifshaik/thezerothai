import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';

/// The feature flag (`GetMe.enabled_features`) of message search. The search
/// runs on this device over the cached messages; the flag only shows the UI.
const kFeatureMessageSearch = 'message_search';

/// Message search is on the device only: nothing here sends text anywhere,
/// and the query is never logged, persisted or put in a URL.
const kMessageSearchNote = 'Searching messages on this device';

/// A half-open UTF-16 range `[start, end)` of the original text.
class SearchRange {
  const SearchRange(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is SearchRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SearchRange($start, $end)';
}

/// Where [query] occurs in [text], case-insensitively, as ranges of the
/// ORIGINAL [text] (non-overlapping, in order). Empty for a blank query.
///
/// Lower-casing can change a string's length (`İ` becomes two code units), so
/// the text is folded one code point at a time and each folded unit remembers
/// the code point it came from: a range always covers whole code points of the
/// original and is never shifted.
List<SearchRange> matchRanges(String text, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || text.isEmpty) return const [];
  final folded = StringBuffer();
  final starts = <int>[];
  final ends = <int>[];
  var offset = 0;
  for (final rune in text.runes) {
    final original = String.fromCharCode(rune);
    final lower = original.toLowerCase();
    folded.write(lower);
    for (var i = 0; i < lower.length; i++) {
      starts.add(offset);
      ends.add(offset + original.length);
    }
    offset += original.length;
  }
  final haystack = folded.toString();
  final ranges = <SearchRange>[];
  var from = 0;
  while (true) {
    final at = haystack.indexOf(needle, from);
    if (at < 0) break;
    final last = at + needle.length - 1;
    final start = starts[at];
    final end = ends[last];
    // Two folded matches inside one expanded code point collapse into one.
    if (ranges.isEmpty || start >= ranges.last.end) {
      ranges.add(SearchRange(start, end));
    }
    from = at + needle.length;
  }
  return ranges;
}

/// A visible window of [text] around its first match for a one-line result:
/// at most [maxLength] code units, with an ellipsis where it was cut, and the
/// [ranges] moved into the window.
class SearchSnippet {
  const SearchSnippet(this.text, this.ranges);

  final String text;
  final List<SearchRange> ranges;
}

/// Cuts [text] to a window that keeps the first of [ranges] in view.
SearchSnippet snippetAround(
  String text,
  List<SearchRange> ranges, {
  int maxLength = 140,
  int lead = 40,
}) {
  if (text.length <= maxLength || ranges.isEmpty) {
    return SearchSnippet(text, ranges);
  }
  var start = ranges.first.start > lead ? ranges.first.start - lead : 0;
  var end = start + maxLength;
  if (end > text.length) {
    end = text.length;
    start = end - maxLength;
  }
  // Never split a surrogate pair.
  if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start--;
  if (end < text.length && _isLowSurrogate(text.codeUnitAt(end))) end++;
  final prefix = start > 0 ? '\u2026' : '';
  final suffix = end < text.length ? '\u2026' : '';
  final shift = prefix.length - start;
  return SearchSnippet('$prefix${text.substring(start, end)}$suffix', [
    for (final r in ranges)
      if (r.start >= start && r.end <= end)
        SearchRange(r.start + shift, r.end + shift),
  ]);
}

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Whether messages of [conversation] may ever be searched. Not when either
/// side blocks the other or the peer's account is gone (`can_reply` false:
/// the conservative reading of "blocked either way").
bool isSearchableConversation(pb.Conversation conversation) =>
    conversation.id.isNotEmpty && conversation.canReply;

/// Whether [message] may be searched: only a VISIBLE one with text. A deleted
/// account's or a moderator-removed message (empty text), and an unspecified
/// state, never match. (The protocol has no "unsend" or per-message hide.)
bool isSearchableMessage(pb.Message message) =>
    message.state == MessageState.MESSAGE_STATE_VISIBLE &&
    message.text.isNotEmpty;

/// One matching message and where the term sits in its text.
class MessageSearchHit {
  const MessageSearchHit({
    required this.conversation,
    required this.message,
    required this.ranges,
  });

  final pb.Conversation conversation;
  final pb.Message message;
  final List<SearchRange> ranges;
}

/// The hits of one conversation, newest first.
class ConversationHits {
  const ConversationHits({required this.conversation, required this.hits});

  final pb.Conversation conversation;
  final List<MessageSearchHit> hits;
}

/// Matches [query] over [messagesByConversation], only for the
/// [conversations] given (a message whose conversation header is not cached is
/// never matched: its block state cannot be checked). Groups come newest
/// activity first (by their newest hit), hits newest first.
List<ConversationHits> searchMessages({
  required Iterable<pb.Conversation> conversations,
  required Map<String, List<pb.Message>> messagesByConversation,
  required String query,
}) {
  if (query.trim().isEmpty) return const [];
  final groups = <ConversationHits>[];
  for (final conversation in conversations) {
    if (!isSearchableConversation(conversation)) continue;
    final messages = messagesByConversation[conversation.id];
    if (messages == null) continue;
    final hits = <MessageSearchHit>[];
    final seen = <String>{};
    for (final message in messages) {
      if (!isSearchableMessage(message) || !seen.add(message.id)) continue;
      final ranges = matchRanges(message.text, query);
      if (ranges.isEmpty) continue;
      hits.add(
        MessageSearchHit(
          conversation: conversation,
          message: message,
          ranges: ranges,
        ),
      );
    }
    if (hits.isEmpty) continue;
    hits.sort(_newestFirst);
    groups.add(ConversationHits(conversation: conversation, hits: hits));
  }
  groups.sort((a, b) => _newestFirst(a.hits.first, b.hits.first));
  return groups;
}

int _micros(pb.Message m) =>
    m.hasCreatedAt() ? m.createdAt.toDateTime().microsecondsSinceEpoch : 0;

int _newestFirst(MessageSearchHit a, MessageSearchHit b) {
  final byTime = _micros(b.message).compareTo(_micros(a.message));
  return byTime != 0 ? byTime : b.message.id.compareTo(a.message.id);
}
