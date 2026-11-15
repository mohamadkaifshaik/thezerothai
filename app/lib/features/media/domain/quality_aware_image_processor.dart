import 'dart:typed_data';

import 'image_processor.dart';
import 'image_size_plan.dart';
import 'processed_image.dart';
import 'processing_cancellation.dart';

/// An [ImageProcessor] that picks the [ImageQuality] when a photo is
/// processed (not when the app starts): [resolve] answers for the connection
/// and the Data usage choice of that moment. A caller that passes its own
/// quality keeps it. Wraps the platform processor, so post photos of the
/// composer and of articles are both covered; avatars ignore the quality.
class QualityAwareImageProcessor implements ImageProcessor {
  const QualityAwareImageProcessor(this._inner, this._resolve);

  final ImageProcessor _inner;
  final ImageQuality Function() _resolve;

  @override
  Future<ProcessedImage> process(
    Uint8List bytes,
    ImagePurpose purpose, {
    ProcessingCancellation? cancellation,
    ImageQuality? quality,
  }) => _inner.process(
    bytes,
    purpose,
    cancellation: cancellation,
    quality: quality ?? _resolve(),
  );
}
