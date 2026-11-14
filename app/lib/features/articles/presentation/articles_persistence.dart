// ignore_for_file: invalid_use_of_protected_member

part of 'articles_screen.dart';

/// Autosave, conflict handling, publish, cover and delete for [_ArticlesScreenState].
extension _ArticlesPersistence on _ArticlesScreenState {
  Future<bool> _save() async {
    _debounce?.cancel();
    if (_saving) return false;
    if (!_dirty) return true;
    if (_conflict != null) return false;
    final generation = _generation;
    final loadGeneration = _loadGeneration;
    final draft = _draft;
    final tooLarge = _sizeError(draft.saveErrors);
    if (tooLarge != null) {
      // Refused locally: the server would reject it. The editor keeps the text.
      setState(() => _error = tooLarge);
      return false;
    }
    final sentKey = _contentKey;
    setState(() => _saving = true);
    try {
      final record = await _repository.save(
        draft,
        expectedRevision: draft.revision,
      );
      if (!mounted || loadGeneration != _loadGeneration) return false;
      setState(() {
        _record = record.images.isEmpty && _record != null
            ? record.withImages(_record!.images)
            : record;
        if (_page != null) {
          _page = ArticlePage(
            _page!.articles
                .map((item) => item.draft.id == record.draft.id ? record : item)
                .toList(),
            nextPageToken: _page!.nextPageToken,
          );
        }
        _dirty = generation != _generation;
        _error = null;
      });
      if (_dirty) {
        _debounce = Timer(
          const Duration(milliseconds: 200),
          () => unawaited(_save()),
        );
      }
      return !_dirty;
    } on ArticleRevisionConflict {
      if (!mounted || loadGeneration != _loadGeneration) return false;
      // Awaited inside the try: _saving stays true until the server copy is
      // read, so an edit made meanwhile cannot send the stale revision; the
      // adopt path queues that follow-up save itself.
      return await _reconcile(draft.id, sentKey, generation, loadGeneration);
    } catch (error) {
      if (mounted && loadGeneration == _loadGeneration) {
        setState(() => _error = _message(error));
      }
      return false;
    } finally {
      if (mounted && loadGeneration == _loadGeneration) {
        setState(() => _saving = false);
      }
    }
  }

  /// A save was refused as stale. When the server already holds exactly what
  /// was sent (an earlier save committed but its reply was lost), adopt the
  /// server revision and carry on. Otherwise the article changed elsewhere:
  /// pause autosave and let the author keep theirs or reload; local blocks
  /// are never dropped without that choice.
  Future<bool> _reconcile(
    String id,
    String sentKey,
    int generation,
    int loadGeneration,
  ) async {
    final ArticleRecord server;
    try {
      server = await _repository.get(id);
    } catch (error) {
      if (mounted && loadGeneration == _loadGeneration) {
        setState(() => _error = _message(error));
      }
      return false;
    }
    if (!mounted || loadGeneration != _loadGeneration) return false;
    final serverKey = _ArticlesScreenState._keyOf(
      server.draft.title,
      server.draft.coverMediaId,
      server.draft.blocks,
    );
    if (serverKey == sentKey && !server.published) {
      setState(() {
        _record = server;
        _dirty = generation != _generation;
        _error = null;
      });
      if (_dirty) {
        _debounce = Timer(
          const Duration(milliseconds: 200),
          () => unawaited(_save()),
        );
      }
      return !_dirty;
    }
    setState(() {
      _conflict = server;
      _error = null;
    });
    return false;
  }

  /// Keep mine: overwrite the server copy with the editor's content, based on
  /// the server revision just read.
  Future<void> _keepMine() async {
    final server = _conflict;
    if (server == null) return;
    setState(() {
      _record = server;
      _conflict = null;
      _dirty = true;
    });
    await _save();
  }

  /// Reload: replace the editor with the server copy (the author chose to).
  /// The conflict (and the dirty state) clear only when the load succeeds;
  /// until then autosave stays paused and the local text stays.
  Future<void> _reloadServer() async {
    _debounce?.cancel();
    await _load();
  }

  Future<void> _create() async {
    if (_record != null && !await _save()) return;
    setState(() => _busy = true);
    try {
      final record = await _repository.create();
      if (mounted) context.go('/compose/articles/edit/${record.draft.id}');
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _navigate(String location) async {
    if (await _save() && mounted) context.go(location);
  }

  Future<void> _back() async {
    final needsSave = _dirty;
    if (!await _save() || !mounted) return;
    // Let PopScope receive the saved state before attempting a stack pop.
    if (needsSave) await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (widget.preview || (widget.focus && !widget.reader)) {
      context.go('/compose/articles/edit/${widget.articleId}');
    } else if (widget.articleId != null && !widget.reader) {
      context.go('/compose/articles');
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  Future<void> _publish() async {
    if (!await _save() || !mounted) return;
    final publishErrors = _draft.publishErrors;
    if (publishErrors.isNotEmpty) {
      setState(
        () => _error =
            _sizeError(publishErrors) ??
            'Add a title and article body before publishing.',
      );
      return;
    }
    final record = _record!;
    final options = await showAppMaterialDialog<_PublishOptions>(
      context: context,
      // On the tablet layout a form dialog (D 560): the confirm width (400)
      // cannot hold the reply choices (T2 ruling 4). Elsewhere unchanged.
      maxWidth: AppSize.dialogMax,
      builder: (_) => _PublishDialog(
        draft: _draft,
        initialCaption: _retryOptions?.caption ?? record.publicationCaption,
        initialPolicy: _publishPolicy(record),
        locked: record.publicationPending || _retryOptions != null,
        canChooseReplyAudience: _repository.canChooseReplyAudience,
        // Focus mode has no library beside it.
        libraryBeside: !widget.focus && !widget.reader,
      ),
    );
    if (options == null || !mounted) return;
    _policyChoice = options.policy;
    setState(() => _busy = true);
    _retryOptions = options;
    final publishKey = sha256
        .convert(
          utf8.encode(
            '${record.draft.authorId}:${record.draft.id}:${record.draft.revision}:publish',
          ),
        )
        .toString();
    try {
      final published = await _repository.publish(
        _record!,
        idempotencyKey: publishKey,
        caption: options.caption,
        replyAudience: options.policy,
      );
      if (mounted) context.go('/articles/${published.draft.id}');
    } catch (error) {
      // FEATURE_DISABLED is FAILED_PRECONDITION, which clears the pending
      // key server-side: the next try may choose again (only Everyone now,
      // the gate remembers the answer), even if the refresh below fails. A
      // record still marked pending would re-lock the dialog and resend the
      // refused policy, so it stops being pending here too.
      if (error is FeatureDisabledException &&
          error.feature == kFeatureReplyAudience) {
        _retryOptions = null;
        if (_record case final current?
            when current.publicationPending &&
                current.draft.id == record.draft.id) {
          _record = current.withPublicationRefused();
        }
      }
      if (mounted) setState(() => _error = _message(error));
      try {
        final refreshed = await _repository.get(record.draft.id);
        if (mounted) {
          setState(() {
            _record = refreshed;
            if (!refreshed.publicationPending) _retryOptions = null;
          });
        }
      } catch (_) {
        /* Preserve the original error and publication intent. */
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The reply policy a publication goes out with: a locked retry's or a
  /// pending publication's stored one, else the author's choice, else what
  /// the record stores.
  ReplyAudience _publishPolicy(ArticleRecord record) =>
      _retryOptions?.policy ??
      (record.publicationPending
          ? record.publicationReplyAudience
          : _policyChoice ?? record.publicationReplyAudience);

  Future<void> _cover({bool retry = false}) async {
    if (_busy) return;
    final owner = _record!.draft.authorId;
    final articleId = _record!.draft.id;
    final picker = context.read<ImagePickerService>();
    final processor = context.read<ImageProcessor>();
    _coverUploader ??= MediaUploader(
      repository: context.read<MediaRepository>(),
    );
    setState(() => _busy = true);
    try {
      if (!retry || _coverJob == null) {
        final files = await picker.pickImages(limit: 1);
        if (files.isEmpty || !mounted) return;
        final image = await processor.process(files.single, ImagePurpose.post);
        _coverJob = UploadJob(id: const Uuid().v4(), image: image);
      }
      final outcomes = await _coverUploader!.upload(
        purpose: MediaPurpose.MEDIA_PURPOSE_POST,
        jobs: [_coverJob!],
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
              : 'Cover upload failed. Use Retry cover upload to try again.',
        );
        return;
      }
      setState(() {
        _coverMediaId = outcome.mediaId;
        _coverBytes = _coverJob!.image.fullBytes;
      });
      _changed();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ArticleRecord article) async {
    final confirmed = await showAppMaterialDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete article?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repository.delete(article);
      if (mounted) {
        if (widget.articleId != null) {
          context.go('/compose/articles');
        } else {
          await _load();
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }
}
