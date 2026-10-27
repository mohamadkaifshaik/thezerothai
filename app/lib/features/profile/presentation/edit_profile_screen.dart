import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../shared/widgets/app_form_header.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/character_counter.dart';
import '../../media/data/image_picker_service.dart';
import '../../media/data/media_repository.dart';
import '../../media/data/media_uploader.dart';
import '../../media/domain/image_processor.dart';
import '../../media/domain/media_feature_flag.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../domain/profile_edit_feature_flag.dart';
import '../domain/profile_extras_rules.dart';
import 'bloc/edit_profile_cubit.dart';
import 'profile_edit_error_messages.dart';
import 'widgets/avatar_editor.dart';
import 'widgets/banner_editor.dart';
import 'widgets/profile_edit_unavailable.dart';

/// Settings -> Edit profile (`/settings/profile`, only reachable with the
/// `profile_snapshot` flag on): display name, bio and, with `FEATURE_MEDIA`
/// on, the profile photo (tap it to choose one; it is resized on the device
/// and uploaded on Save). With media off the avatar is shown read-only (the
/// server answers MEDIA_NOT_READY).
///
/// With `profile_extras` on (ADR-0024, W3-15) it also offers the banner (above
/// the avatar; it also needs media), the location and the website. Without
/// that flag none of them is shown, so none can reach a request. Saves only
/// the changed fields and pops with the server's [identity.Profile] so the
/// caller can show it without another read.
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
        avatarUrl: profile.avatarThumbUrl,
        // The 600 px thumb is plenty for the editor's band.
        bannerUrl: profile.bannerThumbUrl.isNotEmpty
            ? profile.bannerThumbUrl
            : profile.bannerUrl,
      ),
    );
  }
}

class _EditProfileView extends StatefulWidget {
  const _EditProfileView({required this.avatarUrl, required this.bannerUrl});

  final String avatarUrl;
  final String bannerUrl;

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
      context.go(AppRouter.settingsPath);
    }
  }

  Future<bool> _confirmDiscard(BuildContext context) async {
    final discard = await showDialog<bool>(
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
    // back, so the (now hidden) fields follow.
    if (_location.text != state.location) _location.text = state.location;
    if (_website.text != state.website) _website.text = state.website;
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

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<EditProfileCubit>();
    return BlocConsumer<EditProfileCubit, EditProfileState>(
      listener: _onState,
      builder: (context, state) {
        final nameOver = state.displayNameRemaining < 0;
        final bioOver = state.bioRemaining < 0;
        final websiteHost = websiteHostPreview(state.website);
        // The banner is edited with media on; with media off it is only shown
        // (and only when the profile has one), like the avatar.
        final showBanner =
            state.extrasEnabled &&
            (cubit.canChangeBanner ||
                (!state.bannerRemoved && widget.bannerUrl.isNotEmpty));
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
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        children: [
                          if (showBanner) ...[
                            BannerEditor(
                              url: widget.bannerUrl,
                              previewBytes: state.bannerPreview,
                              removed: state.bannerRemoved,
                              busy: state.isPreparingBanner || state.isSaving,
                              preparing: state.isPreparingBanner,
                              onChange: cubit.canChangeBanner
                                  ? cubit.pickBanner
                                  : null,
                              onRemove: cubit.canChangeBanner
                                  ? cubit.removeBanner
                                  : null,
                            ),
                            const SizedBox(height: AppSpacing.md),
                          ],
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
                              errorText: nameOver
                                  ? 'At most $kMaxDisplayNameLength characters.'
                                  : (state.displayName.trim().isEmpty
                                        ? 'Your name cannot be empty.'
                                        : null),
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
                              errorText: bioOver
                                  ? 'At most $kMaxBioLength characters.'
                                  : null,
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
