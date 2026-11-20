import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'mls_pair.dart';

const int _twoPow32 = 4294967296;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// SHA-256("dz-group-v1" || utf8(conversationId) || u64be(generation)); 32 bytes. R5.
///
/// The generation is written as two 32-bit halves so the code works on the web (no 64-bit integer operations).
Uint8List mlsGroupId(String conversationId, int generation) {
  if (generation < 0 || generation > kMaxPairComponent) {
    throw ArgumentError.value(generation, 'generation', 'out of range');
  }
  final tail = ByteData(8)
    ..setUint32(0, generation ~/ _twoPow32)
    ..setUint32(4, generation % _twoPow32);
  final input = BytesBuilder(copy: false)
    ..add(utf8.encode('dz-group-v1'))
    ..add(utf8.encode(conversationId))
    ..add(tail.buffer.asUint8List());
  return Uint8List.fromList(sha256.convert(input.toBytes()).bytes);
}

int _compareBytes(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length - b.length;
}

/// Lower-case hex of SHA-256("dz-party-v1" || utf8(conversationId) || SHA-256(k1 || k2 || ...)) where k1.. are the
/// device keys de-duplicated and sorted bytewise (unsigned, lexicographic). 64 characters. R4. The SecurityParty user
/// id passed to CryptoEngine.securityCode is utf8(partyId). ArgumentError for no keys.
String partyId(String conversationId, List<Uint8List> deviceKeys) {
  if (deviceKeys.isEmpty) {
    throw ArgumentError.value(deviceKeys, 'deviceKeys', 'must not be empty');
  }
  final unique = <String, Uint8List>{};
  for (final k in deviceKeys) {
    unique[_hex(k)] = k;
  }
  final sorted = unique.values.toList()..sort(_compareBytes);
  final inner = BytesBuilder(copy: false);
  for (final k in sorted) {
    inner.add(k);
  }
  final innerDigest = sha256.convert(inner.toBytes()).bytes;
  final outer = BytesBuilder(copy: false)
    ..add(utf8.encode('dz-party-v1'))
    ..add(utf8.encode(conversationId))
    ..add(innerDigest);
  return _hex(sha256.convert(outer.toBytes()).bytes);
}

/// First 32 hex characters of SHA-256(utf8(authUid + "|SendMessage|" + idempotencyKey)). K3.
String expectedMessageId(String authUid, String idempotencyKey) {
  final d = sha256.convert(utf8.encode('$authUid|SendMessage|$idempotencyKey'));
  return _hex(d.bytes).substring(0, 32);
}

/// SHA-256(ascii "dz-report-v1" || contentBytes); 32 bytes.
Uint8List reportCommitment(Uint8List contentBytes) {
  final input = BytesBuilder(copy: false)
    ..add(ascii.encode('dz-report-v1'))
    ..add(contentBytes);
  return Uint8List.fromList(sha256.convert(input.toBytes()).bytes);
}

/// Lower-case hex of SHA-256(ciphertext): the vault_sent digest (R2, R7).
String sentDigest(Uint8List ciphertext) =>
    _hex(sha256.convert(ciphertext).bytes);
