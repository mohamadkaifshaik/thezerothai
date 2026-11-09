import 'dart:typed_data';

import 'processed_image.dart';

/// The largest picked file the processors accept (checked before any decode).
/// The platform pickers already downsize to 2048 px (PlatformImagePickerService),
/// so this only stops odd inputs (a file the picker could not resize).
const kMaxSourceBytes = 40 * 1024 * 1024;

/// The most pixels a picked image may have, read from its header before any
/// decode: 50 MP covers a 48 MP phone camera, and keeps a decoded bitmap
/// (4 bytes per pixel) at or under 200 MB. The web worker never draws into a
/// canvas larger than the output (at most 1600 x 1600), so the iOS canvas-area
/// cap (about 16.7 MP) does not apply to the source.
const kMaxSourcePixels = 50 * 1000 * 1000;

/// Pixel size read from an image header (no pixels decoded).
typedef ImageDims = ({int width, int height});

/// Refuses [bytes] that are too big to decode safely: more than
/// [kMaxSourceBytes], or a header that declares more than [kMaxSourcePixels]
/// (or a zero side). A format whose header this function cannot read is left
/// to the decoder, which refuses what it cannot decode.
void preflightImage(Uint8List bytes) {
  if (bytes.isEmpty) throw const UnsupportedImageException();
  if (bytes.length > kMaxSourceBytes) throw tooLargeSource;
  final dims = probeImageDims(bytes);
  if (dims != null) checkSourceDims(dims.width, dims.height);
}

/// The pixel bound of [preflightImage], also applied to the decoded size.
void checkSourceDims(int width, int height) {
  if (width <= 0 || height <= 0) throw const UnsupportedImageException();
  if (width * height > kMaxSourcePixels) throw tooLargeSource;
}

const tooLargeSource = UnsupportedImageException(
  'This image is too large. Pick one under 50 megapixels.',
);

/// The width and height a JPEG, PNG, GIF or WebP header declares, or null
/// for anything else (or a header that does not parse). Bounded: it walks
/// JPEG segment headers only (never entropy-coded data) and reads fixed
/// offsets for the other formats.
ImageDims? probeImageDims(Uint8List b) {
  if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) return jpegDims(b);
  if (b.length >= 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      _ascii(b, 12, 'IHDR')) {
    return (width: _be32(b, 16), height: _be32(b, 20));
  }
  if (b.length >= 10 && (_ascii(b, 0, 'GIF87a') || _ascii(b, 0, 'GIF89a'))) {
    return (width: b[6] | b[7] << 8, height: b[8] | b[9] << 8);
  }
  if (b.length >= 30 && _ascii(b, 0, 'RIFF') && _ascii(b, 8, 'WEBP')) {
    if (_ascii(b, 12, 'VP8 ')) {
      return (
        width: (b[26] | b[27] << 8) & 0x3FFF,
        height: (b[28] | b[29] << 8) & 0x3FFF,
      );
    }
    if (_ascii(b, 12, 'VP8L') && b[20] == 0x2F) {
      return (
        width: 1 + (((b[22] & 0x3F) << 8) | b[21]),
        height: 1 + (((b[24] & 0x0F) << 10) | (b[23] << 2) | (b[22] >> 6)),
      );
    }
    if (_ascii(b, 12, 'VP8X')) {
      return (
        width: 1 + (b[24] | b[25] << 8 | b[26] << 16),
        height: 1 + (b[27] | b[28] << 8 | b[29] << 16),
      );
    }
  }
  return null;
}

/// The size in a JPEG's first SOF marker, or null when there is none before
/// the first SOS (or the segments are truncated). This is what the server
/// reads to verify the declared size (B14).
ImageDims? jpegDims(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    // Standalone markers carry no length.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return null; // SOS / EOI first
    final length = b[i + 2] << 8 | b[i + 3];
    if (length < 2) return null;
    if (_isSof(marker)) {
      if (i + 9 > b.length) return null;
      return (
        width: b[i + 7] << 8 | b[i + 8],
        height: b[i + 5] << 8 | b[i + 6],
      );
    }
    i += 2 + length;
  }
  return null;
}

bool _isSof(int m) =>
    m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;

bool _ascii(Uint8List b, int at, String s) {
  if (at + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[at + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

int _be32(Uint8List b, int at) =>
    b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];
