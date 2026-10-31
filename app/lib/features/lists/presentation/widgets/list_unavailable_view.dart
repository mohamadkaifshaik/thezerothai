import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_empty_view.dart';

/// "This List is unavailable" (W5-12): the one calm state for a List the
/// server answers NOT_FOUND for. The server uses the same answer for private,
/// deleted, hidden and blocked, so the text never says which. [onUnpin] adds
/// an "Unpin from Home" button (a pinned List the user can no longer open);
/// [busy] disables it while the unpin is saved. Shared by the List detail and
/// the Home tab (W5-14).
class ListUnavailableView extends StatelessWidget {
  const ListUnavailableView({super.key, this.onUnpin, this.busy = false});

  final VoidCallback? onUnpin;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AppEmptyView(
      icon: Icons.list_alt_outlined,
      title: 'This List is unavailable',
      subtitle: "You can't view this List right now.",
      action: onUnpin == null
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
              ),
              child: OutlinedButton(
                style: kListOutlinedButtonStyle,
                onPressed: busy ? null : onUnpin,
                child: const Text('Unpin from Home'),
              ),
            ),
    );
  }
}

/// The theme's outlined button is full width (`Size.fromHeight`); in a `Wrap`
/// or a centred column it needs a finite minimum.
final ButtonStyle kListOutlinedButtonStyle = OutlinedButton.styleFrom(
  minimumSize: const Size(88, AppSpacing.minTapTarget),
);
