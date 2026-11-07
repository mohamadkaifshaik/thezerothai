import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/auth_repository.dart';
import '../../domain/auth_failure.dart';

typedef PasswordResetState = ({bool busy, bool sent, String? error});

class PasswordResetCubit extends Cubit<PasswordResetState> {
  PasswordResetCubit(this._repository)
    : super((busy: false, sent: false, error: null));
  final AuthRepository _repository;

  Future<void> send(String email) async {
    if (state.busy || state.sent) return;
    emit((busy: true, sent: false, error: null));
    try {
      await _repository.sendPasswordResetEmail(email);
      if (!isClosed) emit((busy: false, sent: true, error: null));
    } on AuthFailure catch (failure) {
      if (!isClosed) emit((busy: false, sent: false, error: failure.message));
    } catch (_) {
      if (!isClosed) {
        emit((
          busy: false,
          sent: false,
          error: 'Couldn’t send a reset link. Please try again.',
        ));
      }
    }
  }
}
