import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;

const int kReportKeyBytes = 32;
const int kMaxMessageContentBytes = 4096;

const int _maxGroupDepth = 64;
const int _maxFieldNumber = 536870911; // 2^29 - 1
const int _maxLength = 2147483647; // 2^31 - 1

/// pb.MessageContent(text, sharedPostId, reportKey).writeToBuffer(). ArgumentError when reportKey is not 32 bytes or
/// the result exceeds 4096 bytes. These exact bytes are encrypted, committed to and stored.
Uint8List encodeMessageContent({
  required String text,
  String sharedPostId = '',
  required Uint8List reportKey,
}) {
  if (reportKey.length != kReportKeyBytes) {
    throw ArgumentError.value(
      reportKey.length,
      'reportKey',
      'must be $kReportKeyBytes bytes',
    );
  }
  final bytes = pb.MessageContent(
    text: text,
    sharedPostId: sharedPostId,
    reportKey: reportKey,
  ).writeToBuffer();
  if (bytes.length > kMaxMessageContentBytes) {
    throw ArgumentError.value(
      bytes.length,
      'content',
      'exceeds $kMaxMessageContentBytes bytes',
    );
  }
  return bytes;
}

class DecodedContent {
  const DecodedContent({
    required this.text,
    required this.sharedPostId,
    required this.reportKey,
    required this.wireOk,
  });

  const DecodedContent._malformed()
    : text = '',
      sharedPostId = '',
      reportKey = null,
      wireOk = false;

  final String text;
  final String sharedPostId;
  final Uint8List? reportKey;
  final bool wireOk;
}

class _Malformed implements Exception {
  const _Malformed();
}

/// A varint read as two 32-bit halves (no 64-bit integer operations: the code runs on the web).
class _Varint {
  _Varint(this.lo, this.hi, this.next);
  final int lo;
  final int hi;
  final int next;
}

/// 2^n by multiplication: `1 << 31` is negative on the web.
int _pow2(int n) {
  var p = 1;
  for (var i = 0; i < n; i++) {
    p *= 2;
  }
  return p;
}

_Varint _readVarint(Uint8List b, int pos) {
  var lo = 0;
  var hi = 0;
  for (var i = 0; i < 10; i++) {
    if (pos + i >= b.length) throw const _Malformed();
    final byte = b[pos + i];
    if (i == 9 && byte > 1) throw const _Malformed();
    final bits = byte & 0x7f;
    final shift = 7 * i;
    if (shift < 32) {
      lo += bits * (1 << shift);
      if (shift + 7 > 32) {
        // The part of these seven bits above bit 31 goes to the high half.
        final over = lo ~/ 4294967296;
        lo = lo % 4294967296;
        hi += over;
      }
    } else {
      hi += bits * _pow2(shift - 32);
    }
    if (byte < 0x80) {
      return _Varint(lo % 4294967296, hi % 4294967296, pos + i + 1);
    }
  }
  throw const _Malformed();
}

/// Reads a tag; returns (fieldNumber, wireType, next). Tags above 32 bits and field number 0 are malformed.
(int, int, int) _readTag(Uint8List b, int pos) {
  final v = _readVarint(b, pos);
  if (v.hi != 0) throw const _Malformed();
  final num = v.lo ~/ 8;
  if (num == 0 || num > _maxFieldNumber) throw const _Malformed();
  return (num, v.lo % 8, v.next);
}

int _readLength(Uint8List b, int pos, int end) {
  final v = _readVarint(b, pos);
  if (v.hi != 0 || v.lo > _maxLength) throw const _Malformed();
  if (v.next + v.lo > end) throw const _Malformed();
  return v.lo;
}

/// Skips the value of a non-group field (types 0, 1, 2, 5); returns the next position.
int _skipScalar(Uint8List b, int type, int pos) {
  switch (type) {
    case 0:
      return _readVarint(b, pos).next;
    case 1:
      if (pos + 8 > b.length) throw const _Malformed();
      return pos + 8;
    case 2:
      final len = _readLength(b, pos, b.length);
      return _readVarint(b, pos).next + len;
    case 5:
      if (pos + 4 > b.length) throw const _Malformed();
      return pos + 4;
    default:
      throw const _Malformed();
  }
}

/// Skips a group whose start tag (field [num]) was just read; [pos] is after that tag. Returns the next position.
int _skipGroup(Uint8List b, int num, int pos) {
  final open = <int>[num];
  while (open.isNotEmpty) {
    if (pos >= b.length) throw const _Malformed();
    final (n, type, next) = _readTag(b, pos);
    pos = next;
    if (type == 3) {
      if (open.length >= _maxGroupDepth) throw const _Malformed();
      open.add(n);
    } else if (type == 4) {
      if (open.removeLast() != n) throw const _Malformed();
    } else {
      pos = _skipScalar(b, type, pos);
    }
  }
  return pos;
}

/// Never throws (catches every Error and Exception). wireOk false => text and sharedPostId are '' and reportKey null.
DecodedContent decodeMessageContentLenient(Uint8List bytes) {
  try {
    Uint8List? text;
    Uint8List? shared;
    Uint8List? key;
    var pos = 0;
    while (pos < bytes.length) {
      final (num, type, next) = _readTag(bytes, pos);
      pos = next;
      if (type == 2 && (num == 1 || num == 2 || num == 3)) {
        final len = _readLength(bytes, pos, bytes.length);
        final start = _readVarint(bytes, pos).next;
        final value = Uint8List.fromList(bytes.sublist(start, start + len));
        if (num == 1) {
          text = value;
        } else if (num == 2) {
          shared = value;
        } else {
          key = value;
        }
        pos = start + len;
      } else if (type == 3) {
        pos = _skipGroup(bytes, num, pos);
      } else if (type == 4) {
        throw const _Malformed();
      } else {
        pos = _skipScalar(bytes, type, pos);
      }
    }
    return DecodedContent(
      text: text == null ? '' : goUtf8Lossy(text),
      sharedPostId: shared == null ? '' : goUtf8Lossy(shared),
      reportKey: key,
      wireOk: true,
    );
  } catch (_) {
    return const DecodedContent._malformed();
  }
}

enum MessageCheck { ok, unverified, undecodable }

bool _constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// unverified: the commitment is not 32 bytes or differs from reportCommitment(bytes) (constant-time compare);
/// else undecodable: !wireOk; else unverified: reportKey is not 32 bytes; else ok.
MessageCheck checkMessageContent(Uint8List contentBytes, Uint8List commitment) {
  if (commitment.length != 32 ||
      !_constantTimeEquals(commitment, reportCommitment(contentBytes))) {
    return MessageCheck.unverified;
  }
  final d = decodeMessageContentLenient(contentBytes);
  if (!d.wireOk) return MessageCheck.undecodable;
  if (d.reportKey?.length != kReportKeyBytes) return MessageCheck.unverified;
  return MessageCheck.ok;
}

bool _isCont(Uint8List b, int i, [int lo = 0x80, int hi = 0xBF]) =>
    i < b.length && b[i] >= lo && b[i] <= hi;

/// Go's string(bytes) -> valid UTF-8 rule: every byte utf8.DecodeRune rejects becomes one U+FFFD.
String goUtf8Lossy(Uint8List bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.add(b);
      i += 1;
    } else if (b >= 0xC2 && b <= 0xDF && _isCont(bytes, i + 1)) {
      out.add(((b & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if (b >= 0xE0 && b <= 0xEF) {
      final lo = b == 0xE0 ? 0xA0 : 0x80;
      final hi = b == 0xED ? 0x9F : 0xBF;
      if (_isCont(bytes, i + 1, lo, hi) && _isCont(bytes, i + 2)) {
        out.add(
          ((b & 0x0F) << 12) |
              ((bytes[i + 1] & 0x3F) << 6) |
              (bytes[i + 2] & 0x3F),
        );
        i += 3;
      } else {
        out.add(0xFFFD);
        i += 1;
      }
    } else if (b >= 0xF0 && b <= 0xF4) {
      final lo = b == 0xF0 ? 0x90 : 0x80;
      final hi = b == 0xF4 ? 0x8F : 0xBF;
      if (_isCont(bytes, i + 1, lo, hi) &&
          _isCont(bytes, i + 2) &&
          _isCont(bytes, i + 3)) {
        out.add(
          ((b & 0x07) << 18) |
              ((bytes[i + 1] & 0x3F) << 12) |
              ((bytes[i + 2] & 0x3F) << 6) |
              (bytes[i + 3] & 0x3F),
        );
        i += 4;
      } else {
        out.add(0xFFFD);
        i += 1;
      }
    } else {
      out.add(0xFFFD);
      i += 1;
    }
  }
  return String.fromCharCodes(out);
}
