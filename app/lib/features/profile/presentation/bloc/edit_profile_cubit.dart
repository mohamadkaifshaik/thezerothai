import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../../gen/dzeroth/media/v1/media.pb.dart' as media;
import '../../../media/data/image_picker_service.dart';
import '../../../media/data/media_uploader.dart';
import '../../../media/domain/image_processor.dart';
import '../../../media/domain/processed_image.dart';
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
    this.avatarPreview,
    this.isPreparingAvatar = false,
    this.avatarFailed = false,
    this.pickFailed = false,
    this.avatarDropped = false,
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

  /// Thumbnail of the newly chosen avatar (not saved yet), or null.
  final Uint8List? avatarPreview;

  /// The chosen photo is being resized on the device.
  final bool isPreparingAvatar;

  /// [error] came from the photo (pick/upload), not the text fields, so the
  /// UI words it for the photo.
  final bool avatarFailed;

  /// [error] is the photo picker (or its permission) failing, not a save.
  final bool pickFailed;

  /// [error] means the uploaded avatar was discarded (MEDIA_NOT_READY on
  /// UpdateProfile), so the user must choose it again.
  final bool avatarDropped;

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
    Uint8List? avatarPreview,
    bool clearAvatarPreview = false,
    bool? isPreparingAvatar,
    bool? avatarFailed,
    bool? pickFailed,
    bool? avatarDropped,
  }) => EditProfileState(
    displayName: displayName ?? this.displayName,
    bio: bio ?? this.bio,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    saved: saved ?? this.saved,
    avatarPreview: clearAvatarPreview
        ? null
        : (avatarPreview ?? this.avatarPreview),
    isPreparingAvatar: isPreparingAvatar ?? this.isPreparingAvatar,
    avatarFailed: clearError ? false : (avatarFailed ?? this.avatarFailed),
    pickFailed: clearError ? false : (pickFailed ?? this.pickFailed),
    avatarDropped: clearError
        ? false
        : (avatarDropped ?? this.avatarDropped),
  );
}

/// Drives Edit profile (P2-T5): display name and bio, plus the avatar when
/// `FEATURE_MEDIA` is on (P4: [pickAvatar] resizes on the device, [save]
/// uploads it and sends its media id with UpdateProfile). Sends just the
/// fields that changed, one idempotency key per distinct edit (reused by a
/// retry of the same edit, so a dropped response cannot apply twice; the
/// uploaded media id is remembered so a retry never uploads again), and
/// reports the server's profile when done.
class EditProfileCubit extends Cubit<EditProfileState> {
  EditProfileCubit({
    required IdentityRepository identityRepository,
    required identity.Profile initial,
    Uuid? uuid,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    ImagePickerService? picker,
    ImageProcessor? processor,
    MediaUploader? uploader,
  }) : _repository = identityRepository,
       _picker = picker,
       _processor = processor,
       _uploader = uploader,
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
  final ImagePickerService? _picker;
  final ImageProcessor? _processor;
  final MediaUploader? _uploader;

  static const _avatarJobId = 'avatar';
  ProcessedImage? _avatar;
  String? _avatarMediaId;

  /// The avatar can be changed (media is on and the pieces are wired).
  bool get canChangeAvatar =>
      _picker != null && _processor != null && _uploader != null;

  bool get isAvatarChanged => _avatar != null;

  String get _trimmedName => state.displayName.trim();
  String get _trimmedBio => state.bio.trim();

  bool get isNameChanged => _trimmedName != _initial.displayName;
  bool get isBioChanged => _trimmedBio != _initial.bio;
  bool get hasChanges => isNameChanged || isBioChanged || isAvatarChanged;

  bool get _valid =>
      _trimmedName.isNotEmpty &&
      state.displayNameRemaining >= 0 &&
      state.bioRemaining >= 0;

  /// Save is offered only for a valid, changed, idle form.
  bool get canSave =>
      !state.isSaving &&
      state.status != EditProfileStatus.saved &&
      !state.isPreparingAvatar &&
      _valid &&
      hasChanges;

  /// Opens the picker and prepares the chosen photo for upload (resize,
  /// compress and strip metadata on the device). Nothing is sent until
  /// [save].
  Future<void> pickAvatar() async {
    final picker = _picker;
    final processor = _processor;
    if (picker == null ||
        processor == null ||
        state.isSaving ||
        state.isPreparingAvatar) {
      return;
    }
    final Uint8List? bytes;
    try {
      bytes = await picker.pickAvatar();
    } catch (_) {
      // Permission denied / picker failure: keep what we had, and say so.
      if (!isClosed) {
        emit(
          state.copyWith(
            avatarFailed: true,
            pickFailed: true,
            error: const UnknownApiException('The photo picker failed.'),
          ),
        );
      }
      return;
    }
    if (bytes == null || isClosed) return;
    emit(state.copyWith(isPreparingAvatar: true, clearError: true));
    try {
      final image = await processor.process(bytes, ImagePurpose.avatar);
      _avatar = image;
      _avatarMediaId = null;
      _uploader?.forget(_avatarJobId);
      if (isClosed) return;
      emit(
        state.copyWith(
          avatarPreview: image.thumbBytes,
          isPreparingAvatar: false,
          status: EditProfileStatus.editing,
        ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        state.copyWith(
          isPreparingAvatar: false,
          avatarFailed: true,
          error: const ValidationException(
            "That file can't be used as a photo. Choose a different image.",
            field: 'media',
          ),
        ),
      );
    }
  }

  /// Uploads the chosen avatar (once) and returns its READY media id, or
  /// null when there is no new avatar. Throws [AppException].
  Future<String?> _uploadAvatar() async {
    final image = _avatar;
    final uploader = _uploader;
    if (image == null || uploader == null) return null;
    final known = _avatarMediaId;
    if (known != null) return known;
    final outcomes = await uploader.upload(
      purpose: media.MediaPurpose.MEDIA_PURPOSE_AVATAR,
      jobs: [UploadJob(id: _avatarJobId, image: image)],
    );
    final outcome = outcomes.single;
    switch (outcome.status) {
      case UploadOutcomeStatus.ready:
        return _avatarMediaId = outcome.mediaId;
      case UploadOutcomeStatus.rejected:
        // Dead for good: drop it so the user chooses another photo.
        _avatar = null;
        uploader.forget(_avatarJobId);
        throw ValidationException(
          outcome.reason.isEmpty
              ? "That photo can't be used. Choose a different one."
              : outcome.reason,
          field: 'media',
        );
      case UploadOutcomeStatus.failed:
        throw outcome.error ??
            const UnknownApiException('Upload did not finish.');
    }
  }

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
    emit(state.copyWith(status: EditProfileStatus.saving, clearError: true));
    var uploading = _avatar != null && _avatarMediaId == null;
    try {
      final avatarId = await _uploadAvatar();
      uploading = false;
      if (isClosed) return;
      // The key covers the avatar's media id too: a different photo is a
      // different request body (the server answers IDEMPOTENCY_KEY_REUSED).
      final intent =
          '${name ?? '\u0000'}\u0001${bio ?? '\u0000'}\u0001${avatarId ?? ''}';
      final key = _keys.putIfAbsent(intent, _uuid.v4);
      final profile = await _repository.updateProfile(
        idempotencyKey: key,
        displayName: name,
        bio: bio,
        avatarMediaId: avatarId,
      );
      _keys.remove(intent);
      if (isClosed) return;
      emit(state.copyWith(status: EditProfileStatus.saved, saved: profile));
    } on AppException catch (e, stack) {
      // Upload-step failures were already reported where they happened
      // (repository / uploader); an UpdateProfile one is reported here.
      if (!uploading && e is UnknownApiException) {
        _onUnexpectedError?.call(e, stack);
      }
      // Only an UpdateProfile refusal means the uploaded avatar is gone; a
      // MEDIA_NOT_READY from the upload step just means "try again".
      final dropped = e is MediaNotReadyException && !uploading;
      if (dropped) {
        // The uploaded avatar is gone server-side: forget it so the user
        // picks again instead of re-sending a dead media id.
        _avatar = null;
        _avatarMediaId = null;
        _uploader?.forget(_avatarJobId);
      }
      if (isClosed) return;
      emit(
        state.copyWith(
          status: EditProfileStatus.editing,
          error: e,
          avatarFailed: uploading || e is MediaNotReadyException,
          avatarDropped: dropped,
          clearAvatarPreview: _avatar == null,
        ),
      );
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
