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
  final today = istDay(now);
  final tomorrow = istDay(now.add(const Duration(days: 1)));

  test('none stored: a new day with no batches', () {
    final d = KeyBatchDay.read(null, today, 4);
    expect((d.day, d.count, d.reported), (today, 0, false));
  });

  test('the same day is kept; another day starts over', () {
    final stored = KeyBatchDay(today, 3, reported: true).encode();
    final same = KeyBatchDay.read(stored, today, 4);
    expect((same.count, same.reported), (3, true));
    final next = KeyBatchDay.read(stored, tomorrow, 4);
    expect((next.day, next.count, next.reported), (tomorrow, 0, false));
  });

  test('an unreadable record counts as the cap for today, unreported', () {
    for (final raw in [
      '{',
      '[]',
      '{"v":2,"day":"$today","n":1,"reported":false}',
      '{"v":1,"day":"today","n":1,"reported":false}',
      '{"v":1,"day":"$today","n":-1,"reported":false}',
      '{"v":1,"day":"$today","n":1}',
    ]) {
      final d = KeyBatchDay.read(_bytes(raw), today, 4);
      expect((d.day, d.count, d.reported), (today, 4, false), reason: raw);
    }
    final big = Uint8List(257);
    expect(KeyBatchDay.read(big, today, 4).count, 4);
  });
}
