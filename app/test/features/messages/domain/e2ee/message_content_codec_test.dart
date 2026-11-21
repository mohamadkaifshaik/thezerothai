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
    expect(cases.length, 31);
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

  test(
    'a matching commitment with a bad report key length is badReportKey',
    () {
      for (final keyLen in [0, 31, 33]) {
        final b = Uint8List.fromList(
          _hex('0a026869') + [0x1a, keyLen] + Uint8List(keyLen),
        );
        expect(
          checkMessageContentDetail(b, reportCommitment(b)),
          MessageCheckDetail.badReportKey,
          reason: 'key length $keyLen',
        );
      }
      // No report key at all.
      final noKey = _hex('0a026869');
      expect(
        checkMessageContentDetail(noKey, reportCommitment(noKey)),
        MessageCheckDetail.badReportKey,
      );
    },
  );

  test('a commitment mismatch is mismatch whatever the key length', () {
    for (final keyLen in [0, 31, 32, 33]) {
      final b = Uint8List.fromList(
        _hex('0a026869') + [0x1a, keyLen] + Uint8List(keyLen),
      );
      final wrong = Uint8List.fromList(reportCommitment(b))..[0] ^= 1;
      expect(
        checkMessageContentDetail(b, wrong),
        MessageCheckDetail.mismatch,
        reason: 'key length $keyLen',
      );
      expect(
        checkMessageContentDetail(
          b,
          Uint8List.sublistView(reportCommitment(b), 0, 31),
        ),
        MessageCheckDetail.mismatch,
        reason: 'short commitment, key length $keyLen',
      );
    }
    // Undecodable bytes under a wrong commitment are a mismatch too.
    final junk = _hex('0e');
    expect(
      checkMessageContentDetail(junk, Uint8List(32)),
      MessageCheckDetail.mismatch,
    );
  });

  test('the detailed check is ok and undecodable where the three-valued one '
      'is', () {
    final good = encodeMessageContent(text: 'hi', reportKey: _key());
    expect(
      checkMessageContentDetail(good, reportCommitment(good)),
      MessageCheckDetail.ok,
    );
    final junk = _hex('0e');
    expect(
      checkMessageContentDetail(junk, reportCommitment(junk)),
      MessageCheckDetail.undecodable,
    );
  });

  test(
    'the three-valued check maps mismatch and badReportKey to unverified',
    () {
      final good = encodeMessageContent(text: 'hi', reportKey: _key());
      final shortKey = Uint8List.fromList(
        _hex('0a026869') + _hex('1a1f') + Uint8List(31),
      );
      final junk = _hex('0e');
      final rows = <(Uint8List, Uint8List, MessageCheckDetail, MessageCheck)>[
        (good, reportCommitment(good), MessageCheckDetail.ok, MessageCheck.ok),
        (
          good,
          Uint8List(32),
          MessageCheckDetail.mismatch,
          MessageCheck.unverified,
        ),
        (
          shortKey,
          reportCommitment(shortKey),
          MessageCheckDetail.badReportKey,
          MessageCheck.unverified,
        ),
        (
          junk,
          reportCommitment(junk),
          MessageCheckDetail.undecodable,
          MessageCheck.undecodable,
        ),
      ];
      for (final (bytes, commitment, detail, check) in rows) {
        expect(checkMessageContentDetail(bytes, commitment), detail);
        expect(
          checkMessageContent(bytes, commitment),
          check,
          reason: '$detail',
        );
      }
    },
  );

  test('the stored name of each detailed check', () {
    expect(
      {for (final d in MessageCheckDetail.values) d: d.storedName},
      {
        MessageCheckDetail.ok: 'ok',
        MessageCheckDetail.mismatch: 'unverified',
        MessageCheckDetail.badReportKey: 'badReportKey',
        MessageCheckDetail.undecodable: 'undecodable',
      },
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

  // Go's protowire allows 10001 nested groups (DefaultRecursionLimit 10000) and refuses 10002.
  const goMaxGroups = 10001;
  Uint8List nest(int n) =>
      Uint8List.fromList([...List.filled(n, 0x0b), ...List.filled(n, 0x0c)]);

  test('N nested groups are wireOk like Go', () {
    expect(decodeMessageContentLenient(nest(goMaxGroups)).wireOk, isTrue);
  });

  test('N+1 nested groups are not wireOk', () {
    expect(decodeMessageContentLenient(nest(goMaxGroups + 1)).wireOk, isFalse);
  });

  test('goUtf8Lossy follows the Go rule', () {
    String lossy(List<int> b) => goUtf8Lossy(Uint8List.fromList(b));
    expect(lossy([0xE2, 0x82, 0xAC]), '€');
    expect(lossy([0xF0, 0x9F, 0x98, 0x80]), '\u{1F600}');
    expect(lossy([0xC0]), '�');
    expect(lossy([0xC1]), '�');
    expect(lossy([0xF5]), '�');
    expect(lossy([0xE0, 0x80]), '��');
    expect(lossy([0xF0, 0x80]), '��');
    expect(lossy([0xF4, 0x90]), '��');
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
