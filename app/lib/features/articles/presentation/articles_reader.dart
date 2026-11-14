// ignore_for_file: invalid_use_of_protected_member

part of 'articles_screen.dart';

/// The reader view for [_ArticlesScreenState].
extension _ArticlesReader on _ArticlesScreenState {
  Widget _reader() {
    final imagesOn = _imagesEnabled();
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          // 680 on the tablet layout (the readable column), else 600.
          constraints: BoxConstraints(
            maxWidth: ShellGeometry.readableMaxWidth(context),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_record!.published)
                  const Padding(
                    padding: EdgeInsets.only(bottom: AppSpacing.lg),
                    child: Text('Only you can view this unpublished Article.'),
                  ),
                if (_record!.coverUrl.isNotEmpty)
                  AspectRatio(
                    aspectRatio: 5 / 2,
                    child: Image.network(_record!.coverUrl, fit: BoxFit.cover),
                  ),
                Text(
                  _record!.draft.title,
                  style: Theme.of(context).textTheme.headlineLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (_record!.authorName.isNotEmpty ||
                    _record!.authorHandle.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundImage: _record!.authorAvatar.isEmpty
                          ? null
                          : NetworkImage(_record!.authorAvatar),
                      child: _record!.authorAvatar.isEmpty
                          ? const Icon(Icons.person_outline)
                          : null,
                    ),
                    title: Text(_record!.authorName),
                    subtitle: Text('@${_record!.authorHandle}'),
                  ),
                const SizedBox(height: AppSpacing.lg),
                // The prose: at most [kArticleProseMax] a line, from the
                // start edge under the title (the column may be wider).
                LayoutBuilder(
                  builder: (context, constraints) => Padding(
                    padding: EdgeInsetsDirectional.only(
                      end: math.max(0, constraints.maxWidth - kArticleProseMax),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Unknown kinds (a newer server) are skipped, not shown.
                        for (final block in _record!.draft.blocks.where(
                          (b) => b.kind != ArticleBlockKind.unknown,
                        ))
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.md,
                            ),
                            child: block.kind == ArticleBlockKind.divider
                                ? const Divider()
                                : block.kind == ArticleBlockKind.image
                                ? ArticleImageBlock(
                                    block: block,
                                    media: _record!.images[block.mediaId],
                                    enabled: imagesOn,
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SelectableText.rich(
                                        TextSpan(
                                          style: _blockStyle(
                                            context,
                                            block.kind,
                                          ),
                                          children: [
                                            if (block.kind ==
                                                ArticleBlockKind
                                                    .bulletedListItem)
                                              const TextSpan(text: '• '),
                                            ...block.runs.map(
                                              (r) => TextSpan(
                                                text: r.text,
                                                style: articleRunStyle(r),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      for (final link
                                          in block.runs
                                              .map((r) => r.link)
                                              .whereType<String>()
                                              .toSet())
                                        TextButton(
                                          onPressed: () => launchUrl(
                                            Uri.parse(link),
                                            mode:
                                                LaunchMode.externalApplication,
                                          ),
                                          child: Text(link),
                                        ),
                                    ],
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_record!.published && _record!.postId.isNotEmpty)
                  TextButton(
                    onPressed: () => context.push('/post/${_record!.postId}'),
                    child: const Text('View conversation'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
