import 'package:material_ui/material_ui.dart';

import '../../../../shared/widgets/user/follow_pill.dart';

/// The Follow / Following toggle of a List (the `list_follows` flag is the
/// caller's to check): the x.com [FollowPill] (Following turns into a red
/// "Unfollow" on hover); [onDark] draws it for the navy hero. Disabled while
/// a call is [busy] (spoken as such).
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
    final button = FollowPill(
      label: label,
      hoverLabel: following ? 'Unfollow' : null,
      style: following ? FollowPillStyle.outlined : FollowPillStyle.filled,
      onDark: onDark,
      busy: busy,
      onPressed: busy ? null : onToggle,
    );
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
