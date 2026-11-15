import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show ReplyPolicy;
import 'composer_draft.dart';
import 'poll_rules.dart';

/// What makes two post requests the same for the server: text, media ids, alt
/// texts and the audience. Idempotency keys are remembered per such body.
String postBodyKey(
  String text,
  List<String> mediaIds,
  List<String> altTexts,
  ReplyPolicy policy, [
  DraftPoll? poll,
]) {
  var body = mediaIds.isEmpty
      ? text
      : '$text\u0001${mediaIds.join(',')}\u0001${altTexts.join('\u0002')}';
  // The poll is part of the request. Keyed on the NORMALISED labels and the
  // length, like the server's hash: an edit that changes only spacing is the
  // same request and reuses its key; any real change gets its own.
  if (poll != null) {
    body =
        '$body\u0001poll=${analyzePoll(poll).stored.join('\u001f')}'
        '\u0001dur=${poll.durationMinutes}';
  }
  // A different audience is a different request body for the server.
  return policy == ReplyPolicy.REPLY_POLICY_UNSPECIFIED
      ? body
      : 'p:${policy.value}\u0001$body';
}

/// The full intent of a CreatePost: [postBodyKey] plus the community, the
/// quoted post and the plan, each of which is its own request for the server
/// (the same body with another community is IDEMPOTENCY_KEY_REUSED).
String postIntentKey({
  required String text,
  required List<String> mediaIds,
  required List<String> altTexts,
  required ReplyPolicy policy,
  DraftPoll? poll,
  String communityId = '',
  String quoteOfPostId = '',
  String beaconId = '',
}) {
  final body = postBodyKey(text, mediaIds, altTexts, policy, poll);
  final withCommunity = communityId.isEmpty
      ? body
      : 'c:$communityId\u0001$body';
  final withQuote = quoteOfPostId.isEmpty
      ? withCommunity
      : 'q:$quoteOfPostId\u0001$withCommunity';
  return beaconId.isEmpty ? withQuote : 'b:$beaconId\u0001$withQuote';
}
