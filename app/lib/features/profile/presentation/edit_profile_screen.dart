import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../shared/widgets/primitives/app_form_header.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
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

  /// Cancel acts like Back: nothing to discard leaves at once, edits ask
  /// first, and a save in flight cannot be abandoned.
  Future<void> _cancel(BuildContext context) async {
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
    // "How others see you" is offered at every width (the desktop mock's side
    // box is a dialog here, as on the tablet). Up to 1.3x text it is the
    // header's third button; above, three buttons would cut Save short, so it
    // is the form's first row instead and Save keeps 40 % of the header.
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final preview = !largeText;
    final previewRow = largeText;
    return BlocConsumer<EditProfileCubit, EditProfileState>(
      listener: _onState,
      builder: (context, state) {
        final websiteHost = websiteHostPreview(state.website);
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
              child: AppMainColumn(
                child: Column(
                  children: [
                    AppFormHeader(
                      title: 'Edit profile',
                      busy: state.isSaving,
                      busySemanticsLabel: 'Saving',
                      onCancel: () => _cancel(context),
                      actionLabel: 'Save',
                      onAction: cubit.canSave ? cubit.save : null,
                      secondaryLabel: preview
                          ? kEditProfilePreviewAction
                          : null,
                      onSecondary: preview ? () => _openPreview(context) : null,
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        children: [
                          if (previewRow) ...[
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(
                                  AppSpacing.minTapTarget,
                                ),
                              ),
                              onPressed: state.isSaving
                                  ? null
                                  : () => _openPreview(context),
                              icon: const Icon(Icons.visibility_outlined),
                              label: const Text(kEditProfilePreviewAction),
                            ),
                            const SizedBox(height: AppSpacing.md),
                          ],
                          AspectRatio(
                            aspectRatio: ProfileCoverBand.aspect,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              child: const ProfileCoverBand(),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: AvatarEditor(
                              url: widget.avatarUrl,
                              previewBytes: state.avatarPreview,
                              busy: state.isPreparingAvatar || state.isSaving,
                              preparing: state.isPreparingAvatar,
                              onChange: cubit.canChangeAvatar
                                  ? cubit.pickAvatar
                                  : null,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          TextField(
                            controller: _name,
                            enabled: !state.isSaving,
                            textInputAction: TextInputAction.next,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: 'Display name',
                              helperText:
                                  'Also updates on your recent posts shortly. '
                                  'Name changes are limited each day.',
                              helperMaxLines: 3,
                              counter: CharacterCounter(
                                remaining: state.displayNameRemaining,
                              ),
                              errorText: displayNameFieldError(
                                state.displayNameProblem,
                              ),
                            ),
                            onChanged: cubit.displayNameChanged,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          TextField(
                            controller: _bio,
                            enabled: !state.isSaving,
                            minLines: 3,
                            maxLines: 6,
                            keyboardType: TextInputType.multiline,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              labelText: 'Bio',
                              alignLabelWithHint: true,
                              counter: CharacterCounter(
                                remaining: state.bioRemaining,
                              ),
                              errorText: bioFieldError(state.bioProblem),
                            ),
                            onChanged: cubit.bioChanged,
                          ),
                          if (state.extrasEnabled) ...[
                            const SizedBox(height: AppSpacing.md),
                            TextField(
                              controller: _location,
                              enabled: !state.isSaving,
                              maxLines: 1,
                              textInputAction: TextInputAction.next,
                              textCapitalization: TextCapitalization.words,
                              decoration: InputDecoration(
                                labelText: 'Location',
                                counter: CharacterCounter(
                                  remaining: state.locationRemainingChars,
                                ),
                                errorText: state.locationRejected
                                    ? kLocationRejectedMessage
                                    : locationFieldError(state.locationProblem),
                              ),
                              onChanged: cubit.locationChanged,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            TextField(
                              controller: _website,
                              enabled: !state.isSaving,
                              maxLines: 1,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              enableSuggestions: false,
                              textInputAction: TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: 'Website',
                                hintText: 'https://example.com',
                                helperText: websiteHost == null
                                    ? null
                                    : 'Shows as $websiteHost',
                                counter: CharacterCounter(
                                  remaining: state.websiteRemainingChars,
                                ),
                                errorText: state.websiteRejected
                                    ? kWebsiteRejectedMessage
                                    : websiteFieldError(state.websiteProblem),
                              ),
                              onChanged: cubit.websiteChanged,
                            ),
                          ] else ...[
                            // No `profile_extras`: a saved location or website
                            // is shown as it is, read-only, with Remove (the
                            // only change a caller outside the cohort may
                            // make to them).
                            if (cubit.hasSavedLocation) ...[
                              const SizedBox(height: AppSpacing.md),
                              _RemovableField(
                                controller: _location,
                                label: 'Location',
                                noun: 'location',
                                removed: state.locationRemoved,
                                canRemove: !state.removalRefused,
                                enabled: !state.isSaving,
                                onRemove: cubit.removeLocation,
                              ),
                            ],
                            if (cubit.hasSavedWebsite) ...[
                              const SizedBox(height: AppSpacing.md),
                              _RemovableField(
                                controller: _website,
                                label: 'Website',
                                noun: 'website',
                                removed: state.websiteRemoved,
                                canRemove: !state.removalRefused,
                                enabled: !state.isSaving,
                                onRemove: cubit.removeWebsite,
                              ),
                            ],
                          ],
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
}

/// A saved location or website shown read-only with Remove, for a caller
/// without `profile_extras`: the same outlined
/// `TextField` as the editable fields (so it reads and scrolls like them), with
/// a 48dp close button in the field. It is `readOnly`, not disabled, so the
/// button keeps taking taps. After Remove the field reads empty and says the
/// value goes when the form is saved; there is no way to type a new one.
class _RemovableField extends StatelessWidget {
  const _RemovableField({
    required this.controller,
    required this.label,
    required this.noun,
    required this.removed,
    required this.canRemove,
    required this.enabled,
    required this.onRemove,
  });

  final TextEditingController controller;
  final String label;

  /// Lower case, for the button's spoken label ("Remove location").
  final String noun;
  final bool removed;

  /// False once the server refused a removal: the value stays, read-only.
  final bool canRemove;
  final bool enabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: true,
      enabled: enabled,
      maxLines: 1,
      decoration: InputDecoration(
        labelText: label,
        helperText: removed
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
                onPressed: enabled ? onRemove : null,
              ),
      ),
    );
  }
}
