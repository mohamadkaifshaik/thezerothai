import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../domain/image_size_plan.dart';
import '../domain/processed_image.dart';
import '../domain/raster_image_processor.dart';

/// The worker script (app/web/image_worker.js), same origin, so the CSP's
/// `worker-src 'self'` allows it. Relative, so it resolves against the
/// document's `<base href>` like the rest of the app. The query string busts a
/// cached copy when the protocol changes.
const kImageWorkerUrl = 'image_worker.js?v=$kImageWorkerProtocol';

/// Must match `PROTOCOL` in app/web/image_worker.js.
const kImageWorkerProtocol = 1;

/// How long a worker may take to start before the browser counts as
/// unsupported (a missing script fails fast through `onerror`).
const _kStartTimeout = Duration(seconds: 10);

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String url);
  external void postMessage(JSAny? message);
  external void terminate();
  external set onmessage(JSFunction? handler);
  external set onerror(JSFunction? handler);
  external set onmessageerror(JSFunction? handler);
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

extension type _Request._(JSObject _) implements JSObject {
  external factory _Request({
    required int seq,
    required String op,
    JSUint8Array? bytes,
    required int sx,
    required int sy,
    required int sw,
    required int sh,
    required int w,
    required int h,
    required int quality,
  });
}

extension type _Reply._(JSObject _) implements JSObject {
  external JSAny? get seq;
  external String? get op;
  external bool get ok;
  external bool? get capability;
  external int? get protocol;
  external String? get kind;
  external String? get error;
  external int get width;
  external int get height;
  external JSArrayBuffer? get bytes;
}

/// [RasterCodec] over app/web/image_worker.js: one Web Worker per image,
/// terminated by [RasterSession.close] (which is also how a cancelled image
/// stops mid-decode).
class WorkerRasterCodec implements RasterCodec {
  const WorkerRasterCodec({
    this.url = kImageWorkerUrl,
    this.requestTimeout = kRasterStepTimeout,
  });

  final String url;

  /// How long one request may wait for its answer before the worker is
  /// terminated (RasterImageProcessor also bounds each step).
  final Duration requestTimeout;

  /// Whether this browser has `Worker` at all (the worker itself reports
  /// `createImageBitmap` / `OffscreenCanvas` support when it starts).
  static bool get available => globalContext.has('Worker');

  @override
  Future<RasterSession> open() async {
    if (!available) {
      throw const RasterUnavailableException.capability('no Worker');
    }
    final session = _WorkerSession(url, requestTimeout);
    try {
      await session.ready.timeout(_kStartTimeout);
    } on TimeoutException {
      session.close();
      throw const RasterUnavailableException.capability(
        'worker did not start',
      );
    } catch (_) {
      session.close();
      rethrow;
    }
    return session;
  }
}

class _WorkerSession implements RasterSession {
  _WorkerSession(String url, this._requestTimeout) {
    try {
      _worker = _Worker(url);
    } catch (e) {
      throw RasterUnavailableException.capability('worker: $e');
    }
    _worker.onmessage = ((JSObject event) => _onMessage(event)).toJS;
    // A script that is not served (the SPA rewrite answers HTML) fails
    // before it is ready: this browser/deployment cannot run it. An error
    // after that is a one-off for this image.
    _worker.onerror = ((JSObject _) {
      _failAll(
        _ready.isCompleted
            ? const RasterUnavailableException('worker error')
            : const RasterUnavailableException.capability(
                'worker script failed to load',
              ),
      );
    }).toJS;
    // A reply that cannot be deserialized would otherwise never arrive.
    _worker.onmessageerror = ((JSObject _) {
      _failAll(const RasterUnavailableException('worker message error'));
    }).toJS;
  }

  final Duration _requestTimeout;

  late final _Worker _worker;
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<_Reply>> _pending = {};
  int _seq = 0;
  bool _closed = false;

  Future<void> get ready => _ready.future;

  void _onMessage(JSObject event) {
    final data = (event as _MessageEvent).data;
    if (data == null || !data.isA<JSObject>()) return;
    final reply = data as _Reply;
    final rawSeq = reply.seq;
    // Ignore anything without an integer sequence number.
    if (rawSeq == null || !rawSeq.isA<JSNumber>()) return;
    final seqValue = (rawSeq as JSNumber).toDartDouble;
    if (seqValue != seqValue.truncateToDouble() || seqValue < 0) return;
    final seq = seqValue.toInt();
    if (seq == 0 && reply.op == 'ready') {
      if (_ready.isCompleted) return;
      if (reply.protocol != kImageWorkerProtocol) {
        _ready.completeError(
          const RasterUnavailableException.capability(
            'worker protocol mismatch',
          ),
        );
      } else if (!reply.ok) {
        _ready.completeError(
          const RasterUnavailableException.capability('no OffscreenCanvas'),
        );
      } else {
        _ready.complete();
      }
      return;
    }
    _pending.remove(seq)?.complete(reply);
  }

  void _failAll(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final c in waiting) {
      c.completeError(error);
    }
  }

  Future<_Reply> _send(
    String op, {
    Uint8List? bytes,
    CropRect? crop,
    int w = 0,
    int h = 0,
    int quality = 0,
  }) async {
    if (_closed) throw const RasterUnavailableException('closed');
    final seq = ++_seq;
    final done = Completer<_Reply>();
    _pending[seq] = done;
    // The input is copied (structured clone), not transferred: the Dart
    // bytes must stay usable for the package:image fallback.
    _worker.postMessage(
      _Request(
        seq: seq,
        op: op,
        bytes: bytes?.toJS,
        sx: crop?.x ?? 0,
        sy: crop?.y ?? 0,
        sw: crop?.width ?? 0,
        sh: crop?.height ?? 0,
        w: w,
        h: h,
        quality: quality,
      ),
    );
    final reply = await done.future.timeout(
      _requestTimeout,
      onTimeout: () {
        // A hung decode/encode, or a worker killed without an error event.
        close();
        throw const RasterUnavailableException('worker request timed out');
      },
    );
    if (!reply.ok) {
      if (reply.kind == 'decode') throw const UnsupportedImageException();
      final reason = reply.error ?? 'worker failure';
      throw (reply.capability ?? false)
          ? RasterUnavailableException.capability(reason)
          : RasterUnavailableException(reason);
    }
    return reply;
  }

  @override
  Future<({int width, int height})> decode(Uint8List bytes) async {
    final reply = await _send('decode', bytes: bytes);
    return (width: reply.width, height: reply.height);
  }

  @override
  Future<Uint8List> encodeJpeg(
    CropRect crop,
    int width,
    int height,
    int quality,
  ) async {
    final reply = await _send(
      'jpeg',
      crop: crop,
      w: width,
      h: height,
      quality: quality,
    );
    return _bytesOf(reply);
  }

  @override
  Future<Uint8List> rgba(CropRect crop, int width, int height) async {
    final reply = await _send('rgba', crop: crop, w: width, h: height);
    return _bytesOf(reply);
  }

  Uint8List _bytesOf(_Reply reply) {
    final buffer = reply.bytes;
    if (buffer == null) throw const RasterUnavailableException('no bytes');
    return buffer.toDart.asUint8List();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _worker.terminate();
    _failAll(const RasterUnavailableException('closed'));
  }
}
