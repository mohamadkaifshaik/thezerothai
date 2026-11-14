part of 'articles_screen.dart';

TextStyle? _blockStyle(BuildContext context, ArticleBlockKind kind) {
  final text = Theme.of(context).textTheme;
  return switch (kind) {
    ArticleBlockKind.heading1 => text.headlineMedium?.copyWith(
      fontWeight: FontWeight.bold,
    ),
    ArticleBlockKind.heading2 => text.titleLarge?.copyWith(
      fontWeight: FontWeight.bold,
    ),
    ArticleBlockKind.code => text.bodyLarge?.copyWith(fontFamily: 'monospace'),
    ArticleBlockKind.quote => text.bodyLarge?.copyWith(
      fontStyle: FontStyle.italic,
    ),
    _ => text.bodyLarge,
  };
}

class _EditableBlock {
  _EditableBlock(ArticleBlock block, VoidCallback changed)
    : kind = block.kind,
      mediaId = block.mediaId,
      _opaque = block.kind == ArticleBlockKind.unknown ? block : null,
      alt = TextEditingController(text: block.altText),
      caption = TextEditingController(text: block.caption),
      controller = ArticleTextController(block.runs) {
    controller.addListener(changed);
    alt.addListener(changed);
    caption.addListener(changed);
  }
  ArticleBlockKind kind;
  final String? mediaId;
  final ArticleBlock? _opaque;
  final TextEditingController alt;
  final TextEditingController caption;
  final ArticleTextController controller;

  /// The block as saved. An unknown block is returned untouched, and an
  /// image keeps its media id whatever flags are on, so a save never drops
  /// content the editor cannot create.
  ArticleBlock get value =>
      _opaque ??
      ArticleBlock(
        kind: kind,
        runs: kind == ArticleBlockKind.divider || kind == ArticleBlockKind.image
            ? const []
            : controller.runs,
        mediaId: kind == ArticleBlockKind.image ? mediaId : null,
        altText: kind == ArticleBlockKind.image ? alt.text : '',
        caption: kind == ArticleBlockKind.image ? caption.text : '',
      );
  void dispose() {
    controller.dispose();
    alt.dispose();
    caption.dispose();
  }
}
