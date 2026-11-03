import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/drafts_repository.dart';

/// How many unsent posts [uid] has on this device (the state), for Settings'
/// "Delete unsent posts on this device" (security L-5).
///
/// Local only: [DraftsRepository.watchCount] (0 RPCs), whatever the `drafts`
/// flag says, so the rows stay deletable while the Drafts screen is off. The
/// state is 0 until the first count arrives and after a read failure (the
/// entry then stays hidden; sign-out still offers the choice). Nothing about a
/// draft is read or logged.
class UnsentPostsCubit extends Cubit<int> {
  UnsentPostsCubit({
    required DraftsRepository repository,
    required String uid,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = repository,
       _uid = uid,
       _onUnexpectedError = onUnexpectedError,
       super(0) {
    _sub = _repository
        .watchCount(uid)
        .listen(
          (count) {
            if (!isClosed) emit(count);
          },
          onError: (Object error, StackTrace stack) {
            // Without details: a storage error can carry a draft's text.
            _onUnexpectedError?.call(
              StateError('Unsent posts could not be counted.'),
              stack,
            );
            if (!isClosed) emit(0);
          },
        );
  }

  final DraftsRepository _repository;
  final String _uid;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  StreamSubscription<int>? _sub;

  /// Deletes every unsent post of this account from the device (the screen
  /// asked first). True when it worked; a storage failure answers false and is
  /// reported without details. The count follows by itself.
  Future<bool> deleteAll() async {
    try {
      await _repository.deleteAll(_uid);
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
    await _sub?.cancel();
    return super.close();
  }
}
