import 'package:flutter/material.dart';

import '../../../../shared/widgets/primitives/app_pill_button.dart';
import 'list_unavailable_view.dart';

/// The Follow / Following toggle of a List (the `list_follows` flag is the
/// caller's to check). Follow is the strong compact pill and Following the
/// outlined one, like the Pin button; [onDark] draws it for the navy hero.
/// Disabled while a call is [busy] (spoken as such).
class ListFollowButton extends StatelessWidget {
  const ListFollowButton({
    super.key,
    required this.listName,
    required this.following,
    required this.busy,
    required this.onToggle,
    this.onDark = false,
  });

  final String listName;
  final bool following;
  final bool busy;
  final VoidCallback onToggle;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final label = following ? 'Following' : 'Follow';
    final Widget button;
    if (following && onDark) {
      button = OutlinedButton(
        style: kListOnDarkOutlinedButtonStyle,
        onPressed: busy ? null : onToggle,
        child: Text(label),
      );
    } else {
      button = AppPillButton(
        label: label,
        compact: true,
        variant: following
            ? AppButtonVariant.outline
            : AppButtonVariant.primary,
        onPressed: busy ? null : onToggle,
      );
    }
    return Semantics(
      container: true,
      label: following ? 'Following $listName. Unfollow.' : 'Follow $listName',
      excludeSemantics: true,
      button: true,
      enabled: !busy,
      onTap: busy ? null : onToggle,
      child: button,
    );
  }
}
