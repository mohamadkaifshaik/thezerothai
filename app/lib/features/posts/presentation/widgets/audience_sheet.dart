import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pbc;
import '../../../../shared/widgets/primitives/sheet_option_row.dart';
import '../../../communities/presentation/widgets/community_row.dart';
import '../../domain/compose_audience.dart';

/// "Choose audience" (W5-34, `composer.md` §3): `Everyone`, then a "My
/// Communities" section with one row per community the caller is in (name,
/// "N members"). Picking one closes the sheet and returns it; dismissing
/// returns null. A bottom sheet at every width, like the "Who can reply?"
/// sheet. Every row is a `menuItem`, the chosen one marked selected and with
/// a check.
Future<ComposeAudience?> showAudienceSheet(
  BuildContext context, {
  required ComposeAudience selected,
  required List<pbc.Community> communities,
}) {
  return showModalBottomSheet<ComposeAudience>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => AudienceSheet(selected: selected, communities: communities),
  );
}

class AudienceSheet extends StatelessWidget {
  const AudienceSheet({
    super.key,
    required this.selected,
    required this.communities,
  });

  final ComposeAudience selected;
  final List<pbc.Community> communities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    Widget check() => Icon(Icons.check, size: AppIconSize.lg, color: accent);
    // Title, Everyone, the section label, then the communities (at most 50).
    const fixed = 3;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        // The rows are `menuItem`s, which need a `menu` above them.
        child: Semantics(
          role: SemanticsRole.menu,
          explicitChildNodes: true,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: fixed + communities.length,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    0,
                    AppSpacing.md,
                    AppSpacing.sm,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Choose audience',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                );
              }
              if (index == 1) {
                final isSelected = !selected.isCommunity;
                return SheetOptionRow(
                  icon: Icons.public,
                  label: ComposeAudience.everyone.label,
                  selected: isSelected,
                  role: SemanticsRole.menuItem,
                  onTap: () =>
                      Navigator.of(context).pop(ComposeAudience.everyone),
                  trailing: isSelected ? check() : null,
                );
              }
              if (index == 2) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.md,
                    AppSpacing.xs,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(
                      'My Communities',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              }
              final community = communities[index - fixed];
              final isSelected = selected.communityId == community.communityId;
              return CommunityRow(
                key: ValueKey(community.communityId),
                community: community,
                role: SemanticsRole.menuItem,
                selected: isSelected,
                onTap: () =>
                    Navigator.of(context).pop(community.composeAudience),
                trailing: isSelected ? check() : null,
              );
            },
          ),
        ),
      ),
    );
  }
}
