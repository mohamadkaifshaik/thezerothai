import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../../../shared/widgets/app_tile_icon.dart';

/// "1 member" / "N members" (plain digits, no compact form: a list holds at
/// most 150).
String listMemberCountLabel(int count) =>
    count == 1 ? '1 member' : '$count members';

/// One List in "Your Lists" (W5-11): the default tile, a bold name with a
/// muted "· N members", and a lock icon when private. A custom row (no
/// `ListTile`); the whole row is the tap target (>= 48dp). [onEdit] adds a
/// trailing Edit button for the owner. Reused by W5-13 for "a user's lists"
/// (without [onEdit]) and, with [checked] and [checkTrailing], for the
/// checkbox rows of the Add-to-Lists sheet.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.list,
    this.onTap,
    this.onEdit,
    this.checked,
    this.checkTrailing,
    this.enabled = true,
  });

  final pb.ListInfo list;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;

  /// Non-null makes the row a checkbox (spoken as checked or not) instead of a
  /// button; [checkTrailing] is the box (or a spinner) at the end of the row.
  final bool? checked;
  final Widget? checkTrailing;

  /// False while the row's action is in flight (spoken as disabled).
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final members = listMemberCountLabel(list.memberCount);
    final spoken = [
      list.name,
      members,
      if (list.isPrivate) 'private',
    ].join(', ');
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: checked == null && onTap != null,
            checked: checked,
            enabled: enabled,
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
                    vertical: AppSpacing.smd,
                  ),
                  child: Row(
                    children: [
                      const AppTileIcon(icon: Icons.list_alt_outlined),
                      const SizedBox(width: AppSpacing.smd),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: list.name,
                                style: theme.textTheme.titleMedium,
                              ),
                              TextSpan(
                                text: ' · $members',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: muted,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (list.isPrivate) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Icon(
                          Icons.lock_outline,
                          size: AppIconSize.md,
                          color: muted,
                        ),
                      ],
                      if (checkTrailing != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        checkTrailing!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (onEdit != null)
          IconButton(
            tooltip: 'Edit ${list.name}',
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit,
          ),
      ],
    );
  }
}
