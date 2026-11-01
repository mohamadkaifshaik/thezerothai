import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;

/// The one context line above a post: a muted icon in the avatar column and
/// muted text (W5-33, `communities.md` §3). There is exactly one row per post,
/// so a caller picks the variant: [PostContextLabel.repost] wins over
/// [PostContextLabel.community]. Later labels (Pinned, W3-17) add a named
/// constructor here rather than a second row.
///
/// Display only: 0 RPCs. [onTap] is non-null only for a tappable variant.
class PostContextLabel extends StatelessWidget {
  const PostContextLabel({
    super.key,
    required this.icon,
    required this.text,
    this.semanticsLabel,
    this.onTap,
    this.trailing,
  });

  /// 'name reposted' (the viewer's own reads "You reposted").
  factory PostContextLabel.repost({
    Key? key,
    required common.AuthorSnapshot reposter,
    required bool isOwn,
    Widget? trailing,
  }) => PostContextLabel(
    key: key,
    icon: Icons.repeat,
    text: repostedByLabel(reposter, isOwn),
    trailing: trailing,
  );

  /// the community name with a people icon. Tappable only with [onTap].
  factory PostContextLabel.community({
    Key? key,
    required String name,
    VoidCallback? onTap,
    Widget? trailing,
  }) => PostContextLabel(
    key: key,
    icon: Icons.people_outline,
    text: name,
    // The article label starts with the community name (communities.md §4).
    semanticsLabel: name,
    onTap: onTap,
    trailing: trailing,
  );

  final IconData icon;
  final String text;
  final String? semanticsLabel;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final tappable = onTap != null;
    final content = Row(
      children: [
        SizedBox(
          width: AppSpacing.minTapTarget,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Icon(icon, size: AppIconSize.sm, color: muted),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
    final label = Semantics(
      container: true,
      button: tappable,
      label: semanticsLabel ?? text,
      excludeSemantics: true,
      child: tappable
          ? InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: content,
                ),
              ),
            )
          : content,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: trailing == null
          ? label
          : Row(
              children: [
                Expanded(child: label),
                trailing!,
              ],
            ),
    );
  }
}

/// 'name reposted', or "You reposted" for the viewer's own repost.
String repostedByLabel(common.AuthorSnapshot reposter, bool isOwn) {
  if (isOwn) return 'You reposted';
  final name = reposter.displayName.isEmpty
      ? '@${reposter.handle}'
      : reposter.displayName;
  return '$name reposted';
}
