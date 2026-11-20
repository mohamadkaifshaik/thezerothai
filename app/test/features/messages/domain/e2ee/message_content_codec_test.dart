import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

Uint8List _key([int v = 7]) => Uint8List.fromList(List.filled(32, v));

void main() {
  test('every row of report_payload_decode.json', () {
    final f = jsonDecode(
      File('../testdata/report_payload_decode.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final cases = (f['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, 27);
    for (final c in cases) {
      final d = decodeMessageContentLenient(_hex(c['payload_hex'] as String));
      final name = c['name'];
      expect(d.wireOk, c['want_wire_ok'], reason: '$name wireOk');
      expect(d.text, c['want_text'], reason: '$name text');
      expect(d.sharedPostId, c['want_shared_post_id'], reason: '$name shared');
      if (!d.wireOk) {
        expect(d.reportKey, isNull, reason: '$name key');
      }
    }
  });

  test('encode then lenient decode round-trips and wireOk', () {
    final bytes = encodeMessageContent(
      text: 'héllo',
      sharedPostId: '1234567890123456789',
      reportKey: _key(),
    );
    final d = decodeMessageContentLenient(bytes);
    expect(d.wireOk, isTrue);
    expect(d.text, 'héllo');
    expect(d.sharedPostId, '1234567890123456789');
    expect(d.reportKey, _key());
  });

  test('the commitment of encoded bytes verifies ok', () {
    final bytes = encodeMessageContent(text: 'hi', reportKey: _key());
    expect(
      checkMessageContent(bytes, reportCommitment(bytes)),
      MessageCheck.ok,
    );
  });

  test('a flipped content byte is unverified', () {
    final bytes = encodeMessageContent(text: 'hi', reportKey: _key());
    final commitment = reportCommitment(bytes);
    final flipped = Uint8List.fromList(bytes)..[2] ^= 1;
    expect(checkMessageContent(flipped, commitment), MessageCheck.unverified);
  });

  test('a 31-byte report key is unverified', () {
    final bytes = _hex('0a026869') + _hex('1a1f') + Uint8List(31);
    final b = Uint8List.fromList(bytes);
    expect(
      checkMessageContent(b, reportCommitment(b)),
      MessageCheck.unverified,
    );
  });

  test('well-formed commitment over non-protobuf bytes is undecodable', () {
    final b = _hex('0e');
    expect(
      checkMessageContent(b, reportCommitment(b)),
      MessageCheck.undecodable,
    );
  });

  test('a 31-byte commitment is unverified', () {
    final bytes = encodeMessageContent(text: 'hi', reportKey: _key());
    final c = Uint8List.sublistView(reportCommitment(bytes), 0, 31);
    expect(checkMessageContent(bytes, c), MessageCheck.unverified);
  });

  test('a negative length never throws', () {
    final d = decodeMessageContentLenient(_hex('0affffffff0f'));
    expect(d.wireOk, isFalse);
    expect(d.text, '');
    expect(d.reportKey, isNull);
  });

  test('65 nested groups are not wireOk', () {
    Uint8List nest(int n) =>
        Uint8List.fromList([...List.filled(n, 0x0b), ...List.filled(n, 0x0c)]);
    expect(decodeMessageContentLenient(nest(64)).wireOk, isTrue);
    expect(decodeMessageContentLenient(nest(65)).wireOk, isFalse);
  });

  test('encode refuses a 33-byte report key and content over 4096 bytes', () {
    expect(
      () => encodeMessageContent(text: 'a', reportKey: Uint8List(33)),
      throwsArgumentError,
    );
    expect(
      () => encodeMessageContent(text: 'a' * 4100, reportKey: _key()),
      throwsArgumentError,
    );
  });

  test('DecodedContent keeps Object.toString', () {
    final d = decodeMessageContentLenient(_hex('0a0161'));
    expect(d.toString(), startsWith("Instance of 'DecodedContent'"));
  });
}
