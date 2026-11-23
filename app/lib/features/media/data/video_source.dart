import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:get_thumbnail_video_plus/video_thumbnail.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../domain/image_processor.dart';
import '../domain/processed_image.dart';

VideoPlayerController pickedVideoController(String path) => kIsWeb
    ? VideoPlayerController.networkUrl(Uri.parse(path))
    : VideoPlayerController.file(File(path));

Future<ProcessedImage?> pickPostVideo(ImageProcessor processor) async {
  final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
  if (file == null) return null;
  if (await file.length() > 96 * 1024 * 1024) {
    throw const FormatException('Choose a video up to 96 MiB.');
  }
  final controller = pickedVideoController(file.path);
  try {
    await controller.initialize();
    final value = controller.value;
    final width = value.size.width.round();
    final height = value.size.height.round();
    if (value.duration > const Duration(minutes: 5) ||
        width > 1920 ||
        height > 1920) {
      throw const FormatException(
        'Choose a clip up to 5 minutes and 1920 pixels per side.',
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length < 12 || String.fromCharCodes(bytes, 4, 8) != 'ftyp') {
      throw const FormatException('Choose an H.264 MP4 video.');
    }
    final poster = await VideoThumbnail.thumbnailData(
      video: file.path,
      maxWidth: math.min(width, 480),
      timeMs: 1,
    );
    final preview = await processor.process(poster, ImagePurpose.post);
    return ProcessedImage(
      fullBytes: bytes,
      thumbBytes: preview.thumbBytes,
      width: width,
      height: height,
      fullMd5: base64Encode(md5.convert(bytes).bytes),
      thumbMd5: preview.thumbMd5,
      blurhash: preview.blurhash,
      contentType: kVideoContentType,
      videoPreviewPath: file.path,
      thumbContentType: 'image/jpeg',
    );
  } finally {
    await controller.dispose();
  }
}
