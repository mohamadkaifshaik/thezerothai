import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/drafts_repository.dart';
import '../../data/unsent_posts_store.dart';

/// How many unsent posts [uid] has on this device (the state), for Settings'
/// "Delete unsent posts on this device" (security L-5).
///
/// Local only: [DraftsRepository.watchCount] (0 RPCs), whatever the `drafts`
/// flag says, so the rows stay deletable while the Drafts screen is off. The
/// Posts that wait or failed to send and kept their photos on the device
/// ([UnsentPostsStore]) are counted and deleted with the drafts.
/// The state is 0 until the first count arrives and after a read failure (the
/// entry then stays hidden; sign-out still offers the choice). Nothing about a
/// draft is read or logged.
class UnsentPostsCubit extends Cubit<int> {
  UnsentPostsCubit({
    required DraftsRepository repository,
    required String uid,
    UnsentPostsStore? photos,
    Future<void> Function(String uid)? deleteStored,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = repository,
       _photos = photos,
       _deleteStored = deleteStored,
       _uid = uid,
       _onUnexpectedError = onUnexpectedError,
       super(0) {
    void onError(Object error, StackTrace stack) {
      // Without details: a storage error can carry a draft's text.
      _onUnexpectedError?.call(
        StateError('Unsent posts could not be counted.'),
        stack,
      );
      if (!isClosed) emit(0);
    }

    _subs.add(
      _repository.watchCount(uid).listen((count) {
        _drafts = count;
        _publish();
      }, onError: onError),
    );
    final store = photos;
    if (store != null) {
      _subs.add(
        store.watchCountWithoutDraft(uid).listen((count) {
          _stored = count;
          _publish();
        }, onError: onError),
      );
    }
  }

  final UnsentPostsStore? _photos;
  final Future<void> Function(String uid)? _deleteStored;
  int _drafts = 0;
  int _stored = 0;

  void _publish() {
    // Drafts, plus the posts kept for a restart that have no draft row (a
    // post with one is counted among the drafts).
    final total = _drafts + _stored;
    if (!isClosed) emit(total);
  }

  final DraftsRepository _repository;
  final String _uid;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final List<StreamSubscription<int>> _subs = [];

  /// Deletes every unsent post of this account from the device (the screen
  /// asked first). True when it worked; a storage failure answers false and is
  /// reported without details. The count follows by itself.
  Future<bool> deleteAll() async {
    try {
      await _repository.deleteAll(_uid);
      // Through the sender when there is one (it also clears the rows on
      // Home and orders the store writes); else straight from the store.
      final deleteStored = _deleteStored;
      if (deleteStored != null) {
        await deleteStored(_uid);
      } else {
        await _photos?.deleteAll(_uid);
      }
      return true;
    } catch (_, stack) {
      _onUnexpectedError?.call(
        StateError('Unsent posts could not be deleted.'),
        stack,
      );
      return false;
    }
  }

  @override
  Future<void> close() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    return super.close();
  }
}
