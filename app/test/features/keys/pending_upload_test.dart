import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/features/keys/domain/pending_upload.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _json(Map<String, Object?> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, Object?> _record({
  List<Object?>? oneTime,
  Object? lastResort = 'AQ==',
  Object? countBefore = 3,
  Object? outcome = 'unknown',
}) => {
  'v': 1,
  'oneTime': oneTime ?? ['AQI='],
  'lastResort': lastResort,
  'countBefore': countBefore,
  'outcome': outcome,
};

void main() {
  test('round trip keeps packages, count and outcome', () {
    final p = PendingUpload(
      [
        Uint8List.fromList([1, 2]),
      ],
      Uint8List.fromList([3]),
      7,
      failed: true,
    );
    final back = PendingUpload.decode(p.encode());
    expect(back.oneTime, p.oneTime);
    expect(back.lastResort, p.lastResort);
    expect(back.countBefore, 7);
    expect(back.failed, isTrue);
    expect(PendingUpload.decode(_json(_record())).failed, isFalse);
  });

  test('the largest record encode() can write decodes', () {
    final max = Uint8List(kMaxKeyPackageBytes)..fillRange(0, 4096, 255);
    final p = PendingUpload(List.filled(50, max), max, 1 << 62, failed: true);
    final back = PendingUpload.decode(p.encode());
    expect(back.oneTime, hasLength(50));
    expect(back.lastResort, hasLength(kMaxKeyPackageBytes));
  });

  test('a record with no packages is empty', () {
    expect(PendingUpload.decode(PendingUpload.empty.encode()).isEmpty, isTrue);
  });

  test('bad base64 is unreadable', () {
    expect(
      () => PendingUpload.decode(_json(_record(oneTime: ['not base64!']))),
      throwsFormatException,
    );
    expect(
      () => PendingUpload.decode(_json(_record(lastResort: '%%%'))),
      throwsFormatException,
    );
  });

  test('more than 50 one-time packages is unreadable', () {
    final ok = List.filled(50, 'AQ==');
    expect(
      PendingUpload.decode(_json(_record(oneTime: ok))).oneTime,
      hasLength(50),
    );
    expect(
      () => PendingUpload.decode(_json(_record(oneTime: [...ok, 'AQ==']))),
      throwsFormatException,
    );
  });

  test('an oversize package or record is unreadable', () {
    final max = base64Encode(Uint8List(4096));
    expect(
      PendingUpload.decode(_json(_record(oneTime: [max]))).oneTime.single,
      hasLength(4096),
    );
    expect(
      () => PendingUpload.decode(
        _json(_record(oneTime: [base64Encode(Uint8List(4097))])),
      ),
      throwsFormatException,
    );
    expect(
      () => PendingUpload.decode(_json(_record(oneTime: ['']))),
      throwsFormatException,
      reason: 'an empty package',
    );
    expect(
      () => PendingUpload.decode(Uint8List(51 * 5500 + 1024)),
      throwsFormatException,
    );
  });

  test('a missing lastResort key is unreadable (null is not)', () {
    final record = _record()..remove('lastResort');
    expect(() => PendingUpload.decode(_json(record)), throwsFormatException);
    expect(
      PendingUpload.decode(_json(_record(lastResort: null))).lastResort,
      isNull,
    );
  });

  test('an outcome other than failed or unknown is unreadable', () {
    for (final outcome in ['ok', null, 1]) {
      expect(
        () => PendingUpload.decode(_json(_record(outcome: outcome))),
        throwsFormatException,
        reason: '$outcome',
      );
    }
  });

  test('a negative or non-integer count is unreadable', () {
    for (final count in [-1, 1.5, '3', null]) {
      expect(
        () => PendingUpload.decode(_json(_record(countBefore: count))),
        throwsFormatException,
        reason: '$count',
      );
    }
  });

  test('another version or shape is unreadable', () {
    expect(
      () => PendingUpload.decode(_json({..._record(), 'v': 2})),
      throwsFormatException,
    );
    expect(
      () => PendingUpload.decode(Uint8List.fromList(utf8.encode('[]'))),
      throwsFormatException,
    );
    expect(
      () => PendingUpload.decode(Uint8List.fromList(utf8.encode('{'))),
      throwsFormatException,
    );
  });
}
