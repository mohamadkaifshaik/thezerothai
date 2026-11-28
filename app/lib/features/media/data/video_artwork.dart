import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../domain/image_preflight.dart';
import '../domain/video_edit.dart';

Future<List<VideoLayer>> renderVideoLayers(
  VideoProject project,
  int width,
  int height,
) async {
  final layers = <VideoLayer>[];
  final overlay = project.overlay;
  if (overlay != null) {
    layers.add((
      png: await _textImage(overlay.text, width, height, overlay: overlay),
      position:
          project.captions.isNotEmpty &&
              overlay.position == VideoTextPosition.bottom
          ? VideoTextPosition.center
          : overlay.position,
      start: null,
      end: null,
    ));
  }
  for (final cue in project.captions) {
    final range = project.range;
    final start = cue.start < range.start ? range.start : cue.start;
    final end = cue.end > range.end ? range.end : cue.end;
    if (end <= start) continue;
    layers.add((
      png: await _textImage(cue.text, width, height),
      position: VideoTextPosition.bottom,
      start: start - range.start,
      end: end - range.start,
    ));
  }
  return layers;
}

TextStyle videoTextStyle(double shortest, {VideoOverlay? overlay}) => TextStyle(
  color: Color(overlay?.color ?? 0xffffffff),
  fontSize: shortest * .056 * (overlay?.size ?? 1),
  fontWeight: switch (overlay?.style ?? VideoTextStyle.strong) {
    VideoTextStyle.basic => FontWeight.w500,
    VideoTextStyle.strong => FontWeight.w700,
    VideoTextStyle.typewriter => FontWeight.w600,
    VideoTextStyle.poster => FontWeight.w900,
  },
  fontFamily: overlay?.style == VideoTextStyle.typewriter ? 'monospace' : null,
);

Color videoTextBackground(VideoOverlay? overlay) =>
    Color(overlay?.style == VideoTextStyle.poster ? 0xff16191f : 0xd9000000);

Future<Uint8List> _textImage(
  String text,
  int width,
  int height, {
  VideoOverlay? overlay,
}) async {
  final shortest = math.min(width, height).toDouble();
  final padding = math.max(1.0, shortest * .018);
  final direction = RegExp(r'[\u0590-\u08ff]').hasMatch(text)
      ? ui.TextDirection.rtl
      : ui.TextDirection.ltr;
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: videoTextStyle(shortest, overlay: overlay),
    ),
    textAlign: TextAlign.center,
    textDirection: direction,
    maxLines: 4,
    ellipsis: '…',
  )..layout(maxWidth: math.max(1, width * .88 - padding * 2));
  try {
    final size = Size(
      painter.width + padding * 2,
      painter.height + padding * 2,
    );
    return await _png(size, (canvas) {
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(padding),
        ),
        Paint()..color = videoTextBackground(overlay),
      );
      painter.paint(canvas, Offset(padding, padding));
    });
  } finally {
    painter.dispose();
  }
}

Future<Uint8List> renderVideoCover(
  Uint8List bytes,
  int width,
  int height,
) async {
  preflightImage(bytes);
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: 960,
    allowUpscaling: false,
  );
  final frame = await codec.getNextFrame().whenComplete(codec.dispose);
  final image = frame.image;
  try {
    final factor = math.min(1.0, 480 / math.max(width, height));
    final size = Size(
      math.max(1, (width * factor).floor()).toDouble(),
      math.max(1, (height * factor).floor()).toDouble(),
    );
    final original = Size(image.width.toDouble(), image.height.toDouble());
    final crop = applyBoxFit(BoxFit.cover, original, size).source;
    return await _png(size, (canvas) {
      canvas.drawColor(const Color(0xffffffff), BlendMode.src);
      canvas.drawImageRect(
        image,
        Alignment.center.inscribe(crop, Offset.zero & original),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium,
      );
    });
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _png(Size size, void Function(Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        throw const FormatException('Could not render the video artwork.');
      }
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
