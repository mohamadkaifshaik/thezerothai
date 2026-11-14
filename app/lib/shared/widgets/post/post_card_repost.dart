part of 'post_card.dart';

/// A REPOST whose original cannot be shown (blocked / muted author, or
/// already tombstoned): the "X reposted" line over a placeholder box, with
/// nothing from the snapshot.
class _RepostPlaceholder extends StatelessWidget {
  const _RepostPlaceholder({
    required this.reposter,
    required this.isOwn,
    required this.placeholder,
    required this.original,
    required this.menu,
    this.onUndo,
  });

  final common.AuthorSnapshot reposter;
  final bool isOwn;
  final EmbedPlaceholder placeholder;

  /// The original's author: shown only for the protected placeholder.
  final common.AuthorSnapshot original;

  /// Actions on the repost itself (the hidden original gets none).
  final Widget menu;

  /// Undo repost on the caller's own protected REPOST; null: none.
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final gutter = postCardGutterOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        AppSpacing.sm,
        gutter,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PostContextLabel.repost(
            reposter: reposter,
            isOwn: isOwn,
            trailing: menu,
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: kPostAvatarInset),
            child: placeholder == EmbedPlaceholder.protected
                ? ProtectedPostBox(
                    author: original,
                    actionLabel: onUndo == null ? null : 'Undo repost',
                    actionSemanticLabel:
                        "Undo repost of @${original.handle}'s post",
                    onAction: onUndo,
                  )
                : UnavailablePostBox(
                    message: EmbeddedPostCard.placeholderMessage(placeholder),
                  ),
          ),
        ],
      ),
    );
  }
}
