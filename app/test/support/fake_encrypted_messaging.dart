import 'dart:async';

import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:flutter/foundation.dart';

/// Scripted, in memory; records every call. It asserts what the real pipeline
/// promises: `text` is '' unless visible and ok; `digits` is null or 60 digits.
class FakeEncryptedMessaging implements EncryptedMessaging {
  /// Method names in call order, no arguments.
  final List<String> calls = [];

  final Map<ThreadRef, EncryptedThread> _threads = {};
  final Map<ThreadRef, StreamController<EncryptedThread>> _controllers = {};
  final Map<String, SecurityCode> _codes = {};
  Map<String, ConversationPreview> _previews = {};
  List<EncryptedSearchHit> _hits = [];
  final Map<String, Uint8List?> _payloads = {};
  OwnDeviceList _own = const OwnDeviceList();
  final StreamController<String> _previewChanged =
      StreamController<String>.broadcast();

  SendOutcome nextSendOutcome = const SendOutcome(SendOutcomeKind.queued);

  /// When set, `send` records the call, then awaits it before answering.
  Completer<void>? holdSend;

  /// Thrown by the next Future-returning call, then cleared.
  Object? failNext;

  @override
  final ValueNotifier<bool> removedElsewhere = ValueNotifier(false);
  @override
  final ValueNotifier<int> removalsPending = ValueNotifier(0);

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

  void _throwIfFailing() {
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
        final plain =
            e.state == EncryptedMessageState.visible &&
            e.check == MessageCheck.ok;
        assert(
          plain || (e.text.isEmpty && e.sharedPostId.isEmpty),
          'text only for a visible, ok message',
        );
      }
    }
  }

  void setThread(ThreadRef ref, EncryptedThread thread) {
    _check(thread);
    _threads[ref] = thread;
    _controllers[ref]?.add(thread);
  }

  void setSecurityCode(String conversationId, SecurityCode code) {
    final d = code.digits;
    assert(
      d == null || RegExp(r'^[0-9]{60}$').hasMatch(d),
      'digits are null or 60 digits',
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
    return local.contains(conversationId);
  }

  @override
  Stream<EncryptedThread> watchThread(ThreadRef ref) {
    calls.add('watchThread');
    late StreamController<EncryptedThread> c;
    c = StreamController<EncryptedThread>(
      onListen: () => c.add(_threads[ref] ?? _empty(ref)),
    );
    _controllers[ref] = c;
    return c.stream;
  }

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
    sent.add((
      to: to,
      localId: localId,
      text: text,
      sharedPostId: sharedPostId,
    ));
    final hold = holdSend;
    if (hold != null) await hold.future;
    _throwIfFailing();
    return nextSendOutcome;
  }

  @override
  Future<void> retrySend(String localId) async {
    calls.add('retrySend');
    retried.add(localId);
    _throwIfFailing();
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
    _throwIfFailing();
    return _own;
  }

  @override
  Future<void> removeDevice(String ref) async {
    calls.add('removeDevice');
    removedDevices.add(ref);
    _throwIfFailing();
  }
}
