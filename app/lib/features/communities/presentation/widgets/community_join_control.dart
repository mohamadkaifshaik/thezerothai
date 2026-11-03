import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';

/// What [CommunityJoinControl] shows. The caller maps the server's
/// `viewer_role` (plus its own in-flight and refused-join state) to one of
/// these; the control derives no role.
enum CommunityJoinState { join, joined, banned }

/// The spoken and shown text for a banned viewer (the plan's wording).
const kCommunityBannedText = "You can't join this Community";

/// The one Join / Joined / Banned control of a community, shared by the
/// directory rows and the community header.
///
/// - [CommunityJoinState.join]: the strong "Join" pill.
/// - [CommunityJoinState.joined]: an outlined "Joined" pill; with [onLeave] it
///   is a button (the header's Leave), without it it is inert (a row whose
///   Join is still in flight, or a row that is not the place to leave).
/// - [CommunityJoinState.banned]: muted text, not a button. [compact] shortens
///   it to "Banned" for a row (the spoken label stays the full sentence).
///
/// [name] makes the spoken labels unique in a list ("Join Chess club").
class CommunityJoinControl extends StatelessWidget {
  const CommunityJoinControl({
    super.key,
    required this.state,
    required this.name,
    this.onJoin,
    this.onLeave,
    this.busy = false,
    this.compact = false,
  });

  final CommunityJoinState state;
  final String name;
  final VoidCallback? onJoin;
  final VoidCallback? onLeave;

  /// A call is in flight: the control ignores taps.
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (state) {
      case CommunityJoinState.join:
        final enabled = !busy && onJoin != null;
        return Semantics(
          button: true,
          enabled: enabled,
          label: 'Join $name',
          excludeSemantics: true,
          onTap: enabled ? onJoin : null,
          child: AppPillButton(
            label: 'Join',
            compact: true,
            onPressed: enabled ? onJoin : null,
          ),
        );
      case CommunityJoinState.joined:
        final tappable = onLeave != null && !busy;
        return Semantics(
          button: onLeave != null,
          enabled: tappable,
          label: onLeave != null ? 'Joined $name, leave' : 'Joined $name',
          excludeSemantics: true,
          onTap: tappable ? onLeave : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 88,
              minHeight: AppSpacing.minTapTarget,
            ),
            child: Center(
              widthFactor: 1,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(88, AppSize.pillCompact),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                  ),
                ),
                onPressed: tappable ? onLeave : null,
                child: const Text('Joined'),
              ),
            ),
          ),
        );
      case CommunityJoinState.banned:
        return Semantics(
          label: kCommunityBannedText,
          excludeSemantics: true,
          child: Text(
            compact ? 'Banned' : kCommunityBannedText,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
    }
  }
}
