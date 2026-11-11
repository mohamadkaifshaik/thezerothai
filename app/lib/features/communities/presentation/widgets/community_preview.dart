import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_section_header.dart';
import 'community_about.dart';

/// A rule of a community being created, as typed (trimmed); either part may
/// be empty.
@immutable
class CommunityDraftRule {
  const CommunityDraftRule({required this.title, required this.text});

  final String title;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is CommunityDraftRule && other.title == title && other.text == text;

  @override
  int get hashCode => Object.hash(title, text);
}

/// The create form as typed (trimmed), for its preview.
@immutable
class CommunityDraft {
  const CommunityDraft({
    this.name = '',
    this.description = '',
    this.rules = const [],
  });

  final String name;
  final String description;
  final List<CommunityDraftRule> rules;

  @override
  bool operator ==(Object other) =>
      other is CommunityDraft &&
      other.name == name &&
      other.description == description &&
      listEquals(other.rules, rules);

  @override
  int get hashCode => Object.hash(name, description, Object.hashAll(rules));
}

/// The placeholder of a draft with no name yet.
const kCommunityPreviewUnnamed = 'Your Community';

/// How a community being created will read (tablet plan section 4.1,
/// CreateCommunity): the name, the description and the numbered rules, as
/// the community's About shows them. Built from the form only: no count, no
/// role and no call. Shown in band B's context pane and, in band A, in the
/// header's Preview dialog.
class CommunityPreview extends StatelessWidget {
  const CommunityPreview({super.key, required this.draft});

  final CommunityDraft draft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final named = draft.name.isNotEmpty;
    final rules = [
      for (final r in draft.rules)
        if (r.title.isNotEmpty || r.text.isNotEmpty) r,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Text(
            named ? draft.name : kCommunityPreviewUnnamed,
            style: theme.textTheme.titleLarge?.copyWith(
              color: named ? null : muted,
            ),
          ),
        ),
        if (draft.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Text(draft.description, style: theme.textTheme.bodyLarge),
          ),
        const AppSectionHeader(title: 'Rules'),
        if (rules.isEmpty)
          const CommunityNoRules()
        else
          for (var i = 0; i < rules.length; i++)
            CommunityRuleRow(
              key: ValueKey('preview-rule-$i'),
              number: i + 1,
              title: rules[i].title,
              text: rules[i].text,
            ),
        const SizedBox(height: AppSpacing.sm),
      ],
    );
  }
}
