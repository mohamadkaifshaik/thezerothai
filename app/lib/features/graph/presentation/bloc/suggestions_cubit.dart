import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/suggestions_repository.dart';
import 'suggestions_state.dart';

/// The one "Who to follow" list of the session, above every surface that shows
/// it (the Home card and the desktop right column), so a dismissal or a follow
/// in one is gone from the other and the two never fetch twice. Provided once
/// by `AppWidget`; reset on sign-out.
///
/// It owns no cache: [SuggestionsRepository] holds the answer (48 h; 6 h when
/// empty, 24 h after a limit), the dismissals, the once-per-session refill and
/// the failure rules, so [ensureLoaded] is free to call from every surface
/// that mounts (a warm call is memory only, 0 RPCs).
class SuggestionsCubit extends Cubit<SuggestionsState> {
  SuggestionsCubit({required SuggestionsRepository repository})
    : _repository = repository,
      super(const SuggestionsState());

  final SuggestionsRepository _repository;
  String? _uid;

  /// Loads (or re-reads from the cache) the suggestions of [uid]. Never
  /// throws; a failure leaves the list empty.
  Future<void> ensureLoaded(String uid) async {
    if (_uid != uid) {
      _uid = uid;
      emit(const SuggestionsState());
    }
    final items = await _repository.suggestionsFor(uid);
    if (isClosed || _uid != uid) return;
    emit(SuggestionsState(items: items));
  }

  /// Hides [userId] for the session (the row's x). Never asks for a new list.
  void hide(String userId) {
    final uid = _uid;
    if (uid == null) return;
    _repository.hide(uid, userId);
    emit(SuggestionsState(items: _repository.current(uid)));
  }

  /// A follow of [userId] from the card was confirmed by the server: the row
  /// goes at once, and when it was the last visible one the list is asked for
  /// again (ADR-0024 Amendment 2 B2 rule 4). The repository allows that once
  /// per session and account, so this cannot loop; both surfaces share the
  /// answer through this cubit.
  Future<void> followed(String userId) async {
    final uid = _uid;
    if (uid == null) return;
    final refill = _repository.followed(uid, userId);
    if (isClosed) return;
    // On a refill the old state stays until the answer lands, so the card does
    // not collapse and come back; ensureLoaded then emits the new rows (or
    // nothing, on a failure).
    if (refill) {
      await ensureLoaded(uid);
    } else {
      emit(SuggestionsState(items: _repository.current(uid)));
    }
  }

  /// Removes [userId] for good (W3-22 L-1): the server answered NOT_FOUND for
  /// it (it blocked the viewer, was suspended or deleted), so it must not come
  /// back from the cache either. Silent: the row just goes.
  void drop(String userId) {
    final uid = _uid;
    if (uid == null) return;
    _repository.drop(uid, userId);
    emit(SuggestionsState(items: _repository.current(uid)));
  }

  /// Sign-out: forget the account's list and everything the repository holds
  /// in memory.
  void reset() {
    _uid = null;
    _repository.clearSession();
    if (!isClosed) emit(const SuggestionsState());
  }
}
