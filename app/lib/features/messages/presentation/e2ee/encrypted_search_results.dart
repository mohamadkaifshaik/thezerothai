import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/message_search.dart';

// Decrypted search hits (R14, security read M7). Plain classes: no freezed, no
// toString, no copyWith. They live in memory only, outside MessageSearchState
// (whose generated toString prints its fields), and never reach the
// repository, the store, a route or a log.

/// One conversation's encrypted hits, newest first.
final class EncryptedHitGroup {
  const EncryptedHitGroup({
    required this.conversation,
    required this.hits,
    required this.ranges,
  });

  final pb.Conversation conversation;
  final List<EncryptedSearchHit> hits;

  /// Where the query sits in each hit's text; one list per hit, in order.
  final List<List<SearchRange>> ranges;
}

/// The encrypted answer to one query. [query] is the text the answer is for.
final class EncryptedHitGroups {
  const EncryptedHitGroups({this.groups = const [], this.query = ''});

  /// The shared empty answer.
  static const EncryptedHitGroups empty = EncryptedHitGroups();

  final List<EncryptedHitGroup> groups;
  final String query;

  bool get isEmpty => groups.isEmpty;
}

/// Groups [encrypted] by conversation (found in [conversations]; a hit whose
/// conversation header is not cached, or is not searchable, is dropped), hits
/// newest first, groups by their newest hit, with [matchRanges] per hit.
/// Builds NO pb.Message from decrypted text.
EncryptedHitGroups groupEncryptedHits(
  Iterable<pb.Conversation> conversations,
  List<EncryptedSearchHit> encrypted,
  String query,
) {
  if (query.trim().isEmpty) return EncryptedHitGroups(query: query);
  final headers = {
    for (final c in conversations)
      if (isSearchableConversation(c)) c.id: c,
  };
  final byConversation = <String, List<EncryptedSearchHit>>{};
  final seen = <String>{};
  for (final hit in encrypted) {
    if (!headers.containsKey(hit.conversationId)) continue;
    if (!seen.add('${hit.conversationId}/${hit.messageId}')) continue;
    byConversation.putIfAbsent(hit.conversationId, () => []).add(hit);
  }
  final groups = <EncryptedHitGroup>[];
  for (final entry in byConversation.entries) {
    final hits = [...entry.value]..sort(_newestFirst);
    groups.add(
      EncryptedHitGroup(
        conversation: headers[entry.key]!,
        hits: hits,
        ranges: [for (final h in hits) matchRanges(h.text, query)],
      ),
    );
  }
  groups.sort((a, b) => _newestFirst(a.hits.first, b.hits.first));
  return EncryptedHitGroups(groups: groups, query: query);
}

int _newestFirst(EncryptedSearchHit a, EncryptedSearchHit b) {
  final byTime = b.at.compareTo(a.at);
  return byTime != 0 ? byTime : b.messageId.compareTo(a.messageId);
}
