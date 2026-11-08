import 'package:flutter/foundation.dart';

import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;

/// How many unsent texts per conversation keep their idempotency key.
const _maxRememberedKeys = 8;

enum OutgoingStatus {
  /// The send is in flight: the dimmed "Sending…" bubble.
  sending,

  /// The send failed: the "Not sent. Tap to retry" bubble.
  failed,

  /// The server answered; [OutgoingMessage.sent] holds its message. The row
  /// stays until the thread has it too, so the bubble never blinks out.
  sent,
}

/// One message the caller sent from a thread screen and the server has not
/// confirmed in the thread yet.
@immutable
class OutgoingMessage {
  const OutgoingMessage({
    required this.localId,
    required this.text,
    required this.status,
    this.error,
    this.sent,
  });

  /// The idempotency key of this intent: also the row's stable key.
  final String localId;
  final String text;
  final OutgoingStatus status;
  final AppException? error;

  /// The server's message once [status] is [OutgoingStatus.sent].
  final pb.Message? sent;

  OutgoingMessage copyWith({
    OutgoingStatus? status,
    AppException? error,
    pb.Message? sent,
    bool clearError = false,
  }) => OutgoingMessage(
    localId: localId,
    text: text,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    sent: sent ?? this.sent,
  );
}

class _Box {
  String draft = '';

  // Insertion-ordered (least recently used first) and bounded.
  final Map<String, String> keys = {};
  List<OutgoingMessage> rows = const [];

  bool get isEmpty => draft.isEmpty && keys.isEmpty && rows.isEmpty;
}

/// Session-scoped, in-memory store of what a thread composer holds: the draft
/// text, the unsent or failed outgoing rows and the idempotency key of every
/// unsent text, per conversation (a draft thread uses [draftScope]).
///
/// It outlives the per-route composer cubit, so leaving a thread and coming
/// back keeps the draft and the "Not sent" rows, and a resend from the new
/// screen carries the same key (a commit whose response was lost can never
/// become a second message). It lives on the `MessagingRepository` and is
/// emptied by `clearSession()` (sign-out and account switch). Never persisted
/// and never logged.
class MessageOutbox {
  final Map<String, _Box> _boxes = {};

  /// The scope of a thread that does not exist yet (first message to a person).
  static String draftScope(String recipientUserId) => 'draft:$recipientUserId';

  _Box _box(String scope) => _boxes.putIfAbsent(scope, _Box.new);

  void _prune(String scope) {
    if (_boxes[scope]?.isEmpty ?? false) _boxes.remove(scope);
  }

  String draftOf(String scope) => _boxes[scope]?.draft ?? '';

  /// Rows worth keeping, oldest first. A send that was in flight when its
  /// screen went away has an unknown outcome: it comes back as "Not sent",
  /// and tapping it resends with the same key.
  List<OutgoingMessage> rowsOf(String scope) => [
    for (final m in _boxes[scope]?.rows ?? const <OutgoingMessage>[])
      m.status == OutgoingStatus.sending
          ? m.copyWith(status: OutgoingStatus.failed)
          : m,
  ];

  /// Replaces the draft and the rows of [scope] (rows already confirmed by the
  /// server are not kept).
  void save(
    String scope, {
    required String draft,
    required List<OutgoingMessage> rows,
  }) {
    final box = _box(scope)
      ..draft = draft
      ..rows = [
        for (final m in rows)
          if (m.status != OutgoingStatus.sent) m,
      ];
    if (box.isEmpty) _prune(scope);
  }

  String? peekKey(String scope, String text) => _boxes[scope]?.keys[text];

  /// The key for [text]: the stored one, or a new one from [create].
  String keyFor(
    String scope,
    String text, {
    required String Function() create,
  }) {
    final box = _box(scope);
    final key = box.keys.remove(text) ?? create();
    box.keys[text] = key;
    while (box.keys.length > _maxRememberedKeys) {
      box.keys.remove(box.keys.keys.first);
    }
    return key;
  }

  void forgetKey(String scope, String text) {
    _boxes[scope]?.keys.remove(text);
    _prune(scope);
  }

  void removeRow(String scope, String localId) {
    final box = _boxes[scope];
    if (box == null) return;
    box.rows = [
      for (final m in box.rows)
        if (m.localId != localId) m,
    ];
    _prune(scope);
  }

  void markFailed(String scope, String localId, AppException error) {
    final box = _boxes[scope];
    if (box == null) return;
    box.rows = [
      for (final m in box.rows)
        if (m.localId == localId)
          m.copyWith(status: OutgoingStatus.failed, error: error)
        else
          m,
    ];
  }

  /// Forgets [scope] (the draft thread turned into a real conversation).
  void drop(String scope) => _boxes.remove(scope);

  /// Sign-out and account switch: nothing of the previous user stays.
  void clear() => _boxes.clear();

  @visibleForTesting
  bool get isEmpty => _boxes.isEmpty;
}
