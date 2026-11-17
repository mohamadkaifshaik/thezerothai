import 'dart:async';

import '../../../shared/widgets/post/post_list_skeleton.dart';

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart'
    show TextInputFormatter, TextEditingValue;
import 'package:crypto/crypto.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/feature_flags/feature_flags.dart';
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
import '../../media/domain/media_feature_flag.dart' show kMaxAltTextLength;
import '../../../shared/widgets/primitives/character_counter.dart';
import 'widgets/article_cover_placeholder.dart';
import 'widgets/article_image_block.dart';

part 'articles_persistence.dart';
part 'articles_library.dart';
part 'articles_layout.dart';
part 'articles_editor.dart';
part 'articles_toolbar.dart';
part 'articles_block_editors.dart';
part 'articles_reader.dart';
part 'articles_blocks.dart';
part 'articles_publish_dialog.dart';

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
  MediaUploader? _imageUploader;

  /// Thumbnails of images inserted this session, by media id (the server's
  /// resolved copy is not in a save's answer).
  final _imageThumbs = <String, Uint8List>{};
  int _loadGeneration = 0;
  bool _loadingMore = false;
  int _sideGeneration = 0;
  bool _sideLoading = false;
  bool _sideRequested = false;
  String? _error;

  /// The draft-limit copy last built by [_message] (it carries the server's
  /// cap), so the banner can tell that error apart: it only dismisses.
  String? _draftLimitText;
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
      ? (_draftLimitText = articleDraftLimitMessageFor(error))
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

  @override
  Widget build(BuildContext context) {
    final read =
        widget.preview ||
        widget.reader ||
        (_record?.published ?? false) ||
        (_record?.publicationPending ?? false);
    final body = _loading
        ? const PostListSkeleton(
            mediaEvery: 0,
            semanticsLabel: 'Loading articles',
          )
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
      // Nothing to pop (reached with go from the drawer): take the back
      // gesture ourselves so _back() can step up to the library or Home.
      canPop: !_dirty && !_saving && (GoRouter.maybeOf(context)?.canPop() ?? true),
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
                  if (_error == _draftLimitText ||
                      _error == articleDraftLimitMessage)
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
}
