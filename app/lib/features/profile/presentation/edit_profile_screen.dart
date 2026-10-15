import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../shared/widgets/character_counter.dart';
import '../../media/data/image_picker_service.dart';
import '../../media/data/media_repository.dart';
import '../../media/data/media_uploader.dart';
import '../../media/domain/image_processor.dart';
import '../../media/domain/media_feature_flag.dart';
import '../../media/presentation/media_error_messages.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import 'bloc/edit_profile_cubit.dart';
import 'profile_edit_error_messages.dart';
import 'widgets/avatar_editor.dart';
import 'widgets/profile_edit_unavailable.dart';

/// Settings -> Edit profile (`/settings/profile`, only reachable with the
/// `profile_snapshot` flag on): display name, bio and, with `FEATURE_MEDIA`
/// on, the profile photo (tap it to choose one; it is resized on the device
/// and uploaded on Save). With media off the avatar is shown read-only (the
/// server answers MEDIA_NOT_READY). Saves only the changed fields and pops
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
    return BlocProvider<EditProfileCubit>(
      create: (context) => EditProfileCubit(
        identityRepository: context.read<IdentityRepository>(),
        initial: profile,
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
        picker: mediaEnabled ? context.read<ImagePickerService>() : null,
        processor: mediaEnabled ? context.read<ImageProcessor>() : null,
        uploader: mediaEnabled
            ? MediaUploader(repository: context.read<MediaRepository>())
            : null,
      ),
      child: _EditProfileView(avatarUrl: profile.avatarThumbUrl),
    );
  }
}

class _EditProfileView extends StatefulWidget {
  const _EditProfileView({required this.avatarUrl});

  final String avatarUrl;

  @override
  State<_EditProfileView> createState() => _EditProfileViewState();
}

class _EditProfileViewState extends State<_EditProfileView> {
  late final TextEditingController _name;
  late final TextEditingController _bio;

  @override
  void initState() {
    super.initState();
    final state = context.read<EditProfileCubit>().state;
    _name = TextEditingController(text: state.displayName);
    _bio = TextEditingController(text: state.bio);
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
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

  void _onState(BuildContext context, EditProfileState state) {
    final saved = state.saved;
    if (state.status == EditProfileStatus.saved && saved != null) {
      context.read<OnboardingBloc>().add(OnboardingProfileUpdated(saved));
      _leave(context, saved: saved);
      return;
    }
    final error = state.error;
    if (error == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            state.avatarFailed
                ? avatarErrorMessage(error)
                : updateProfileErrorMessage(error),
          ),
        ),
      );
    // Whole feature off for this caller: refresh the flag set, which also
    // sends the router's flag redirect back to Settings.
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
        return PopScope(
          canPop: !cubit.hasChanges || state.status == EditProfileStatus.saved,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            if (await _confirmDiscard(context) && context.mounted) {
              _leave(context);
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Edit profile'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(
                        AppSpacing.minButtonWidth,
                        AppSpacing.minTapTarget,
                      ),
                    ),
                    onPressed: cubit.canSave ? cubit.save : null,
                    child: state.isSaving
                        ? const SizedBox(
                            width: AppIconSize.md,
                            height: AppIconSize.md,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              semanticsLabel: 'Saving',
                            ),
                          )
                        : const Text('Save'),
                  ),
                ),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppBreakpoints.mobile,
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    children: [
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
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
