import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../onboarding/data/identity_repository.dart';

/// State of the "Protect your posts" switch.
///
/// [saving] is the value being saved (null when idle); the switch shows it
/// while the call runs and falls back to the profile's value on failure (no
/// optimistic write: the server can refuse with a quota or a cap). [error] is
/// the last failure and [serial] makes each one a new event for the listener.
/// [refused] is set when the server refused to turn protection ON because the
/// flag is off for the caller (FEATURE_DISABLED).
class ProtectPostsState {
  const ProtectPostsState({
    this.saving,
    this.error,
    this.serial = 0,
    this.refused = false,
  });

  final bool? saving;
  final AppException? error;
  final int serial;
  final bool refused;

  @override
  bool operator ==(Object other) =>
      other is ProtectPostsState &&
      other.saving == saving &&
      other.error == error &&
      other.serial == serial &&
      other.refused == refused;

  @override
  int get hashCode => Object.hash(saving, error, serial, refused);
}

/// Turns protection on or off through `UpdateProfile(is_private)` (W3-33b).
///
/// - One `idempotency_key` per intent (`protect` / `unprotect`), reused when
///   the same intent is retried after a failure and dropped once it succeeded.
/// - A call while one is running is ignored.
/// - On success the server's profile goes to [onProfileUpdated] (the screen
///   passes it to `OnboardingProfileUpdated`), so there is no GetMe refetch.
/// - Failures land in [ProtectPostsState.error] for the screen's snackbar;
///   FEATURE_DISABLED on turn-on also sets [ProtectPostsState.refused].
class ProtectPostsCubit extends Cubit<ProtectPostsState> {
  ProtectPostsCubit({
    required IdentityRepository identityRepository,
    required void Function(identity.Profile profile) onProfileUpdated,
    Uuid? uuid,
  }) : _identity = identityRepository,
       _onProfileUpdated = onProfileUpdated,
       _uuid = uuid ?? const Uuid(),
       super(
         ProtectPostsState(refused: identityRepository.privateAccountsRefused),
       );

  final IdentityRepository _identity;
  final void Function(identity.Profile profile) _onProfileUpdated;
  final Uuid _uuid;
  final Map<String, String> _keys = {};

  Future<void> setProtected({required bool protect}) async {
    if (state.saving != null) return;
    final intent = protect ? 'protect' : 'unprotect';
    final key = _keys[intent] ??= _uuid.v4();
    emit(ProtectPostsState(saving: protect, refused: state.refused));
    try {
      final profile = await _identity.setProtected(
        idempotencyKey: key,
        protect: protect,
      );
      _keys.remove(intent);
      _onProfileUpdated(profile);
      if (!isClosed) emit(ProtectPostsState(refused: state.refused));
    } on AppException catch (error) {
      if (isClosed) return;
      emit(
        ProtectPostsState(
          error: error,
          serial: state.serial + 1,
          refused:
              state.refused || (protect && error is FeatureDisabledException),
        ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        ProtectPostsState(
          error: const UnknownApiException('Something went wrong.'),
          serial: state.serial + 1,
          refused: state.refused,
        ),
      );
    }
  }
}
