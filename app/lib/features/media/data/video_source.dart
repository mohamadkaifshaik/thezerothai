import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart' show openFile;
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../domain/image_processor.dart';
import '../domain/processed_image.dart';
import '../domain/processing_cancellation.dart';
import 'video_conversion.dart';
import 'video_conversion_native.dart'
    if (dart.library.js_interop) 'video_conversion_web.dart';

export 'video_conversion_native.dart'
    if (dart.library.js_interop) 'video_conversion_web.dart'
    show withVideoPreview;

VideoPlayerController pickedVideoController(String path) => kIsWeb
    ? VideoPlayerController.networkUrl(Uri.parse(path))
    : VideoPlayerController.file(File(path));

Future<ProcessedImage?> pickPostVideo(
  ImageProcessor processor,
  ProcessingCancellation cancellation, {
  required bool fromFiles,
}) async {
  final file = fromFiles
      ? await openFile()
      : await ImagePicker().pickVideo(source: ImageSource.gallery);
  if (file == null) return null;
  return preparePostVideo(file, processor, cancellation);
}

Future<ProcessedImage> preparePostVideo(
  XFile file,
  ImageProcessor processor,
  ProcessingCancellation cancellation,
) async {
  cancellation.throwIfCancelled();
  if (await file.length() > maxClipBytes) {
    throw const FormatException('Choose a video up to 96 MiB.');
  }
  final clip = await convertClip(file, cancellation);
  final size = clipDimensions(clip.metadata);
  if (clip.video.length > maxClipBytes) {
    throw const FormatException('Choose a video up to 96 MiB.');
  }
  final preview = await processor.process(
    clip.poster,
    ImagePurpose.post,
    cancellation: cancellation,
  );
  return ProcessedImage(
    fullBytes: clip.video,
    thumbBytes: preview.thumbBytes,
    width: size.width,
    height: size.height,
    fullMd5: base64Encode(md5.convert(clip.video).bytes),
    thumbMd5: preview.thumbMd5,
    blurhash: preview.blurhash,
    contentType: kVideoContentType,
    thumbContentType: preview.contentType,
  );
}
