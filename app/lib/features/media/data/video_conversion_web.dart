import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../domain/processing_cancellation.dart';
import '../domain/video_edit.dart';
import 'video_conversion.dart';

const _videoWorkerUrl = 'video_worker.js?v=2';

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String url);
  external void postMessage(JSObject message);
  external set onmessage(JSFunction handler);
  external set onerror(JSFunction handler);
  external void terminate();
}

extension type _Event._(JSObject _) implements JSObject {
  external _Result get data;
}

extension type _Result._(JSObject _) implements JSObject {
  external bool? get error;
  external String get metadata;
  external String get fullMd5;
  external JSUint8Array get video;
  external JSUint8Array get poster;
  external JSArray<JSUint8Array> get captionAudio;
}

Future<List<Uint8List>> extractCaptionSegments(
  String path,
  List<VideoAudioWindow> windows,
  ProcessingCancellation cancellation,
) async {
  final done = Completer<List<Uint8List>>();
  final worker = _Worker(_videoWorkerUrl);
  const error = FormatException('Could not read audio from this video.');
  try {
    worker.onmessage = ((_Event event) {
      final result = event.data;
      if (result.error == true) {
        done.completeError(error);
      } else {
        done.complete([
          for (final chunk in result.captionAudio.toDart) chunk.toDart,
        ]);
      }
    }).toJS;
    worker.onerror = ((JSObject _) {
      if (!done.isCompleted) done.completeError(error);
    }).toJS;
    worker.postMessage(
      {
            'url': path,
            'captionCommands': [
              for (final (index, window) in windows.indexed)
                {
                  'output': 'caption-$index.ogg',
                  'args': encodeCaptionAudio(
                    'input',
                    'caption-$index.ogg',
                    window,
                  ),
                },
            ],
          }.jsify()!
          as JSObject,
    );
    return await cancellation
        .guard(done.future)
        .timeout(const Duration(minutes: 3));
  } finally {
    worker.terminate();
  }
}

Future<ConvertedClip> convertClip(
  XFile file,
  ProcessingCancellation cancellation, {
  ClipEdit edit = const ClipEdit(),
  List<VideoLayer> layers = const [],
  Duration? coverAt,
}) async {
  final done = Completer<ConvertedClip>();
  final worker = _Worker(_videoWorkerUrl);
  final artwork = [
    for (final (index, layer) in layers.indexed)
      (path: 'overlay-$index.png', layer: layer),
  ];
  try {
    worker.onmessage = ((_Event event) {
      final result = event.data;
      if (result.error == true) {
        done.completeError(const FormatException(unreadableClip));
      } else {
        done.complete((
          video: result.video.toDart,
          poster: result.poster.toDart,
          metadata: result.metadata,
          fullMd5: result.fullMd5,
        ));
      }
    }).toJS;
    worker.onerror = ((JSObject _) {
      if (!done.isCompleted) {
        done.completeError(
          const FormatException(
            'Video processing could not start. Reload and try again.',
          ),
        );
      }
    }).toJS;
    worker.postMessage(
      {
            'url': file.path,
            'encode': encodeClip(
              'input',
              'post.mp4',
              web: true,
              edit: edit,
              artwork: artwork,
            ),
            'artwork': [
              for (final item in artwork)
                {'path': item.path, 'png': item.layer.png},
            ],
            'probe': probeClip('post.mp4', 'metadata.json'),
            'poster': posterCandidates(
              'post.mp4',
              'poster.jpg',
              coverAt,
            ).toList(),
          }.jsify()!
          as JSObject,
    );
    return await cancellation
        .guard(done.future)
        .timeout(const Duration(minutes: 15));
  } finally {
    worker.terminate();
  }
}

@JS('URL.revokeObjectURL')
external void _revokeUrl(String url);

Future<void> withVideoPreview(
  Uint8List video,
  Future<void> Function(String) show,
) async {
  final url = XFile.fromData(video, mimeType: 'video/mp4').path;
  try {
    await show(url);
  } finally {
    _revokeUrl(url);
  }
}
