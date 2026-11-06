import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_avatar.dart';

/// One participant: avatar, name, @handle and, on a request row for the
/// organiser, the note. The text area is the tap target (>= 48dp) and speaks
/// name, handle and note as one label; [trailing] holds the organiser's
/// controls.
class ParticipantRow extends StatelessWidget {
  const ParticipantRow({
    super.key,
    required this.participant,
    this.showNote = false,
    this.onTap,
    this.trailing,
  });

  final pb.Participant participant;
  final bool showNote;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final u = participant.user;
    final name = u.displayName.isEmpty ? u.handle : u.displayName;
    final note = showNote ? participant.note : '';
    final spoken = [name, '@${u.handle}', if (note.isNotEmpty) note].join(', ');
    return Row(
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
                      AppAvatar(url: u.avatarUrl, radius: 20),
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
                              Text(note, style: theme.textTheme.bodyMedium),
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
  }
}
