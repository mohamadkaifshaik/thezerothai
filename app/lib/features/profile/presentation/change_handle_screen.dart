import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/domain/handle_rules.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../onboarding/presentation/bloc/onboarding_state.dart'
    show HandleCheckStatus;
import 'bloc/change_handle_cubit.dart';
import 'profile_edit_error_messages.dart';

/// Settings -> Change handle (`/settings/handle`, only reachable with the
/// `profile_snapshot` flag on). Live availability check, a confirmation that
/// states the 7-day cooldown, then ChangeHandle; success lands on the
/// caller's profile under the new handle (the old one is free for others).
class ChangeHandleScreen extends StatelessWidget {
  const ChangeHandleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final handle = context.read<OnboardingBloc>().state.profile?.handle ?? '';
    return BlocProvider<ChangeHandleCubit>(
      create: (context) => ChangeHandleCubit(
        identityRepository: context.read<IdentityRepository>(),
        currentHandle: handle,
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
        final helper = state.checkMessage.isEmpty
            ? kHandleFormatMessage
            : state.checkMessage;
        return Scaffold(
          appBar: AppBar(title: const Text('Change handle')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.mobile,
                ),
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
                        helperText: unavailable ? null : helper,
                        helperMaxLines: 2,
                        errorText: unavailable ? helper : null,
                        errorMaxLines: 2,
                        suffixIcon: _StatusIcon(status: state.checkStatus),
                      ),
                      onChanged: cubit.handleChanged,
                      onSubmitted: (_) {
                        if (state.canSave) {
                          _confirmAndSave(context, state.handle);
                        }
                      },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, AppSpacing.minTapTarget),
                      ),
                      onPressed: state.canSave
                          ? () => _confirmAndSave(context, state.handle)
                          : null,
                      child: state.isSaving
                          ? const SizedBox(
                              width: AppIconSize.md,
                              height: AppIconSize.md,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Change handle'),
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
