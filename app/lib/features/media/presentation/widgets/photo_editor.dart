import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/tablet_modal.dart';
import '../../../../shared/widgets/primitives/app_form_header.dart';
import '../../../../shared/widgets/primitives/app_sheet.dart';
import '../../../../shared/widgets/primitives/character_counter.dart';
import '../../domain/media_feature_flag.dart';
import '../../domain/photo_edit.dart';

/// What the editor returns on Done.
@immutable
class PhotoEditResult {
  const PhotoEditResult({required this.edit, required this.altText});
  final PhotoEdit edit;
  final String altText;
}

/// Opens the photo editor: a full-height bottom sheet on a phone, a dialog on
/// the tablet and desktop layouts (the app's sheet mapping, `showAppSheet`).
/// Returns the edit and alt text on Done, or null on Cancel / dismiss, when
/// nothing changes.
///
/// [source] is the unedited, oriented photo the crop box sits on (the cubit's
/// `previewOf`, at most 2048 px); a GIF passes none and only
/// gets the description. [preview] shows when there is no [source].
Future<PhotoEditResult?> showPhotoEditor(
  BuildContext context, {
  Uint8List? source,
  Uint8List? preview,
  PhotoEdit initialEdit = PhotoEdit.none,
  String initialAlt = '',
  bool isGif = false,
}) {
  final inDialog = TabletModalHost.of(context) != null;
  return showAppSheet<PhotoEditResult>(
    context: context,
    semanticLabel: isGif ? 'Edit GIF' : 'Edit photo',
    // A crop drag must never pull the sheet down.
    enableDrag: false,
    material: const MaterialSheetOptions(
      isScrollControlled: true,
      showDragHandle: false,
      useSafeArea: true,
      useRootNavigator: true,
    ),
    tabletDialogMaxWidth: 720,
    builder: (context) => PhotoEditorView(
      source: isGif ? null : source,
      preview: preview,
      initialEdit: initialEdit,
      initialAlt: initialAlt,
      isGif: isGif,
      expand: !inDialog,
    ),
  );
}

/// The editor content: header (Cancel, title, Done), the photo with its crop
/// box, the aspect presets and Rotate, and the description field. The controls
/// scroll, so everything is reachable at any text scale or width.
class PhotoEditorView extends StatefulWidget {
  const PhotoEditorView({
    super.key,
    this.source,
    this.preview,
    this.initialEdit = PhotoEdit.none,
    this.initialAlt = '',
    this.isGif = false,
    this.expand = false,
  });

  final Uint8List? source;
  final Uint8List? preview;
  final PhotoEdit initialEdit;
  final String initialAlt;
  final bool isGif;

  /// Fill the height the host gives (the phone sheet); else a fixed photo
  /// height (dialogs size to their content).
  final bool expand;

  @override
  State<PhotoEditorView> createState() => _PhotoEditorViewState();
}

class _PhotoEditorViewState extends State<PhotoEditorView> {
  late final TextEditingController _alt = TextEditingController(
    text: widget.initialAlt,
  );
  late PhotoEdit _edit = widget.initialEdit;
  CropPreset _preset = CropPreset.original;

  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _size;
  bool _failed = false;

  bool get _cropping => !widget.isGif && widget.source != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cropping && _provider == null) {
      // Decoded at a bounded size: a 12 MP source is never held in full.
      _provider = ResizeImage(MemoryImage(widget.source!), width: 1600);
      _listener = ImageStreamListener(
        (info, _) {
          if (!mounted) return;
          setState(
            () => _size = Size(
              info.image.width.toDouble(),
              info.image.height.toDouble(),
            ),
          );
        },
        onError: (_, _) {
          if (mounted) setState(() => _failed = true);
        },
      );
      _stream = _provider!.resolve(createLocalImageConfiguration(context))
        ..addListener(_listener!);
    }
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _alt.dispose();
    super.dispose();
  }

  /// Width / height of the photo as the user sees it (after rotation).
  double get _aspect {
    final s = _size!;
    return _edit.quarterTurns.isOdd ? s.height / s.width : s.width / s.height;
  }

  void _selectPreset(CropPreset preset) {
    setState(() {
      _preset = preset;
      _edit = _edit.withBox(
        fitPreset(preset.ratio, _aspect, around: _edit.box),
      );
    });
  }

  void _rotate() {
    setState(() {
      _edit = _edit.rotated();
      _preset = CropPreset.original;
    });
  }

  void _box(CropFractions box) => setState(() => _edit = _edit.withBox(box));

  @override
  Widget build(BuildContext context) {
    final controls = SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_cropping && _size != null && !_failed) ...[
            _presets(),
            const SizedBox(height: AppSpacing.sm),
          ],
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _alt,
            builder: (context, value, _) {
              final left = kMaxAltTextLength - value.text.runes.length;
              return TextField(
                controller: _alt,
                minLines: 2,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Description',
                  hintText: 'Describe the photo for people who cannot see it',
                  alignLabelWithHint: true,
                  counter: CharacterCounter(remaining: left),
                  errorText: left < 0
                      ? 'At most $kMaxAltTextLength characters.'
                      : null,
                ),
              );
            },
          ),
        ],
      ),
    );

    final photoHeight = math.max(
      200.0,
      math.min(400.0, MediaQuery.sizeOf(context).height * 0.4),
    );
    final photo = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: _photo(),
    );

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _alt,
      builder: (context, value, _) {
        final over = kMaxAltTextLength - value.text.runes.length < 0;
        final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
        final column = Column(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppFormHeader(
              title: widget.isGif ? 'Edit GIF' : 'Edit photo',
              onCancel: () => Navigator.of(context).pop(),
              actionLabel: 'Done',
              onAction: over
                  ? null
                  : () => Navigator.of(context)
                        .pop(PhotoEditResult(edit: _edit, altText: _alt.text)),
            ),
            if (widget.expand)
              // With the keyboard up the controls get most of the room.
              Expanded(flex: typing ? 1 : 3, child: photo)
            else
              SizedBox(height: photoHeight, child: photo),
            if (widget.expand)
              Flexible(flex: typing ? 3 : 2, child: controls)
            else
              Flexible(child: controls),
          ],
        );
        // The sheet does not lift for the keyboard by itself.
        return widget.expand
            ? Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: column,
              )
            : column;
      },
    );
  }

  Widget _presets() {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final preset in CropPreset.values)
          ChoiceChip(
            label: Text(preset.label),
            selected: _preset == preset,
            onSelected: (_) => _selectPreset(preset),
          ),
        ActionChip(
          avatar: const Icon(Icons.rotate_90_degrees_cw_outlined, size: 18),
          label: const Text('Rotate'),
          tooltip: 'Rotate 90 degrees',
          onPressed: _rotate,
        ),
      ],
    );
  }

  Widget _photo() {
    if (_cropping) {
      if (_failed) {
        return Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      }
      final size = _size;
      if (size == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return CropCanvas(
        image: _provider!,
        quarterTurns: _edit.quarterTurns,
        aspect: _aspect,
        box: _edit.box,
        lockRatio: _preset.ratio,
        onChanged: _box,
      );
    }
    final preview = widget.preview;
    if (preview == null) return const SizedBox.shrink();
    return Semantics(
      image: true,
      label: widget.isGif ? 'GIF being described' : 'Photo being described',
      excludeSemantics: true,
      child: Image.memory(preview, fit: BoxFit.contain),
    );
  }
}

/// Finds the photo area and the crop box (tests).
const Key kCropPhotoKey = ValueKey('crop-photo');
const Key kCropBoxKey = ValueKey('crop-box');

/// The photo with a draggable crop box. [box] is in fractions of the ROTATED
/// photo, [aspect] its width / height as shown. Drag the box to move it, pinch
/// (or scroll) to resize it about its centre, drag a corner handle to resize
/// it ([lockRatio] keeps the preset's shape, else the corner is free). The box
/// is also reachable without touch: its semantics offer move and size
/// actions.
class CropCanvas extends StatelessWidget {
  const CropCanvas({
    super.key,
    required this.image,
    required this.quarterTurns,
    required this.aspect,
    required this.box,
    required this.onChanged,
    this.lockRatio,
  });

  final ImageProvider image;
  final int quarterTurns;
  final double aspect;
  final CropFractions box;
  final double? lockRatio;
  final ValueChanged<CropFractions> onChanged;

  /// How far one move / size action shifts the box (fraction of the photo).
  static const double actionStep = 0.05;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Room around the photo for the corner handles, so their whole
        // target can be hit.
        const pad = _Interactive.inset * 2;
        final maxW = constraints.maxWidth - pad;
        final maxH = constraints.maxHeight.isFinite
            ? constraints.maxHeight - pad
            : maxW / aspect;
        var w = maxW;
        var h = w / aspect;
        if (h > maxH) {
          h = maxH;
          w = h * aspect;
        }
        return Center(
          child: SizedBox(
            width: w + pad,
            height: h + pad,
            child: _Interactive(
              width: w,
              height: h,
              image: image,
              quarterTurns: quarterTurns,
              aspect: aspect,
              box: box,
              lockRatio: lockRatio,
              onChanged: onChanged,
            ),
          ),
        );
      },
    );
  }
}

class _Interactive extends StatelessWidget {
  const _Interactive({
    required this.width,
    required this.height,
    required this.image,
    required this.quarterTurns,
    required this.aspect,
    required this.box,
    required this.lockRatio,
    required this.onChanged,
  });

  final double width;
  final double height;
  final ImageProvider image;
  final int quarterTurns;
  final double aspect;
  final CropFractions box;
  final double? lockRatio;
  final ValueChanged<CropFractions> onChanged;

  static const double _handle = AppSpacing.minTapTarget;

  /// Space kept around the photo for the handles' outer halves.
  static const double inset = _handle / 2;

  @override
  Widget build(BuildContext context) {
    final rect = Rect.fromLTRB(
      box.left * width,
      box.top * height,
      box.right * width,
      box.bottom * height,
    );
    final colors = Theme.of(context).colorScheme;
    final pctW = ((box.right - box.left) * 100).round();
    final pctH = ((box.bottom - box.top) * 100).round();

    void drag(CropHandle handle, Offset delta) => onChanged(
      dragHandle(
        box,
        handle,
        delta.dx / width,
        delta.dy / height,
        ratio: lockRatio,
        photoAspect: aspect,
      ),
    );

    Widget handle(CropHandle which, Offset corner, String label) {
      return Positioned(
        left: corner.dx - _handle / 2,
        top: corner.dy - _handle / 2,
        width: _handle,
        height: _handle,
        child: Semantics(
          label: label,
          excludeSemantics: true,
          // A scale recognizer, like the box under it, so the handle (hit
          // first) wins the arena instead of the box moving.
          child: _HandleDrag(
            onDelta: (delta) => drag(which, delta),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.onPrimary, width: 2),
                ),
                child: const SizedBox.square(dimension: 16),
              ),
            ),
          ),
        ),
      );
    }

    final shift = const Offset(inset, inset);
    return Stack(
      children: [
        Positioned(
          left: inset,
          top: inset,
          width: width,
          height: height,
          child: SizedBox(
            key: kCropPhotoKey,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ExcludeSemantics(
                    child: RotatedBox(
                      quarterTurns: quarterTurns,
                      child: Image(
                        image: image,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _CropPainter(
                        rect: rect,
                        shade: colors.scrim.withValues(alpha: 0.55),
                        line: colors.onPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // The box: drag to move, pinch to resize.
        Positioned.fromRect(
          rect: rect.shift(shift),
          child: Semantics(
            key: kCropBoxKey,
            container: true,
            label: 'Crop box',
            value: '$pctW percent wide, $pctH percent tall',
            customSemanticsActions: {
              const CustomSemanticsAction(label: 'Move crop left'): () =>
                  onChanged(moveCrop(box, -CropCanvas.actionStep, 0)),
              const CustomSemanticsAction(label: 'Move crop right'): () =>
                  onChanged(moveCrop(box, CropCanvas.actionStep, 0)),
              const CustomSemanticsAction(label: 'Move crop up'): () =>
                  onChanged(moveCrop(box, 0, -CropCanvas.actionStep)),
              const CustomSemanticsAction(label: 'Move crop down'): () =>
                  onChanged(moveCrop(box, 0, CropCanvas.actionStep)),
              const CustomSemanticsAction(label: 'Larger crop'): () =>
                  onChanged(zoomCrop(box, 1 + CropCanvas.actionStep * 2)),
              const CustomSemanticsAction(label: 'Smaller crop'): () =>
                  onChanged(zoomCrop(box, 1 - CropCanvas.actionStep * 2)),
            },
            child: _BoxGesture(
              width: width,
              height: height,
              box: box,
              onChanged: onChanged,
            ),
          ),
        ),
        handle(
          CropHandle.topLeft,
          rect.topLeft + shift,
          'Crop corner, top left',
        ),
        handle(
          CropHandle.topRight,
          rect.topRight + shift,
          'Crop corner, top right',
        ),
        handle(
          CropHandle.bottomLeft,
          rect.bottomLeft + shift,
          'Crop corner, bottom left',
        ),
        handle(
          CropHandle.bottomRight,
          rect.bottomRight + shift,
          'Crop corner, bottom right',
        ),
      ],
    );
  }
}

/// Move (one finger) and resize about the centre (pinch) of the box.
class _BoxGesture extends StatefulWidget {
  const _BoxGesture({
    required this.width,
    required this.height,
    required this.box,
    required this.onChanged,
  });

  final double width;
  final double height;
  final CropFractions box;
  final ValueChanged<CropFractions> onChanged;

  @override
  State<_BoxGesture> createState() => _BoxGestureState();
}

/// A one-finger drag that reports its movement, on a scale recognizer.
class _HandleDrag extends StatefulWidget {
  const _HandleDrag({required this.onDelta, required this.child});

  final ValueChanged<Offset> onDelta;
  final Widget child;

  @override
  State<_HandleDrag> createState() => _HandleDragState();
}

class _HandleDragState extends State<_HandleDrag> {
  Offset _last = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (d) => _last = d.focalPoint,
      onScaleUpdate: (d) {
        widget.onDelta(d.focalPoint - _last);
        _last = d.focalPoint;
      },
      child: widget.child,
    );
  }
}

class _BoxGestureState extends State<_BoxGesture> {
  Offset _last = Offset.zero;
  double _lastScale = 1;
  int _pointers = 0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      // A mouse wheel resizes the box too.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
          final factor = event.scrollDelta.dy > 0 ? 1.05 : 0.95;
          widget.onChanged(zoomCrop(widget.box, factor));
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) {
          _last = d.localFocalPoint;
          _lastScale = 1;
          _pointers = d.pointerCount;
        },
        onScaleUpdate: (d) {
          var next = widget.box;
          if (d.pointerCount != _pointers) {
            // A finger came or went: the focal point jumps, it is not a move.
            _pointers = d.pointerCount;
            _last = d.localFocalPoint;
            _lastScale = d.scale;
          }
          final delta = d.localFocalPoint - _last;
          _last = d.localFocalPoint;
          if (delta != Offset.zero) {
            next = moveCrop(
              next,
              delta.dx / widget.width,
              delta.dy / widget.height,
            );
          }
          if (d.scale != _lastScale && d.pointerCount > 1) {
            // A pinch out shows less of the photo: the box shrinks.
            next = zoomCrop(next, _lastScale / d.scale);
          }
          _lastScale = d.scale;
          if (next != widget.box) widget.onChanged(next);
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.rect,
    required this.shade,
    required this.line,
  });

  final Rect rect;
  final Color shade;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rect);
    canvas.drawPath(outside, Paint()..color = shade);
    final stroke = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, stroke);
    final thin = Paint()
      ..color = line.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = rect.left + rect.width * i / 3;
      final y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), thin);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), thin);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.rect != rect || old.shade != shade || old.line != line;
}
