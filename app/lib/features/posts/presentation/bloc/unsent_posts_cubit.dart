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
    void Function()? onDeleted,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = repository,
       _photos = photos,
       _onDeleted = onDeleted,
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
        store.watchCount(uid).listen((count) {
          _stored = count;
          _publish();
        }, onError: onError),
      );
    }
  }

  final UnsentPostsStore? _photos;
  final void Function()? _onDeleted;
  int _drafts = 0;
  int _stored = 0;

  void _publish() {
    // A post kept for a restart may also have its text in a draft: the
    // larger of the two is what "delete" removes.
    final total = _drafts > _stored ? _drafts : _stored;
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
      await _photos?.deleteAll(_uid);
      // The rows still on Home (waiting or not sent) go with them.
      _onDeleted?.call();
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
