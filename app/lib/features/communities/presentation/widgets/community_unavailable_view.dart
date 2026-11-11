import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';

/// "This community is unavailable": the one calm state for a community
/// the server answers NOT_FOUND for. The server uses the same answer for a
/// missing, suspended and hidden community, so the text never says which.
/// [onUnpin] adds an "Unpin from Home" button (a pinned community the user can
/// no longer open); [busy] disables it while the unpin is saved.
///
/// Drawn as States-Unavailable.dc.html `#un-community`: a 40 dp muted icon,
/// a 17 sp w800 title, a 14 sp w500 muted sentence (line height 1.45) and an
/// outline pill, centred, with 10 dp between them.
class CommunityUnavailableView extends StatelessWidget {
  const CommunityUnavailableView({super.key, this.onUnpin, this.busy = false});

  final VoidCallback? onUnpin;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.groups_outlined,
              size: AppIconSize.xl,
              color: muted,
            ),
          ),
          const SizedBox(height: 10),
          Semantics(
            header: true,
            child: Text(
              'This community is unavailable',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(fontSize: 17),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "You can't view this community right now.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: muted,
              height: 1.45,
            ),
          ),
          if (onUnpin != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppPillButton(
              label: 'Unpin from Home',
              variant: AppButtonVariant.outline,
              onPressed: busy ? null : onUnpin,
            ),
          ],
        ],
      ),
    );
  }
}
