import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
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
    final uid = context.select((AuthBloc bloc) => bloc.state.user?.uid);
    if (repository == null ||
        uid == null ||
        uid.isEmpty ||
        !notificationPrefsEnabled(context)) {
      return const _Unavailable();
    }
    return BlocProvider<NotificationPrefsCubit>(
      // One cubit per account (security review M1): a switch of account
      // with the page open builds a fresh one that loads the new account's
      // values; the old one's answers and saves are dropped.
      key: ValueKey(uid),
      create: (context) {
        final onboarding = context.read<OnboardingBloc>();
        final auth = context.read<AuthBloc>();
        final cubit = NotificationPrefsCubit(
          repository: repository,
          uid: uid,
          currentUid: () => auth.state.user?.uid,
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
            children: [
              SettingsGroupPlaceholder(
                title: kPushNotificationsHeader,
                rows: groups.length,
                semanticsLabel: 'Loading notification settings',
              ),
            ],
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
                    subtitleMaxLines: null,
                    // The server's value, also while a save runs (then
                    // every switch waits, disabled; the one being saved
                    // shows progress).
                    toggled: prefs.isOn(group),
                    busy: state.saving == group,
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
