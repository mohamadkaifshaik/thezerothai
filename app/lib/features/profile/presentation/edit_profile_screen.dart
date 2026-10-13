import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import 'bloc/edit_profile_cubit.dart';
import 'profile_edit_error_messages.dart';

/// Settings -> Edit profile (`/settings/profile`, only reachable with the
/// `profile_snapshot` flag on): display name and bio. The avatar is shown but
/// not editable (the server rejects avatar changes until P4). Saves only the
/// changed fields; pops with `true` so the caller can refresh.
class EditProfileScreen extends StatelessWidget {
  const EditProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.read<OnboardingBloc>().state.profile;
    if (profile == null) {
      // Router redirects keep profile-less callers out; belt and braces.
      return Scaffold(
        appBar: AppBar(title: const Text('Edit profile')),
        body: const SizedBox.shrink(),
      );
    }
    return BlocProvider<EditProfileCubit>(
      create: (context) => EditProfileCubit(
        identityRepository: context.read<IdentityRepository>(),
        initial: profile,
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

  void _leave(BuildContext context, {bool saved = false}) {
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
      _leave(context, saved: true);
      return;
    }
    final error = state.error;
    if (error == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(updateProfileErrorMessage(error))));
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
    final theme = Theme.of(context);
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
                      minimumSize: const Size(72, AppSpacing.minTapTarget),
                    ),
                    onPressed: cubit.canSave ? cubit.save : null,
                    child: state.isSaving
                        ? const SizedBox(
                            width: AppIconSize.md,
                            height: AppIconSize.md,
                            child: CircularProgressIndicator(strokeWidth: 2),
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
                        child: Semantics(
                          label: 'Profile photo',
                          image: true,
                          excludeSemantics: true,
                          child: AppAvatar(
                            url: widget.avatarUrl,
                            radius: AppSpacing.xl + AppSpacing.sm,
                          ),
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
                          counterText: '${state.displayNameRemaining}',
                          counterStyle: theme.textTheme.bodySmall?.copyWith(
                            color: nameOver
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
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
                          counterText: '${state.bioRemaining}',
                          counterStyle: theme.textTheme.bodySmall?.copyWith(
                            color: bioOver
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
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
