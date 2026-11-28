import 'dart:io';

import 'package:file_selector/file_selector.dart' show openFile;
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../domain/image_processor.dart';
import '../domain/processed_image.dart';
import '../domain/processing_cancellation.dart';
import '../domain/video_edit.dart';
import 'video_artwork.dart';
import 'video_conversion.dart';
import 'video_conversion_native.dart'
    if (dart.library.js_interop) 'video_conversion_web.dart';

export 'video_conversion.dart' show ClipEdit;
export 'video_conversion_native.dart'
    if (dart.library.js_interop) 'video_conversion_web.dart'
    show withVideoPreview, extractCaptionSegments;

typedef ChooseClipEdit = Future<ClipEdit?> Function(String path);

VideoPlayerController pickedVideoController(String path) => kIsWeb
    ? VideoPlayerController.networkUrl(Uri.parse(path))
    : VideoPlayerController.file(File(path));

Future<ProcessedImage?> pickPostVideo(
  ImageProcessor processor,
  ProcessingCancellation cancellation, {
  required bool fromFiles,
  ChooseClipEdit? chooseEdit,
}) async {
  final file = fromFiles
      ? await openFile()
      : await ImagePicker().pickVideo(source: ImageSource.gallery);
  if (file == null) return null;
  if (await file.length() > maxClipBytes) {
    throw const FormatException('Choose a video up to 96 MiB.');
  }
  cancellation.throwIfCancelled();
  final edit = chooseEdit == null
      ? const ClipEdit()
      : await chooseEdit(file.path);
  if (edit == null) return null;
  return preparePostVideo(file, processor, cancellation, edit: edit);
}

Future<ProcessedImage> preparePostVideo(
  XFile file,
  ImageProcessor processor,
  ProcessingCancellation cancellation, {
  ClipEdit edit = const ClipEdit(),
  List<VideoLayer> layers = const [],
  Duration? coverAt,
  Uint8List? coverImage,
  int videoLabels = 0,
}) async {
  cancellation.throwIfCancelled();
  if (await file.length() > maxClipBytes) {
    throw const FormatException('Choose a video up to 96 MiB.');
  }
  final clip = await convertClip(
    file,
    cancellation,
    edit: edit,
    layers: layers,
    coverAt: coverAt,
  );
  final size = clipDimensions(clip.metadata);
  if (clip.video.length > maxClipBytes) {
    throw const FormatException('Choose a video up to 96 MiB.');
  }
  final poster = coverImage == null
      ? clip.poster
      : await renderVideoCover(coverImage, size.width, size.height);
  final preview = await processor.process(
    poster,
    ImagePurpose.post,
    cancellation: cancellation,
  );
  return ProcessedImage(
    fullBytes: clip.video,
    thumbBytes: preview.thumbBytes,
    width: size.width,
    height: size.height,
    fullMd5: clip.fullMd5,
    thumbMd5: preview.thumbMd5,
    blurhash: preview.blurhash,
    contentType: kVideoContentType,
    thumbContentType: preview.contentType,
    videoLabels: videoLabels,
  );
}

Future<ProcessedImage> editPostVideo(
  ProcessedImage source,
  VideoProject project,
  ImageProcessor processor,
  ProcessingCancellation cancellation,
) async {
  final edit = project.range;
  if (edit.start < Duration.zero ||
      edit.end <= edit.start ||
      edit.end - edit.start > const Duration(minutes: 5)) {
    throw const FormatException('Choose a valid video range up to 5 minutes.');
  }
  final layers = await cancellation.guard(
    renderVideoLayers(project, source.width, source.height),
  );
  final latestFrame = edit.end - const Duration(milliseconds: 120);
  final frame = project.coverFrame?.clampBetween(
    edit.start,
    latestFrame < edit.start ? edit.start : latestFrame,
  );
  late final ProcessedImage result;
  await withVideoPreview(source.fullBytes, (path) async {
    result = await preparePostVideo(
      XFile(path, length: source.fullBytes.length, mimeType: kVideoContentType),
      processor,
      cancellation,
      edit: ClipEdit(
        start: edit.start,
        length: edit.end - edit.start,
        muted: edit.muted,
      ),
      layers: layers,
      coverAt: frame == null ? null : frame - edit.start,
      coverImage: project.coverImage,
      videoLabels: project.labels,
    );
  });
  return result;
}

extension on Duration {
  Duration clampBetween(Duration min, Duration max) {
    if (this < min) return min;
    if (this > max) return max;
    return this;
  }
}
