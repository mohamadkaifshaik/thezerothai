import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_labeled_field.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../media/data/image_picker_service.dart';
import '../../media/data/media_repository.dart';
import '../../media/data/media_uploader.dart';
import '../../media/domain/image_processor.dart';
import '../../media/domain/media_feature_flag.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../posts/domain/posts_feature_flag.dart';
import '../../settings/presentation/settings_up.dart';
import '../domain/profile_edit_feature_flag.dart';
import '../domain/profile_extras_rules.dart';
import 'bloc/edit_profile_cubit.dart';
import 'profile_edit_error_messages.dart';
import 'widgets/avatar_editor.dart';
import 'widgets/edit_profile_preview.dart';
import 'widgets/profile_cover_band.dart';
import 'widgets/profile_edit_unavailable.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';

/// Settings -> Edit profile (`/settings/profile`, only reachable with the
/// `profile_snapshot` flag on): display name, bio and, with `FEATURE_MEDIA`
/// on, the profile photo (tap it to choose one; it is resized on the device
/// and uploaded on Save). With media off the avatar is shown read-only (the
/// server answers MEDIA_NOT_READY).
///
/// With `profile_extras` on it also offers the location and the website.
/// Without that flag nothing can be set: a saved location or website is shown
/// read-only with Remove, which sends an exact `""` (the server accepts a clear
/// from any caller, Amendment 1 A2, and Remove needs no media either), and no
/// non-empty value can reach a request. Saves only the changed fields and pops
/// with the server's [identity.Profile] so the caller can show it without
/// another read.
class EditProfileScreen extends StatelessWidget {
  const EditProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.read<OnboardingBloc>().state.profile;
    if (profile == null) {
      // Router redirects keep profile-less callers out; belt and braces.
      return const ProfileEditUnavailable(title: 'Edit profile');
    }
    final mediaEnabled = featureEnabledSnapshot(context, kFeatureMedia);
    final extrasEnabled = featureEnabledSnapshot(
      context,
      kFeatureProfileExtras,
    );
    return BlocProvider<EditProfileCubit>(
      create: (context) => EditProfileCubit(
        identityRepository: context.read<IdentityRepository>(),
        initial: profile,
        extrasEnabled: extrasEnabled,
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
        picker: mediaEnabled ? context.read<ImagePickerService>() : null,
        processor: mediaEnabled ? context.read<ImageProcessor>() : null,
        uploader: mediaEnabled
            ? MediaUploader(
                repository: context.read<MediaRepository>(),
                onUnexpectedError: context.read<UnexpectedErrorReporter>(),
              )
            : null,
      ),
      child: _EditProfileView(
        saved: profile,
        avatarUrl: profile.avatarThumbUrl,
      ),
    );
  }
}

class _EditProfileView extends StatefulWidget {
  const _EditProfileView({required this.saved, required this.avatarUrl});

  /// The profile as saved: what the preview starts from.
  final identity.Profile saved;
  final String avatarUrl;

  @override
  State<_EditProfileView> createState() => _EditProfileViewState();
}

class _EditProfileViewState extends State<_EditProfileView> {
  late final TextEditingController _name;
  late final TextEditingController _bio;
  late final TextEditingController _location;
  late final TextEditingController _website;

  @override
  void initState() {
    super.initState();
    final state = context.read<EditProfileCubit>().state;
    _name = TextEditingController(text: state.displayName);
    _bio = TextEditingController(text: state.bio);
    _location = TextEditingController(text: state.location);
    _website = TextEditingController(text: state.website);
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _location.dispose();
    _website.dispose();
    super.dispose();
  }

  void _leave(BuildContext context, {identity.Profile? saved}) {
    if (context.canPop()) {
      context.pop(saved);
    } else {
      // Settings, or its Your account category on the tablet layout.
      context.go(settingsLeafExitLocation(context, AppRouter.editProfilePath));
    }
  }

  Future<bool> _confirmDiscard(BuildContext context) async {
    final discard = await showAppMaterialDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to your profile are not saved yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  /// Close acts like Back: nothing to discard leaves at once, edits ask
  /// first, and a save in flight cannot be abandoned.
  Future<void> _close(BuildContext context) async {
    final cubit = context.read<EditProfileCubit>();
    if (cubit.state.isSaving) return;
    if (!cubit.hasChanges || await _confirmDiscard(context)) {
      if (context.mounted) _leave(context);
    }
  }

  void _onState(BuildContext context, EditProfileState state) {
    final saved = state.saved;
    if (state.status == EditProfileStatus.saved && saved != null) {
      context.read<OnboardingBloc>().add(OnboardingProfileUpdated(saved));
      _leave(context, saved: saved);
      return;
    }
    // The extras were switched off mid-edit: the cubit put the saved values
    // back, so the (now read-only) fields follow. A removed one reads empty.
    final location = state.locationRemoved ? '' : state.location;
    final website = state.websiteRemoved ? '' : state.website;
    if (_location.text != location) _location.text = location;
    if (_website.text != website) _website.text = website;
    final message = editProfileErrorMessage(state);
    final error = state.error;
    if (message == null || error == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    // Whole feature off for this caller: refresh the flag set, which also
    // sends the router's flag redirect back to Settings. (A `profile_extras`
    // answer only hides the extras; the refresh keeps later visits in line.)
    if (error is FeatureDisabledException) {
      context.read<OnboardingBloc>().add(const OnboardingRefreshRequested());
    }
    context.read<EditProfileCubit>().errorShown();
  }

  /// "How others see you": a header action that opens a dialog.
  void _openPreview(BuildContext context) => showEditProfilePreview(
    context,
    cubit: context.read<EditProfileCubit>(),
    saved: widget.saved,
    showPostsCount: featureEnabledSnapshot(context, kFeaturePosts),
  );

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<EditProfileCubit>();
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
    final pad = wide
        ? AppExplorePeopleLayout.editPaddingWide
        : AppExplorePeopleLayout.editPaddingPhone;
    return BlocConsumer<EditProfileCubit, EditProfileState>(
      listener: _onState,
      builder: (context, state) {
        final websiteHost = websiteHostPreview(state.website);
        final photoBusy = state.isPreparingAvatar || state.isSaving;
        return PopScope(
          canPop: !cubit.hasChanges || state.status == EditProfileStatus.saved,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            // A save in flight cannot be discarded: leaving now would drop
            // the answer (and the profile update it carries) unseen.
            if (cubit.state.isSaving) return;
            if (await _confirmDiscard(context) && context.mounted) {
              _leave(context);
            }
          },
          child: Scaffold(
            body: SafeArea(
              // The floating bar overlays the page: the list scrolls behind it
              // and ends with the bar's inset.
              bottom: false,
              child: AppMainColumn(
                child: Column(
                  children: [
                    AppBackHeader(
                      title: 'Edit profile',
                      backTooltip: 'Close',
                      backIcon: Icons.close,
                      onBack: state.isSaving ? null : () => _close(context),
                      actions: [
                        IconButton(
                          tooltip: kEditProfilePreviewTitle,
                          icon: const Icon(Icons.visibility_outlined),
                          onPressed: state.isSaving
                              ? null
                              : () => _openPreview(context),
                        ),
                        AppPillButton(
                          label: 'Save',
                          singleLine: true,
                          busy: state.isSaving,
                          busySemanticsLabel: 'Saving',
                          onPressed: cubit.canSave ? cubit.save : null,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                    ),
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.only(
                          bottom:
                              AppSpacing.lg +
                              MediaQuery.paddingOf(context).bottom,
                        ),
                        children: [
                          _PhotoBand(
                            wide: wide,
                            avatar: AvatarEditor(
                              url: widget.avatarUrl,
                              previewBytes: state.avatarPreview,
                              busy: photoBusy,
                              preparing: state.isPreparingAvatar,
                              onChange: cubit.canChangeAvatar
                                  ? cubit.pickAvatar
                                  : null,
                            ),
                            onChange: cubit.canChangeAvatar
                                ? cubit.pickAvatar
                                : null,
                            busy: photoBusy,
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: pad),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                AppLabeledField(
                                  label: 'Display name',
                                  controller: _name,
                                  enabled: !state.isSaving,
                                  textInputAction: TextInputAction.next,
                                  textCapitalization: TextCapitalization.words,
                                  helper:
                                      'Also updates on your recent posts '
                                      'shortly. Name changes are limited each '
                                      'day.',
                                  helperMaxLines: 3,
                                  remaining: state.displayNameRemaining,
                                  error: displayNameFieldError(
                                    state.displayNameProblem,
                                  ),
                                  onChanged: cubit.displayNameChanged,
                                ),
                                AppLabeledField(
                                  label: 'Bio',
                                  controller: _bio,
                                  enabled: !state.isSaving,
                                  minLines: 3,
                                  maxLines: 6,
                                  keyboardType: TextInputType.multiline,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  remaining: state.bioRemaining,
                                  error: bioFieldError(state.bioProblem),
                                  onChanged: cubit.bioChanged,
                                ),
                                if (state.extrasEnabled) ...[
                                  AppLabeledField(
                                    label: 'Location',
                                    controller: _location,
                                    enabled: !state.isSaving,
                                    textInputAction: TextInputAction.next,
                                    textCapitalization:
                                        TextCapitalization.words,
                                    remaining: state.locationRemainingChars,
                                    error: state.locationRejected
                                        ? kLocationRejectedMessage
                                        : locationFieldError(
                                            state.locationProblem,
                                          ),
                                    onChanged: cubit.locationChanged,
                                  ),
                                  AppLabeledField(
                                    label: 'Website',
                                    controller: _website,
                                    enabled: !state.isSaving,
                                    keyboardType: TextInputType.url,
                                    plainText: true,
                                    textInputAction: TextInputAction.done,
                                    hint: 'https://example.com',
                                    helper: websiteHost == null
                                        ? null
                                        : 'Shows as $websiteHost',
                                    remaining: state.websiteRemainingChars,
                                    error: state.websiteRejected
                                        ? kWebsiteRejectedMessage
                                        : websiteFieldError(
                                            state.websiteProblem,
                                          ),
                                    onChanged: cubit.websiteChanged,
                                  ),
                                ] else ...[
                                  // No `profile_extras`: a saved location or
                                  // website is shown as it is, read-only,
                                  // with Remove (the only change a caller
                                  // outside the cohort may make to them).
                                  if (cubit.hasSavedLocation)
                                    _removableField(
                                      state,
                                      controller: _location,
                                      label: 'Location',
                                      noun: 'location',
                                      removed: state.locationRemoved,
                                      onRemove: cubit.removeLocation,
                                    ),
                                  if (cubit.hasSavedWebsite)
                                    _removableField(
                                      state,
                                      controller: _website,
                                      label: 'Website',
                                      noun: 'website',
                                      removed: state.websiteRemoved,
                                      onRemove: cubit.removeWebsite,
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// A saved location or website for a caller without `profile_extras`: the
  /// same field as the editable ones, `readOnly` (not disabled, so the
  /// 48dp close button in it keeps taking taps). After Remove it reads empty
  /// and says the value goes when the form is saved; there is no way to type
  /// a new one. [noun] is lower case, for the button's spoken label ("Remove
  /// location").
  Widget _removableField(
    EditProfileState state, {
    required TextEditingController controller,
    required String label,
    required String noun,
    required bool removed,
    required VoidCallback onRemove,
  }) {
    final canRemove = !state.removalRefused;
    return AppLabeledField(
      label: label,
      controller: controller,
      enabled: !state.isSaving,
      readOnly: true,
      helper: removed
          ? 'Removed when you save.'
          : canRemove
          ? "You can't change this right now, but you can remove it."
          : "You can't change this right now.",
      helperMaxLines: 3,
      suffixIcon: removed || !canRemove
          ? null
          : IconButton(
              tooltip: 'Remove $noun',
              icon: const Icon(Icons.close),
              onPressed: state.isSaving ? null : onRemove,
            ),
    );
  }
}

/// The flat band with the avatar hanging over its bottom edge (the Edit
/// profile mocks): an inset rounded card on a phone, a full-width strip from
/// 600 dp, where "Change photo" also sits beside the avatar. The box is as
/// tall as the band plus the avatar's lower part, so the avatar is inside it
/// and takes taps.
class _PhotoBand extends StatelessWidget {
  const _PhotoBand({
    required this.wide,
    required this.avatar,
    required this.onChange,
    required this.busy,
  });

  final bool wide;
  final Widget avatar;

  /// Opens the photo picker; null when the photo cannot be changed (media is
  /// off). [busy]: a photo is being prepared or the form is saving.
  final VoidCallback? onChange;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    const ring = AppExplorePeopleLayout.editAvatarRing;
    // The avatar editor's own box (the photo and the badge's room) and the
    // surface-coloured ring round it.
    const disc = AvatarEditor.radius * 2 + AppSpacing.sm + ring * 2;
    const overlap = AppExplorePeopleLayout.editAvatarOverlap;
    final bandHeight = wide
        ? AppExplorePeopleLayout.editBandWide
        : AppExplorePeopleLayout.editBandPhone;
    final inset = wide
        ? AppExplorePeopleLayout.editPaddingWide
        : AppExplorePeopleLayout.editAvatarInsetPhone;
    final side = wide ? 0.0 : AppExplorePeopleLayout.editPaddingPhone;
    return Padding(
      padding: EdgeInsets.fromLTRB(side, wide ? 0 : AppSpacing.md, side, 0),
      child: SizedBox(
        height: bandHeight - overlap + disc,
        child: Stack(
          children: [
            SizedBox(
              height: bandHeight,
              width: double.infinity,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(wide ? 0 : AppRadius.card),
                child: const ProfileCoverBand(),
              ),
            ),
            PositionedDirectional(
              top: bandHeight - overlap,
              start: inset,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(ring),
                  child: avatar,
                ),
              ),
            ),
            if (wide && onChange != null)
              PositionedDirectional(
                start: inset + disc + AppExplorePeopleLayout.editAvatarGap,
                bottom: AppSpacing.sm,
                child: OutlinedButton(
                  // The theme's outlined button spans its parent; this one
                  // is the size of its label.
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTapTarget),
                  ),
                  onPressed: busy ? null : onChange,
                  child: const Text('Change photo'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
