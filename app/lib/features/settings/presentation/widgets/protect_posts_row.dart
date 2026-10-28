import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../onboarding/presentation/bloc/onboarding_event.dart';
import '../bloc/protect_posts_cubit.dart';
import '../protect_posts_messages.dart';
import '../../../../shared/widgets/settings_group.dart';

/// The "Protect your posts" switch of Settings > Privacy & safety (W3-33b).
///
/// Needs a [ProtectPostsCubit] above it (the Settings list provides one only
/// when the row can show: `private_accounts` on, or the caller is already
/// protected - the undo rule). It does not toggle optimistically: a tap opens
/// the confirm dialog, then the switch shows the value being saved until the
/// server answers, and falls back to the profile's value on failure with a
/// typed snackbar.
class ProtectPostsRow extends StatelessWidget {
  const ProtectPostsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final isPrivate = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.isPrivate ?? false,
    );
    return BlocConsumer<ProtectPostsCubit, ProtectPostsState>(
      listenWhen: (before, after) =>
          after.error != null && before.serial != after.serial,
      listener: (context, state) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(protectPostsErrorMessage(state.error!))),
          );
        // The flag turned off since GetMe listed it: refresh it (0 extra
        // reads) so every other surface follows.
        if (state.refused) {
          context.read<OnboardingBloc>().add(
            const OnboardingRefreshRequested(),
          );
        }
      },
      builder: (context, state) {
        // Hidden (turn-on only) after the server said the flag is off.
        if (state.refused && !isPrivate) return const SizedBox.shrink();
        final value = state.saving ?? isPrivate;
        return SettingsRow(
          icon: Icons.lock_outline,
          title: kProtectPostsTitle,
          subtitle: kProtectPostsSubtitle,
          toggled: value,
          onTap: state.saving != null
              ? null
              : () => _toggle(context, turnOn: !isPrivate),
        );
      },
    );
  }

  Future<void> _toggle(BuildContext context, {required bool turnOn}) async {
    final cubit = context.read<ProtectPostsCubit>();
    final confirmed = await showProtectPostsConfirm(context, turnOn: turnOn);
    if (confirmed != true) return;
    await cubit.setProtected(protect: turnOn);
  }
}

/// The confirm dialog before a protection change: [turnOn] lists what
/// protecting does (including that images already shared may still open from
/// their link, founder answer B1); off says pending requests get approved.
/// Resolves true when confirmed.
Future<bool?> showProtectPostsConfirm(
  BuildContext context, {
  required bool turnOn,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text(turnOn ? kProtectConfirmTitle : kUnprotectConfirmTitle),
        content: SingleChildScrollView(
          child: turnOn
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final point in kProtectConfirmPoints)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Text(point, style: theme.textTheme.bodyMedium),
                      ),
                  ],
                )
              : const Text(kUnprotectConfirmBody),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              turnOn ? kProtectConfirmAction : kUnprotectConfirmAction,
            ),
          ),
        ],
      );
    },
  );
}
