import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../posts/domain/post_text_rules.dart';
import '../../data/messaging_repository.dart';

/// How many unsent texts keep their idempotency key (a handful of edits).
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

/// One message the caller sent from this screen and the server has not
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

@immutable
class MessageComposerState {
  const MessageComposerState({
    required this.draft,
    this.outgoing = const [],
    this.error,
    this.degraded = false,
  });

  /// The D9 reading of what is typed (the same rules as posts, ADR-0027 F8).
  final PostDraft draft;

  /// Messages sent from this screen, oldest first.
  final List<OutgoingMessage> outgoing;

  /// The last failed send's error, shown once above the field and cleared by
  /// the next edit or send.
  final AppException? error;

  /// The last send was refused by the degraded (read-only) mode: the banner
  /// shows and Send stays off until the user taps a "Not sent" bubble.
  final bool degraded;

  bool get isSending => outgoing.any((m) => m.status == OutgoingStatus.sending);

  /// One send at a time keeps the order; the field itself stays editable.
  bool get canSend => draft.canPost && !isSending && !degraded;

  MessageComposerState copyWith({
    PostDraft? draft,
    List<OutgoingMessage>? outgoing,
    AppException? error,
    bool? degraded,
    bool clearError = false,
  }) => MessageComposerState(
    draft: draft ?? this.draft,
    outgoing: outgoing ?? this.outgoing,
    error: clearError ? null : (error ?? this.error),
    degraded: degraded ?? this.degraded,
  );
}

/// Drives the conversation composer (W7-16, ADR-0027 D3, D4): the live D9
/// reading of the draft ([analyzePostDraft], no second validator), the
/// optimistic bubble, and one idempotency key per intent.
///
/// Mirrors the intent rules of `ComposerCubit`: the key is generated at the
/// first send of a text and reused by every retry of it (a dropped response
/// can never create a second message, the server answers the stored one), also
/// after an edit-and-revert; a different text gets its own key (the server
/// would answer IDEMPOTENCY_KEY_REUSED for a different body) and a text's key
/// is dropped once its message succeeded. Least recently used, bounded.
///
/// - A failed send stays as a "Not sent" row and the text is not put back in
///   the field; [retry] resends it with the same key. Nothing retries by
///   itself.
/// - CANNOT_MESSAGE is not retryable: the row is dropped and [onCannotMessage]
///   turns the thread read-only.
/// - [DegradedModeException] sets [MessageComposerState.degraded]: Send is off
///   until the user taps a "Not sent" row ([retry]).
/// - [onActivity] (typing, sending) keeps the thread's poller hot; [onSent]
///   lets the thread read the cache back before the row is dropped.
///
/// The text of a message is never logged or reported.
class MessageComposerCubit extends Cubit<MessageComposerState> {
  MessageComposerCubit({
    required MessagingRepository repository,
    required this.conversationId,
    this.onActivity,
    this.onSent,
    this.onCannotMessage,
    this.onUnexpectedError,
    Uuid? uuid,
  }) : _repository = repository,
       _uuid = uuid ?? const Uuid(),
       super(MessageComposerState(draft: analyzePostDraft('')));

  final MessagingRepository _repository;
  final String conversationId;
  final VoidCallback? onActivity;
  final Future<void> Function()? onSent;
  final VoidCallback? onCannotMessage;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;
  final Uuid _uuid;

  /// Idempotency key per sent text, insertion-ordered and bounded.
  final Map<String, String> _keys = {};

  /// The key the next send of [text] would use, for tests and diagnostics.
  @visibleForTesting
  String? keyFor(String text) => _keys[text];

  /// The user typed: re-read the draft and forget the last error.
  void textChanged(String raw) {
    emit(state.copyWith(draft: analyzePostDraft(raw), clearError: true));
    onActivity?.call();
  }

  String _keyFor(String text) {
    final key = _keys.remove(text) ?? _uuid.v4();
    _keys[text] = key;
    while (_keys.length > _maxRememberedKeys) {
      _keys.remove(_keys.keys.first);
    }
    return key;
  }

  /// Sends the draft: the optimistic row and an empty draft appear in the
  /// same turn. No-op unless [MessageComposerState.canSend].
  Future<void> send() async {
    if (!state.canSend) return;
    final text = state.draft.text;
    final key = _keyFor(text);
    emit(
      state.copyWith(
        draft: analyzePostDraft(''),
        outgoing: [
          for (final m in state.outgoing)
            if (m.localId != key) m,
          OutgoingMessage(
            localId: key,
            text: text,
            status: OutgoingStatus.sending,
          ),
        ],
        clearError: true,
      ),
    );
    onActivity?.call();
    await _deliver(key, text);
  }

  /// The "Not sent. Tap to retry" row: resends it with the key it was first
  /// sent with. An explicit tap also lifts the degraded hold.
  Future<void> retry(String localId) async {
    if (state.isSending) return;
    final index = state.outgoing.indexWhere((m) => m.localId == localId);
    if (index < 0 || state.outgoing[index].status != OutgoingStatus.failed) {
      return;
    }
    final entry = state.outgoing[index];
    emit(
      state.copyWith(
        outgoing: _replace(
          localId,
          entry.copyWith(status: OutgoingStatus.sending, clearError: true),
        ),
        degraded: false,
        clearError: true,
      ),
    );
    onActivity?.call();
    await _deliver(entry.localId, entry.text);
  }

  List<OutgoingMessage> _replace(String localId, OutgoingMessage? next) => [
    for (final m in state.outgoing)
      if (m.localId != localId) m else ?next,
  ];

  Future<void> _deliver(String key, String text) async {
    final pb.SendMessageResponse response;
    try {
      response = await _repository.sendMessage(
        idempotencyKey: key,
        text: text,
        conversationId: conversationId,
      );
    } on AppException catch (error, stack) {
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      _fail(key, text, error);
      return;
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
      _fail(key, text, const UnknownApiException('Something went wrong.'));
      return;
    }
    _keys.remove(text);
    if (isClosed) return;
    emit(
      state.copyWith(
        outgoing: _replace(
          key,
          state.outgoing
              .firstWhere((m) => m.localId == key)
              .copyWith(status: OutgoingStatus.sent, sent: response.message),
        ),
      ),
    );
    try {
      await onSent?.call();
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    }
    if (isClosed) return;
    emit(state.copyWith(outgoing: _replace(key, null)));
  }

  void _fail(String key, String text, AppException error) {
    if (isClosed) return;
    if (error is CannotMessageException) {
      // Nothing to retry: the row goes and the thread turns read-only.
      _keys.remove(text);
      emit(state.copyWith(outgoing: _replace(key, null), clearError: true));
      onCannotMessage?.call();
      return;
    }
    emit(
      state.copyWith(
        outgoing: _replace(
          key,
          state.outgoing
              .firstWhere((m) => m.localId == key)
              .copyWith(status: OutgoingStatus.failed, error: error),
        ),
        error: error,
        degraded: error is DegradedModeException,
      ),
    );
  }
}
