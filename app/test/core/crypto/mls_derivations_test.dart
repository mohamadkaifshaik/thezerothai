import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

String _toHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Map<String, dynamic> _fixture() =>
    jsonDecode(File('../testdata/e2ee/derivations-v1.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final f = _fixture();

  test('message_id rows', () {
    final rows = f['message_id'] as List;
    expect(rows, isNotEmpty);
    for (final r in rows.cast<Map<String, dynamic>>()) {
      expect(
        expectedMessageId(r['uid'] as String, r['idempotency_key'] as String),
        r['want'],
      );
    }
  });

  test('report_commitment rows', () {
    final rows = f['report_commitment'] as List;
    expect(rows, isNotEmpty);
    for (final r in rows.cast<Map<String, dynamic>>()) {
      expect(
        _toHex(reportCommitment(_hex(r['content_hex'] as String))),
        r['want_hex'],
      );
    }
  });

  test('group_id rows, including generation 2^32', () {
    final rows = f['group_id'] as List;
    expect(rows.length, 3);
    for (final r in rows.cast<Map<String, dynamic>>()) {
      expect(
        _toHex(
          mlsGroupId(r['conversation_id'] as String, r['generation'] as int),
        ),
        r['want_hex'],
      );
    }
  });

  test('party_id rows', () {
    final rows = f['party_id'] as List;
    expect(rows, isNotEmpty);
    for (final r in rows.cast<Map<String, dynamic>>()) {
      final keys = [
        for (final k in (r['device_keys_hex'] as List).cast<String>()) _hex(k),
      ];
      expect(partyId(r['conversation_id'] as String, keys), r['want']);
    }
  });

  test('partyId ignores order and repetition, differs per conversation', () {
    final a = Uint8List.fromList(List.filled(32, 1));
    final b = Uint8List.fromList(List.filled(32, 2));
    const c = '00112233445566778899aabbccddeeff';
    expect(partyId(c, [a, b]), partyId(c, [b, a, a]));
    expect(partyId(c, [a, b]).length, 64);
    expect(partyId('other', [a, b]), isNot(partyId(c, [a, b])));
    expect(() => partyId(c, []), throwsArgumentError);
  });

  test('mlsGroupId refuses a generation above the web-safe maximum', () {
    expect(() => mlsGroupId('c', kMaxPairComponent + 1), throwsArgumentError);
    expect(() => mlsGroupId('c', -1), throwsArgumentError);
    expect(mlsGroupId('c', kMaxPairComponent).length, 32);
  });

  test('sentDigest is lower-case hex SHA-256', () {
    expect(
      sentDigest(Uint8List(0)),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });
}
