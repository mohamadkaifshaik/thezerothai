import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/primitives/app_section_header.dart';
import '../../../shared/widgets/primitives/app_skeleton.dart';
import '../../../shared/widgets/primitives/app_surface.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../beacons/domain/beacons_feature_flag.dart';
import '../../messages/domain/messaging_feature_gate.dart';
import '../../messages/presentation/widgets/messaging_access_builder.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../settings/presentation/settings_up.dart';
import '../data/notifications_repository.dart';
import '../domain/notification_prefs.dart';
import '../domain/notifications_feature_flag.dart';
import 'bloc/notification_prefs_cubit.dart';
import 'notification_settings_messages.dart';

/// Whether the push preferences can be used: `notifications` and
/// `notification_prefs` both on for the caller (the RPCs need both).
bool notificationPrefsEnabled(BuildContext context) =>
    isFeatureEnabled(context, kFeatureNotifications) &&
    isFeatureEnabled(context, kFeatureNotificationPrefs);

/// Settings > Notification settings (`/settings/notifications`, also the
/// Notifications gear). The router sends it to Settings unless
/// [notificationPrefsEnabled].
class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // The tablet layout with nothing to pop: up to Notifications.
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.notificationSettingsPath),
        ),
        title: const Text(kNotificationSettingsTitle),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
            child: const NotificationSettingsBody(),
          ),
        ),
      ),
    );
  }
}

/// The push switches (F6), one per group, as a scrolling list: the leaf page
/// and the tablet Notifications category both show it.
///
/// One `GetNotificationPrefs` when it opens (none while the flags are off).
/// Plans shows with `beacons` on, Messages while Messages is fully usable;
/// a hidden group keeps its stored value (every save sends all of them).
class NotificationSettingsBody extends StatelessWidget {
  const NotificationSettingsBody({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.read<NotificationsRepository?>();
    if (repository == null || !notificationPrefsEnabled(context)) {
      return const _Unavailable();
    }
    return BlocProvider<NotificationPrefsCubit>(
      create: (context) {
        final onboarding = context.read<OnboardingBloc>();
        final cubit = NotificationPrefsCubit(
          repository: repository,
          onFeatureDisabled: () =>
              onboarding.add(const OnboardingRefreshRequested()),
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocConsumer<NotificationPrefsCubit, NotificationPrefsState>(
        listenWhen: (before, after) =>
            after.error != null && before.serial != after.serial,
        listener: (context, state) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(notificationPrefsErrorMessage(state.error!)),
              ),
            );
        },
        builder: (context, state) => MessagingAccessBuilder(
          builder: (context, access) => _content(context, state, access),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    NotificationPrefsState state,
    MessagingAccess access,
  ) {
    final groups = [
      for (final group in NotificationPrefsGroup.values)
        if (switch (group) {
          NotificationPrefsGroup.plans => isFeatureEnabled(
            context,
            kFeatureBeacons,
          ),
          NotificationPrefsGroup.messages => access == MessagingAccess.full,
          _ => true,
        })
          group,
    ];
    final padding = EdgeInsets.only(
      top: AppSpacing.md,
      bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
    );
    final prefs = state.prefs;
    switch (state.status) {
      case NotificationPrefsStatus.unavailable:
        return const _Unavailable();
      case NotificationPrefsStatus.failed:
        return ListView(
          padding: padding,
          children: [
            AppErrorView(
              error: state.loadError!,
              onRetry: context.read<NotificationPrefsCubit>().load,
            ),
          ],
        );
      case NotificationPrefsStatus.loading:
      case NotificationPrefsStatus.ready:
        if (prefs == null) {
          return ListView(
            padding: padding,
            children: [_Placeholder(rows: groups.length)],
          );
        }
        final cubit = context.read<NotificationPrefsCubit>();
        return ListView(
          padding: padding,
          children: [
            SettingsGroup(
              title: kPushNotificationsHeader,
              rows: [
                for (final group in groups)
                  SettingsRow(
                    icon: _icon(group),
                    title: group.label,
                    subtitle: group.description,
                    // The server's value, also while a save runs (then
                    // every switch waits, disabled).
                    toggled: prefs.isOn(group),
                    onTap: state.saving != null
                        ? null
                        : () => cubit.setGroup(group, on: !prefs.isOn(group)),
                  ),
              ],
            ),
            const _Note(),
          ],
        );
    }
  }

  static IconData _icon(NotificationPrefsGroup group) => switch (group) {
    NotificationPrefsGroup.plans => Icons.event_outlined,
    NotificationPrefsGroup.mentionsReplies => Icons.alternate_email,
    NotificationPrefsGroup.likesReposts => Icons.favorite_border,
    NotificationPrefsGroup.followers => Icons.person_add_alt,
    NotificationPrefsGroup.messages => Icons.mail_outline,
  };
}

class _Note extends StatelessWidget {
  const _Note();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Text(
        kPushNotificationsNote,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The card while `GetNotificationPrefs` runs: the header and [rows] rows of
/// the same shape, so nothing jumps when the switches arrive.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.rows});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return AppSkeletonScope(
      semanticsLabel: 'Loading notification settings',
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppSectionHeader(title: kPushNotificationsHeader),
            AppSurface(
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Column(
                children: [
                  for (var i = 0; i < rows; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    const SizedBox(
                      height: AppSpacing.xxl + AppSpacing.sm,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                        ),
                        child: Row(
                          children: [
                            AppSkeletonBlock(
                              width: AppSpacing.xl + AppSpacing.sm,
                              height: AppSpacing.xl + AppSpacing.sm,
                              radius: AppRadius.md,
                            ),
                            SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: FractionallySizedBox(
                                alignment: AlignmentDirectional.centerStart,
                                widthFactor: 0.6,
                                child: AppSkeletonBlock(height: AppSpacing.md),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppSpacing.md),
    children: const [
      HeadlineMessage(
        title: kNotificationSettingsUnavailableTitle,
        body: kNotificationSettingsUnavailableBody,
      ),
    ],
  );
}
