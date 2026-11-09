import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_size_plan.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/features/media/domain/raster_image_processor.dart';

/// A JPEG header (SOI + baseline SOF0 of [width] x [height]) padded with
/// [padding] bytes: what the processors and the server read, without pixels.
Uint8List fakeJpeg(int width, int height, {int padding = 0}) {
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, length 17, 8-bit
    height >> 8, height & 0xFF, width >> 8, width & 0xFF,
    0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
    ...List.filled(padding, 0),
  ]);
}

/// [jpeg] with an APP1 segment of [size] bytes inserted before the SOF.
Uint8List jpegWithApp(Uint8List jpeg, int size) {
  final length = size + 2;
  return Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE1,
    length >> 8 & 0xFF,
    length & 0xFF,
    ...List.filled(size, 0x41),
    ...jpeg.sublist(2),
  ]);
}

Uint8List _riff(String chunk, List<int> body) => Uint8List.fromList([
  ...'RIFF'.codeUnits,
  0,
  0,
  0,
  0,
  ...'WEBP'.codeUnits,
  ...chunk.codeUnits,
  0,
  0,
  0,
  0,
  ...body,
  ...List.filled(16, 0),
]);

Uint8List webpVp8x(int w, int h) => _riff('VP8X', [
  0, 0, 0, 0, // flags + reserved
  (w - 1) & 0xFF, (w - 1) >> 8 & 0xFF, (w - 1) >> 16 & 0xFF,
  (h - 1) & 0xFF, (h - 1) >> 8 & 0xFF, (h - 1) >> 16 & 0xFF,
]);

Uint8List webpVp8l(int w, int h) {
  final bits = (w - 1) | (h - 1) << 14;
  return _riff('VP8L', [
    0x2F,
    bits & 0xFF,
    bits >> 8 & 0xFF,
    bits >> 16 & 0xFF,
    bits >> 24 & 0xFF,
  ]);
}

Uint8List webpVp8(int w, int h) => _riff('VP8 ', [
  0, 0, 0, // frame tag
  0x9D, 0x01, 0x2A, // start code
  w & 0xFF, w >> 8 & 0x3F,
  h & 0xFF, h >> 8 & 0x3F,
]);

/// One `encodeJpeg` call a [FakeRasterCodec] saw.
typedef FakeEncode = ({CropRect crop, int width, int height, int quality});

/// [RasterCodec] that "encodes" a [fakeJpeg] of the asked size whose length
/// is [sizeOf], so the processor's size math and checks run without pixels.
class FakeRasterCodec implements RasterCodec {
  FakeRasterCodec({
    this.decoded = (width: 4000, height: 3000),
    this.sizeOf = _small,
    this.unavailable = false,
    this.decodeFails = false,
    this.lieBy = 0,
    this.holdDecode = false,
    this.hangSessions = 0,
  });

  final ({int width, int height}) decoded;
  final int Function(int width, int height, int quality) sizeOf;

  /// [open] throws [RasterUnavailableException] (no worker in this browser).
  final bool unavailable;

  /// [RasterSession.decode] reports an undecodable file.
  final bool decodeFails;

  /// Every JPEG's SOF says width + [lieBy] (a codec that broke the contract).
  final int lieBy;

  /// Decode waits until the session is closed (a cancellation mid-decode).
  final bool holdDecode;

  /// The first [hangSessions] sessions never answer decode (a hung
  /// `createImageBitmap`, or a worker killed without an error event); only
  /// closing them ends the wait.
  final int hangSessions;

  final List<FakeEncode> encodes = [];
  final List<({int width, int height})> rgbaCalls = [];
  int opened = 0;
  int closed = 0;
  final Completer<void> decodeStarted = Completer<void>();

  static int _small(int w, int h, int q) => 100;

  @override
  Future<RasterSession> open() async {
    if (unavailable) {
      throw const RasterUnavailableException.capability('fake');
    }
    opened++;
    return _FakeSession(this, opened);
  }
}

class _FakeSession implements RasterSession {
  _FakeSession(this.codec, this.index);
  final FakeRasterCodec codec;

  /// 1-based order in which the session was opened.
  final int index;
  final Completer<void> _closed = Completer<void>();

  @override
  Future<({int width, int height})> decode(Uint8List bytes) async {
    if (!codec.decodeStarted.isCompleted) codec.decodeStarted.complete();
    if (codec.holdDecode || index <= codec.hangSessions) {
      await _closed.future;
      throw const RasterUnavailableException('closed');
    }
    if (codec.decodeFails) throw const UnsupportedImageException();
    return codec.decoded;
  }

  @override
  Future<Uint8List> encodeJpeg(
    CropRect crop,
    int width,
    int height,
    int quality,
  ) async {
    codec.encodes.add((
      crop: crop,
      width: width,
      height: height,
      quality: quality,
    ));
    final header = fakeJpeg(width + codec.lieBy, height);
    final size = codec.sizeOf(width, height, quality);
    return Uint8List(size < header.length ? header.length : size)
      ..setAll(0, header);
  }

  @override
  Future<Uint8List> rgba(CropRect crop, int width, int height) async {
    codec.rgbaCalls.add((width: width, height: height));
    return Uint8List(width * height * 4)..fillRange(0, width * height * 4, 128);
  }

  @override
  void close() {
    if (_closed.isCompleted) return;
    codec.closed++;
    _closed.complete();
  }
}
