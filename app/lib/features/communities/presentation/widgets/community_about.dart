import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/primitives/app_section_header.dart';
import '../../../graph/presentation/widgets/user_list_row.dart';
import '../bloc/community_detail_state.dart';

/// The muted line of a community with no rules (the About tab, the pane card
/// and the create preview).
const kCommunityNoRulesText = "This Community hasn't set any rules yet.";

/// The owner, then the moderators who are not the owner: the people the
/// About tab and the pane card list.
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
  const CommunityNoRules({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
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
/// "Rule N: title. text". Used by the About tab, the pane card and the create
/// preview.
class CommunityRuleRow extends StatelessWidget {
  const CommunityRuleRow({
    super.key,
    required this.number,
    required this.title,
    required this.text,
  });

  final int number;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      label: 'Rule $number: $title. $text',
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
              child: Text('$number.', style: theme.textTheme.titleSmall),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  if (text.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
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

/// Band B's context pane on a community page (tablet plan section 4.1,
/// Community: "Posts | rules, moderators, View moderation log"): the rules
/// card, the moderators card and, for the owner and moderators
/// ([onModerationLog]), "View moderation log". The page lends it over its own
/// state (`ContextPaneSlots`), so it adds no call. The About tab keeps the
/// same rules and moderators at every width (R-inline): the pane only adds a
/// second place.
///
/// Draws nothing until the community is known, and nothing when it is
/// unavailable (the page says so).
class CommunityAboutPane extends StatelessWidget {
  const CommunityAboutPane({
    super.key,
    required this.state,
    this.onModerationLog,
  });

  final CommunityDetailState state;
  final VoidCallback? onModerationLog;

  @override
  Widget build(BuildContext context) {
    if (state.community == null ||
        state.status == CommunityDetailStatus.unavailable) {
      return const SizedBox.shrink();
    }
    final people = communityModeratorsOf(state);
    final rules = state.rules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ContextPaneCard(
          title: 'Rules',
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: rules.isEmpty
                ? const CommunityNoRules()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < rules.length; i++)
                        CommunityRuleRow(
                          key: ValueKey('pane-rule-$i'),
                          number: i + 1,
                          title: rules[i].title,
                          text: rules[i].text,
                        ),
                    ],
                  ),
          ),
        ),
        if (people.isNotEmpty)
          ContextPaneCard(
            title: 'Moderators',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < people.length; i++)
                  UserListRow(
                    key: ValueKey('pane-mod-${people[i].user.userId}'),
                    item: people[i],
                    showDivider: i < people.length - 1,
                  ),
              ],
            ),
          ),
        if (onModerationLog != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(AppSpacing.minTapTarget),
              ),
              onPressed: onModerationLog,
              icon: const Icon(Icons.shield_outlined, size: AppIconSize.md),
              label: const Text('View moderation log'),
            ),
          ),
      ],
    );
  }
}
