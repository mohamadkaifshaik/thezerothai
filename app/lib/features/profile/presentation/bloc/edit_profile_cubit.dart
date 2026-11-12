import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../../gen/dzeroth/media/v1/media.pb.dart' as media;
import '../../../media/data/image_picker_service.dart';
import '../../../media/data/image_upload_slot.dart';
import '../../../media/data/media_uploader.dart';
import '../../../media/domain/image_processor.dart';
import '../../../onboarding/data/identity_repository.dart';
import '../../domain/profile_edit_feature_flag.dart';
import '../../domain/profile_extras_rules.dart';

enum EditProfileStatus { editing, saving, saved }

@immutable
class EditProfileState {
  const EditProfileState({
    required this.displayName,
    required this.bio,
    this.location = '',
    this.website = '',
    this.extrasEnabled = false,
    this.status = EditProfileStatus.editing,
    this.error,
    this.saved,
    this.avatarPreview,
    this.isPreparingAvatar = false,
    this.avatarFailed = false,
    this.pickFailed = false,
    this.avatarDropped = false,
    this.locationRemoved = false,
    this.websiteRemoved = false,
    this.removalRefused = false,
    this.extrasDisabled = false,
    this.locationRejected = false,
    this.websiteRejected = false,
  });

  final String displayName;
  final String bio;

  /// The location and website as typed (not yet trimmed).
  final String location;
  final String website;

  /// The location and website can be SET (`profile_extras` is on for
  /// the caller). It only ever turns off: the server answered FEATURE_DISABLED
  /// `profile_extras`, and from then on none of them can be set. They can
  /// still be REMOVED (an exact `""`, which the server accepts from any caller
  /// whatever the flag), so without this flag Edit
  /// profile shows each saved one read-only with Remove
  /// ([locationRemoved], [websiteRemoved]).
  final bool extrasEnabled;

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

  /// The saved location / website is to be removed on Save (`""`). Only set
  /// while [extrasEnabled] is false: with the flag on the field is typed in
  /// and emptying it is the removal.
  final bool locationRemoved;
  final bool websiteRemoved;

  /// The server answered FEATURE_DISABLED `profile_extras` to a request that
  /// only cleared extras (an older server revision): from
  /// then on none of them can be removed here and Remove is hidden.
  final bool removalRefused;

  /// [error] means the extras were switched off for this account mid-edit.
  final bool extrasDisabled;

  /// The server refused the location / website as typed (VALIDATION); shown
  /// inline until that field is edited.
  final bool locationRejected;
  final bool websiteRejected;

  bool get isSaving => status == EditProfileStatus.saving;

  /// Code points left in the name and bio after trim and NFC (negative when
  /// over the limit): the count the server checks.
  int get displayNameRemaining => profileNameRemaining(displayName);
  int get bioRemaining => profileBioRemaining(bio);

  DisplayNameIssue? get displayNameProblem => displayNameIssue(displayName);
  BioIssue? get bioProblem => bioIssue(bio);

  /// Code points left in the location after trim and NFC (negative when over).
  int get locationRemainingChars => locationRemaining(location);
  int get websiteRemainingChars => websiteRemaining(website);

  LocationIssue? get locationProblem => locationIssue(location);
  WebsiteIssue? get websiteProblem => websiteIssue(website);

  EditProfileState copyWith({
    String? displayName,
    String? bio,
    String? location,
    String? website,
    bool? extrasEnabled,
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
    bool? locationRemoved,
    bool? websiteRemoved,
    bool? removalRefused,
    bool? extrasDisabled,
    bool? locationRejected,
    bool? websiteRejected,
  }) => EditProfileState(
    displayName: displayName ?? this.displayName,
    bio: bio ?? this.bio,
    location: location ?? this.location,
    website: website ?? this.website,
    extrasEnabled: extrasEnabled ?? this.extrasEnabled,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    saved: saved ?? this.saved,
    avatarPreview: clearAvatarPreview
        ? null
        : (avatarPreview ?? this.avatarPreview),
    isPreparingAvatar: isPreparingAvatar ?? this.isPreparingAvatar,
    avatarFailed: clearError ? false : (avatarFailed ?? this.avatarFailed),
    pickFailed: clearError ? false : (pickFailed ?? this.pickFailed),
    avatarDropped: clearError ? false : (avatarDropped ?? this.avatarDropped),
    locationRemoved: locationRemoved ?? this.locationRemoved,
    websiteRemoved: websiteRemoved ?? this.websiteRemoved,
    removalRefused: removalRefused ?? this.removalRefused,
    extrasDisabled: clearError
        ? false
        : (extrasDisabled ?? this.extrasDisabled),
    locationRejected: locationRejected ?? this.locationRejected,
    websiteRejected: websiteRejected ?? this.websiteRejected,
  );
}

/// Drives Edit profile: display name and bio, the avatar when
/// `FEATURE_MEDIA` is on, and with `profile_extras` also the location and
/// website.
///
/// - Sends just the fields that changed (field presence is the signal: absent
///   leaves a field alone, `""` clears it), with one idempotency key per
///   distinct edit, reused by a retry of the same edit so a dropped response
///   cannot apply twice.
/// - The avatar is an [ImageUploadSlot]: resized on the device when picked,
///   uploaded on Save, its media id remembered so a retry never uploads again.
/// - **An extra is never SET unless `extrasEnabled`**: the server refuses a
///   set (a non-empty location or website) when `profile_extras`
///   is off for the caller, which would fail every name or bio save too. A
///   **clear** (an exact `""`) is accepted whatever the flag,
/// so without the flag the screen offers Remove
///   for each saved one ([removeLocation], [removeWebsite])
///   and the only extras a request can then carry are `""`. A server
///   FEATURE_DISABLED `profile_extras` switches the setting off for good here
///   (the removals asked for are dropped with it; if the request only cleared,
///   the server predates the clear rule and Remove is hidden too) and keeps
///   the name and bio edits.
/// - Reports the server's profile when done.
class EditProfileCubit extends Cubit<EditProfileState> {
  EditProfileCubit({
    required IdentityRepository identityRepository,
    required identity.Profile initial,
    bool extrasEnabled = false,
    Uuid? uuid,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    ImagePickerService? picker,
    ImageProcessor? processor,
    MediaUploader? uploader,
  }) : _repository = identityRepository,
       _picker = picker,
       _initial = initial,
       _uuid = uuid ?? const Uuid(),
       _onUnexpectedError = onUnexpectedError,
       super(
         EditProfileState(
           displayName: initial.displayName,
           bio: initial.bio,
           location: initial.location,
           website: initial.website,
           extrasEnabled: extrasEnabled,
         ),
       ) {
    if (picker != null && processor != null && uploader != null) {
      // One upload() call with one item (AVATAR takes exactly one, so it is
      // never batched).
      _avatar = ImageUploadSlot(
        uploader: uploader,
        processor: processor,
        uploadPurpose: media.MediaPurpose.MEDIA_PURPOSE_AVATAR,
        imagePurpose: ImagePurpose.avatar,
        jobId: 'avatar',
      );
    }
  }

  final IdentityRepository _repository;
  final identity.Profile _initial;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Map<String, String> _keys = {};
  final ImagePickerService? _picker;

  /// Null when media is off (nothing to pick or upload).
  ImageUploadSlot? _avatar;

  /// The avatar can be changed (media is on and the pieces are wired).
  bool get canChangeAvatar => _avatar != null;

  bool get isAvatarChanged => _avatar?.hasImage ?? false;

  /// The profile has a saved location / website (so there is something to
  /// remove). The server omits the website while `profile_extras` is globally
  /// off, so it is then never there to remove.
  bool get hasSavedLocation => _initial.location.trim().isNotEmpty;
  bool get hasSavedWebsite => _initial.website.trim().isNotEmpty;

  // What is sent: trimmed, then NFC, as the server stores it.
  String get _name => normalizeDisplayName(state.displayName);
  String get _bio => normalizeBio(state.bio);

  bool get isNameChanged => _name != _initial.displayName;
  bool get isBioChanged => _bio != _initial.bio;
  // With the flag on the field is typed in; without it the only change is the
  // removal of the saved value.
  bool get isLocationChanged => state.extrasEnabled
      ? normalizeProfileLocation(state.location) != _initial.location
      : state.locationRemoved && hasSavedLocation;
  bool get isWebsiteChanged => state.extrasEnabled
      ? normalizeProfileWebsite(state.website) != _initial.website
      : state.websiteRemoved && hasSavedWebsite;

  bool get hasChanges =>
      isNameChanged ||
      isBioChanged ||
      isAvatarChanged ||
      isLocationChanged ||
      isWebsiteChanged;

  bool get _valid =>
      state.displayNameProblem == null &&
      state.bioProblem == null &&
      (!state.extrasEnabled ||
          (state.locationProblem == null &&
              state.websiteProblem == null &&
              !state.locationRejected &&
              !state.websiteRejected));

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
    final slot = _avatar;
    final picker = _picker;
    if (slot == null ||
        picker == null ||
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
      final image = await slot.choose(bytes);
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

  /// Removes the saved location on Save (`location: ""`). Only without
  /// `profile_extras` (the field is read-only then); with it, empty the field.
  void removeLocation() {
    if (state.isSaving ||
        state.extrasEnabled ||
        state.removalRefused ||
        !hasSavedLocation) {
      return;
    }
    emit(
      state.copyWith(
        locationRemoved: true,
        status: EditProfileStatus.editing,
        clearError: true,
      ),
    );
  }

  /// Removes the saved website on Save (`website: ""`); see [removeLocation].
  void removeWebsite() {
    if (state.isSaving ||
        state.extrasEnabled ||
        state.removalRefused ||
        !hasSavedWebsite) {
      return;
    }
    emit(
      state.copyWith(
        websiteRemoved: true,
        status: EditProfileStatus.editing,
        clearError: true,
      ),
    );
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

  void locationChanged(String value) {
    if (state.isSaving || !state.extrasEnabled) return;
    emit(
      state.copyWith(
        location: value,
        locationRejected: false,
        status: EditProfileStatus.editing,
        clearError: true,
      ),
    );
  }

  void websiteChanged(String value) {
    if (state.isSaving || !state.extrasEnabled) return;
    emit(
      state.copyWith(
        website: value,
        websiteRejected: false,
        status: EditProfileStatus.editing,
        clearError: true,
      ),
    );
  }

  Future<void> save() async {
    if (!canSave) return;
    final name = isNameChanged ? _name : null;
    final bio = isBioChanged ? _bio : null;
    // A typed value is read only while the extras are on. Without them the
    // only change the getters report is a removal, and a removal is "": an
    // account outside the cohort never has a non-empty location or website in
    // a request (the server refuses a set, and a clear next to a
    // set, whole).
    final extras = state.extrasEnabled;
    final location = isLocationChanged
        ? (extras ? normalizeProfileLocation(state.location) : '')
        : null;
    final website = isWebsiteChanged
        ? (extras ? normalizeProfileWebsite(state.website) : '')
        : null;
    emit(state.copyWith(status: EditProfileStatus.saving, clearError: true));
    // The picture being uploaded when a step fails, so the error is worded
    // for it; null once both are uploaded (a failure is then UpdateProfile's).
    ImageUploadSlot? uploading;
    String? avatarId;
    try {
      final avatarSlot = _avatar;
      uploading = avatarSlot != null && avatarSlot.needsUpload
          ? avatarSlot
          : null;
      avatarId = await avatarSlot?.ensureUploaded();
      uploading = null;
      if (isClosed) return;
      assert(
        extras || [location, website].every((v) => v == null || v.isEmpty),
        'without profile_extras a request may only clear an extra',
      );
      // The key covers every field sent, the media id included: a different
      // photo is a different request body (the server answers
      // IDEMPOTENCY_KEY_REUSED), and JSON tells an absent field from "".
      final intent = jsonEncode([name, bio, avatarId, location, website]);
      final key = _keys.putIfAbsent(intent, _uuid.v4);
      final profile = await _repository.updateProfile(
        idempotencyKey: key,
        displayName: name,
        bio: bio,
        avatarMediaId: avatarId,
        location: location,
        website: website,
      );
      _keys.remove(intent);
      if (isClosed) return;
      emit(state.copyWith(status: EditProfileStatus.saved, saved: profile));
    } on AppException catch (e, stack) {
      final failedUpload = uploading;
      // Upload-step failures were already reported where they happened
      // (repository / uploader); an UpdateProfile one is reported here.
      if (failedUpload == null && e is UnknownApiException) {
        _onUnexpectedError?.call(e, stack);
      }
      final extrasOff =
          e is FeatureDisabledException && e.feature == kFeatureProfileExtras;
      // Only an UpdateProfile refusal means the uploaded photo is gone; a
      // MEDIA_NOT_READY from the upload step just means "try again".
      final avatarDropped =
          e is MediaNotReadyException &&
          failedUpload == null &&
          avatarId != null;
      if (avatarDropped) _avatar?.discard();
      if (isClosed) return;
      // Switched off: forget every pending extra (a removal asked for with
      // the flag already off included: only an older server
      // refuses it) and keep the name and bio.
      final base = extrasOff
          ? state.copyWith(
              extrasEnabled: false,
              location: _initial.location,
              website: _initial.website,
              locationRemoved: false,
              websiteRemoved: false,
              // A request that only cleared was refused: Remove goes.
              removalRefused: !extras,
              locationRejected: false,
              websiteRejected: false,
            )
          : state;
      emit(
        base.copyWith(
          status: EditProfileStatus.editing,
          error: e,
          avatarFailed:
              (failedUpload != null && identical(failedUpload, _avatar)) ||
              avatarDropped,
          avatarDropped: avatarDropped,
          extrasDisabled: extrasOff,
          locationRejected:
              e is ValidationException &&
              e.field == 'location' &&
              location != null,
          websiteRejected:
              e is ValidationException &&
              e.field == 'website' &&
              website != null,
          clearAvatarPreview: !(_avatar?.hasImage ?? false),
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
