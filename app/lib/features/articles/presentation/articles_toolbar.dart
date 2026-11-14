// ignore_for_file: invalid_use_of_protected_member

part of 'articles_screen.dart';

/// The formatting toolbar and block insertion for [_ArticlesScreenState].
extension _ArticlesToolbar on _ArticlesScreenState {
  /// The formatting tools. From 600dp a white pill under the header (the
  /// tablet and desktop mocks); on a phone a bar above the keyboard with a
  /// hairline over it (the phone mock's chip row). It scrolls sideways.
  Widget _toolbar({required bool phone}) {
    final colors = context.appColors;
    final tools = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: _tools(),
    );
    if (phone) {
      return DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.hairline)),
        ),
        child: SafeArea(top: false, child: tools),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: colors.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppArticlesLayout.toolbarPadding),
          child: tools,
        ),
      ),
    );
  }

  Widget _tools() => Row(
    children: [
      _tool('Bold', Icons.format_bold, () => _mark(ArticleMark.bold)),
      _tool('Italic', Icons.format_italic, () => _mark(ArticleMark.italic)),
      _tool(
        'Strikethrough',
        Icons.format_strikethrough,
        () => _mark(ArticleMark.strikethrough),
      ),
      PopupMenuButton<ArticleBlockKind>(
        tooltip: 'Text style',
        onSelected: _kind,
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: ArticleBlockKind.heading1,
            child: Text('Heading'),
          ),
          const PopupMenuItem(
            value: ArticleBlockKind.heading2,
            child: Text('Subheading'),
          ),
          const PopupMenuItem(
            value: ArticleBlockKind.paragraph,
            child: Text('Body'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [Text('Body'), Icon(Icons.arrow_drop_down)],
          ),
        ),
      ),
      _tool('Quote', Icons.format_quote, () => _kind(ArticleBlockKind.quote)),
      _tool(
        'Bulleted list',
        Icons.format_list_bulleted,
        () => _kind(ArticleBlockKind.bulletedListItem),
      ),
      _tool(
        'Numbered list',
        Icons.format_list_numbered,
        () => _kind(ArticleBlockKind.numberedListItem),
      ),
      _tool('Link', Icons.link, _link),
      PopupMenuButton<ArticleBlockKind>(
        tooltip: 'Insert',
        onSelected: _append,
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: ArticleBlockKind.divider,
            child: Text('Divider'),
          ),
          const PopupMenuItem(
            value: ArticleBlockKind.code,
            child: Text('Code'),
          ),
          if (_imagesEnabled(listen: false))
            const PopupMenuItem(
              value: ArticleBlockKind.image,
              child: Text('Image'),
            ),
        ],
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [Text('Insert'), Icon(Icons.arrow_drop_down)],
          ),
        ),
      ),
    ],
  );
  Widget _tool(String name, IconData icon, VoidCallback action) =>
      IconButton(tooltip: name, onPressed: action, icon: Icon(icon));
  void _mark(ArticleMark mark) {
    if (_blocks.isEmpty || !_blocks[_active].controller.format(mark: mark)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select text to apply formatting.')),
      );
    }
  }

  void _kind(ArticleBlockKind kind) {
    if (_blocks.isEmpty) return;
    // Restyling an image or an unknown block would drop its media or content.
    final current = _blocks[_active].kind;
    if (current == ArticleBlockKind.image ||
        current == ArticleBlockKind.unknown) {
      return;
    }
    setState(() => _blocks[_active].kind = kind);
    _changed();
  }

  /// Whether the author may insert images (`article_images`). Off, existing
  /// image and unknown blocks still show and save unchanged.
  bool _imagesEnabled({bool listen = true}) {
    try {
      return listen
          ? isFeatureEnabled(context, kFeatureArticleImages)
          : featureEnabledSnapshot(context, kFeatureArticleImages);
    } on ProviderNotFoundException {
      return false;
    }
  }

  /// Picks one image, uploads it through the post upload path and inserts an
  /// image block after the current block.
  Future<void> _insertImage() async {
    if (_busy || _record == null) return;
    if (_blocks.where((b) => b.kind == ArticleBlockKind.image).length >=
        articleMaxImages) {
      setState(
        () => _error =
            'You can add up to $articleMaxImages images to an article.',
      );
      return;
    }
    final owner = _record!.draft.authorId;
    final articleId = _record!.draft.id;
    final picker = context.read<ImagePickerService>();
    final processor = context.read<ImageProcessor>();
    _imageUploader ??= MediaUploader(
      repository: context.read<MediaRepository>(),
    );
    setState(() => _busy = true);
    try {
      final files = await picker.pickImages(limit: 1);
      if (files.isEmpty || !mounted) return;
      final image = await processor.process(files.single, ImagePurpose.post);
      final job = UploadJob(id: const Uuid().v4(), image: image);
      final outcomes = await _imageUploader!.upload(
        purpose: MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: [job],
      );
      if (!mounted ||
          _record?.draft.authorId != owner ||
          _record?.draft.id != articleId) {
        return;
      }
      final outcome = outcomes.single;
      if (outcome.status != UploadOutcomeStatus.ready) {
        setState(
          () => _error = outcome.status == UploadOutcomeStatus.rejected
              ? 'This image could not be used. Choose another image.'
              : 'Image upload failed. Try inserting it again.',
        );
        return;
      }
      setState(() {
        _imageThumbs[outcome.mediaId] = image.thumbBytes;
        final at = _blocks.isEmpty ? 0 : _active + 1;
        _blocks.insert(
          at,
          _EditableBlock(
            ArticleBlock(
              kind: ArticleBlockKind.image,
              mediaId: outcome.mediaId,
            ),
            _changed,
          ),
        );
        _active = at;
      });
      _changed();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _append(ArticleBlockKind kind) {
    if (kind == ArticleBlockKind.image) {
      unawaited(_insertImage());
      return;
    }
    setState(() {
      _blocks.add(_EditableBlock(ArticleBlock(kind: kind), _changed));
      _active = _blocks.length - 1;
    });
    _changed();
  }

  Future<void> _link() async {
    if (_blocks.isEmpty || _blocks[_active].controller.selection.isCollapsed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select text to add a link.')),
      );
      return;
    }
    final controller = TextEditingController();
    final link = await showAppMaterialDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add link'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'URL'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (articleLinkAllowed(controller.text)) {
                Navigator.pop(context, controller.text);
              }
            },
            child: const Text('Insert'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (link != null && mounted) _blocks[_active].controller.format(link: link);
  }
}
