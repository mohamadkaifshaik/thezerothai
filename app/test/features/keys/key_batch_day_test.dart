import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/vault/vault_records.dart' show istDay;
import 'package:dzeroth/features/keys/domain/key_batch_day.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  // Days relative to the clock (no fixed date: see the fixed-date guard);
  // only compared with each other.
  final now = DateTime.now().toUtc();
  String dayAt(int offset) => istDay(now.add(Duration(days: offset)));
  final yesterday = dayAt(-1);
  final today = dayAt(0);
  final tomorrow = dayAt(1);
  final later = dayAt(2);

  KeyBatchDay read(Uint8List? stored) =>
      KeyBatchDay.read(stored, today: today, tomorrow: tomorrow, cap: 4);

  // (count, reportedCap, reportedInvalid, invalid)
  (int, bool, bool, bool) facts(KeyBatchDay d) =>
      (d.count, d.reportedCap, d.reportedInvalid, d.invalid);

  test('none stored: a new day with no batches', () {
    final d = read(null);
    expect((d.day, facts(d)), (today, (0, false, false, false)));
  });

  test('the same day is kept; an earlier day starts over', () {
    final same = read(
      KeyBatchDay(today, 3, reportedCap: true, reportedInvalid: true).encode(),
    );
    expect(facts(same), (3, true, true, false));
    final earlier = read(
      KeyBatchDay(
        yesterday,
        3,
        reportedCap: true,
        reportedInvalid: true,
      ).encode(),
    );
    expect((earlier.day, facts(earlier)), (today, (0, false, false, false)));
  });

  test('the two report flags are stored apart', () {
    final cap = read(KeyBatchDay(today, 4, reportedCap: true).encode());
    expect(facts(cap), (4, true, false, false));
    final invalid = read(KeyBatchDay(today, 4, reportedInvalid: true).encode());
    expect(facts(invalid), (4, false, true, false));
  });

  test('a record of tomorrow (the clock set back a day) keeps its count: '
      'moving the clock back never resets the cap', () {
    final d = read(KeyBatchDay(tomorrow, 4).encode());
    expect((d.day, facts(d)), (tomorrow, (4, false, false, false)));
  });

  test('a record of tomorrow does not carry its reports over: they were '
      'made on another day, so today reports again', () {
    final d = read(
      KeyBatchDay(
        tomorrow,
        4,
        reportedCap: true,
        reportedInvalid: true,
      ).encode(),
    );
    expect(facts(d), (4, false, false, false));
  });

  test('a record dated more than one day ahead is the cap for today, '
      'invalid and unreported', () {
    final d = read(KeyBatchDay(later, 0).encode());
    expect((d.day, facts(d)), (today, (4, false, false, true)));
  });

  test('an unreadable record counts as the cap for today, unreported and '
      'invalid', () {
    const flags = '"reportedCap":false,"reportedInvalid":false';
    for (final raw in [
      '{',
      '[]',
      '{"v":2,"day":"$today","n":1,$flags}',
      '{"v":1,"day":"today","n":1,$flags}',
      '{"v":1,"day":"$today","n":-1,$flags}',
      '{"v":1,"day":"$today","n":1}',
      '{"v":1,"day":"$today","n":1,"reportedCap":false}',
      '{"v":1,"day":"$today","n":1,"reportedInvalid":false}',
      // The single flag of fix round 2 (never shipped).
      '{"v":1,"day":"$today","n":1,"reported":false}',
    ]) {
      final d = read(_bytes(raw));
      expect((d.day, facts(d)), (today, (4, false, false, true)), reason: raw);
    }
  });

  test('a valid record padded with JSON whitespace past the limit is '
      'unreadable; padded to the limit it is read', () {
    Uint8List padded(int length) {
      final valid = KeyBatchDay(today, 1).encode();
      return Uint8List.fromList([
        ...valid,
        ...List.filled(length - valid.length, 0x20),
      ]);
    }

    final atLimit = read(padded(kMaxKeyBatchDayBytes));
    expect((atLimit.count, atLimit.invalid), (1, false));
    final over = read(padded(kMaxKeyBatchDayBytes + 1));
    expect((over.count, over.invalid), (4, true));
  });

  test('invalid is never stored', () {
    final d = KeyBatchDay.decode(KeyBatchDay.capped(today, 4).encode());
    expect((d.count, d.invalid), (4, false));
  });
}
