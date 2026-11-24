// ignore_for_file: invalid_use_of_protected_member

part of 'articles_screen.dart';

/// The editable block widgets for [_ArticlesScreenState].
extension _ArticlesBlockEditors on _ArticlesScreenState {
  /// An inserted image: its picture (thumbnail), alt text and caption.
  Widget _imageEditor(int index, _EditableBlock block, Widget removeButton) {
    final colors = Theme.of(context).colorScheme;
    final ref = _record?.images[block.mediaId];
    final bytes = _imageThumbs[block.mediaId];
    final thumbUrl = ref == null
        ? ''
        : (ref.thumbUrl.isNotEmpty ? ref.thumbUrl : ref.url);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          alignment: AlignmentDirectional.topEnd,
          children: [
            SizedBox(
              width: double.infinity,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: 96,
                  maxHeight: 240,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  child: ColoredBox(
                    color: colors.surfaceContainerHigh,
                    child: bytes != null
                        ? Image.memory(bytes, fit: BoxFit.contain)
                        : thumbUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: thumbUrl,
                            fit: BoxFit.contain,
                            errorWidget: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          )
                        : const Center(child: Icon(Icons.image_outlined)),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Material(
                color: colors.surface,
                shape: const CircleBorder(),
                child: removeButton,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          minLines: 2,
          maxLines: 5,
          controller: block.alt,
          onTap: () => _active = index,
          inputFormatters: [_CodePointLimit(kMaxAltTextLength)],
          decoration: const InputDecoration(
            labelText: 'Alt text (optional)',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: AppSpacing.sm,
          children: [
            Text(
              'Describe the image for people who cannot see it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: block.alt,
              builder: (_, value, _) => CharacterCounter(
                remaining: kMaxAltTextLength - value.text.runes.length,
                limit: kMaxAltTextLength,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          minLines: 1,
          maxLines: 5,
          controller: block.caption,
          onTap: () => _active = index,
          inputFormatters: [_CodePointLimit(articleMaxImageCaptionCodePoints)],
          decoration: const InputDecoration(labelText: 'Caption (optional)'),
        ),
      ],
    );
  }

  Widget _blockEditor(int index) {
    final block = _blocks[index];
    final removeButton = IconButton(
      tooltip: 'Remove block',
      onPressed: () {
        setState(() {
          _blocks.removeAt(index).dispose();
          _active = 0;
        });
        _changed();
      },
      icon: const Icon(Icons.close, size: AppIconSize.sm),
    );
    if (block.kind == ArticleBlockKind.image) {
      return _imageEditor(index, block, removeButton);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (block.kind == ArticleBlockKind.bulletedListItem) const Text('• '),
        if (block.kind == ArticleBlockKind.numberedListItem)
          Text('${index + 1}. '),
        Expanded(
          child: block.kind == ArticleBlockKind.divider
              ? const Divider()
              : block.kind == ArticleBlockKind.unknown
              ? Text(
                  'Content this app cannot edit. It is kept as it is.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                )
              : Focus(
                  onFocusChange: (focused) {
                    if (focused) _active = index;
                  },
                  child: TextField(
                    key: ValueKey(block),
                    controller: block.controller,
                    maxLines: null,
                    style: _blockStyle(context, block.kind),
                    decoration: InputDecoration(
                      hintText: index == 0
                          ? 'Start writing'
                          : 'Continue writing',
                      border: InputBorder.none,
                      filled: false,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
        ),
        removeButton,
      ],
    );
  }
}
