import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_avatar.dart';

/// One participant (R12, the designs' PlanPeople): a 44 dp avatar, name,
/// @handle and, on a request row for the organiser, the note. The text area
/// is the tap target (>= 48dp) and speaks name, handle and note as one
/// label; [trailing] holds the organiser's menu and [footer] (a request's
/// Decline and Accept) sits under the row. Rows are split by a hairline.
class ParticipantRow extends StatelessWidget {
  const ParticipantRow({
    super.key,
    required this.participant,
    this.showNote = false,
    this.onTap,
    this.trailing,
    this.footer,
  });

  final pb.Participant participant;
  final bool showNote;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final u = participant.user;
    final name = u.displayName.isEmpty ? u.handle : u.displayName;
    final note = showNote ? participant.note : '';
    final spoken = [name, '@${u.handle}', if (note.isNotEmpty) note].join(', ');
    final row = Row(
      children: [
        Expanded(
          child: Semantics(
            button: onTap != null,
            label: spoken,
            excludeSemantics: true,
            onTap: onTap,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppAvatar(
                        url: u.avatarUrl,
                        name: name,
                        radius: AppSize.avatarRow / 2,
                      ),
                      const SizedBox(width: AppSpacing.smd),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              '@${u.handle}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: muted,
                              ),
                            ),
                            if (note.isNotEmpty) ...[
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                note,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: context.appColors.text2,
                                ),
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
          ),
        ),
        ?trailing,
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.appColors.hairline)),
      ),
      child: footer == null
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row,
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    0,
                    AppSpacing.md,
                    AppSpacing.smd,
                  ),
                  child: footer,
                ),
              ],
            ),
    );
  }
}
