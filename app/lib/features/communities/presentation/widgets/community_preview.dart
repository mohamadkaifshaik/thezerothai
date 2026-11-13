import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../lists/presentation/widgets/list_row.dart'
    show listMemberCountLabel;
import '../../domain/community_role.dart';
import 'community_about.dart';
import 'community_header.dart' show communityNameStyle;
import 'community_row.dart' show communityRoleBadge;

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

/// The title of the preview dialog.
const kCommunityPreviewTitle = 'Preview';

/// The role and count a new community starts with: the server makes the
/// creator its owner and only member (`CreateCommunity`).
final kCommunityPreviewStanding =
    '${communityRoleBadge(CommunityRole.owner)} · ${listMemberCountLabel(1)}';

/// How a community being created will read (tablet plan section 4.1,
/// CreateCommunity): the name (bold, as the community's header), the
/// creator's standing ("Owner · 1 member"), the description and the
/// numbered rules under a "Rules" heading. Built from the form only: no
/// call. Shown in the header's Preview dialog.
class CommunityPreview extends StatelessWidget {
  const CommunityPreview({
    super.key,
    required this.draft,
    this.inset = AppSpacing.md,
  });

  final CommunityDraft draft;

  /// The start and end padding of every line: 0 where the container pads
  /// already (the dialog), so the preview lines up with the title above it.
  final double inset;

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
          padding: EdgeInsets.fromLTRB(inset, AppSpacing.sm, inset, 0),
          child: Text(
            named ? draft.name : kCommunityPreviewUnnamed,
            // The page header's own name style (R10), so the preview
            // matches the page it previews.
            style: communityNameStyle(theme)
                ?.copyWith(color: named ? null : muted),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            inset,
            AppSpacing.xs,
            inset,
            AppSpacing.sm,
          ),
          child: Text(
            kCommunityPreviewStanding,
            // The header's count line: 14 w700 in the accent text colour.
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: context.appColors.accentText,
            ),
          ),
        ),
        if (draft.description.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, AppSpacing.sm),
            // As the header draws it: 14 w500 in text2, 2 lines at most.
            child: Text(
              draft.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: context.appColors.text2,
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(inset, AppSpacing.sm, inset, 0),
          child: Semantics(
            header: true,
            child: Text('Rules', style: theme.textTheme.titleSmall),
          ),
        ),
        if (rules.isEmpty)
          CommunityNoRules(inset: inset)
        else
          for (var i = 0; i < rules.length; i++)
            CommunityRuleRow(
              key: ValueKey('preview-rule-$i'),
              number: i + 1,
              title: rules[i].title,
              text: rules[i].text,
              inset: inset,
            ),
        const SizedBox(height: AppSpacing.sm),
      ],
    );
  }
}
