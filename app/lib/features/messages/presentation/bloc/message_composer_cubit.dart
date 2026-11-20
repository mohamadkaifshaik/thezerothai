import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../posts/domain/post_text_rules.dart';
import '../../data/message_outbox.dart';
import '../../data/messaging_repository.dart';
import '../../domain/e2ee/encrypted_messaging.dart';

export '../../data/message_outbox.dart' show OutgoingMessage, OutgoingStatus;

@immutable
class MessageComposerState {
  const MessageComposerState({
    required this.draft,
    this.outgoing = const [],
    this.error,
    this.degraded = false,
    this.cannotMessage = false,
    this.refusedProblem = SendProblem.none,
    this.sendPending = false,
  });

  /// The D9 reading of what is typed (the same rules as posts).
  final PostDraft draft;

  /// Messages sent from this screen, oldest first.
  final List<OutgoingMessage> outgoing;

  /// The last failed send's error, shown once above the field and cleared by
  /// the next edit or send.
  final AppException? error;

  /// The last send was refused by the degraded (read-only) mode: the banner
  /// shows and Send stays off until the user taps a "Not sent" bubble.
  final bool degraded;

  /// A send was refused with CANNOT_MESSAGE (also reported through
  /// [MessageComposerCubit.onCannotMessage]); a draft thread turns
  /// read-only on it.
  final bool cannotMessage;

  /// The send of an encrypted port is a refusal the port gave before saving
  /// the text (nothing was sent): the text stays in the field and the reason
  /// shows above it. Cleared like [error].
  final SendProblem refusedProblem;

  /// A send through the encrypted port is awaiting its answer (a device lookup
  /// and, when encryption starts, a claim). It is the composer's normal sending
  /// state, with no row: the text stays in the field until the answer.
  final bool sendPending;

  bool get isSending =>
      sendPending || outgoing.any((m) => m.status == OutgoingStatus.sending);

  /// One send at a time keeps the order; the field itself stays editable.
  bool get canSend => draft.canPost && !isSending && !degraded;

  MessageComposerState copyWith({
    PostDraft? draft,
    List<OutgoingMessage>? outgoing,
    AppException? error,
    bool? degraded,
    bool? cannotMessage,
    SendProblem? refusedProblem,
    bool? sendPending,
    bool clearError = false,
  }) => MessageComposerState(
    draft: draft ?? this.draft,
    outgoing: outgoing ?? this.outgoing,
    error: clearError ? null : (error ?? this.error),
    degraded: degraded ?? this.degraded,
    cannotMessage: cannotMessage ?? this.cannotMessage,
    refusedProblem: clearError
        ? (refusedProblem ?? SendProblem.none)
        : (refusedProblem ?? this.refusedProblem),
    sendPending: sendPending ?? this.sendPending,
  );
}

/// Drives the conversation composer: the live D9
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
/// Draft mode: with [recipientUserId] and no [conversationId] the
/// first send names the recipient (`recipient_user_id`); the server opens (or
/// continues) the 1:1 conversation and the cubit then sends to the id it
/// returned and calls [onConversationCreated] once, so the screen can switch
/// to `/messages/<id>`. A retry before that reuses the same key and the same
/// recipient.
///
/// The text of a message is never logged or reported.
class MessageComposerCubit extends Cubit<MessageComposerState> {
  MessageComposerCubit({
    required MessagingRepository repository,
    String? conversationId,
    this.recipientUserId,
    this.recipient,
    EncryptedMessaging? encrypted,
    this.onConversationCreated,
    this.onActivity,
    this.onSent,
    this.onCannotMessage,
    this.onUnexpectedError,
    required MessageOutbox outbox,
    Uuid? uuid,
  }) : assert(
         (conversationId == null) != (recipientUserId == null),
         'Exactly one of conversationId and recipientUserId',
       ),
       assert(
         recipient == null || recipient.userId == recipientUserId,
         'recipient is the snapshot of recipientUserId',
       ),
       _repository = repository,
       _encrypted = encrypted,
       _conversationId = conversationId,
       _uuid = uuid ?? const Uuid(),
       _outbox = outbox.lease(),
       super(
         _restore(
           outbox.lease(),
           conversationId ?? MessageOutbox.draftScope(recipientUserId!),
         ),
       );

  static MessageComposerState _restore(OutboxLease outbox, String scope) {
    return MessageComposerState(
      draft: analyzePostDraft(outbox.draftOf(scope)),
      outgoing: outbox.rowsOf(scope),
    );
  }

  final OutboxLease _outbox;

  String get _scope =>
      _conversationId ?? MessageOutbox.draftScope(recipientUserId!);

  @override
  void onChange(Change<MessageComposerState> change) {
    super.onChange(change);
    // Write-through: what the screen shows is what survives the screen.
    _outbox.save(
      _scope,
      draft: change.nextState.draft.text,
      rows: change.nextState.outgoing,
    );
  }

  final MessagingRepository _repository;

  /// The conversation sent to; null in draft mode until the first send
  /// created it.
  String? _conversationId;

  /// The conversation sent to, null while this is still a draft.
  String? get conversationId => _conversationId;

  /// The person a draft thread writes to (draft mode only).
  final String? recipientUserId;

  /// Draft mode: the person's snapshot (second re-read R1). With a port the
  /// person is addressed only as `ThreadRef.recipientOf(recipient)`; a draft
  /// composer with a port and no snapshot sends nothing.
  final common.AuthorSnapshot? recipient;

  /// The encrypted messaging port, or null: then every path is today's.
  final EncryptedMessaging? _encrypted;

  /// Whether sends go through the encrypted port (the field then keeps the
  /// text until the port answers).
  bool get hasPort => _encrypted != null;

  /// Draft mode: called once with the id of the conversation the first send
  /// created.
  final void Function(String conversationId)? onConversationCreated;
  final VoidCallback? onActivity;
  final Future<void> Function()? onSent;
  final VoidCallback? onCannotMessage;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;
  final Uuid _uuid;

  /// The key the next send of [text] would use, for tests and diagnostics.
  @visibleForTesting
  String? keyFor(String text) => _outbox.peekKey(_scope, text);

  /// The user typed: re-read the draft and forget the last error.
  void textChanged(String raw) {
    emit(state.copyWith(draft: analyzePostDraft(raw), clearError: true));
    onActivity?.call();
  }

  String _keyFor(String text) => _outbox.keyFor(_scope, text, create: _uuid.v4);

  /// Sends the draft: the optimistic row and an empty draft appear in the
  /// same turn. No-op unless [MessageComposerState.canSend].
  Future<void> send() async {
    if (!state.canSend) return;
    final text = state.draft.text;
    final key = _keyFor(text);
    final port = _encrypted;
    if (port != null) {
      await _sendThroughPort(port, key, text);
      return;
    }
    await _sendPlain(key, text);
  }

  /// Today's send: the optimistic row and an empty draft in the same turn,
  /// then `SendMessage` with [key].
  Future<void> _sendPlain(String key, String text) async {
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

  /// With a port: the row id is the key of today's send; the port saves the
  /// text on this device and sends when it may. While it answers the composer
  /// is in its sending state and the text stays in the field. The text is
  /// never reported.
  Future<void> _sendThroughPort(
    EncryptedMessaging port,
    String key,
    String text,
  ) async {
    final id = _conversationId;
    final person = recipient;
    final ThreadRef? to = id != null
        ? ThreadRef.conversation(id)
        : (person == null ? null : ThreadRef.recipientOf(person));
    if (to == null) {
      // A draft with a port and no snapshot of the person: a programming
      // error. Nothing goes out, least of all in plaintext.
      emit(
        state.copyWith(refusedProblem: SendProblem.blocked, clearError: true),
      );
      return;
    }
    emit(state.copyWith(sendPending: true, clearError: true));
    onActivity?.call();
    final SendOutcome outcome;
    try {
      outcome = await port.send(to: to, localId: key, text: text);
    } on Object catch (error, stack) {
      // Never the thrown object: an ArgumentError can carry what was typed.
      onUnexpectedError?.call(StateError('send'), stack);
      if (isClosed) return;
      emit(
        state.copyWith(
          sendPending: false,
          error: error is ArgumentError
              ? const ValidationException('That message cannot be sent.')
              : const UnknownApiException('Something went wrong.'),
        ),
      );
      return;
    }
    if (isClosed) {
      // The screen is gone. Only a saved text must not come back as a draft.
      if (outcome.kind == SendOutcomeKind.queued) {
        _outbox
          ..forgetKey(_scope, text)
          ..save(_scope, draft: '', rows: state.outgoing);
      }
      return;
    }
    switch (outcome.kind) {
      case SendOutcomeKind.queued:
        _outbox.forgetKey(_scope, text);
        emit(
          state.copyWith(
            sendPending: false,
            draft: state.draft.text == text ? analyzePostDraft('') : null,
          ),
        );
        onActivity?.call();
        final created = outcome.conversationId;
        if (created != null) conversationKnown(created);
      case SendOutcomeKind.notEncrypted:
        emit(state.copyWith(sendPending: false));
        await _sendPlain(key, text);
      case SendOutcomeKind.refused:
        final error = outcome.error;
        emit(
          state.copyWith(
            sendPending: false,
            refusedProblem: outcome.problem,
            error: error,
            degraded: error is DegradedModeException,
            cannotMessage: error is CannotMessageException ? true : null,
          ),
        );
        if (error is CannotMessageException) onCannotMessage?.call();
    }
  }

  /// Draft mode: the conversation of the first send is known (from the
  /// port's answer or from its thread). Once only; later calls do nothing.
  void conversationKnown(String conversationId) {
    final recipient = recipientUserId;
    if (isClosed ||
        _conversationId != null ||
        recipient == null ||
        conversationId.isEmpty) {
      return;
    }
    _outbox.drop(MessageOutbox.draftScope(recipient));
    _conversationId = conversationId;
    onConversationCreated?.call(conversationId);
  }

  /// The "Not sent. Tap to retry" row: resends it with the key it was first
  /// sent with. An explicit tap also lifts the degraded hold.
  Future<void> retry(String localId) async {
    final port = _encrypted;
    if (port != null && !state.outgoing.any((m) => m.localId == localId)) {
      // A row of the port's thread (the port owns its retry).
      try {
        await port.retrySend(localId);
      } on Object catch (_, stack) {
        onUnexpectedError?.call(StateError('retrySend'), stack);
      }
      return;
    }
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
      final id = _conversationId;
      response = await _repository.sendMessage(
        idempotencyKey: key,
        text: text,
        conversationId: id,
        recipientUserId: id == null ? recipientUserId : null,
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
    _outbox.forgetKey(_scope, text);
    if (isClosed) {
      // The screen is gone but the server has the message: drop its row.
      _outbox.removeRow(_scope, key);
      return;
    }
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
    if (_conversationId == null) {
      // Draft mode: the server named the conversation. Later sends use it.
      final created =
          response.hasConversation() && response.conversation.id.isNotEmpty
          ? response.conversation.id
          : response.message.conversationId;
      if (created.isNotEmpty) {
        _outbox.drop(MessageOutbox.draftScope(recipientUserId!));
        _conversationId = created;
        onConversationCreated?.call(created);
        if (isClosed) return;
      }
    }
    try {
      await onSent?.call();
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    }
    if (isClosed) return;
    emit(state.copyWith(outgoing: _replace(key, null)));
  }

  void _fail(String key, String text, AppException error) {
    if (isClosed) {
      // The screen is gone: a failed row waits in the outbox for a retry.
      if (error is CannotMessageException) {
        _outbox
          ..forgetKey(_scope, text)
          ..removeRow(_scope, key);
      } else {
        _outbox.markFailed(_scope, key, error);
      }
      return;
    }
    if (error is CannotMessageException) {
      // Nothing to retry: the row goes and the thread turns read-only.
      _outbox.forgetKey(_scope, text);
      emit(
        state.copyWith(
          outgoing: _replace(key, null),
          cannotMessage: true,
          clearError: true,
        ),
      );
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
