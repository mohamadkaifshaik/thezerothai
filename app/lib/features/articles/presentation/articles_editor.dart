// ignore_for_file: invalid_use_of_protected_member

part of 'articles_screen.dart';

/// The editor page for [_ArticlesScreenState].
extension _ArticlesEditor on _ArticlesScreenState {
  Widget _editor() {
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final theme = Theme.of(context);
    final cover = _coverBytes != null
        ? Image.memory(_coverBytes!, fit: BoxFit.cover)
        : _record!.coverUrl.isNotEmpty && _coverMediaId != null
        ? Image.network(
            _record!.coverUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                const Center(child: Icon(Icons.broken_image_outlined)),
          )
        : null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppArticlesLayout.gutter,
            AppSpacing.sm,
            AppArticlesLayout.gutter,
            0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  'Article · Draft'.toUpperCase(),
                  style: AppTextStyles.eyebrow(theme)
                      .copyWith(color: context.appColors.accentText),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  _saving
                      ? 'Saving…'
                      : _dirty
                      ? 'Unsaved changes'
                      : 'Saved',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
        if (!phone) _toolbar(phone: false),
        Expanded(
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                // 680 on the tablet layout (the readable column), else 600.
                constraints: BoxConstraints(
                  maxWidth: ShellGeometry.readableMaxWidth(context),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppArticlesLayout.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (cover != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.card),
                          child: AspectRatio(aspectRatio: 5 / 2, child: cover),
                        )
                      else ...[
                        ArticleCoverPlaceholder(
                          height: phone
                              ? AppArticlesLayout.phoneCoverHeight
                              : AppArticlesLayout.wideCoverHeight,
                          onTap: _busy ? null : () => _cover(),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.sm),
                          child: Text(
                            'We recommend an image with a 5:2 aspect ratio for best results.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                      if (cover != null || _coverJob != null)
                        Wrap(
                          children: [
                            if (cover != null)
                              TextButton(
                                onPressed: _busy ? null : () => _cover(),
                                child: const Text('Replace cover image'),
                              ),
                            if (_coverMediaId != null)
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () {
                                        setState(() {
                                          _coverMediaId = null;
                                          _coverBytes = null;
                                          _coverJob = null;
                                        });
                                        _changed();
                                      },
                                child: const Text('Remove cover image'),
                              ),
                            if (_coverJob != null && _coverMediaId == null)
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _cover(retry: true),
                                child: const Text('Retry cover upload'),
                              ),
                          ],
                        ),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        key: const Key('article-title'),
                        controller: _title,
                        maxLength: articleMaxTitleCodePoints,
                        maxLines: null,
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontSize: phone
                              ? AppArticlesLayout.phoneTitle
                              : AppArticlesLayout.wideTitle,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Add a title',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                      for (var i = 0; i < _blocks.length; i++) _blockEditor(i),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: AppPillButton(
                          label: 'Add paragraph',
                          icon: Icons.add,
                          compact: true,
                          variant: AppButtonVariant.outline,
                          onPressed: () => _append(ArticleBlockKind.paragraph),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (phone) _toolbar(phone: true),
      ],
    );
  }
}
