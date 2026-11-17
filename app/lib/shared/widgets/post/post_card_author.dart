part of 'post_card.dart';

/// The display name, then the verified and protected badges.
List<Widget> _nameWithBadges(
  ThemeData theme, {
  required String displayName,
  required bool verified,
  required bool protected,
  TextStyle? style,
}) => [
  Flexible(
    child: Text(
      displayName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style ?? theme.textTheme.titleSmall,
    ),
  ),
  if (verified) ...[
    const SizedBox(width: AppSpacing.xs),
    Icon(
      Icons.verified,
      size: AppIconSize.sm,
      color: theme.colorScheme.primary,
    ),
  ],
  if (protected) ...[
    const SizedBox(width: AppSpacing.xs),
    const ProtectedBadge(),
  ],
];

/// The opened post's author: the name (and badges) over the handle, with no
/// relative time (the full time sits under the post).
class _FocalAuthorLines extends StatelessWidget {
  const _FocalAuthorLines({
    required this.displayName,
    required this.handle,
    required this.verified,
    required this.protected,
  });

  final String displayName;
  final String? handle;
  final bool verified;
  final bool protected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: _nameWithBadges(
            theme,
            displayName: displayName,
            verified: verified,
            protected: protected,
            // The PostDetail designs' 16 sp name.
            style: theme.textTheme.titleSmall?.copyWith(fontSize: 16),
          ),
        ),
        if (handle != null)
          Text(
            '@$handle',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _AuthorLine extends StatelessWidget {
  const _AuthorLine({
    required this.displayName,
    required this.handle,
    required this.verified,
    required this.time,
    this.protected = false,
  });

  final String displayName;
  final String? handle;
  final bool verified;
  final bool protected;
  final String time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        ..._nameWithBadges(
          theme,
          displayName: displayName,
          verified: verified,
          protected: protected,
        ),
        if (handle != null) ...[
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              '@$handle',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ),
        ],
        if (time.isNotEmpty) ...[
          Text(
            ' · ',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
          Text(
            time,
            maxLines: 1,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ],
      ],
    );
  }
}
