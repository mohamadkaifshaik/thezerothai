// ignore_for_file: invalid_use_of_protected_member

part of 'articles_screen.dart';

/// The header and the page-with-library layout for [_ArticlesScreenState].
extension _ArticlesLayout on _ArticlesScreenState {
  /// The header title. A draft in the editor shows its word count (the
  /// phone mock: the count alone; tablet and desktop: "Article" over
  /// "Draft · N words"); every other page keeps its plain title.
  Widget _headerTitle({required bool phone, required bool read}) {
    if (read || widget.reader || _record == null) {
      return Text(
        widget.reader
            ? 'Article'
            : widget.preview
            ? 'Preview'
            : 'Articles',
      );
    }
    final theme = Theme.of(context);
    final words = '${_draft.wordCount} words';
    final muted = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (phone) return Text(words, style: muted, maxLines: 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Article'),
        Text('Draft · $words', style: muted),
      ],
    );
  }

  /// Preview or Edit, Publish and Focus mode. From 600dp they sit in the
  /// header as pills and an icon; on a phone only Publish does, and the other
  /// two go into a menu so the header fits at 320dp with large text.
  List<Widget> _draftActions({required bool phone, required bool read}) {
    final id = _record!.draft.id;
    final preview = !read;
    final modeLabel = preview
        ? 'Preview'
        : _record!.publicationPending
        ? null
        : 'Edit';
    final modeEnabled = !preview || !(_saving || _busy);
    void mode() => unawaited(
      _navigate(
        preview
            ? '/compose/articles/edit/$id/preview'
            : '/compose/articles/edit/$id',
      ),
    );
    void focus() => unawaited(
      _navigate('/compose/articles/edit/$id${widget.focus ? '' : '/focus'}'),
    );
    final publish = AppPillButton(
      label: 'Publish',
      compact: true,
      busy: _busy,
      busySemanticsLabel: 'Publishing',
      onPressed: _saving || _busy || _draft.publishErrors.isNotEmpty
          ? null
          : _publish,
    );
    if (phone) {
      return [
        publish,
        PopupMenuButton<VoidCallback>(
          tooltip: 'More',
          onSelected: (action) => action(),
          itemBuilder: (_) => [
            if (modeLabel != null)
              PopupMenuItem(
                value: mode,
                enabled: modeEnabled,
                child: Text(modeLabel),
              ),
            PopupMenuItem(value: focus, child: const Text('Focus mode')),
          ],
        ),
      ];
    }
    return [
      if (modeLabel != null)
        AppPillButton(
          label: modeLabel,
          compact: true,
          variant: AppButtonVariant.outline,
          onPressed: modeEnabled ? mode : null,
        ),
      const SizedBox(width: AppSpacing.sm),
      publish,
      IconButton(
        tooltip: 'Focus mode',
        onPressed: focus,
        icon: Icon(widget.focus ? Icons.fullscreen_exit : Icons.fullscreen),
      ),
      const SizedBox(width: AppSpacing.sm),
    ];
  }

  /// [sides]: the window's safe-area insets on the tablet layout (zero
  /// elsewhere). There the library sits at the leading edge and the page at
  /// the trailing edge of the window, so each pads by its side's inset (a
  /// landscape phone's notch), and the library is the list pane of
  /// `C = W - insets` (tablet plan section 3).
  Widget _withLibrary(
    BoxConstraints constraints,
    Widget page, {
    required bool tablet,
    required EdgeInsets sides,
    required bool rtl,
  }) {
    final body = KeyedSubtree(key: _bodyKey, child: page);
    final wide = articleLibraryShownAt(constraints.maxWidth, tablet: tablet);
    final libraryWidth = articleLibraryWidth(
      constraints.maxWidth - sides.horizontal,
      tablet: tablet,
    );
    final leadingInset = EdgeInsets.only(
      left: rtl ? 0 : sides.left,
      right: rtl ? sides.right : 0,
    );
    final trailingInset = EdgeInsets.only(
      left: rtl ? sides.left : 0,
      right: rtl ? 0 : sides.right,
    );
    Widget pad(EdgeInsets insets, Widget child) => insets == EdgeInsets.zero
        ? child
        : Padding(padding: insets, child: child);
    if (widget.articleId == null && wide && !_loading) {
      return Row(
        children: [
          pad(leadingInset, SizedBox(width: libraryWidth, child: body)),
          const VerticalDivider(width: 1),
          Expanded(child: pad(trailingInset, _writingWelcome())),
        ],
      );
    }
    final showLibrary =
        widget.articleId != null && !widget.reader && !widget.focus && wide;
    // Band B of the tablet layout: "Publish settings" above the library,
    // for a draft that can still be published.
    final record = _record;
    final settings =
        showLibrary &&
        tablet &&
        ShellBand.of(constraints.maxWidth) == ShellBand.expanded &&
        record != null &&
        !record.published;
    if (showLibrary && !_sideRequested) {
      _sideRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadSide());
      });
    }
    final library = _sideLoading
        ? const PostListSkeleton(
            mediaEvery: 0,
            semanticsLabel: 'Loading articles',
          )
        : _library();
    return showLibrary
        ? Row(
            children: [
              pad(
                leadingInset,
                SizedBox(
                  width: libraryWidth,
                  child: settings
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // At most a third of the pane (a landscape phone
                            // at large text): the settings scroll, the
                            // library keeps the rest.
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: constraints.maxHeight / 3,
                              ),
                              child: SingleChildScrollView(
                                child: _PublishSettings(
                                  policy: _publishPolicy(record),
                                  locked:
                                      record.publicationPending ||
                                      _retryOptions != null,
                                  canChooseReplyAudience:
                                      _repository.canChooseReplyAudience,
                                  onChanged: (value) =>
                                      setState(() => _policyChoice = value),
                                ),
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(child: library),
                          ],
                        )
                      : library,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: pad(trailingInset, body)),
            ],
          )
        : body;
  }
}
