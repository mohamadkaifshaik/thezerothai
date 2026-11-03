import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_section_header.dart';
import '../../../graph/presentation/widgets/user_list_row.dart';
import '../bloc/community_detail_state.dart';

/// The About tab of a community page as slivers: the description, the
/// numbered rules and the owner and moderators (`UserListRow`). Data comes
/// from the one `GetCommunity` already made: no extra RPC.
List<Widget> communityAboutSlivers(
  BuildContext context,
  CommunityDetailState state,
) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  final description = state.community?.description ?? '';
  final owner = state.owner;
  final people = [
    if (owner != null && owner.user.userId.isNotEmpty) owner,
    ...state.moderators.where((m) => m.user.userId != owner?.user.userId),
  ];
  return [
    if (description.isNotEmpty)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(description, style: theme.textTheme.bodyLarge),
        ),
      ),
    const SliverToBoxAdapter(child: AppSectionHeader(title: 'Rules')),
    if (state.rules.isEmpty)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            "This Community hasn't set any rules yet.",
            style: theme.textTheme.bodyLarge?.copyWith(color: muted),
          ),
        ),
      )
    else
      SliverList.builder(
        itemCount: state.rules.length,
        itemBuilder: (context, i) {
          final rule = state.rules[i];
          return Semantics(
            key: ValueKey('rule-$i'),
            label: 'Rule ${i + 1}: ${rule.title}. ${rule.text}',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: AppSpacing.lg,
                    child: Text('${i + 1}.', style: theme.textTheme.titleSmall),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rule.title, style: theme.textTheme.titleSmall),
                        if (rule.text.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            rule.text,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    if (people.isNotEmpty) ...[
      const SliverToBoxAdapter(child: AppSectionHeader(title: 'Moderators')),
      SliverList.builder(
        itemCount: people.length,
        itemBuilder: (context, i) => UserListRow(
          key: ValueKey('mod-${people[i].user.userId}'),
          item: people[i],
        ),
      ),
    ],
    const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
  ];
}
