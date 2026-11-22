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

  test('none stored: a new day with no batches', () {
    final d = read(null);
    expect((d.day, d.count, d.reported, d.invalid), (today, 0, false, false));
  });

  test('the same day is kept; an earlier day starts over', () {
    final same = read(KeyBatchDay(today, 3, reported: true).encode());
    expect((same.count, same.reported, same.invalid), (3, true, false));
    final earlier = read(KeyBatchDay(yesterday, 3, reported: true).encode());
    expect(
      (earlier.day, earlier.count, earlier.reported, earlier.invalid),
      (today, 0, false, false),
    );
  });

  test('a record of tomorrow (the clock set back a day) is kept: moving the '
      'clock back never resets the cap', () {
    final d = read(KeyBatchDay(tomorrow, 4, reported: true).encode());
    expect((d.day, d.count, d.reported, d.invalid), (tomorrow, 4, true, false));
  });

  test('a record dated more than one day ahead is the cap for today, '
      'invalid and unreported', () {
    final d = read(KeyBatchDay(later, 0).encode());
    expect((d.day, d.count, d.reported, d.invalid), (today, 4, false, true));
  });

  test('an unreadable record counts as the cap for today, unreported and '
      'invalid', () {
    for (final raw in [
      '{',
      '[]',
      '{"v":2,"day":"$today","n":1,"reported":false}',
      '{"v":1,"day":"today","n":1,"reported":false}',
      '{"v":1,"day":"$today","n":-1,"reported":false}',
      '{"v":1,"day":"$today","n":1}',
    ]) {
      final d = read(_bytes(raw));
      expect(
        (d.day, d.count, d.reported, d.invalid),
        (today, 4, false, true),
        reason: raw,
      );
    }
    final big = Uint8List(257);
    expect(read(big).count, 4);
  });

  test('invalid is never stored', () {
    final d = KeyBatchDay.decode(KeyBatchDay.capped(today, 4).encode());
    expect((d.count, d.invalid), (4, false));
  });
}
