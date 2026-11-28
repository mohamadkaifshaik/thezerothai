import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'video_conversion.dart';
import 'video_source.dart' show withVideoPreview;

const _gallery = MethodChannel('dzeroth/photo_gallery');

Future<bool> canSavePhotoToGallery() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await _gallery.invokeMethod<bool>('available') ?? false;
  } on MissingPluginException {
    return false;
  }
}

Future<void> savePhotoToGallery(Uint8List jpeg) =>
    _gallery.invokeMethod<void>('saveJpeg', jpeg);

Future<void> saveVideoToGallery(String localPath) =>
    _gallery.invokeMethod<void>('saveMp4', localPath);

Future<void> downloadVideoToGallery(String url) async {
  final uri = Uri.parse(url);
  if (!uri.hasAuthority || (uri.scheme != 'https' && uri.scheme != 'http')) {
    throw const FormatException('Invalid video URL.');
  }
  final client = http.Client();
  try {
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 ||
        response.headers['content-type']?.split(';').first.trim() !=
            'video/mp4' ||
        (response.contentLength ?? 0) > maxClipBytes) {
      throw const FormatException('Video download is unavailable.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > maxClipBytes) {
        throw const FormatException('The video is too large to save.');
      }
      bytes.add(chunk);
    }
    if (bytes.isEmpty) throw const FormatException('The download is empty.');
    await withVideoPreview(bytes.takeBytes(), saveVideoToGallery);
  } finally {
    client.close();
  }
}
