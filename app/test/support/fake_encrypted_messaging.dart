import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart'
    show ReauthRequiredException;
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:flutter/foundation.dart';

/// Scripted, in memory; records every call. It asserts what the real pipeline
/// promises: `text` is '' unless visible and ok; `digits` is null or 60 digits.
///
/// Scripting seam for screen tests (do not edit this class per screen):
/// - [queueSendOutcomes]: outcomes consumed one per `send`, then
///   [nextSendOutcome] again. `fake.queueSendOutcomes([refusedOutcome, queued])`.
/// - [failNextOn]: fails only the named port method's next call, once.
///   `fake.failNextOn('ownDevices', StateError('x'))`. The global [failNext]
///   still fails whichever Future-returning call comes next.
///
/// [sent], [removedDevices], [resetConversations] and [retried] are CALL logs,
/// recorded before a scripted failure throws, not logs of successes.
class FakeEncryptedMessaging implements EncryptedMessaging {
  /// Method names in call order, no arguments.
  final List<String> calls = [];

  /// Every `search` query, in order.
  final List<String> searchQueries = [];

  final Map<String, Object> _failOn = {};
  final List<SendOutcome> _queuedOutcomes = [];

  /// Fails the next call of the port method [method] (as listed in [calls])
  /// with [error], once.
  void failNextOn(String method, Object error) => _failOn[method] = error;

  /// Outcomes for the next sends, one each, validated like [nextSendOutcome].
  void queueSendOutcomes(List<SendOutcome> outcomes) {
    outcomes.forEach(_validateOutcome);
    _queuedOutcomes.addAll(outcomes);
  }

  static void _validateOutcome(SendOutcome o) {
    assert(
      o.kind != SendOutcomeKind.refused || o.problem != SendProblem.none,
      'a refused outcome carries a problem',
    );
    assert(
      o.kind != SendOutcomeKind.queued || o.problem == SendProblem.none,
      'a queued outcome carries no problem',
    );
    assert(
      o.kind != SendOutcomeKind.notEncrypted ||
          (o.problem == SendProblem.none && o.error == null),
      'a notEncrypted outcome carries no problem and no error',
    );
    assert(
      o.error == null || o.problem == SendProblem.refused,
      'an error is set only with problem refused',
    );
  }

  final Map<ThreadRef, EncryptedThread> _threads = {};
  final Map<ThreadRef, List<StreamController<EncryptedThread>>> _controllers =
      {};
  final Map<String, SecurityCode> _codes = {};
  Map<String, ConversationPreview> _previews = {};
  List<EncryptedSearchHit> _hits = [];
  final Map<String, Uint8List?> _payloads = {};
  OwnDeviceList _own = const OwnDeviceList();
  final StreamController<String> _previewChanged =
      StreamController<String>.broadcast();

  SendOutcome _nextSendOutcome = const SendOutcome(SendOutcomeKind.queued);

  SendOutcome get nextSendOutcome => _nextSendOutcome;

  /// Port rules: see [_validateOutcome].
  set nextSendOutcome(SendOutcome o) {
    _validateOutcome(o);
    _nextSendOutcome = o;
  }

  /// When set, `send` records the call, then awaits it before answering.
  Completer<void>? holdSend;

  /// Thrown by the next Future-returning call, then cleared.
  Object? failNext;

  @override
  final ValueNotifier<bool> removedElsewhere = ValueNotifier(false);
  @override
  final CountingNotifier removalsPending = CountingNotifier(0);

  /// True while [parkedRemovals] is not empty (set by [park] and
  /// [dropRemoval]).
  @override
  final ValueNotifier<bool> needsReauth = ValueNotifier(false);
  @override
  final ValueNotifier<List<String>> parkedRemovals = ValueNotifier(const []);

  /// Parks [refs] as removals waiting for a re-sign-in (REAUTH_REQUIRED).
  void park(List<String> refs) {
    parkedRemovals.value = List.unmodifiable({
      ...parkedRemovals.value,
      ...refs,
    });
    needsReauth.value = parkedRemovals.value.isNotEmpty;
  }

  /// The answer of every `discardUnsent` (scripted).
  UnsentDiscard nextDiscard = UnsentDiscard.discarded;

  /// The answer of every `removeDevice` that does not fail (scripted).
  DeviceRemoval nextRemoval = const DeviceRemoval();

  final Map<String, Object> _failRemovalOf = {};

  /// Fails the next `removeDevice` of [ref] (and only that ref) with [error],
  /// once.
  void failRemovalOf(String ref, Object error) => _failRemovalOf[ref] = error;

  final List<DeviceRemoval> _queuedRemovals = [];

  /// Answers for the next `removeDevice` calls that do not fail, one each,
  /// then [nextRemoval] again.
  void queueRemovals(List<DeviceRemoval> answers) =>
      _queuedRemovals.addAll(answers);

  /// Call logs (recorded before a scripted failure throws).
  final List<String> discardedUnsent = [];
  final List<(String, String)> deletedUnreadable = [];
  final List<String> droppedRemovals = [];

  /// When set, `deleteUnreadableUnsent` records the call, then awaits it
  /// before answering.
  Completer<void>? holdDeleteUnreadable;

  /// When set, `removeDevice` records the call, then awaits it before
  /// answering.
  Completer<void>? holdRemoveDevice;

  /// When set, `ownDevices` records the call, then awaits it before
  /// answering.
  Completer<void>? holdOwnDevices;

  final List<({ThreadRef to, String localId, String text, String sharedPostId})>
  sent = [];
  final List<String> removedDevices = [];
  final List<String> resetConversations = [];
  final List<String> retried = [];
  int setUpAgainCalls = 0;
  int retryDeviceSetupCalls = 0;
  int checkRemovedAgainCalls = 0;

  /// Conversation ids for [hasLocal].
  Set<String> local = {};

  /// Every port method adds its name to [calls] first, so the method being
  /// served is `calls.last`.
  void _throwIfFailing() {
    final named = _failOn.remove(calls.last);
    if (named != null) throw named;
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  static EncryptedThread _empty(ThreadRef ref) => EncryptedThread(
    conversationId: ref.conversationId,
    security: const ConversationSecurity(
      state: ConversationEncryptionState.ready,
    ),
  );

  static void _check(EncryptedThread thread) {
    for (final e in thread.entries) {
      if (e is DecryptedMessage) {
        final visible = e.state == EncryptedMessageState.visible;
        final plain = visible && e.check == MessageCheck.ok;
        assert(
          plain || (e.text.isEmpty && e.sharedPostId.isEmpty),
          'text only for a visible, ok message',
        );
        assert(
          e.problem == SendProblem.none || e.progress == SendProgress.notSent,
          'problem is set only with progress notSent',
        );
        assert(
          e.error == null || e.problem == SendProblem.refused,
          'error is set only with problem refused',
        );
        assert(
          e.state == EncryptedMessageState.undecryptable ||
              e.mine ||
              e.progress == SendProgress.delivered,
          'a received message is delivered',
        );
        assert(
          !e.canReport || (visible && !e.mine),
          'canReport only for a visible message that is not mine',
        );
        assert(
          !e.waitingToDecrypt ||
              (e.state == EncryptedMessageState.undecryptable && !e.mine),
          'waitingToDecrypt only for an undecryptable row that is not mine',
        );
        assert(
          e.checkDetail == null || e.checkDetail!.check == e.check,
          'checkDetail agrees with check',
        );
      }
    }
  }

  void setThread(ThreadRef ref, EncryptedThread thread) {
    _check(thread);
    _threads[ref] = thread;
    for (final c in List.of(_controllers[ref] ?? const [])) {
      c.add(thread);
    }
  }

  /// False: a new watcher stream emits nothing until [setThread] (the port
  /// emits at once; a screen test of what stays drawn before it does).
  bool emitOnWatch = true;

  /// Ends every open watcher stream of [ref] (done, no error), as the port
  /// does when the vault it reads changes.
  void endWatchers(ThreadRef ref) {
    final list = _controllers[ref] ?? <StreamController<EncryptedThread>>[];
    for (final c in List.of(list)) {
      list.remove(c);
      unawaited(c.close());
    }
  }

  /// Puts [error] on every open watcher stream of [ref] (the port never does
  /// this: a screen test of its `onError`).
  void errorWatchers(ThreadRef ref, Object error) {
    for (final c in List.of(_controllers[ref] ?? const [])) {
      c.addError(error);
    }
  }

  /// How many watcher streams of [ref] are listened to now.
  int watcherCount(ThreadRef ref) => (_controllers[ref] ?? const []).length;

  /// Closes every watcher stream and [previewChanged].
  void dispose() {
    for (final list in _controllers.values) {
      for (final c in List.of(list)) {
        unawaited(c.close());
      }
    }
    _controllers.clear();
    unawaited(_previewChanged.close());
  }

  void setSecurityCode(String conversationId, SecurityCode code) {
    final d = code.digits;
    assert(
      d == null || RegExp(r'^[0-9]{60}$').hasMatch(d),
      'digits are null or 60 digits',
    );
    assert(
      (d == null) != (code.reason == null),
      'exactly one of digits and reason',
    );
    assert(
      code.reason != NoCodeReason.unavailable ||
          (code.myDevices == 0 && code.theirDevices == 0),
      'counts are 0 with unavailable',
    );
    _codes[conversationId] = code;
  }

  /// Also emits [previewChanged].
  void setPreviews(Map<String, ConversationPreview> previews) {
    _previews = Map.of(previews);
    for (final id in previews.keys) {
      _previewChanged.add(id);
    }
  }

  void setSearchHits(List<EncryptedSearchHit> hits) => _hits = List.of(hits);

  void setReportPayload(
    String conversationId,
    String messageId,
    Uint8List? bytes,
  ) => _payloads['$conversationId/$messageId'] = bytes;

  void setOwnDevices(OwnDeviceList list) => _own = list;

  @override
  Future<void> checkRemovedAgain() async {
    calls.add('checkRemovedAgain');
    checkRemovedAgainCalls++;
    _throwIfFailing();
  }

  @override
  Future<void> setUpDeviceAgain() async {
    calls.add('setUpDeviceAgain');
    setUpAgainCalls++;
    if (!removedElsewhere.value) {
      throw StateError('the device is not removed elsewhere');
    }
    _throwIfFailing();
  }

  @override
  Future<void> retryDeviceSetup() async {
    calls.add('retryDeviceSetup');
    retryDeviceSetupCalls++;
    _throwIfFailing();
  }

  @override
  bool hasLocal(String conversationId) {
    calls.add('hasLocal');
    // Only a named failure: the global failNext keeps skipping this check.
    final named = _failOn.remove('hasLocal');
    if (named != null) throw named;
    return local.contains(conversationId);
  }

  @override
  Stream<EncryptedThread> watchThread(ThreadRef ref) {
    calls.add('watchThread');
    late StreamController<EncryptedThread> c;
    final list = _controllers.putIfAbsent(ref, () => []);
    c = StreamController<EncryptedThread>(
      onListen: () {
        if (emitOnWatch) c.add(_threads[ref] ?? _empty(ref));
      },
      onCancel: () => list.remove(c),
    );
    list.add(c);
    return c.stream;
  }

  // Never cleared, also when a scripted thread later shows the row delivered:
  // the fake is slightly stricter than the port there.
  final Set<String> _queuedIds = {};

  /// A row is "already unsent" when a scripted thread holds it undelivered or
  /// an earlier send with that id returned a queued outcome (a refused or
  /// notEncrypted answer saved nothing, so the same id may be sent again).
  bool _isUnsentRow(String localId) =>
      _queuedIds.contains(localId) ||
      _threads.values.any(
        (t) => t.entries.any(
          (e) =>
              e.id == localId &&
              e is DecryptedMessage &&
              e.progress != SendProgress.delivered,
        ),
      );

  @override
  Future<void> loadOlder(ThreadRef ref) async {
    calls.add('loadOlder');
    _throwIfFailing();
  }

  @override
  Future<SendOutcome> send({
    required ThreadRef to,
    required String localId,
    required String text,
    String sharedPostId = '',
  }) async {
    calls.add('send');
    if (_isUnsentRow(localId)) {
      throw ArgumentError.value(localId, 'localId', 'is already an unsent row');
    }
    sent.add((
      to: to,
      localId: localId,
      text: text,
      sharedPostId: sharedPostId,
    ));
    final hold = holdSend;
    if (hold != null) await hold.future;
    _throwIfFailing();
    final outcome = _queuedOutcomes.isEmpty
        ? nextSendOutcome
        : _queuedOutcomes.removeAt(0);
    if (outcome.kind == SendOutcomeKind.queued) _queuedIds.add(localId);
    return outcome;
  }

  @override
  Future<void> retrySend(String localId) async {
    calls.add('retrySend');
    retried.add(localId);
    _throwIfFailing();
  }

  /// Never throws, as the port promises (CR m2): a scripted failure
  /// answers `notDecided`.
  @override
  Future<UnsentDiscard> discardUnsent(String localId) async {
    calls.add('discardUnsent');
    discardedUnsent.add(localId);
    try {
      _throwIfFailing();
    } on Object {
      return UnsentDiscard.notDecided;
    }
    return nextDiscard;
  }

  /// True only for a ref the scripted thread of [conversationId] lists in
  /// `unreadableUnsent`; that thread is then emitted without it. Never
  /// throws, as the port promises (CR m2): a scripted failure answers false.
  @override
  Future<bool> deleteUnreadableUnsent(String conversationId, String ref) async {
    calls.add('deleteUnreadableUnsent');
    deletedUnreadable.add((conversationId, ref));
    final hold = holdDeleteUnreadable;
    if (hold != null) await hold.future;
    try {
      _throwIfFailing();
    } on Object {
      return false;
    }
    final key = ThreadRef.conversation(conversationId);
    final t = _threads[key];
    if (t == null || !t.unreadableUnsent.contains(ref)) return false;
    setThread(
      key,
      EncryptedThread(
        conversationId: t.conversationId,
        entries: t.entries,
        hasMore: t.hasMore,
        security: t.security,
        unreadableUnsent: [
          for (final r in t.unreadableUnsent)
            if (r != ref) r,
        ],
      ),
    );
    return true;
  }

  @override
  Future<void> resetConversation(String conversationId) async {
    calls.add('resetConversation');
    resetConversations.add(conversationId);
    _throwIfFailing();
  }

  @override
  Future<SecurityCode> securityCode(String conversationId) async {
    calls.add('securityCode');
    _throwIfFailing();
    return _codes[conversationId] ??
        const SecurityCode(reason: NoCodeReason.unavailable);
  }

  @override
  Future<Map<String, ConversationPreview>> previews(
    Iterable<String> conversationIds,
  ) async {
    calls.add('previews');
    _throwIfFailing();
    return {
      for (final id in conversationIds)
        if (_previews[id] != null) id: _previews[id]!,
    };
  }

  @override
  Stream<String> get previewChanged => _previewChanged.stream;

  @override
  Future<List<EncryptedSearchHit>> search(
    String query, {
    String? conversationId,
    int limit = 200,
  }) async {
    calls.add('search');
    searchQueries.add(query);
    _throwIfFailing();
    return [
      for (final h in _hits)
        if (conversationId == null || h.conversationId == conversationId) h,
    ].take(limit).toList();
  }

  @override
  Future<Uint8List?> reportPayload(
    String conversationId,
    String messageId,
  ) async {
    calls.add('reportPayload');
    _throwIfFailing();
    return _payloads['$conversationId/$messageId'];
  }

  @override
  Future<OwnDeviceList> ownDevices() async {
    calls.add('ownDevices');
    final hold = holdOwnDevices;
    if (hold != null) await hold.future;
    _throwIfFailing();
    return _own;
  }

  @override
  Future<DeviceRemoval> removeDevice(String ref) async {
    calls.add('removeDevice');
    if (_own.devices.any((d) => d.ref == ref && d.thisDevice)) {
      throw ArgumentError.value(ref, 'ref', 'is this device');
    }
    removedDevices.add(ref);
    final hold = holdRemoveDevice;
    if (hold != null) await hold.future;
    try {
      final forRef = _failRemovalOf.remove(ref);
      if (forRef != null) throw forRef;
      _throwIfFailing();
    } on ReauthRequiredException {
      // As the port (CR m1): REAUTH_REQUIRED parks the removal first.
      park([ref]);
      rethrow;
    }
    // As the port (CR m1): a removal that went through is no longer parked.
    _unpark(ref);
    return _queuedRemovals.isEmpty ? nextRemoval : _queuedRemovals.removeAt(0);
  }

  void _unpark(String ref) {
    if (!parkedRemovals.value.contains(ref)) return;
    parkedRemovals.value = List.unmodifiable([
      for (final r in parkedRemovals.value)
        if (r != ref) r,
    ]);
    needsReauth.value = parkedRemovals.value.isNotEmpty;
  }

  /// StateError for a ref that is not parked (the port's rule).
  @override
  Future<void> dropRemoval(String ref) async {
    calls.add('dropRemoval');
    droppedRemovals.add(ref);
    if (!parkedRemovals.value.contains(ref)) {
      throw StateError('Not a parked removal.');
    }
    _throwIfFailing();
    _unpark(ref);
  }
}

/// A [ValueNotifier] that counts its listeners, so a test can prove a
/// listener was removed.
class CountingNotifier extends ValueNotifier<int> {
  CountingNotifier(super.value);

  int listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    // Only a listener that was added counts down (the base ignores others).
    final before = hasListeners;
    super.removeListener(listener);
    if (before && listenerCount > 0) listenerCount--;
  }
}
