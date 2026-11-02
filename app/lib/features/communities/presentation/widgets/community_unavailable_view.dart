import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';

/// "This Community is unavailable" (W5-32): the one calm state for a community
/// the server answers NOT_FOUND for. The server uses the same answer for a
/// missing, suspended and hidden community, so the text never says which.
/// [onUnpin] adds an "Unpin from Home" button (a pinned community the user can
/// no longer open); [busy] disables it while the unpin is saved.
class CommunityUnavailableView extends StatelessWidget {
  const CommunityUnavailableView({super.key, this.onUnpin, this.busy = false});

  final VoidCallback? onUnpin;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AppEmptyView(
      icon: Icons.groups_outlined,
      title: 'This Community is unavailable',
      subtitle: "You can't view this Community right now.",
      action: onUnpin == null
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
              ),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(88, AppSpacing.minTapTarget),
                ),
                onPressed: busy ? null : onUnpin,
                child: const Text('Unpin from Home'),
              ),
            ),
    );
  }
}
