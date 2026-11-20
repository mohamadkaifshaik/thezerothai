import '../../../../core/vault/keyed_mutex.dart';

/// One lock per conversation id for the whole encrypted pipeline.
///
/// Order: the conversation lock first, then `session.runWrite` inside it,
/// never the reverse; never two conversation locks at once (a pass over many
/// conversations takes them one at a time). NOT re-entrant: code that already
/// holds a conversation's lock calls only the `...Locked` variants for it.
/// RPCs run under the lock and outside `runWrite`.
class ConversationLocks {
  final KeyedMutex _mutex = KeyedMutex();

  /// Runs [body] once every earlier call for [conversationId] has finished.
  Future<T> run<T>(String conversationId, Future<T> Function() body) =>
      _mutex.run(conversationId, body);
}
