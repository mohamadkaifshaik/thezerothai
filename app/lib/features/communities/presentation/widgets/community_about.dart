import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/primitives/app_section_header.dart';
import '../../../graph/presentation/widgets/user_list_row.dart';
import '../bloc/community_detail_state.dart';

/// The muted line of a community with no rules (the About tab and the create
/// preview).
const kCommunityNoRulesText = "This Community hasn't set any rules yet.";

/// The owner, then the moderators who are not the owner: the people the
/// About tab and the header's avatars show.
List<graph.UserListItem> communityModeratorsOf(CommunityDetailState state) {
  final owner = state.owner;
  return [
    if (owner != null && owner.user.userId.isNotEmpty) owner,
    ...state.moderators.where((m) => m.user.userId != owner?.user.userId),
  ];
}

/// The About tab of a community page as slivers: the description, the
/// numbered rules and the owner and moderators (`UserListRow`). Data comes
/// from the one `GetCommunity` already made: no extra RPC.
List<Widget> communityAboutSlivers(
  BuildContext context,
  CommunityDetailState state,
) {
  final theme = Theme.of(context);
  final description = state.community?.description ?? '';
  final people = communityModeratorsOf(state);
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
      const SliverToBoxAdapter(child: CommunityNoRules())
    else
      SliverList.builder(
        itemCount: state.rules.length,
        itemBuilder: (context, i) => CommunityRuleRow(
          key: ValueKey('rule-$i'),
          number: i + 1,
          title: state.rules[i].title,
          text: state.rules[i].text,
        ),
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

/// [kCommunityNoRulesText], muted, padded like a rule.
class CommunityNoRules extends StatelessWidget {
  const CommunityNoRules({super.key, this.inset = AppSpacing.md});

  /// The start and end padding (as [CommunityRuleRow.inset]).
  final double inset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset, vertical: AppSpacing.sm),
      child: Text(
        kCommunityNoRulesText,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One numbered rule: "N." then the bold title and the muted text, spoken as
/// "Rule N: title. text". Used by the About tab and the create preview.
///
/// A rule with no title (only the create preview has one: the server needs
/// a title) draws and speaks the text alone, "Rule N: text".
class CommunityRuleRow extends StatelessWidget {
  const CommunityRuleRow({
    super.key,
    required this.number,
    required this.title,
    required this.text,
    this.inset = AppSpacing.md,
  });

  final int number;
  final String title;
  final String text;

  /// The start and end padding (0 where the container pads already: the
  /// preview dialog).
  final double inset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final titled = title.isNotEmpty;
    return Semantics(
      label: titled ? 'Rule $number: $title. $text' : 'Rule $number: $text',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: inset,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: AppSpacing.lg,
              child: Text('$number.', style: theme.textTheme.titleSmall),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (titled) Text(title, style: theme.textTheme.titleSmall),
                  if (text.isNotEmpty) ...[
                    if (titled) const SizedBox(height: AppSpacing.xs),
                    Text(
                      text,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
