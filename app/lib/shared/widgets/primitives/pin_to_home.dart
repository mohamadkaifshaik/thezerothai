import 'package:flutter/material.dart';

import '../../../features/lists/domain/lists_feature_flag.dart'
    show kMaxPinnedHomeTabs;
import '../../../features/lists/presentation/widgets/list_unavailable_view.dart'
    show kListOnDarkOutlinedButtonStyle, kListOutlinedButtonStyle;
import 'app_pill_button.dart';

/// The "Pin to Home" / "Unpin from Home" button of a List or Community page.
/// Pin is the strong compact pill, disabled at the cap, while
/// the write is unavailable or in flight; Unpin is an outlined button. Pair it
/// with [pinToHomeHint] under the row.
class PinToHomeButton extends StatelessWidget {
  const PinToHomeButton({
    super.key,
    required this.pinned,
    required this.full,
    required this.writeUnavailable,
    required this.busy,
    required this.onToggle,
    this.onDark = false,
  });

  final bool pinned;

  /// [kMaxPinnedHomeTabs] timelines are already pinned.
  final bool full;
  final bool writeUnavailable;
  final bool busy;
  final VoidCallback onToggle;

  /// Draws Unpin for a navy surface (the List hero) instead of the page.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    if (pinned) {
      return OutlinedButton(
        style: onDark
            ? kListOnDarkOutlinedButtonStyle
            : kListOutlinedButtonStyle,
        onPressed: busy ? null : onToggle,
        child: const Text('Unpin from Home'),
      );
    }
    return AppPillButton(
      label: 'Pin to Home',
      compact: true,
      onPressed: full || writeUnavailable || busy ? null : onToggle,
    );
  }
}

/// Why Pin is disabled (cap reached, or the server cannot save tabs yet); null
/// when pinned or when there is nothing to say.
String? pinToHomeHint({
  required bool pinned,
  required bool full,
  required bool writeUnavailable,
}) {
  if (pinned) return null;
  if (full) {
    return 'You can pin up to $kMaxPinnedHomeTabs timelines to Home. Unpin '
        'one first.';
  }
  if (writeUnavailable) return "Pinning isn't available yet.";
  return null;
}
