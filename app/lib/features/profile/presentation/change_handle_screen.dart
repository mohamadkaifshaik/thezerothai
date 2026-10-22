import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/format/coarse_wait.dart';
import '../../../shared/widgets/app_form_header.dart';
import '../../../shared/widgets/app_gradient_button.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/domain/handle_rules.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import 'bloc/change_handle_cubit.dart';
import 'profile_edit_error_messages.dart';
import 'widgets/profile_edit_unavailable.dart';

/// Settings -> Change handle (`/settings/handle`, only reachable with the
/// `profile_snapshot` flag on). Live availability check, a confirmation that
/// states the 7-day cooldown, then ChangeHandle; success lands on the
/// caller's profile under the new handle (the old one is free for others).
class ChangeHandleScreen extends StatelessWidget {
  const ChangeHandleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final handle = context.read<OnboardingBloc>().state.profile?.handle;
    if (handle == null) {
      // Router redirects keep profile-less callers out; belt and braces.
      return const ProfileEditUnavailable(title: 'Change handle');
    }
    return BlocProvider<ChangeHandleCubit>(
      create: (context) => ChangeHandleCubit(
        identityRepository: context.read<IdentityRepository>(),
        currentHandle: handle,
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
      ),
      child: _ChangeHandleView(currentHandle: handle),
    );
  }
}

class _ChangeHandleView extends StatefulWidget {
  const _ChangeHandleView({required this.currentHandle});

  final String currentHandle;

  @override
  State<_ChangeHandleView> createState() => _ChangeHandleViewState();
}

class _ChangeHandleViewState extends State<_ChangeHandleView> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirmAndSave(BuildContext context, String handle) async {
    final cubit = context.read<ChangeHandleCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Change your handle to @$handle?'),
        content: const Text(
          "You won't be able to change it again for 7 days. Your old handle "
          'becomes available to other people, and links to it stop working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Change handle'),
          ),
        ],
      ),
    );
    if (confirmed == true) await cubit.save();
  }

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.settingsPath);
    }
  }

  void _onState(BuildContext context, ChangeHandleState state) {
    final saved = state.saved;
    if (state.status == ChangeHandleStatus.saved && saved != null) {
      context.read<OnboardingBloc>().add(OnboardingProfileUpdated(saved));
      // The old /profile/<handle> URL may be stale now: land on the new one.
      context.go(AppRouter.profilePath(saved.handle));
      return;
    }
    final error = state.error;
    if (error == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(changeHandleErrorMessage(error))));
    if (error is FeatureDisabledException) {
      context.read<OnboardingBloc>().add(const OnboardingRefreshRequested());
    }
    context.read<ChangeHandleCubit>().errorShown();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ChangeHandleCubit>();
    final theme = Theme.of(context);
    return BlocConsumer<ChangeHandleCubit, ChangeHandleState>(
      listener: _onState,
      builder: (context, state) {
        final unavailable = state.checkStatus == HandleCheckStatus.unavailable;
        final cooldown = cubit.cooldownLeft;
        final helper = state.checkMessage.isEmpty
            ? kHandleFormatMessage
            : state.checkMessage;
        // One live-region note under the field: the cooldown, else why the
        // handle can't be used, else the format hint. Screen readers announce
        // it as the availability answer arrives.
        final note = cooldown != null
            ? 'You can change your handle again in ${coarseWait(cooldown)}.'
            : helper;
        final isProblem = cooldown != null || unavailable;
        return PopScope(
          // A save in flight cannot be abandoned: leaving now would drop the
          // answer (and the profile update it carries) unseen.
          canPop: !state.isSaving,
          child: Scaffold(
            body: SafeArea(
              child: AppMainColumn(
                child: Column(
                  children: [
                    AppFormHeader(
                      title: 'Change handle',
                      busy: state.isSaving,
                      onCancel: () => _leave(context),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        children: [
                          Text(
                            'Current handle: @${widget.currentHandle}',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'You can change your handle once every 7 days. Your old '
                            'handle becomes available to other people.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          TextField(
                            controller: _controller,
                            enabled: !state.isSaving,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.done,
                            decoration: InputDecoration(
                              labelText: 'New handle',
                              prefixText: '@',
                              helper: isProblem ? null : _FieldNote(text: note),
                              helperMaxLines: 2,
                              error: isProblem
                                  ? _FieldNote(text: note, isError: true)
                                  : null,
                              errorMaxLines: 2,
                              suffixIcon: _StatusIcon(
                                status: state.checkStatus,
                              ),
                            ),
                            onChanged: cubit.handleChanged,
                            onSubmitted: (_) {
                              if (state.canSave) {
                                _confirmAndSave(context, state.handle);
                              }
                            },
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          AppGradientButton(
                            label: 'Change handle',
                            busy: state.isSaving,
                            busySemanticsLabel: 'Saving',
                            onPressed: state.canSave
                                ? () => _confirmAndSave(context, state.handle)
                                : null,
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
}

/// The helper / error line under the handle field, a live region so the
/// availability answer is announced without moving focus.
class _FieldNote extends StatelessWidget {
  const _FieldNote({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isError
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final HandleCheckStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (status) {
      HandleCheckStatus.checking => Semantics(
        label: 'Checking availability',
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.sm + AppSpacing.xs),
          child: SizedBox(
            width: AppIconSize.sm,
            height: AppIconSize.sm,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      HandleCheckStatus.available => Semantics(
        label: 'Handle is available',
        child: Icon(Icons.check_circle_outline, color: colors.primary),
      ),
      HandleCheckStatus.unavailable => Semantics(
        label: 'Handle is not available',
        child: Icon(Icons.error_outline, color: colors.error),
      ),
      HandleCheckStatus.unknown => Semantics(
        label: 'Availability unknown',
        child: Icon(Icons.help_outline, color: colors.onSurfaceVariant),
      ),
      HandleCheckStatus.idle => const SizedBox.shrink(),
    };
  }
}
