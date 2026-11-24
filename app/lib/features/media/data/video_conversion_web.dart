import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../domain/processing_cancellation.dart';
import 'video_conversion.dart';

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
}

Future<ConvertedClip> convertClip(
  XFile file,
  ProcessingCancellation cancellation, {
  ClipEdit edit = const ClipEdit(),
}) async {
  final done = Completer<ConvertedClip>();
  final worker = _Worker('video_worker.js');
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
            'encode': encodeClip('input', 'post.mp4', web: true, edit: edit),
            'probe': probeClip('post.mp4', 'metadata.json'),
            'poster': extractPoster('post.mp4', 'poster.jpg'),
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
