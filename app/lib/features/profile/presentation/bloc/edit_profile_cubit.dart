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

/// The two pictures Edit profile can change.
enum ProfilePicture { avatar, banner }

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
    this.bannerPreview,
    this.isPreparingBanner = false,
    this.bannerRemoved = false,
    this.bannerFailed = false,
    this.bannerDropped = false,
    this.extrasDisabled = false,
    this.locationRejected = false,
    this.websiteRejected = false,
  });

  final String displayName;
  final String bio;

  /// The location and website as typed (not yet trimmed).
  final String location;
  final String website;

  /// The banner, location and website are offered (`profile_extras` is on for
  /// the caller). It only ever turns off: the server answered FEATURE_DISABLED
  /// `profile_extras`, and from then on none of those fields is sent.
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

  /// Thumbnail of the newly chosen banner (not saved yet), or null.
  final Uint8List? bannerPreview;

  /// The chosen banner is being cropped and resized on the device.
  final bool isPreparingBanner;

  /// The saved banner is to be removed on Save (`banner_media_id: ""`).
  final bool bannerRemoved;

  /// [error] came from the banner (pick/upload), so the UI words it for it.
  final bool bannerFailed;

  /// [error] means the uploaded banner was discarded (MEDIA_NOT_READY on
  /// UpdateProfile); it must be chosen again.
  final bool bannerDropped;

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
    Uint8List? bannerPreview,
    bool clearBannerPreview = false,
    bool? isPreparingBanner,
    bool? bannerRemoved,
    bool? bannerFailed,
    bool? bannerDropped,
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
    bannerPreview: clearBannerPreview
        ? null
        : (bannerPreview ?? this.bannerPreview),
    isPreparingBanner: isPreparingBanner ?? this.isPreparingBanner,
    bannerRemoved: bannerRemoved ?? this.bannerRemoved,
    bannerFailed: clearError ? false : (bannerFailed ?? this.bannerFailed),
    bannerDropped: clearError ? false : (bannerDropped ?? this.bannerDropped),
    extrasDisabled: clearError
        ? false
        : (extrasDisabled ?? this.extrasDisabled),
    locationRejected: locationRejected ?? this.locationRejected,
    websiteRejected: websiteRejected ?? this.websiteRejected,
  );
}

/// Drives Edit profile: display name and bio (P2-T5), the avatar when
/// `FEATURE_MEDIA` is on (P4), and with `profile_extras` also the banner,
/// location and website (ADR-0024, W3-15).
///
/// - Sends just the fields that changed (field presence is the signal: absent
///   leaves a field alone, `""` clears it), with one idempotency key per
///   distinct edit, reused by a retry of the same edit so a dropped response
///   cannot apply twice.
/// - Each picture is an [ImageUploadSlot]: resized on the device when picked,
///   uploaded on Save, its media id remembered so a retry never uploads again.
/// - **The extras are never put in a request unless `extrasEnabled`**: the
///   server refuses any of them, even a clear, when `profile_extras` is off
///   for the caller, which would fail every name or bio save too. A server
///   FEATURE_DISABLED `profile_extras` switches them off for good here and
///   keeps the name and bio edits.
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
      // One uploader, one slot per picture, one upload() call per slot (AVATAR
      // and BANNER take exactly one item, so they are never batched).
      _avatar = ImageUploadSlot(
        uploader: uploader,
        processor: processor,
        uploadPurpose: media.MediaPurpose.MEDIA_PURPOSE_AVATAR,
        imagePurpose: ImagePurpose.avatar,
        jobId: 'avatar',
      );
      _banner = ImageUploadSlot(
        uploader: uploader,
        processor: processor,
        uploadPurpose: media.MediaPurpose.MEDIA_PURPOSE_BANNER,
        imagePurpose: ImagePurpose.banner,
        jobId: 'banner',
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
  ImageUploadSlot? _banner;

  ImageUploadSlot? _slot(ProfilePicture which) =>
      which == ProfilePicture.avatar ? _avatar : _banner;

  /// The avatar can be changed (media is on and the pieces are wired).
  bool get canChangeAvatar => _avatar != null;

  /// The banner can be changed: `profile_extras` and media are both on.
  bool get canChangeBanner => state.extrasEnabled && _banner != null;

  bool get isAvatarChanged => _avatar?.hasImage ?? false;

  /// The profile has a saved banner (so there is something to remove).
  bool get hasSavedBanner =>
      _initial.bannerUrl.isNotEmpty || _initial.bannerThumbUrl.isNotEmpty;

  // What is sent: trimmed, then NFC, as the server stores it.
  String get _name => normalizeDisplayName(state.displayName);
  String get _bio => normalizeBio(state.bio);

  bool get isNameChanged => _name != _initial.displayName;
  bool get isBioChanged => _bio != _initial.bio;
  bool get isLocationChanged =>
      state.extrasEnabled &&
      normalizeProfileLocation(state.location) != _initial.location;
  bool get isWebsiteChanged =>
      state.extrasEnabled &&
      normalizeProfileWebsite(state.website) != _initial.website;

  /// A new banner is chosen, or the saved one is to be removed.
  bool get isBannerChanged =>
      state.extrasEnabled &&
      ((_banner?.hasImage ?? false) || (state.bannerRemoved && hasSavedBanner));

  bool get hasChanges =>
      isNameChanged ||
      isBioChanged ||
      isAvatarChanged ||
      isLocationChanged ||
      isWebsiteChanged ||
      isBannerChanged;

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
      !state.isPreparingBanner &&
      _valid &&
      hasChanges;

  /// Opens the picker and prepares the chosen photo for upload (resize,
  /// compress and strip metadata on the device). Nothing is sent until
  /// [save].
  Future<void> pickAvatar() => _pick(ProfilePicture.avatar);

  /// Opens the picker and prepares the chosen image as a banner (centered
  /// 3:1 crop, full 1500 x 500 and thumb 600 x 200, on the device). Nothing
  /// is sent until [save]. Needs [canChangeBanner].
  Future<void> pickBanner() => _pick(ProfilePicture.banner);

  bool _isPreparing(ProfilePicture which) => which == ProfilePicture.avatar
      ? state.isPreparingAvatar
      : state.isPreparingBanner;

  Future<void> _pick(ProfilePicture which) async {
    final slot = _slot(which);
    final picker = _picker;
    if (slot == null ||
        picker == null ||
        state.isSaving ||
        _isPreparing(which) ||
        (which == ProfilePicture.banner && !state.extrasEnabled)) {
      return;
    }
    final Uint8List? bytes;
    try {
      bytes = which == ProfilePicture.avatar
          ? await picker.pickAvatar()
          : (await picker.pickImages(limit: 1)).firstOrNull;
    } catch (_) {
      // Permission denied / picker failure: keep what we had, and say so.
      if (!isClosed) {
        emit(
          _flagged(
            which,
            const UnknownApiException('The photo picker failed.'),
            pickFailed: true,
          ),
        );
      }
      return;
    }
    if (bytes == null || isClosed) return;
    emit(_preparing(which).copyWith(clearError: true));
    try {
      final image = await slot.choose(bytes);
      if (isClosed) return;
      emit(
        which == ProfilePicture.avatar
            ? state.copyWith(
                avatarPreview: image.thumbBytes,
                isPreparingAvatar: false,
                status: EditProfileStatus.editing,
              )
            : state.copyWith(
                bannerPreview: image.thumbBytes,
                isPreparingBanner: false,
                bannerRemoved: false,
                status: EditProfileStatus.editing,
              ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        _flagged(
          which,
          ValidationException(
            which == ProfilePicture.avatar
                ? "That file can't be used as a photo. Choose a different "
                      'image.'
                : "That file can't be used as a banner. Choose a different "
                      'image.',
            field: 'media',
          ),
          preparing: false,
        ),
      );
    }
  }

  /// [state] with the picture [which] marked as being prepared.
  EditProfileState _preparing(ProfilePicture which) =>
      which == ProfilePicture.avatar
      ? state.copyWith(isPreparingAvatar: true)
      : state.copyWith(isPreparingBanner: true);

  /// [state] with [error] attributed to the picture [which].
  EditProfileState _flagged(
    ProfilePicture which,
    AppException error, {
    bool pickFailed = false,
    bool? preparing,
  }) => which == ProfilePicture.avatar
      ? state.copyWith(
          isPreparingAvatar: preparing,
          avatarFailed: true,
          pickFailed: pickFailed,
          error: error,
        )
      : state.copyWith(
          isPreparingBanner: preparing,
          bannerFailed: true,
          pickFailed: pickFailed,
          error: error,
        );

  /// Drops the chosen banner and, when the profile has one, removes it on
  /// Save (`banner_media_id: ""`). The result is always "no banner".
  void removeBanner() {
    final slot = _banner;
    if (slot == null || !state.extrasEnabled || state.isSaving) return;
    slot.discard();
    emit(
      state.copyWith(
        clearBannerPreview: true,
        bannerRemoved: hasSavedBanner,
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
    // Each extra is read only while the extras are on (the getters check it):
    // a switched-off account never has a banner, location or website in the
    // request.
    final location = isLocationChanged
        ? normalizeProfileLocation(state.location)
        : null;
    final website = isWebsiteChanged
        ? normalizeProfileWebsite(state.website)
        : null;
    final extras = state.extrasEnabled;
    emit(state.copyWith(status: EditProfileStatus.saving, clearError: true));
    // The picture being uploaded when a step fails, so the error is worded
    // for it; null once both are uploaded (a failure is then UpdateProfile's).
    ImageUploadSlot? uploading;
    String? avatarId;
    String? bannerId;
    try {
      final avatarSlot = _avatar;
      uploading = avatarSlot != null && avatarSlot.needsUpload
          ? avatarSlot
          : null;
      avatarId = await avatarSlot?.ensureUploaded();
      final bannerSlot = extras ? _banner : null;
      uploading = bannerSlot != null && bannerSlot.needsUpload
          ? bannerSlot
          : null;
      bannerId = await bannerSlot?.ensureUploaded();
      uploading = null;
      if (isClosed) return;
      // "" removes the saved banner; only a saved one is worth a request.
      final bannerArg =
          bannerId ??
          (extras && state.bannerRemoved && hasSavedBanner ? '' : null);
      // The key covers every field sent, the media ids included: a different
      // photo or banner is a different request body (the server answers
      // IDEMPOTENCY_KEY_REUSED), and JSON tells an absent field from "".
      final intent = jsonEncode([
        name,
        bio,
        avatarId,
        bannerArg,
        location,
        website,
      ]);
      final key = _keys.putIfAbsent(intent, _uuid.v4);
      final profile = await _repository.updateProfile(
        idempotencyKey: key,
        displayName: name,
        bio: bio,
        avatarMediaId: avatarId,
        bannerMediaId: bannerArg,
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
      // Only an UpdateProfile refusal means the uploaded pictures are gone; a
      // MEDIA_NOT_READY from the upload step just means "try again". The
      // answer does not say which picture, so every one that was sent goes.
      final dropped = e is MediaNotReadyException && failedUpload == null;
      final avatarDropped = dropped && avatarId != null;
      final bannerDropped = dropped && bannerId != null;
      if (avatarDropped) _avatar?.discard();
      if (bannerDropped || extrasOff) _banner?.discard();
      if (isClosed) return;
      // Switched off: forget every pending extra and keep the name and bio.
      final base = extrasOff
          ? state.copyWith(
              extrasEnabled: false,
              location: _initial.location,
              website: _initial.website,
              bannerRemoved: false,
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
          bannerFailed:
              (failedUpload != null && identical(failedUpload, _banner)) ||
              bannerDropped,
          avatarDropped: avatarDropped,
          bannerDropped: bannerDropped,
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
          clearBannerPreview: !(_banner?.hasImage ?? false),
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
