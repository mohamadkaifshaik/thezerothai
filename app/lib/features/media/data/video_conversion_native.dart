import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/processing_cancellation.dart';
import '../domain/video_edit.dart';
import 'video_conversion.dart';

Future<ConvertedClip> convertClip(
  XFile file,
  ProcessingCancellation cancellation, {
  ClipEdit edit = const ClipEdit(),
  List<VideoLayer> layers = const [],
  Duration? coverAt,
}) async {
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
    final artwork = [
      for (final (index, layer) in layers.indexed)
        (
          path: (await File(
            '${directory.path}/overlay-$index.png',
          ).writeAsBytes(layer.png)).path,
          layer: layer,
        ),
    ];
    cancellation.throwIfCancelled();
    final converted = await _runFFmpeg(
      encodeClip(input, video.path, web: false, edit: edit, artwork: artwork),
      cancellation,
    );
    if (!converted) {
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
    var created = false;
    for (final args in posterCandidates(video.path, poster.path, coverAt)) {
      final ok = await _runFFmpeg(args, cancellation);
      if (ok && await poster.exists() && await poster.length() > 0) {
        created = true;
        break;
      }
      if (await poster.exists()) await poster.delete();
    }
    if (!created) {
      throw const FormatException('Could not create a poster for this clip.');
    }
    return (
      video: await video.readAsBytes(),
      poster: await poster.readAsBytes(),
      metadata: info,
      fullMd5: await _checksum(video.path),
    );
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<bool> _runFFmpeg(
  List<String> args,
  ProcessingCancellation cancellation,
) async {
  cancellation.throwIfCancelled();
  final finished = Completer<FFmpegSession>();
  final running = await FFmpegKit.executeWithArgumentsAsync(
    args,
    finished.complete,
  );
  try {
    final session = await cancellation.guard(finished.future);
    return ReturnCode.isSuccess(await session.getReturnCode());
  } on ImageProcessingCancelled {
    final id = running.getSessionId();
    if (id != null && !finished.isCompleted) await FFmpegKit.cancel(id);
    await finished.future;
    rethrow;
  }
}

Future<List<Uint8List>> extractCaptionSegments(
  String path,
  List<VideoAudioWindow> windows,
  ProcessingCancellation cancellation,
) async {
  final directory = await Directory.systemTemp.createTemp('caption-audio-');
  try {
    final chunks = <Uint8List>[];
    for (final (index, window) in windows.indexed) {
      final output = File('${directory.path}/segment-$index.ogg');
      final ok = await _runFFmpeg(
        encodeCaptionAudio(path, output.path, window),
        cancellation,
      );
      if (!ok) {
        throw const FormatException('Could not read audio from this video.');
      }
      chunks.add(await output.readAsBytes());
    }
    return chunks;
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<String> _checksum(String path) => Isolate.run(
  () async =>
      base64Encode((await md5.bind(File(path).openRead()).single).bytes),
);

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
