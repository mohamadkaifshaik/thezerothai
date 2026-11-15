import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';

import '../../../core/theme/app_theme.dart';

/// Loads the colour the article card's overlay is tinted with, or null when
/// it cannot be known (the card then uses its near-black scrim).
typedef ArticleTintLoader = Future<Color?> Function(String coverUrl);

/// The widest luminance the tint may have: white text on it stays above 4.5:1
/// (AA) with room for the image showing through the last 10 %.
const double kArticleTintMaxLuminance = 0.1;

/// The average colour of RGBA [bytes] (alpha weighted), or null when every
/// pixel is transparent.
Color? averageColorOfRgba(Uint8List bytes) {
  var r = 0.0, g = 0.0, b = 0.0, weight = 0.0;
  for (var i = 0; i + 3 < bytes.length; i += 4) {
    final a = bytes[i + 3] / 255;
    r += bytes[i] * a;
    g += bytes[i + 1] * a;
    b += bytes[i + 2] * a;
    weight += a;
  }
  if (weight == 0) return null;
  return Color.fromARGB(
    255,
    (r / weight).round(),
    (g / weight).round(),
    (b / weight).round(),
  );
}

/// [average] darkened toward the deep navy until white text passes AA on it.
Color articleOverlayTint(Color average) {
  var color = average.withValues(alpha: 1);
  for (
    var i = 0;
    i < 24 && color.computeLuminance() > kArticleTintMaxLuminance;
    i++
  ) {
    color = Color.lerp(color, AppPalette.navyDeep, 0.2)!;
  }
  return color;
}

/// The tint per cover URL, computed once (a small LRU: the feed re-builds its
/// cards while scrolling).
final LinkedHashMap<String, Color> _tints = LinkedHashMap();
const int _maxCachedTints = 128;

/// Decodes the cover at 8 px wide through the image cache (no new download
/// when the card already showed it), averages it and darkens it. Null on any
/// failure.
Future<Color?> loadArticleCoverTint(String coverUrl) async {
  final cached = _tints.remove(coverUrl);
  if (cached != null) {
    _tints[coverUrl] = cached;
    return cached;
  }
  final provider = ResizeImage(CachedNetworkImageProvider(coverUrl), width: 8);
  final stream = provider.resolve(ImageConfiguration.empty);
  final done = Completer<ui.Image?>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!done.isCompleted) done.complete(info.image);
    },
    onError: (_, _) {
      if (!done.isCompleted) done.complete(null);
    },
  );
  stream.addListener(listener);
  try {
    final image = await done.future;
    if (image == null) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final average = averageColorOfRgba(data.buffer.asUint8List());
    if (average == null) return null;
    final tint = articleOverlayTint(average);
    _tints[coverUrl] = tint;
    if (_tints.length > _maxCachedTints) _tints.remove(_tints.keys.first);
    return tint;
  } catch (_) {
    return null;
  } finally {
    stream.removeListener(listener);
  }
}
