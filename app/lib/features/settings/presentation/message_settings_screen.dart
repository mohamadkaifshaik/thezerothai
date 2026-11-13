import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../messages/presentation/widgets/messaging_access_builder.dart';
import '../../messages/domain/messaging_feature_gate.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../onboarding/presentation/bloc/onboarding_state.dart';
import '../domain/message_privacy.dart';
import 'bloc/message_privacy_cubit.dart';
import 'message_settings_messages.dart';
import 'settings_up.dart';
import 'widgets/message_privacy_rows.dart';

/// Settings > Message settings (`/settings/messages`, also the Messages
/// gear): "Who can message you" (F9) and "Read receipts" (F3), each shown by
/// its own rule (flag, or the undo rule while it is set). With neither, a
/// "not available" line. 0 RPCs to open: the values are the server's answer
/// already in [MessagePrivacyScope]'s store.
class MessageSettingsScreen extends StatelessWidget {
  const MessageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // The tablet layout with nothing to pop: up to Privacy & safety.
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.messageSettingsPath),
        ),
        title: const Text(kMessageSettingsTitle),
      ),
      body: SafeArea(
        // The floating bar overlays the page: the content scrolls behind it and
        // ends with the bar's inset.
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            // 680 on the tablet layout (the readable column), else 600.
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: MessagePrivacyScope(
              child: MessagingAccessBuilder(
                builder: (context, access) => _body(context, access),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, MessagingAccess access) {
    final messagingOn = access == MessagingAccess.full;
    final visible = MessagePrivacyVisibility.of(
      context,
      messagingOn: messagingOn,
    );
    if (!visible.any) {
      // A flag is on but this session has no server answer yet (a refresh
      // running, or failed): a placeholder or the error, never "not
      // available" (R4 review UX 2).
      final flagOn =
          isFeatureEnabled(context, kFeatureReadReceipts) ||
          isFeatureEnabled(context, kFeatureDmPolicy);
      final waiting =
          context.select<MessagePrivacyCubit?, bool>(
            (cubit) => cubit != null && cubit.state.confirmed == null,
          ) &&
          flagOn;
      if (waiting) {
        final onboarding = context.watch<OnboardingBloc>().state;
        final failed =
            onboarding.refreshFailed ||
            onboarding.status == OnboardingStatus.error;
        return ListView(
          padding: EdgeInsets.only(
            top: AppSpacing.md,
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            if (failed)
              AppErrorView(
                error:
                    onboarding.error ??
                    const NetworkException("Couldn't load your settings."),
                onRetry: () => context.read<OnboardingBloc>().add(
                  const OnboardingRefreshRequested(),
                ),
              )
            else
              const SettingsGroupPlaceholder(
                rows: 2,
                semanticsLabel: kMessageSettingsLoading,
              ),
          ],
        );
      }
      return ListView(
        padding:
            const EdgeInsets.all(AppSpacing.md) + shellBottomInsets(context),
        children: const [
          HeadlineMessage(
            title: kMessageSettingsUnavailableTitle,
            body: kMessageSettingsUnavailableBody,
          ),
        ],
      );
    }
    final followingAllowed =
        messagingOn && isFeatureEnabled(context, kFeatureDmPolicy);
    return ListView(
      padding: EdgeInsets.only(
        top: AppSpacing.md,
        bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        SettingsGroup(
          rows: [
            if (visible.whoCanMessage)
              WhoCanMessageRow(followingAllowed: followingAllowed),
            if (visible.readReceipts) const ReadReceiptsRow(),
          ],
        ),
      ],
    );
  }
}
