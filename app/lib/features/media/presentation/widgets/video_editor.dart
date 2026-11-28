import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_form_header.dart';
import '../../../../shared/widgets/primitives/app_sheet.dart';
import '../../data/image_picker_service.dart';
import '../../data/photo_gallery.dart';
import '../../data/video_artwork.dart';
import '../../data/video_source.dart';
import '../../domain/image_preflight.dart';
import '../../domain/processing_cancellation.dart';
import '../../domain/video_edit.dart';

Future<VideoProject?> showVideoEditor(
  BuildContext context,
  String path,
  VideoProject? initial, {
  int savedLabels = 0,
  Future<List<VideoCaption>> Function(Uint8List, String)? transcribe,
  Future<void> Function(VideoProject)? onSaveCopy,
}) => showAppSheet<VideoProject>(
  context: context,
  semanticLabel: 'Edit video',
  enableDrag: false,
  material: const MaterialSheetOptions(
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: true,
  ),
  tabletDialogMaxWidth: 680,
  builder: (_) => _VideoEditor(
    path: path,
    initial: initial,
    savedLabels: savedLabels,
    transcribe: transcribe,
    onSaveCopy: onSaveCopy,
  ),
);

enum _Tool {
  trim('Trim', Icons.content_cut),
  text('Text', Icons.title),
  captions('Captions', Icons.closed_caption_outlined),
  cover('Cover', Icons.image_outlined),
  settings('Settings', Icons.tune);

  const _Tool(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _VideoEditor extends StatefulWidget {
  const _VideoEditor({
    required this.path,
    required this.initial,
    required this.savedLabels,
    required this.transcribe,
    required this.onSaveCopy,
  });

  final String path;
  final VideoProject? initial;
  final int savedLabels;
  final Future<List<VideoCaption>> Function(Uint8List, String)? transcribe;
  final Future<void> Function(VideoProject)? onSaveCopy;

  @override
  State<_VideoEditor> createState() => _VideoEditorState();
}

class _VideoEditorState extends State<_VideoEditor> {
  late final VideoPlayerController _player;
  late final TextEditingController _overlay;
  late final _galleryAvailable = canSavePhotoToGallery();
  late VideoTextPosition _position;
  late VideoTextStyle _textStyle;
  late double _textSize;
  late int _textColor;
  late List<VideoCaption> _captions;
  late Duration? _coverFrame;
  late Uint8List? _coverImage;
  late int _labels;
  VideoEdit? _range;
  VideoEdit? _originalRange;
  _Tool _tool = _Tool.trim;
  bool _failed = false;
  bool _busy = false;
  String? _feedback;
  String _captionLanguage = 'en-US';
  ProcessingCancellation? _captionWork;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _overlay = TextEditingController(text: initial?.overlay?.text);
    _position = initial?.overlay?.position ?? VideoTextPosition.top;
    _textStyle = initial?.overlay?.style ?? VideoTextStyle.strong;
    _textSize = initial?.overlay?.size ?? 1;
    _textColor = initial?.overlay?.color ?? 0xffffffff;
    _captions = initial?.captions ?? const [];
    _coverFrame = initial?.coverFrame;
    _coverImage = initial?.coverImage;
    _labels = initial?.labels ?? widget.savedLabels;
    _player = pickedVideoController(widget.path)..addListener(_onPlayback);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _player.initialize();
      if (!mounted) return;
      final duration = _player.value.duration;
      if (duration.inMilliseconds < 1) {
        setState(() => _failed = true);
        return;
      }
      final initial = widget.initial?.range;
      _originalRange = initial != null && initial.end <= duration
          ? initial
          : (start: Duration.zero, end: duration, muted: false);
      await _player.setVolume(_originalRange!.muted ? 0 : 1);
      if (!mounted) return;
      await _player.seekTo(_originalRange!.start);
      if (mounted) setState(() => _range = _originalRange);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onPlayback() {
    final range = _range;
    final value = _player.value;
    if (range != null && value.isPlaying && value.position >= range.end) {
      unawaited(_player.pause());
    }
  }

  Future<void> _togglePlayback(VideoEdit range) async {
    if (_player.value.isPlaying) {
      await _player.pause();
      return;
    }
    final position = _player.value.position;
    if (position < range.start || position >= range.end) {
      await _player.seekTo(range.start);
    }
    if (mounted) await _player.play();
  }

  @override
  void dispose() {
    _captionWork?.cancel();
    _overlay.dispose();
    _player.removeListener(_onPlayback);
    unawaited(_player.dispose());
    super.dispose();
  }

  VideoOverlay? get _currentOverlay {
    final text = _overlay.text.trim();
    return text.isEmpty
        ? null
        : (
            text: text,
            position: _position,
            style: _textStyle,
            size: _textSize,
            color: _textColor,
          );
  }

  VideoProject _project(VideoEdit range) => VideoProject(
    range: range,
    overlay: _currentOverlay,
    captions: _captions,
    coverFrame: _coverFrame,
    coverImage: _coverImage,
    labels: _labels,
  );

  void _done(VideoEdit range) {
    final original = widget.initial;
    final changed =
        range != _originalRange ||
        _currentOverlay != original?.overlay ||
        _captions != (original?.captions ?? const <VideoCaption>[]) ||
        _coverFrame != original?.coverFrame ||
        _coverImage != original?.coverImage ||
        _labels != (original?.labels ?? widget.savedLabels);
    Navigator.pop(context, changed ? _project(range) : null);
  }

  void _changeRange(RangeValues selection, VideoEdit previous) {
    final start = Duration(milliseconds: selection.start.round());
    final end = Duration(milliseconds: selection.end.round());
    final duration = _player.value.duration;
    const threshold = Duration(milliseconds: 100);
    final minimum = duration < threshold ? duration : threshold;
    if (end - start < minimum) return;
    setState(() => _range = (start: start, end: end, muted: previous.muted));
  }

  static String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}.'
      '${value.inMilliseconds % 1000 ~/ 100}';

  Future<void> _importCaptions() async {
    await _run(() async {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Captions',
            extensions: ['srt', 'vtt'],
            mimeTypes: ['application/x-subrip', 'text/vtt', 'text/plain'],
            uniformTypeIdentifiers: ['public.text'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 64 * 1024) {
        throw const FormatException('Choose a caption file under 64 KiB.');
      }
      final cues = parseVideoCaptions(utf8.decode(await file.readAsBytes()));
      final duration = _player.value.duration;
      if (!cues.any((cue) => cue.start < duration)) {
        throw const FormatException('The captions start after the video ends.');
      }
      if (mounted) {
        setState(() {
          _captions = List.unmodifiable(
            cues.where((cue) => cue.start < duration),
          );
        });
      }
    }, failure: 'Could not import the captions.');
  }

  Future<void> _generateCaptions() async {
    final range = _range;
    final transcribe = widget.transcribe;
    if (range == null || transcribe == null || _busy) return;
    final language = _captionLanguage;
    final cancellation = ProcessingCancellation();
    _captionWork = cancellation;
    await _run(
      () async {
        final windows = captionWindows(range);
        final chunks = await extractCaptionSegments(
          widget.path,
          windows,
          cancellation,
        );
        final captions = <VideoCaption>[];
        for (final (i, window) in windows.indexed) {
          cancellation.throwIfCancelled();
          if (mounted) {
            setState(
              () => _feedback =
                  'Transcribing audio ${i + 1} of ${windows.length}…',
            );
          }
          final result = await cancellation.guard(
            transcribe(chunks[i], language),
          );
          final limit = window.start + window.length;
          for (final cue in result) {
            final start = window.start + cue.start;
            final end = window.start + cue.end;
            if (start < limit && end > start) {
              captions.add((
                start: start,
                end: end > limit ? limit : end,
                text: cue.text,
              ));
            }
          }
        }
        if (captions.isEmpty) {
          throw const FormatException('No speech was detected.');
        }
        if (mounted) setState(() => _captions = List.unmodifiable(captions));
      },
      failure: 'Could not generate captions.',
      success: 'Captions generated.',
    );
    _captionWork = null;
  }

  Future<void> _reviewCaptions() async {
    await _player.pause();
    if (!mounted) return;
    final index = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review captions'),
        content: SizedBox(
          width: 440,
          height: MediaQuery.sizeOf(context).height * .45,
          child: ListView.builder(
            itemCount: _captions.length,
            itemBuilder: (context, index) {
              final cue = _captions[index];
              return ListTile(
                title: Text(cue.text),
                subtitle: Text('${_time(cue.start)} – ${_time(cue.end)}'),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => Navigator.pop(context, index),
              );
            },
          ),
        ),
      ),
    );
    if (!mounted || index == null) return;
    final cue = _captions[index];
    var edited = cue.text;
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit caption'),
        content: TextFormField(
          initialValue: edited,
          autofocus: true,
          maxLength: 240,
          maxLines: 4,
          onChanged: (value) => edited = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, edited.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (!mounted || text == null) return;
    setState(() {
      final updated = [..._captions];
      if (text.isEmpty) {
        updated.removeAt(index);
      } else {
        updated[index] = (start: cue.start, end: cue.end, text: text);
      }
      _captions = List.unmodifiable(updated);
    });
  }

  Future<void> _uploadCover() async {
    await _run(() async {
      final images = await PlatformImagePickerService().pickImages(limit: 1);
      if (images.isEmpty || !mounted) return;
      preflightImage(images.single);
      setState(() {
        _coverImage = images.single;
        _coverFrame = null;
      });
    }, failure: 'Could not open that cover image.');
  }

  Future<void> _run(
    Future<void> Function() action, {
    required String failure,
    String? success,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await action();
      if (mounted) setState(() => _feedback = success);
    } catch (error) {
      if (mounted) {
        setState(
          () => _feedback = switch (error) {
            FormatException(:final message) => message,
            AppException(:final message) => message,
            _ => failure,
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFormHeader(
          title: 'Edit video',
          onCancel: () => Navigator.pop(context),
          actionLabel: 'Done',
          onAction: range == null || _busy ? null : () => _done(range),
        ),
        Flexible(
          child: SingleChildScrollView(
            clipBehavior: Clip.none,
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: _failed
                ? const Text('This clip could not be opened for editing.')
                : range == null
                ? const Center(child: CircularProgressIndicator())
                : _workspace(context, range),
          ),
        ),
      ],
    );
  }

  Widget _workspace(BuildContext context, VideoEdit range) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _preview(context, range),
      const SizedBox(height: 8),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tool in _Tool.values)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: ChoiceChip(
                  avatar: Icon(tool.icon, size: 18),
                  label: Text(tool.label),
                  selected: _tool == tool,
                  onSelected: _busy
                      ? null
                      : (_) {
                          setState(() {
                            _tool = tool;
                            _feedback = null;
                          });
                          if (tool == _Tool.cover) {
                            unawaited(_player.pause());
                            unawaited(
                              _player.seekTo(_coverFrame ?? range.start),
                            );
                          }
                        },
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      switch (_tool) {
        _Tool.trim => _trimPanel(range),
        _Tool.text => _textPanel(),
        _Tool.captions => _captionPanel(),
        _Tool.cover => _coverPanel(range),
        _Tool.settings => _settingsPanel(),
      },
      if (widget.onSaveCopy != null)
        FutureBuilder<bool>(
          future: _galleryAvailable,
          builder: (context, available) => available.data == true
              ? Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => widget.onSaveCopy!(_project(range)),
                            failure:
                                'Could not save the video to your gallery.',
                            success: 'Saved to gallery.',
                          ),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Save video to gallery'),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      if (_busy) const LinearProgressIndicator(),
      if (_feedback case final message?)
        Semantics(liveRegion: true, child: Text(message)),
    ],
  );

  Widget _preview(BuildContext context, VideoEdit range) =>
      ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: _player,
        builder: (context, value, _) {
          final overlay = _currentOverlay;
          final captions = _captions.where(
            (cue) => value.position >= cue.start && value.position < cue.end,
          );
          final cover = _tool == _Tool.cover ? _coverImage : null;
          return Column(
            children: [
              SizedBox(
                height: MediaQuery.sizeOf(context).height * .36,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: value.aspectRatio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final shortest = constraints.biggest.shortestSide;
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              if (cover != null)
                                Image.memory(
                                  cover,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Center(
                                    child: Text(
                                      'This cover could not be displayed.',
                                    ),
                                  ),
                                )
                              else
                                VideoPlayer(_player),
                              if (cover == null && overlay != null)
                                _previewLabel(
                                  overlay.text,
                                  _overlayPosition(overlay),
                                  shortest,
                                  overlay: overlay,
                                ),
                              if (cover == null && captions.isNotEmpty)
                                _previewLabel(
                                  captions.first.text,
                                  VideoTextPosition.bottom,
                                  shortest,
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: value.isPlaying ? 'Pause preview' : 'Play preview',
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                    onPressed: _busy || cover != null
                        ? null
                        : () => _togglePlayback(range),
                  ),
                  Text(_time(value.position)),
                  IconButton(
                    tooltip: range.muted ? 'Unmute audio' : 'Mute audio',
                    icon: Icon(
                      range.muted
                          ? Icons.volume_off_outlined
                          : Icons.volume_up_outlined,
                    ),
                    onPressed: _busy
                        ? null
                        : () {
                            setState(
                              () => _range = (
                                start: range.start,
                                end: range.end,
                                muted: !range.muted,
                              ),
                            );
                            unawaited(_player.setVolume(range.muted ? 1 : 0));
                          },
                  ),
                ],
              ),
            ],
          );
        },
      );

  VideoTextPosition _overlayPosition(VideoOverlay overlay) =>
      _captions.isNotEmpty && overlay.position == VideoTextPosition.bottom
      ? VideoTextPosition.center
      : overlay.position;

  Widget _previewLabel(
    String text,
    VideoTextPosition position,
    double size, {
    VideoOverlay? overlay,
  }) => Align(
    alignment: switch (position) {
      VideoTextPosition.top => const Alignment(0, -.85),
      VideoTextPosition.center => Alignment.center,
      VideoTextPosition.bottom => const Alignment(0, .85),
    },
    child: FractionallySizedBox(
      widthFactor: .88,
      child: Center(
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: videoTextBackground(overlay),
            borderRadius: BorderRadius.circular(size * .018),
          ),
          child: Padding(
            padding: EdgeInsets.all(size * .018),
            child: Text(
              text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: videoTextStyle(size, overlay: overlay),
              textScaler: TextScaler.noScaling,
            ),
          ),
        ),
      ),
    ),
  );

  Widget _trimPanel(VideoEdit range) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${_time(range.start)} – ${_time(range.end)}  ·  ${_time(range.end - range.start)} selected',
      ),
      Semantics(
        label: 'Trim range',
        child: RangeSlider(
          values: RangeValues(
            range.start.inMilliseconds.toDouble(),
            range.end.inMilliseconds.toDouble(),
          ),
          max: _player.value.duration.inMilliseconds.toDouble(),
          labels: RangeLabels(_time(range.start), _time(range.end)),
          semanticFormatterCallback: (value) =>
              _time(Duration(milliseconds: value.round())),
          onChangeStart: (_) => unawaited(_player.pause()),
          onChanged: _busy ? null : (value) => _changeRange(value, range),
          onChangeEnd: (_) => unawaited(_player.seekTo(_range!.start)),
        ),
      ),
    ],
  );

  Widget _textPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _overlay,
        enabled: !_busy,
        onChanged: (_) => setState(() {}),
        minLines: 1,
        maxLines: 3,
        maxLength: 100,
        decoration: const InputDecoration(labelText: 'Video text'),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final style in VideoTextStyle.values)
            ChoiceChip(
              label: Text(style.label),
              selected: _textStyle == style,
              onSelected: _busy
                  ? null
                  : (_) => setState(() => _textStyle = style),
            ),
        ],
      ),
      Row(
        children: [
          PopupMenuButton<int>(
            tooltip: 'Text color',
            enabled: !_busy,
            onSelected: (value) => setState(() => _textColor = value),
            icon: const Icon(Icons.palette_outlined),
            itemBuilder: (_) => [
              for (final (color, label) in const [
                (0xffffffff, 'White'),
                (0xffffdb74, 'Yellow'),
                (0xff8ce4ff, 'Blue'),
                (0xffff9eae, 'Pink'),
              ])
                PopupMenuItem(value: color, child: Text(label)),
            ],
          ),
          Expanded(
            child: Semantics(
              label: 'Text size',
              child: Slider(
                value: _textSize,
                min: .65,
                max: 1.45,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _textSize = value),
              ),
            ),
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final (position, label) in const [
            (VideoTextPosition.top, 'Top'),
            (VideoTextPosition.center, 'Center'),
            (VideoTextPosition.bottom, 'Bottom'),
          ])
            ChoiceChip(
              label: Text(label),
              selected: _position == position,
              onSelected:
                  _busy ||
                      (_captions.isNotEmpty &&
                          position == VideoTextPosition.bottom)
                  ? null
                  : (_) => setState(() => _position = position),
            ),
        ],
      ),
    ],
  );

  Widget _captionPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _captions.isEmpty
            ? 'Captions appear in the exported video.'
            : '${_captions.length} timed captions',
      ),
      if (widget.transcribe != null) ...[
        const Text(
          'Generate captions from the selected audio using Google Cloud.',
        ),
        DropdownButton<String>(
          value: _captionLanguage,
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) setState(() => _captionLanguage = value);
                },
          items: [
            for (final (code, name) in const [
              ('en-US', 'English (US)'),
              ('en-IN', 'English (India)'),
              ('hi-IN', 'Hindi'),
              ('te-IN', 'Telugu'),
              ('ta-IN', 'Tamil'),
              ('es-ES', 'Spanish'),
              ('fr-FR', 'French'),
            ])
              DropdownMenuItem(value: code, child: Text(name)),
          ],
        ),
      ],
      Wrap(
        spacing: 8,
        children: [
          if (widget.transcribe != null)
            TextButton.icon(
              onPressed: _busy ? null : _generateCaptions,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Generate captions'),
            ),
          TextButton.icon(
            onPressed: _busy ? null : _importCaptions,
            icon: const Icon(Icons.upload_file_outlined),
            label: Text(
              _captions.isEmpty ? 'Import captions' : 'Replace captions',
            ),
          ),
          if (_captions.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : _reviewCaptions,
              child: const Text('Review captions'),
            ),
          if (_captions.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _captions = const []),
              child: const Text('Remove captions'),
            ),
        ],
      ),
    ],
  );

  Widget _settingsPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Sensitive content is hidden until viewers choose to reveal it.',
      ),
      for (final label in VideoLabel.values)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(label.label),
          value: _labels & label.bit != 0,
          onChanged: _busy
              ? null
              : (checked) => setState(() {
                  _labels = checked == true
                      ? _labels | label.bit
                      : _labels & ~label.bit;
                }),
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Allow in-app downloads'),
        subtitle: const Text('Show a download action to viewers in Dzeroth.'),
        value: _labels & kAllowVideoDownload != 0,
        onChanged: _busy
            ? null
            : (allowed) => setState(() {
                _labels = allowed
                    ? _labels | kAllowVideoDownload
                    : _labels & ~kAllowVideoDownload;
              }),
      ),
    ],
  );

  Widget _coverPanel(VideoEdit range) {
    final min = range.start.inMilliseconds.toDouble();
    final max = range.end.inMilliseconds.toDouble();
    final frame = (_coverFrame?.inMilliseconds.toDouble() ?? min).clamp(
      min,
      max,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _coverImage != null
              ? 'Uploaded cover'
              : 'Cover frame · ${_time(Duration(milliseconds: frame.round()))}',
        ),
        if (_coverImage == null)
          Semantics(
            label: 'Cover frame',
            child: Slider(
              min: min,
              max: max,
              value: frame,
              semanticFormatterCallback: (value) =>
                  _time(Duration(milliseconds: value.round())),
              onChanged: _busy
                  ? null
                  : (value) {
                      final time = Duration(milliseconds: value.round());
                      setState(() => _coverFrame = time);
                      unawaited(_player.pause());
                      unawaited(_player.seekTo(time));
                    },
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _busy ? null : _uploadCover,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Upload cover'),
            ),
            if (_coverImage != null || _coverFrame != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _coverImage = null;
                        _coverFrame = null;
                        unawaited(_player.seekTo(range.start));
                      }),
                child: const Text('Use first frame'),
              ),
          ],
        ),
      ],
    );
  }
}
