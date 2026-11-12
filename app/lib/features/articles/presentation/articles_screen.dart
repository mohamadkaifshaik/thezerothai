import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../core/widgets/tablet_layout.dart';
import '../../../gen/dzeroth/media/v1/media.pbenum.dart';
import '../../media/data/image_picker_service.dart';
import '../../media/data/media_repository.dart';
import '../../media/data/media_uploader.dart';
import '../../media/domain/image_processor.dart';
import '../../posts/domain/reply_audience.dart';
import '../../posts/presentation/post_error_messages.dart'
    show kReplyAudienceUnavailableMessage;
import '../domain/article.dart';
import '../domain/articles_repository.dart';
import 'article_text_controller.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import 'widgets/article_cover_placeholder.dart';

/// Whether the article library shows beside the page in a window [width]
/// wide: from 840dp on the tablet layout ([tablet]: both flags, 600-1199dp;
/// tablet plan section 4.1, Article row), from 1200dp everywhere else
/// (today's rule; desktop unchanged, ruling R-1).
bool articleLibraryShownAt(double width, {required bool tablet}) =>
    width >= (tablet ? AppBreakpoints.expanded : AppBreakpoints.tablet);

/// The library's width beside the page: the list pane of band B on the
/// tablet layout (`clamp(0.4 * W, 320, 400)`: the editor has no rail, so its
/// content area is the window), today's side column elsewhere.
double articleLibraryWidth(double width, {required bool tablet}) =>
    tablet ? ShellGeometry.listPaneWidthFor(width) : AppSize.sideColumn;

/// The longest line of the reader's prose (its body blocks), in dp. The
/// reader's column is the readable 680 on the tablet layout; its title,
/// cover and byline use it all, but body text stops here so a line stays
/// comfortable to read. On phones and desktop the column is narrower than
/// this, so nothing changes there.
const double kArticleProseMax = 600;

/// Band B of the tablet layout: the editor's library pane carries "Publish
/// settings" (the audience and who can reply), so the publish dialog does
/// not (tablet plan section 6, item 5). Band A, phones, desktop and either
/// flag off keep them in the dialog.
bool articlePublishSettingsInPaneAt(BuildContext context) =>
    tabletLayoutAt(context) &&
    ShellBand.of(MediaQuery.sizeOf(context).width) == ShellBand.expanded;

class ArticlesScreen extends StatefulWidget {
  const ArticlesScreen({
    super.key,
    this.articleId,
    this.preview = false,
    this.focus = false,
    this.reader = false,
  });
  final String? articleId;
  final bool preview;
  final bool focus;
  final bool reader;
  @override
  State<ArticlesScreen> createState() => _ArticlesScreenState();
}

class _ArticlesScreenState extends State<ArticlesScreen> {
  ArticlesRepository get _repository => context.read<ArticlesRepository>();
  ArticleRecord? _record;
  final _title = TextEditingController();
  final _blocks = <_EditableBlock>[];
  ArticlePage? _page;
  bool _publishedTab = false;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _busy = false;
  int _generation = 0;
  int _active = 0;
  String _contentSnapshot = '';
  String? _coverMediaId;
  Uint8List? _coverBytes;
  UploadJob? _coverJob;
  MediaUploader? _coverUploader;
  int _loadGeneration = 0;
  bool _loadingMore = false;
  int _sideGeneration = 0;
  bool _sideLoading = false;
  bool _sideRequested = false;
  String? _error;
  // The server copy after a revision conflict whose content differs from the
  // editor's: autosave pauses until the author keeps theirs or reloads.
  ArticleRecord? _conflict;
  Timer? _debounce;
  _PublishOptions? _retryOptions;

  /// Who can reply, as chosen in the library pane's "Publish settings" (band
  /// B) or in the last publish dialog; null until the author chooses. The
  /// publish dialog opens on it.
  ReplyAudience? _policyChoice;

  /// The page (the editor, the reader, the library list) keeps its state
  /// when the library appears or goes beside it (crossing 840 or 1200dp):
  /// the same element is re-parented, so focus, selection and scroll stay.
  final _bodyKey = GlobalKey(debugLabel: 'article-body');

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_sideRequested &&
        widget.articleId != null &&
        !widget.reader &&
        !widget.focus &&
        articleLibraryShownAt(
          MediaQuery.sizeOf(context).width,
          tablet: tabletLayoutAt(context, listen: false),
        )) {
      _sideRequested = true;
      unawaited(_loadSide());
    }
  }

  Future<void> _loadSide() async {
    final generation = ++_sideGeneration;
    setState(() => _sideLoading = true);
    try {
      final page = await _repository.list(published: _publishedTab);
      if (mounted && generation == _sideGeneration) {
        setState(() => _page = page);
      }
    } catch (error) {
      if (mounted && generation == _sideGeneration) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && generation == _sideGeneration) {
        setState(() => _sideLoading = false);
      }
    }
  }

  @override
  void didUpdateWidget(ArticlesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.articleId != widget.articleId) {
      _debounce?.cancel();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _title.dispose();
    for (final b in _blocks) {
      b.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final loadGeneration = ++_loadGeneration;
    if (_record?.draft.id != widget.articleId) {
      _coverBytes = null;
      _coverJob = null;
      _coverUploader = null;
      _retryOptions = null;
      _policyChoice = null;
      _saving = false;
      _dirty = false;
      _conflict = null;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.articleId == null) {
        final page = await _repository.list(published: _publishedTab);
        if (!mounted || loadGeneration != _loadGeneration) return;
        setState(() => _page = page);
      } else {
        final record = await _repository.get(widget.articleId!);
        if (!mounted || loadGeneration != _loadGeneration) return;
        _coverMediaId = record.draft.coverMediaId;
        _title.removeListener(_changed);
        _title.text = record.draft.title;
        _title.addListener(_changed);
        for (final block in _blocks) {
          block.dispose();
        }
        _blocks.clear();
        for (final block in record.draft.blocks) {
          _blocks.add(_EditableBlock(block, _changed));
        }
        if (_blocks.isEmpty) {
          _blocks.add(
            _EditableBlock(
              ArticleBlock(kind: ArticleBlockKind.paragraph),
              _changed,
            ),
          );
        }
        setState(() {
          _record = record;
          _dirty = false;
          _conflict = null;
          _active = 0;
        });
        _contentSnapshot = _contentKey;
      }
    } catch (error) {
      if (mounted && loadGeneration == _loadGeneration) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && loadGeneration == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  /// The copy for a body over a server limit, or null. Both limits are shown
  /// so the author knows how much to cut.
  String? _sizeError(List<String> errors) {
    if (errors.contains('bodySize')) {
      return 'This article is too long to save: it is '
          '${_draft.bodyBytes} of $articleMaxBodyBytes bytes, including '
          'formatting. Shorten it; your text stays here.';
    }
    if (errors.contains('bodyLength')) {
      return 'This article is too long to save: the limit is '
          '$articleMaxBodyCodePoints characters. Shorten it; your text stays '
          'here.';
    }
    return null;
  }

  String _message(Object error) => isArticleDraftLimit(error)
      // Fixed copy, not the server's text; nothing in the editor is touched.
      ? articleDraftLimitMessage
      // The flag went off after the dialog offered a narrower audience.
      : error is FeatureDisabledException &&
            error.feature == kFeatureReplyAudience
      ? kReplyAudienceUnavailableMessage
      : error is AppException
      ? error.message
      : 'Could not load or save this article. Please try again.';
  ArticleDraft get _draft => ArticleDraft(
    id: _record!.draft.id,
    authorId: _record!.draft.authorId,
    revision: _record!.draft.revision,
    title: _title.text,
    coverMediaId: _coverMediaId,
    blocks: _blocks.map((b) => b.value),
  );
  String get _contentKey =>
      _keyOf(_title.text, _coverMediaId, _blocks.map((b) => b.value));
  static String _keyOf(
    String title,
    String? coverMediaId,
    Iterable<ArticleBlock> blocks,
  ) =>
      jsonEncode([title, coverMediaId, blocks.map((b) => b.toJson()).toList()]);
  void _changed() {
    if (_record == null ||
        widget.reader ||
        widget.preview ||
        _record!.published) {
      return;
    }
    final content = _contentKey;
    if (content == _contentSnapshot) return;
    _contentSnapshot = content;
    _generation++;
    _debounce?.cancel();
    setState(() {
      _dirty = true;
      _error = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 800),
      () => unawaited(_save()),
    );
  }

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
        _record = record;
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
    final serverKey = _keyOf(
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

  @override
  Widget build(BuildContext context) {
    final read =
        widget.preview ||
        widget.reader ||
        (_record?.published ?? false) ||
        (_record?.publicationPending ?? false);
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : widget.articleId == null
        ? _library()
        : _record == null
        ? _failure()
        : read
        ? _reader()
        : _editor();
    // The tablet layout (both flags, 600-1199dp) moves the library's
    // threshold and width (tablet plan section 4.1, Article row).
    final tablet = tabletLayoutAt(context);
    final sides = tablet ? MediaQuery.paddingOf(context) : EdgeInsets.zero;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: _saving || _busy ? null : () => unawaited(_back()),
          ),
          title: _headerTitle(phone: phone, read: read),
          actions: [
            if (widget.reader && _record != null)
              IconButton(
                tooltip: 'Focus mode',
                onPressed: () => context.go(
                  '/articles/${_record!.draft.id}${widget.focus ? '' : '/focus'}',
                ),
                icon: Icon(
                  widget.focus ? Icons.fullscreen_exit : Icons.fullscreen,
                ),
              ),
            if (widget.articleId == null)
              IconButton(
                tooltip: 'Create article',
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.edit_note),
              ),
            if (_record != null && !_record!.published)
              ..._draftActions(phone: phone, read: read),
          ],
        ),
        body: Column(
          children: [
            if (_conflict != null)
              MaterialBanner(
                key: const Key('article-conflict'),
                content: const Text(
                  'Changed elsewhere. This article was edited on another '
                  'device or tab. Keep your version, or reload the saved one?',
                ),
                actions: [
                  TextButton(
                    onPressed: _keepMine,
                    child: const Text('Keep mine'),
                  ),
                  TextButton(
                    onPressed: _reloadServer,
                    child: const Text('Reload'),
                  ),
                ],
              ),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                actions: [
                  // Retrying the draft cap cannot succeed (and Retry would
                  // reload the editor): it only dismisses.
                  if (_error == articleDraftLimitMessage)
                    TextButton(
                      onPressed: () => setState(() => _error = null),
                      child: const Text('Dismiss'),
                    )
                  else
                    TextButton(
                      onPressed: _record != null && _dirty ? _save : _load,
                      child: const Text('Retry'),
                    ),
                ],
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => _withLibrary(
                  constraints,
                  body,
                  tablet: tablet,
                  sides: sides,
                  rtl: rtl,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
        ? const Center(child: CircularProgressIndicator())
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
    setState(() => _blocks[_active].kind = kind);
    _changed();
  }

  void _append(ArticleBlockKind kind) {
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

  Widget _blockEditor(int index) {
    final block = _blocks[index];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (block.kind == ArticleBlockKind.bulletedListItem) const Text('• '),
        if (block.kind == ArticleBlockKind.numberedListItem)
          Text('${index + 1}. '),
        Expanded(
          child: block.kind == ArticleBlockKind.divider
              ? const Divider()
              : block.kind == ArticleBlockKind.image
              ? Text('Image: ${block.mediaId}')
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
        IconButton(
          tooltip: 'Remove block',
          onPressed: () {
            setState(() {
              _blocks.removeAt(index).dispose();
              _active = 0;
            });
            _changed();
          },
          icon: const Icon(Icons.close, size: AppIconSize.sm),
        ),
      ],
    );
  }

  Widget _reader() => SingleChildScrollView(
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
                      for (final block in _record!.draft.blocks)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.md),
                          child: block.kind == ArticleBlockKind.divider
                              ? const Divider()
                              : block.kind == ArticleBlockKind.image
                              ? Text(block.altText)
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SelectableText.rich(
                                      TextSpan(
                                        style: _blockStyle(context, block.kind),
                                        children: [
                                          if (block.kind ==
                                              ArticleBlockKind.bulletedListItem)
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
                                          mode: LaunchMode.externalApplication,
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
      altText = block.altText,
      controller = ArticleTextController(block.runs) {
    controller.addListener(changed);
  }
  ArticleBlockKind kind;
  final String? mediaId;
  final String altText;
  final ArticleTextController controller;
  ArticleBlock get value => ArticleBlock(
    kind: kind,
    runs: kind == ArticleBlockKind.divider || kind == ArticleBlockKind.image
        ? const []
        : controller.runs,
    mediaId: kind == ArticleBlockKind.image ? mediaId : null,
    altText: kind == ArticleBlockKind.image ? altText : '',
  );
  void dispose() => controller.dispose();
}

class _PublishOptions {
  const _PublishOptions(this.caption, this.policy);
  final String caption;
  final ReplyAudience policy;
}

class _PublishDialog extends StatefulWidget {
  const _PublishDialog({
    required this.draft,
    this.initialCaption = '',
    this.initialPolicy = ReplyAudience.everyone,
    this.locked = false,
    this.canChooseReplyAudience = false,
    this.libraryBeside = false,
  });
  final ArticleDraft draft;

  /// The page shows the library beside it where the window allows (not in
  /// focus mode): in band B of the tablet layout its "Publish settings"
  /// then hold the audience and who can reply, and this dialog does not
  /// ([articlePublishSettingsInPaneAt], decided live).
  final bool libraryBeside;
  final String initialCaption;
  final ReplyAudience initialPolicy;

  /// A publication is pending (or being retried): the caption and policy
  /// of its first attempt are shown read-only and sent again.
  final bool locked;

  /// `reply_audience` is usable ([ArticlesRepository.canChooseReplyAudience]).
  /// Without it, like the composer, there is no reply control and the
  /// article goes out as Everyone.
  final bool canChooseReplyAudience;
  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  final _caption = TextEditingController();
  ReplyAudience _policy = ReplyAudience.everyone;

  /// A locked retry keeps its stored choice visible (disabled) even with the
  /// capability gone: it must be sent again unchanged.
  bool get _showReplyAudience => widget.canChooseReplyAudience || widget.locked;

  @override
  void initState() {
    super.initState();
    _caption.text = widget.initialCaption;
    // A refused earlier choice may still be stored on the record.
    _policy = _showReplyAudience
        ? widget.initialPolicy
        : ReplyAudience.everyone;
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsHere =
        !widget.libraryBeside || !articlePublishSettingsInPaneAt(context);
    return _dialog(context, settingsHere: settingsHere);
  }

  Widget _dialog(
    BuildContext context, {
    required bool settingsHere,
  }) => AlertDialog(
    title: const Text('Publish Article'),
    content: SizedBox(
      width: AppSize.contentMax,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (settingsHere) ...[
              Text(
                'Choose your audience',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const ListTile(
                title: Text('Everyone'),
                trailing: Icon(Icons.check_circle),
              ),
              const Divider(),
            ],
            if (settingsHere && _showReplyAudience) ...[
              Text(
                'Who can reply?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              _ReplyAudienceField(
                value: _policy,
                labelText: 'Choose who can reply to this Article',
                onChanged: widget.locked
                    ? null
                    : (value) => setState(() => _policy = value),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            TextField(
              controller: _caption,
              readOnly: widget.locked,
              maxLength: 280,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Add a caption to your article',
                helperText:
                    'Optional. Your Article link will be added automatically.',
              ),
            ),
            const Divider(),
            const Text('Post preview'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Article'),
                    Text(
                      widget.draft.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(widget.draft.excerpt()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size(
            AppSpacing.minButtonWidth,
            AppSpacing.minTapTarget,
          ),
        ),
        onPressed: () =>
            Navigator.pop(context, _PublishOptions(_caption.text, _policy)),
        child: const Text('Publish'),
      ),
    ],
  );
}

/// "Publish settings" at the top of the editor's library pane in band B of
/// the tablet layout (tablet plan section 6, item 5): the audience (only
/// Everyone until the new-features audience exists) and who can reply,
/// with the publish dialog's rules: no reply control without
/// `reply_audience` unless a pending publication must be resent, and a
/// pending or retried publication's choice shown read-only.
class _PublishSettings extends StatelessWidget {
  const _PublishSettings({
    required this.policy,
    required this.locked,
    required this.canChooseReplyAudience,
    required this.onChanged,
  });

  final ReplyAudience policy;
  final bool locked;
  final bool canChooseReplyAudience;
  final ValueChanged<ReplyAudience> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showReplyAudience = canChooseReplyAudience || locked;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text('Publish settings', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Choose your audience', style: theme.textTheme.titleMedium),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Everyone'),
            trailing: Icon(Icons.check_circle),
          ),
          if (showReplyAudience)
            _ReplyAudienceField(
              // A new value from outside (the dialog, a reload) rebuilds it.
              key: ValueKey('publish-settings-$policy-$locked'),
              value: policy,
              labelText: 'Who can reply?',
              onChanged: locked ? null : onChanged,
            ),
        ],
      ),
    );
  }
}

/// The "Who can reply?" field of the publish dialog and of the library
/// pane's "Publish settings". It takes the width it is given: the chosen
/// option shows on one line, ellipsized when it does not fit (a phone, a
/// large text scale), and the open menu shows every option whole, wrapping
/// if it must (no fixed item height). [onChanged] null: read-only.
class _ReplyAudienceField extends StatelessWidget {
  const _ReplyAudienceField({
    super.key,
    required this.value,
    required this.labelText,
    required this.onChanged,
  });

  final ReplyAudience value;
  final String labelText;
  final ValueChanged<ReplyAudience>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return DropdownButtonFormField<ReplyAudience>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: labelText),
      selectedItemBuilder: (_) => [
        for (final audience in ReplyAudience.values)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              audience.optionLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      items: [
        for (final audience in ReplyAudience.values)
          DropdownMenuItem(value: audience, child: Text(audience.optionLabel)),
      ],
      onChanged: onChanged == null ? null : (value) => onChanged(value!),
    );
  }
}
