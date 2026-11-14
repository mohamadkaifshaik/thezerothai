// ignore_for_file: invalid_use_of_protected_member

part of 'articles_screen.dart';

/// The article library (drafts and published lists) for [_ArticlesScreenState].
extension _ArticlesLibrary on _ArticlesScreenState {
  Widget _failure() => Center(
    child: TextButton(
      onPressed: _load,
      child: const Text('Article unavailable. Retry'),
    ),
  );
  Widget _writingWelcome() => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This is where you write',
              style: Theme.of(context).textTheme.headlineLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Continue a draft or create a new Article',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: _busy ? null : _create,
              child: const Text('Write'),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _library() => Column(
    children: [
      if (widget.articleId != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Articles',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Create article',
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.edit_note),
              ),
            ],
          ),
        ),
      Row(
        children: [
          for (final published in [false, true])
            Expanded(
              child: TextButton(
                onPressed: () {
                  setState(() => _publishedTab = published);
                  unawaited(widget.articleId == null ? _load() : _loadSide());
                },
                child: Column(
                  children: [
                    Text(
                      published ? 'Published' : 'Drafts',
                      style: TextStyle(
                        fontWeight: _publishedTab == published
                            ? FontWeight.bold
                            : null,
                      ),
                    ),
                    if (_publishedTab == published)
                      const Icon(Icons.horizontal_rule),
                  ],
                ),
              ),
            ),
        ],
      ),
      const Divider(height: 1),
      Expanded(
        child: _page == null || _page!.articles.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _publishedTab
                          ? 'Your published Articles live here'
                          : 'This is where you write',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (!_publishedTab) ...[
                      const Text('Continue a draft or create a new Article'),
                      TextButton(
                        onPressed: _busy ? null : _create,
                        child: const Text('Write'),
                      ),
                    ],
                  ],
                ),
              )
            : ListView.separated(
                itemCount:
                    _page!.articles.length +
                    (_page!.nextPageToken.isEmpty ? 0 : 1),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index == _page!.articles.length) {
                    return TextButton(
                      onPressed: _more,
                      child: const Text('Load more'),
                    );
                  }
                  final record = _page!.articles[index];
                  return ListTile(
                    title: Text(
                      record.draft.title.isEmpty
                          ? '(Needs title)'
                          : record.draft.title,
                    ),
                    subtitle: Text(
                      '${record.published ? 'Published' : 'Draft'} · ${record.updatedAt.toLocal()}\n${record.summary}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (_) => _delete(record),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                    onTap: () => _navigate(
                      record.published
                          ? '/articles/${record.draft.id}'
                          : '/compose/articles/edit/${record.draft.id}',
                    ),
                  );
                },
              ),
      ),
    ],
  );
  Future<void> _more() async {
    if (_loadingMore || _page == null) return;
    final loadGeneration = _loadGeneration;
    final published = _publishedTab;
    final previousPage = _page!;
    _loadingMore = true;
    try {
      final page = await _repository.list(
        published: published,
        pageToken: previousPage.nextPageToken,
      );
      if (mounted &&
          loadGeneration == _loadGeneration &&
          published == _publishedTab &&
          _page == previousPage) {
        setState(
          () => _page = ArticlePage([
            ...previousPage.articles,
            ...page.articles,
          ], nextPageToken: page.nextPageToken),
        );
      }
    } catch (error) {
      if (mounted && loadGeneration == _loadGeneration) {
        setState(() => _error = _message(error));
      }
    } finally {
      _loadingMore = false;
    }
  }
}
