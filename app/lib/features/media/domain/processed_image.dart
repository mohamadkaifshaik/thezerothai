import 'package:flutter/foundation.dart';

/// What a picked photo becomes on the device before upload: a re-encoded
/// full-size JPEG and a smaller thumbnail, both without metadata, plus the
/// values the server binds into the signed URLs (size, base64 MD5) and the
/// BlurHash sent with FinalizeUpload.
@immutable
class ProcessedImage {
  const ProcessedImage({
    required this.fullBytes,
    required this.thumbBytes,
    required this.width,
    required this.height,
    required this.fullMd5,
    required this.thumbMd5,
    required this.blurhash,
    this.contentType = 'image/jpeg',
  });

  final Uint8List fullBytes;
  final Uint8List thumbBytes;

  /// Pixel size of [fullBytes] (what the server stores as the image size).
  final int width;
  final int height;

  /// Base64 MD5 of each file (the signed URL pins it).
  final String fullMd5;
  final String thumbMd5;

  /// <= 64 chars, base83 (server-validated).
  final String blurhash;

  /// `image/jpeg` (the server also accepts `image/webp`; the pure-Dart
  /// encoder here writes JPEG only).
  final String contentType;
}

/// Why a picked file cannot be turned into an upload (not an image, an
/// unsupported format such as an un-transcoded HEIC, or a corrupt file).
class UnsupportedImageException implements Exception {
  const UnsupportedImageException([this.message = 'Unsupported image.']);
  final String message;

  @override
  String toString() => message;
}
