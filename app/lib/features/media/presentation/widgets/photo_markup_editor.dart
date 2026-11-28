import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../data/image_picker_service.dart';
import '../../domain/image_preflight.dart';
import '../../domain/photo_edit.dart';

typedef MarkupResult = ({PhotoMarkup? markup});

Future<MarkupResult?> showPhotoMarkupEditor(
  BuildContext context,
  Uint8List photo,
  PhotoEdit edit,
) => Navigator.of(context).push<MarkupResult>(
  MaterialPageRoute(
    builder: (_) => _MarkupEditor(photo: photo, edit: edit),
  ),
);

enum _Tool {
  draw('Draw', Icons.brush_outlined),
  pixelate('Pixelate', Icons.blur_on),
  redact('Redact', Icons.rectangle_outlined),
  text('Text', Icons.text_fields),
  photo('Add photo', Icons.add_photo_alternate_outlined),
  collage('Collage', Icons.grid_view_outlined);

  const _Tool(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _Mark {
  _Mark(
    this.tool,
    this.color,
    this.width,
    this.points,
    this.text, {
    this.images = const [],
  });

  final _Tool tool;
  final Color color;
  final double width;
  final List<Offset> points;
  final String? text;
  final List<ui.Image> images;
}

class _MarkupEditor extends StatefulWidget {
  const _MarkupEditor({required this.photo, required this.edit});

  final Uint8List photo;
  final PhotoEdit edit;

  @override
  State<_MarkupEditor> createState() => _MarkupEditorState();
}

class _MarkupEditorState extends State<_MarkupEditor> {
  final _marks = <_Mark>[];
  ui.Image? _photo;
  ui.Image? _mosaic;
  ui.Image? _previous;
  bool _hidePrevious = false;
  bool _failed = false;
  bool _saving = false;
  _Mark? _active;
  _Tool _tool = _Tool.draw;
  Color _color = AppColors.markupRed;
  double _width = 0.045;
  String? _text;
  ui.Image? _pendingPhoto;
  final _imported = <ui.Image>[];
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<ui.Image> _decode(Uint8List bytes, {int? width}) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: width,
      allowUpscaling: false,
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  Future<void> _load() async {
    ui.Image? photo;
    ui.Image? previous;
    try {
      photo = await _decode(widget.photo, width: 1600);
      final markup = widget.edit.markup;
      if (markup != null) previous = await _decode(markup.png);
      if (!mounted) return;
      setState(() {
        _photo = photo;
        _previous = previous;
      });
      photo = previous = null;
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      photo?.dispose();
      previous?.dispose();
    }
  }

  @override
  void dispose() {
    _photo?.dispose();
    _previous?.dispose();
    for (final image in _imported) {
      image.dispose();
    }
    super.dispose();
  }

  _MarkupPainter get _painter => _MarkupPainter(
    photo: _photo!,
    previous: _hidePrevious ? null : _previous,
    edit: widget.edit,
    marks: List.of(_marks),
  );

  Future<ui.Image> _snapshot({bool mosaic = false, bool layer = false}) async {
    final painter = _painter;
    final size = painter.size;
    final scale = mosaic ? math.min(1.0, 48 / size.shortestSide) : 1.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    if (layer) {
      painter.paintLayer(canvas, size);
    } else {
      painter.paint(canvas, size);
    }
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(
        math.max(1, (size.width * scale).round()),
        math.max(1, (size.height * scale).round()),
      );
    } finally {
      picture.dispose();
    }
  }

  Future<void> _save() async {
    if (_marks.isEmpty) {
      Navigator.pop(context, _hidePrevious ? (markup: null) : null);
      return;
    }
    setState(() => _saving = true);
    ui.Image? png;
    try {
      png = await _snapshot(layer: true);
      final data = await png.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encoding failed');
      if (mounted) {
        Navigator.pop(context, (
          markup: (
            png: data.buffer.asUint8List(),
            quarterTurns: widget.edit.quarterTurns,
          ),
        ));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save photo markup. Try again.'),
          ),
        );
      }
    } finally {
      png?.dispose();
    }
  }

  Future<void> _enterText() async {
    var text = _text ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add text'),
        content: TextFormField(
          initialValue: text,
          autofocus: true,
          maxLength: 120,
          onChanged: (value) => text = value,
          onFieldSubmitted: (_) => Navigator.pop(context, text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, text.trim()),
            child: const Text('Place text'),
          ),
        ],
      ),
    );
    if (mounted && result != null && result.isNotEmpty) {
      setState(() {
        _tool = _Tool.text;
        _text = result;
        _pendingPhoto = null;
      });
    }
  }

  Future<void> _pickPhotos({required bool collage}) async {
    setState(() => _picking = true);
    final decoded = <ui.Image>[];
    try {
      final images = await PlatformImagePickerService().pickImages(
        limit: collage ? 3 : 1,
      );
      for (final bytes in images) {
        preflightImage(bytes);
        decoded.add(await _decode(bytes, width: 1200));
      }
      if (!mounted || decoded.isEmpty) return;
      if (collage) decoded.insert(0, await _snapshot());
      if (!mounted) return;
      setState(() {
        _tool = collage ? _Tool.collage : _Tool.photo;
        _text = null;
        if (collage) {
          _marks.add(
            _Mark(
              _Tool.collage,
              _color,
              _width,
              [],
              null,
              images: List.of(decoded),
            ),
          );
          _pendingPhoto = null;
        } else {
          _pendingPhoto = decoded.single;
        }
        _imported.addAll(decoded);
      });
      decoded.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add the selected photos.')),
        );
      }
    } finally {
      for (final image in decoded) {
        image.dispose();
      }
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pixelate() async {
    setState(() => _picking = true);
    try {
      final mosaic = await _snapshot(mosaic: true);
      if (!mounted) {
        mosaic.dispose();
        return;
      }
      _imported.add(mosaic);
      setState(() {
        _mosaic = mosaic;
        _tool = _Tool.pixelate;
        _pendingPhoto = null;
        _text = null;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not prepare the pixelation brush.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Offset _fraction(Offset point, Size size) => Offset(
    (point.dx / size.width).clamp(0.0, 1.0),
    (point.dy / size.height).clamp(0.0, 1.0),
  );

  void _start(Offset point, Size size) {
    if (_saving || _picking || (_tool == _Tool.text && _text == null)) return;
    if (_tool == _Tool.collage ||
        (_tool == _Tool.photo && _pendingPhoto == null)) {
      return;
    }
    setState(() {
      _active = _Mark(
        _tool,
        _color,
        _width,
        [_fraction(point, size)],
        _text,
        images: switch (_tool) {
          _Tool.photo => [_pendingPhoto!],
          _Tool.pixelate => [_mosaic!],
          _ => const [],
        },
      );
      _marks.add(_active!);
      if (_tool == _Tool.text) _text = null;
      if (_tool == _Tool.photo) _pendingPhoto = null;
    });
  }

  Widget _canvas() {
    final painter = _painter;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = applyBoxFit(
          BoxFit.contain,
          painter.size,
          constraints.biggest,
        );
        final size = fitted.destination;
        return Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (event) => _start(event.localPosition, size),
            onPanStart: !_brushTool
                ? null
                : (event) => _start(event.localPosition, size),
            onPanUpdate: !_brushTool
                ? null
                : (event) {
                    setState(
                      () => _active?.points.add(
                        _fraction(event.localPosition, size),
                      ),
                    );
                  },
            onPanEnd: (_) => _active = null,
            child: CustomPaint(
              key: const ValueKey('photo-markup-canvas'),
              size: size,
              painter: painter,
            ),
          ),
        );
      },
    );
  }

  bool get _brushTool =>
      _tool == _Tool.draw || _tool == _Tool.pixelate || _tool == _Tool.redact;

  @override
  Widget build(BuildContext context) {
    final ready = _photo != null && !_saving && !_picking;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photo markup'),
        actions: [
          IconButton(
            tooltip: 'Undo last mark',
            onPressed: ready && _marks.isNotEmpty
                ? () => setState(() {
                    _marks.removeLast();
                    _active = null;
                    if (_tool == _Tool.pixelate) _tool = _Tool.draw;
                  })
                : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Clear all markup',
            onPressed:
                ready &&
                    (_marks.isNotEmpty || (_previous != null && !_hidePrevious))
                ? () => setState(() {
                    _marks.clear();
                    _active = null;
                    _hidePrevious = true;
                    _mosaic = null;
                    _tool = _Tool.draw;
                  })
                : null,
            icon: const Icon(Icons.delete_outline),
          ),
          TextButton(
            onPressed: ready ? _save : null,
            child: const Text('Apply'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _failed
                  ? const Center(
                      child: Text('Could not open the photo for markup.'),
                    )
                  : _photo == null
                  ? const Center(child: CircularProgressIndicator())
                  : _canvas(),
            ),
            if (_text != null) const Text('Tap the photo to place your text'),
            if (_pendingPhoto != null)
              const Text('Tap to place the added photo'),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  for (final tool in _Tool.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        avatar: Icon(tool.icon),
                        label: Text(tool.label),
                        selected: tool == _tool,
                        onSelected: !ready
                            ? null
                            : (_) {
                                if (tool == _Tool.text) {
                                  unawaited(_enterText());
                                } else if (tool == _Tool.pixelate) {
                                  unawaited(_pixelate());
                                } else if (tool == _Tool.photo ||
                                    tool == _Tool.collage) {
                                  unawaited(
                                    _pickPhotos(collage: tool == _Tool.collage),
                                  );
                                } else {
                                  setState(() {
                                    _tool = tool;
                                    _text = null;
                                    _pendingPhoto = null;
                                  });
                                }
                              },
                      ),
                    ),
                ],
              ),
            ),
            if (_tool != _Tool.collage)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    if (_tool == _Tool.draw || _tool == _Tool.text)
                      PopupMenuButton<Color>(
                        tooltip: 'Markup color',
                        enabled: ready,
                        icon: Icon(Icons.palette_outlined, color: _color),
                        onSelected: (color) => setState(() => _color = color),
                        itemBuilder: (_) => [
                          for (final (name, color) in const [
                            ('Red', AppColors.markupRed),
                            ('Yellow', AppColors.markupYellow),
                            ('Blue', AppColors.markupBlue),
                            ('White', AppColors.onPhotoBackground),
                            ('Black', AppColors.markupBlack),
                          ])
                            PopupMenuItem(
                              value: color,
                              child: ListTile(
                                leading: Icon(Icons.circle, color: color),
                                title: Text(name),
                              ),
                            ),
                        ],
                      ),
                    Expanded(
                      child: Semantics(
                        label: switch (_tool) {
                          _Tool.text => 'Text size',
                          _Tool.photo => 'Photo size',
                          _ => 'Brush size',
                        },
                        child: Slider(
                          min: 0.01,
                          max: 0.18,
                          value: _width,
                          onChanged: ready
                              ? (value) => setState(() => _width = value)
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MarkupPainter extends CustomPainter {
  const _MarkupPainter({
    required this.photo,
    required this.previous,
    required this.edit,
    required this.marks,
  });

  final ui.Image photo;
  final ui.Image? previous;
  final PhotoEdit edit;
  final List<_Mark> marks;

  Size get size => edit.quarterTurns.isOdd
      ? Size(photo.height.toDouble(), photo.width.toDouble())
      : Size(photo.width.toDouble(), photo.height.toDouble());

  Paint _photoPaint(FilterQuality quality) => Paint()
    ..filterQuality = quality
    ..colorFilter = ColorFilter.matrix(edit.filter.matrix(edit.enhance));

  void _image(
    Canvas canvas,
    ui.Image image,
    Size size,
    int turns,
    Paint paint,
  ) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(turns * math.pi / 2);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: turns.isOdd ? size.height : size.width,
        height: turns.isOdd ? size.width : size.height,
      ),
      paint,
    );
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(AppColors.onPhotoBackground, BlendMode.src);
    _image(
      canvas,
      photo,
      size,
      edit.quarterTurns,
      _photoPaint(FilterQuality.medium),
    );
    paintLayer(canvas, size);
  }

  void paintLayer(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRect(bounds);
    final previous = this.previous;
    if (previous != null) {
      _image(canvas, previous, size, edit.markupRotation, Paint());
    }
    for (final mark in marks) {
      if (mark.tool == _Tool.collage) {
        _collage(canvas, size, mark.images);
        continue;
      }
      final width = size.shortestSide * mark.width;
      Offset position(Offset p) =>
          Offset(p.dx * size.width, p.dy * size.height);
      final first = position(mark.points.first);
      final last = position(mark.points.last);
      if (mark.tool == _Tool.photo) {
        final added = mark.images.single;
        final edge = (mark.width * 5).clamp(0.12, 0.9) * size.shortestSide;
        final imageSize = applyBoxFit(
          BoxFit.contain,
          Size(added.width.toDouble(), added.height.toDouble()),
          Size.square(edge),
        ).destination;
        canvas.drawImageRect(
          added,
          Rect.fromLTWH(0, 0, added.width.toDouble(), added.height.toDouble()),
          Rect.fromCenter(
            center: first,
            width: imageSize.width,
            height: imageSize.height,
          ),
          Paint()..filterQuality = FilterQuality.medium,
        );
        continue;
      }
      if (mark.tool == _Tool.text) {
        final text = TextPainter(
          text: TextSpan(
            text: mark.text,
            style: TextStyle(
              color: mark.color,
              fontWeight: FontWeight.w700,
              fontSize: width * 1.7,
              shadows: const [
                Shadow(color: AppColors.markupTextShadow, blurRadius: 2),
              ],
            ),
          ),
          textDirection: ui.TextDirection.ltr,
          textAlign: TextAlign.center,
        )..layout(maxWidth: size.width);
        text.paint(
          canvas,
          Offset(
            (first.dx - text.width / 2).clamp(
              0.0,
              math.max(0.0, size.width - text.width),
            ),
            (first.dy - text.height / 2).clamp(
              0.0,
              math.max(0.0, size.height - text.height),
            ),
          ),
        );
        text.dispose();
        continue;
      }
      if (mark.tool == _Tool.redact) {
        final box = mark.points.length == 1
            ? Rect.fromCenter(center: first, width: width, height: width)
            : Rect.fromPoints(first, last);
        canvas.drawRect(box, Paint()..color = AppColors.photoBackground);
        continue;
      }
      final pixelate = mark.tool == _Tool.pixelate;
      if (pixelate) canvas.saveLayer(bounds, Paint());
      final brush = Paint()
        ..color = pixelate ? AppColors.onPhotoBackground : mark.color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (mark.points.length == 1) {
        canvas.drawCircle(first, width / 2, brush);
      } else {
        final path = Path()..moveTo(first.dx, first.dy);
        for (final p in mark.points.skip(1).map(position)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, brush..style = PaintingStyle.stroke);
      }
      if (pixelate) {
        _image(
          canvas,
          mark.images.single,
          size,
          0,
          Paint()..blendMode = BlendMode.srcIn,
        );
        canvas.restore();
      }
    }
    canvas.restore();
  }

  void _collage(Canvas canvas, Size size, List<ui.Image> images) {
    final columns = size.width > size.height || images.length > 2 ? 2 : 1;
    final rows = (images.length / columns).ceil();
    final gutter = size.shortestSide * 0.009;
    final height = (size.height - gutter * (rows - 1)) / rows;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.onPhotoBackground,
    );
    for (final (index, image) in images.indexed) {
      final row = index ~/ columns;
      final inRow = math.min(columns, images.length - row * columns);
      final width = (size.width - gutter * (inRow - 1)) / inRow;
      final panel = Rect.fromLTWH(
        (index % columns) * (width + gutter),
        row * (height + gutter),
        width,
        height,
      );
      final frame = Size(image.width.toDouble(), image.height.toDouble());
      final source = applyBoxFit(BoxFit.cover, frame, panel.size).source;
      canvas.drawImageRect(
        image,
        Rect.fromCenter(
          center: frame.center(Offset.zero),
          width: source.width,
          height: source.height,
        ),
        panel,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
  }

  @override
  bool shouldRepaint(_MarkupPainter oldDelegate) => true;
}
