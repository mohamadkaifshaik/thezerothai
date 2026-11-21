import 'dart:async';

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
  final Object _zoneKey = Object();

  /// Runs [body] once every earlier call for [conversationId] has finished.
  Future<T> run<T>(String conversationId, Future<T> Function() body) =>
      _mutex.run(conversationId, () {
        final held = <String, Object>{
          ...(Zone.current[_zoneKey] as Map<String, Object>? ??
              const <String, Object>{}),
          conversationId: Object(),
        };
        return runZoned(body, zoneValues: {_zoneKey: held});
      });

  /// A value unique to the current [run] body for [conversationId] (one per
  /// hold, followed along the body's async chain); null outside one. Lets
  /// work under a held lock count per hold (the receiver's sink pages).
  Object? holdToken(String conversationId) =>
      (Zone.current[_zoneKey] as Map<String, Object>?)?[conversationId];

  /// True when the calling code runs inside a [run] body for
  /// [conversationId] (followed along the body's async chain). For asserts of
  /// the `...Locked` entry points; work that outlives the body (a timer, a
  /// listener) still reads as holding it.
  bool isHeld(String conversationId) => holdToken(conversationId) != null;
}
