import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../../shared/widgets/primitives/settings_group.dart';
import '../../../messages/domain/e2ee/encrypted_messaging.dart';
import '../../../messages/presentation/e2ee/encryption_copy.dart';

/// One of the user's own devices (R4, K5, R17). Shows dates and differences only: never an id, a key or a code.
///
/// - This device: [kDeviceThisTitle] and "Added {date}" (or [kDeviceNotSetUp] when it is neither in the directory
///   nor in a conversation); no Remove (signing out removes it).
/// - Another device: "Device added {date}" and "Last active {relative}", or [kDeviceInactive] (not used, never
///   "removed", still removable).
/// - In conversations but not in the directory: a danger pill and a note; no Remove (the pipeline removes it).
/// - In the directory but in no conversation: a neutral pill.
/// Remove is a separate 48 dp button, shown when [onRemove] is set; [removing] swaps it for a progress indicator.
class OwnDeviceRow extends StatelessWidget {
  const OwnDeviceRow({
    super.key,
    required this.device,
    required this.now,
    this.onRemove,
    this.removing = false,
  });

  final OwnDevice device;
  final DateTime now;
  final VoidCallback? onRemove;
  final bool removing;

  static String _date(DateTime at) => DateFormat.yMMMd().format(at.toLocal());

  @override
  Widget build(BuildContext context) {
    final addedAt = device.addedAt;
    final date = addedAt == null ? '' : _date(addedAt);
    final unlisted = !device.inDirectory && device.inConversations;
    final notJoined = device.inDirectory && !device.inConversations;
    final String title;
    final String? subtitle;
    if (device.thisDevice) {
      title = kDeviceThisTitle;
      subtitle = !device.inDirectory && !device.inConversations
          ? kDeviceNotSetUp
          : (addedAt == null ? null : deviceAddedSubtitle(date));
    } else {
      title = addedAt == null ? kDeviceUnknownDate : deviceAddedTitle(date);
      final lastSeen = device.lastSeenAt;
      subtitle = device.inactive
          ? kDeviceInactive
          : (lastSeen == null
                ? null
                : deviceLastActive(formatRelativeTimeSpoken(lastSeen, now)));
    }
    final pill = unlisted
        ? const AppStatusPill(
            label: kDeviceUnlistedPill,
            tone: AppStatusTone.danger,
          )
        : notJoined
        ? const AppStatusPill(label: kDeviceNotJoinedPill)
        : null;
    final canRemove = onRemove != null || removing;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SettingsRow(
                icon: device.thisDevice
                    ? Icons.smartphone_outlined
                    : Icons.devices_other_outlined,
                title: title,
                subtitle: subtitle,
                subtitleMaxLines: null,
                value: pill,
              ),
            ),
            if (canRemove)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
                child: removing
                    ? Semantics(
                        label: deviceRemoveLabel(date),
                        liveRegion: true,
                        child: const SizedBox(
                          width: AppSpacing.xxl,
                          height: AppSpacing.xxl,
                          child: Center(
                            child: SizedBox(
                              width: SettingsRow.busySize,
                              height: SettingsRow.busySize,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      )
                    : Semantics(
                        container: true,
                        button: true,
                        label: deviceRemoveLabel(date),
                        excludeSemantics: true,
                        onTap: onRemove,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: AppSpacing.xxl,
                            minHeight: AppSpacing.xxl,
                          ),
                          child: TextButton(
                            onPressed: onRemove,
                            child: const Text(kDeviceRemoveAction),
                          ),
                        ),
                      ),
              ),
          ],
        ),
        if (unlisted)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Text(
              kDeviceUnlistedNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
