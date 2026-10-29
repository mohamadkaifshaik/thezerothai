/// The shape of a conversation id: exactly 32 lower-case hex digits (ADR-0027).
/// The one definition: the thread screen, the push routing and the deep-link
/// allowlist (`AppRouter.deepLinkTarget`) all build on it.
const String kConversationIdPattern = '[0-9a-f]{32}';

final RegExp _conversationId = RegExp('^$kConversationIdPattern\$');

/// True for a conversation id the API accepts. Anything else is "This
/// conversation isn't available" with no request.
bool isConversationId(String id) => _conversationId.hasMatch(id);
