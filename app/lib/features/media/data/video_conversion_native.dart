import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/processing_cancellation.dart';
import 'video_conversion.dart';

Future<ConvertedClip> convertClip(
  XFile file,
  ProcessingCancellation cancellation,
) async {
  final directory = await Directory.systemTemp.createTemp('post-video-');
  final video = File('${directory.path}/post.mp4');
  final poster = File('${directory.path}/poster.jpg');
  final metadata = File('${directory.path}/metadata.json');
  try {
    var input = file.path;
    // Some document providers return the bytes without a readable local path.
    if (input.isEmpty || !await File(input).exists()) {
      input = '${directory.path}/input';
      await file.saveTo(input);
    }
    cancellation.throwIfCancelled();
    final finished = Completer<FFmpegSession>();
    final running = await FFmpegKit.executeWithArgumentsAsync(
      encodeClip(input, video.path),
      finished.complete,
    );
    final FFmpegSession session;
    try {
      session = await cancellation.guard(finished.future);
    } on ImageProcessingCancelled {
      final id = running.getSessionId();
      if (id != null && !finished.isCompleted) await FFmpegKit.cancel(id);
      await finished.future;
      rethrow;
    }
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw const FormatException(unreadableClip);
    }
    final probe = await FFprobeKit.executeWithArguments(
      probeClip(video.path, metadata.path),
    );
    if (!ReturnCode.isSuccess(await probe.getReturnCode())) {
      throw const FormatException(unreadableClip);
    }
    final info = await metadata.readAsString();
    clipDimensions(info);
    if (await video.length() > maxClipBytes) {
      throw const FormatException('Choose a video up to 96 MiB.');
    }
    final frame = await FFmpegKit.executeWithArguments(
      extractPoster(video.path, poster.path),
    );
    if (!ReturnCode.isSuccess(await frame.getReturnCode())) {
      throw const FormatException('Could not create a poster for this clip.');
    }
    return (
      video: await video.readAsBytes(),
      poster: await poster.readAsBytes(),
      metadata: info,
    );
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<void> withVideoPreview(
  Uint8List video,
  Future<void> Function(String) show,
) async {
  final directory = await Directory.systemTemp.createTemp('preview-video-');
  try {
    final file = await File('${directory.path}/post.mp4').writeAsBytes(video);
    await show(file.path);
  } finally {
    await directory.delete(recursive: true);
  }
}
