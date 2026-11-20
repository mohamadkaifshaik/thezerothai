import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../data/messaging_repository.dart';
import '../../data/messaging_store.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/message_search.dart';
import '../e2ee/encrypted_search_results.dart';
import 'message_search_state.dart';

/// Searches the messages cached on this device (see
/// `docs/plans/message-search.md`). All conversations, or just
/// [conversationId].
///
/// Nothing here touches the network except [loadOlder] (one conversation, the
/// existing ListMessages path, pages held in memory only). The query and the
/// text are never logged: errors go to [onUnexpectedError] without them.
class MessageSearchCubit extends Cubit<MessageSearchState> {
  MessageSearchCubit({
    required MessagingRepository repository,
    this.conversationId,
    this.debounce = const Duration(milliseconds: 250),
    this.onUnexpectedError,
    EncryptedMessaging? encrypted,
    bool Function()? encryptedAllowed,
  }) : _repository = repository,
       _encrypted = encrypted,
       _encryptedAllowed = encryptedAllowed,
       super(const MessageSearchState()) {
    // An accepted, deleted or blocked conversation changed the cache.
    _changes = _repository.conversationsChanged.listen((_) {
      _corpus = null;
      if (state.hasQuery) unawaited(_run(state.query));
    });
  }

  final MessagingRepository _repository;

  /// Null: every cached conversation. Else only this one.
  final String? conversationId;

  /// Typing pause before a search runs; zero runs at once.
  final Duration debounce;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  final EncryptedMessaging? _encrypted;
  final bool Function()? _encryptedAllowed;
  final ValueNotifier<EncryptedHitGroups> _encryptedResults = ValueNotifier(
    EncryptedHitGroups.empty,
  );

  /// Decrypted hits live OUTSIDE the freezed state (security read M7).
  ValueListenable<EncryptedHitGroups> get encryptedResults => _encryptedResults;

  /// The port, only while the access of this device allows touching it. A
  /// missing [_encryptedAllowed] means NOT allowed (fail closed), as in the
  /// inbox.
  EncryptedMessaging? get _port {
    final port = _encrypted;
    if (port == null) return null;
    return (_encryptedAllowed?.call() ?? false) ? port : null;
  }

  /// The screen calls this when the encryption access of this device may have
  /// changed: with access lost the decrypted hits are dropped at once.
  void accessChanged() {
    if (isClosed || _port != null) return;
    _clearEncrypted();
  }

  void _clearEncrypted() {
    if (!identical(_encryptedResults.value, EncryptedHitGroups.empty)) {
      _encryptedResults.value = EncryptedHitGroups.empty;
    }
  }

  /// The searched conversation is encrypted: older text exists only on this
  /// device and is already searched.
  bool _encryptedConversation = false;
  bool _resultsDisposed = false;

  StreamSubscription<void>? _changes;
  Timer? _timer;
  SearchCorpus? _corpus;
  int _generation = 0;

  /// Older pages of the one searched conversation, in memory only.
  final List<pb.Message> _older = [];
  String _olderToken = '';
  bool _olderKnown = false;

  /// The query changed (a keystroke). Debounced.
  void setQuery(String query) {
    if (isClosed) return;
    _timer?.cancel();
    // A new query drops the old decrypted answer at once.
    _clearEncrypted();
    if (query.trim().isEmpty) {
      _generation++;
      emit(
        state.copyWith(
          query: query,
          status: MessageSearchStatus.idle,
          groups: const [],
        ),
      );
      return;
    }
    emit(state.copyWith(query: query, status: MessageSearchStatus.searching));
    if (debounce == Duration.zero) {
      unawaited(_run(query));
    } else {
      _timer = Timer(debounce, () => unawaited(_run(query)));
    }
  }

  Future<SearchCorpus> _read() async {
    final cached = _corpus;
    if (cached != null) return cached;
    final read = await _repository.cachedSearchCorpus(
      conversationId: conversationId,
    );
    if (!isClosed) _corpus = read;
    return read;
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    try {
      final corpus = await _read();
      final id = conversationId;
      if (id != null && !_olderKnown) {
        _olderKnown = true;
        _olderToken = await _repository.olderSearchToken(id);
      }
      if (isClosed || generation != _generation) return;
      var vault = EncryptedHitGroups.empty;
      final port = _port;
      if (port != null) {
        // The saved copies on this device (R14): in memory only, and only
        // while the access allows it. A failure keeps the cache results.
        try {
          final hits = await port.search(query, conversationId: id);
          if (isClosed || generation != _generation) return;
          if (_port != null) {
            vault = groupEncryptedHits(corpus.conversations, hits, query);
          }
          _encryptedConversation = id != null && _isEncrypted(port, corpus, id);
        } on Object catch (_, stack) {
          if (isClosed || generation != _generation) return;
          // Never the original error: it may carry the query or text.
          onUnexpectedError?.call(StateError('search'), stack);
        }
      } else {
        _encryptedConversation = false;
      }
      final messages = _withOlder(corpus);
      _encryptedResults.value = vault;
      emit(
        state.copyWith(
          status: MessageSearchStatus.ready,
          groups: searchMessages(
            conversations: corpus.conversations,
            messagesByConversation: messages,
            query: query,
          ),
          canLoadOlder:
              id != null && _olderToken.isNotEmpty && !_encryptedConversation,
        ),
      );
    } on Object catch (error, stack) {
      // A broken disk reads as "no results"; never with the query or text.
      onUnexpectedError?.call(error, stack);
      if (isClosed || generation != _generation) return;
      _clearEncrypted();
      emit(state.copyWith(status: MessageSearchStatus.ready, groups: const []));
    }
  }

  bool _isEncrypted(EncryptedMessaging port, SearchCorpus corpus, String id) {
    for (final c in corpus.conversations) {
      if (c.id != id) continue;
      if (c.encryption == ConversationEncryption.CONVERSATION_ENCRYPTION_MLS) {
        return true;
      }
      if (c.hasLastMessage() && c.lastMessage.encrypted) return true;
    }
    return port.hasLocal(id);
  }

  Map<String, List<pb.Message>> _withOlder(SearchCorpus corpus) {
    final id = conversationId;
    if (id == null || _older.isEmpty) return corpus.messages;
    final held = corpus.messages[id] ?? const <pb.Message>[];
    final known = {for (final m in held) m.id};
    return {
      ...corpus.messages,
      id: [
        ...held,
        for (final m in _older)
          if (known.add(m.id)) m,
      ],
    };
  }

  /// "Load older messages": one more older page of the searched conversation
  /// (the existing API), kept in memory, then the search runs again.
  Future<void> loadOlder() async {
    final id = conversationId;
    if (id == null ||
        isClosed ||
        state.loadingOlder ||
        _olderToken.isEmpty ||
        _encryptedConversation) {
      return;
    }
    emit(state.copyWith(loadingOlder: true, olderError: null));
    try {
      final page = await _repository.fetchOlderForSearch(id, _olderToken);
      if (isClosed) return;
      _older.addAll(page.messages);
      _olderToken = page.nextPageToken;
      emit(
        state.copyWith(loadingOlder: false, olderPages: state.olderPages + 1),
      );
      if (state.hasQuery) await _run(state.query);
    } on AppException catch (error) {
      if (!isClosed) {
        emit(state.copyWith(loadingOlder: false, olderError: error));
      }
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
      if (!isClosed) emit(state.copyWith(loadingOlder: false));
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    unawaited(_changes?.cancel());
    _older.clear();
    _corpus = null;
    _clearEncrypted();
    if (_resultsDisposed) return super.close();
    _resultsDisposed = true;
    return super.close().whenComplete(_encryptedResults.dispose);
  }
}
