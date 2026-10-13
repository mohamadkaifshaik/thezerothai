import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../onboarding/data/identity_repository.dart';

/// Server limits (`displayNameIssue` / `bioIssue` in
/// `backend/internal/identity/validate.go`): 1-50 and 0-160 characters.
const kMaxDisplayNameLength = 50;
const kMaxBioLength = 160;

enum EditProfileStatus { editing, saving, saved }

@immutable
class EditProfileState {
  const EditProfileState({
    required this.displayName,
    required this.bio,
    this.status = EditProfileStatus.editing,
    this.error,
    this.saved,
  });

  final String displayName;
  final String bio;
  final EditProfileStatus status;

  /// The last failed save, shown once (snackbar) and cleared by the next
  /// edit or save.
  final AppException? error;

  /// The server's profile after a successful save (with
  /// [EditProfileStatus.saved]).
  final identity.Profile? saved;

  bool get isSaving => status == EditProfileStatus.saving;

  /// Characters left in the name (negative when over the limit).
  int get displayNameRemaining =>
      kMaxDisplayNameLength - displayName.trim().runes.length;
  int get bioRemaining => kMaxBioLength - bio.trim().runes.length;

  EditProfileState copyWith({
    String? displayName,
    String? bio,
    EditProfileStatus? status,
    AppException? error,
    bool clearError = false,
    identity.Profile? saved,
  }) => EditProfileState(
    displayName: displayName ?? this.displayName,
    bio: bio ?? this.bio,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    saved: saved ?? this.saved,
  );
}

/// Drives Edit profile (P2-T5): display name and bio only (avatar stays
/// rejected until P4). Sends just the fields that changed, one idempotency
/// key per distinct edit (reused by a retry of the same edit, so a dropped
/// response cannot apply twice), and reports the server's profile when done.
class EditProfileCubit extends Cubit<EditProfileState> {
  EditProfileCubit({
    required IdentityRepository identityRepository,
    required identity.Profile initial,
    Uuid? uuid,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = identityRepository,
       _initial = initial,
       _uuid = uuid ?? const Uuid(),
       _onUnexpectedError = onUnexpectedError,
       super(
         EditProfileState(displayName: initial.displayName, bio: initial.bio),
       );

  final IdentityRepository _repository;
  final identity.Profile _initial;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Map<String, String> _keys = {};

  String get _trimmedName => state.displayName.trim();
  String get _trimmedBio => state.bio.trim();

  bool get isNameChanged => _trimmedName != _initial.displayName;
  bool get isBioChanged => _trimmedBio != _initial.bio;
  bool get hasChanges => isNameChanged || isBioChanged;

  bool get _valid =>
      _trimmedName.isNotEmpty &&
      state.displayNameRemaining >= 0 &&
      state.bioRemaining >= 0;

  /// Save is offered only for a valid, changed, idle form.
  bool get canSave =>
      !state.isSaving &&
      state.status != EditProfileStatus.saved &&
      _valid &&
      hasChanges;

  void displayNameChanged(String value) {
    if (state.isSaving) return;
    emit(
      state.copyWith(
        displayName: value,
        status: EditProfileStatus.editing,
        clearError: true,
      ),
    );
  }

  void bioChanged(String value) {
    if (state.isSaving) return;
    emit(
      state.copyWith(
        bio: value,
        status: EditProfileStatus.editing,
        clearError: true,
      ),
    );
  }

  Future<void> save() async {
    if (!canSave) return;
    final name = isNameChanged ? _trimmedName : null;
    final bio = isBioChanged ? _trimmedBio : null;
    final intent = '${name ?? '\u0000'}\u0001${bio ?? '\u0000'}';
    final key = _keys.putIfAbsent(intent, _uuid.v4);
    emit(state.copyWith(status: EditProfileStatus.saving, clearError: true));
    try {
      final profile = await _repository.updateProfile(
        idempotencyKey: key,
        displayName: name,
        bio: bio,
      );
      _keys.remove(intent);
      if (isClosed) return;
      emit(state.copyWith(status: EditProfileStatus.saved, saved: profile));
    } on AppException catch (e, stack) {
      if (e is UnknownApiException) _onUnexpectedError?.call(e, stack);
      if (isClosed) return;
      emit(state.copyWith(status: EditProfileStatus.editing, error: e));
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      if (isClosed) return;
      emit(
        state.copyWith(
          status: EditProfileStatus.editing,
          error: const UnknownApiException('Something went wrong.'),
        ),
      );
    }
  }

  /// Marks the error as handled (shown), keeping the form.
  void errorShown() {
    if (state.error != null) emit(state.copyWith(clearError: true));
  }
}
