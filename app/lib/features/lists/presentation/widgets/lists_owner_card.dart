import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_surface.dart';
import '../../../../shared/widgets/user/user_list_skeleton.dart';

/// [ListsOwnerCard] until a person's Lists page has lent it (or while the
/// Lists load): the same outlined card over a one-row skeleton.
class ListsOwnerCardPlaceholder extends StatelessWidget {
  const ListsOwnerCardPlaceholder({super.key});

  @override
  Widget build(BuildContext context) => const AppSurface(
    margin: EdgeInsets.only(bottom: AppSpacing.md),
    padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: UserListSkeleton(rows: 1, semanticsLabel: 'Loading the owner'),
  );
}

/// The owner of the Lists on `/u/:id/lists` (tablet plan section 4.1,
/// UserLists: "owner card" inline in band A's header, in the pane in band B;
/// T8b): avatar, name and @handle from the owner snapshot every
/// `ListUserLists` answer carries (no call of its own). The whole card is one
/// 48 dp button that opens the profile.
class ListsOwnerCard extends StatelessWidget {
  const ListsOwnerCard({
    super.key,
    required this.owner,
    required this.onTap,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
  });

  final common.AuthorSnapshot owner;
  final VoidCallback onTap;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = owner.displayName.trim();
    return AppSurface(
      margin: margin,
      padding: EdgeInsets.zero,
      child: Semantics(
        button: true,
        label:
            'Lists by ${name.isEmpty ? '' : '$name, '}@${owner.handle}. '
            'View profile',
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.cardSmall),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    AppAvatar(url: owner.avatarUrl, radius: AppSpacing.lg),
                    const SizedBox(width: AppSpacing.smd),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (name.isNotEmpty)
                            Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          Text(
                            '@${owner.handle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Directionality.of(context) == TextDirection.rtl
                          ? Icons.chevron_left
                          : Icons.chevron_right,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
