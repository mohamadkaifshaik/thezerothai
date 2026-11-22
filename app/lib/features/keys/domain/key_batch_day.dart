import 'dart:convert';
import 'dart:typed_data';

/// The largest stored record read (a real one is under 70 bytes).
const int kMaxKeyBatchDayBytes = 256;

/// The key package batches generated on one IST day (see
/// `kVaultSettingKeyBatchDay` and `kMaxKeyBatchesPerDay`).
class KeyBatchDay {
  const KeyBatchDay(
    this.day,
    this.count, {
    this.reported = false,
    this.invalid = false,
  });

  /// `YYYY-MM-DD` at UTC+05:30 (`istDay`).
  final String day;
  final int count;

  /// The cap was reported on [day].
  final bool reported;

  /// Read only, never stored: the stored record did not open, did not
  /// decode or was dated more than one day ahead, so [count] is the cap.
  /// Reported as `batchDay`, apart from a real cap (`batchCap`).
  final bool invalid;

  /// The record for [today], with the rule of `DailyLedger` (daily_ledger.dart):
  /// - none stored (null bytes): a new day with no batches;
  /// - stored on a day EARLIER than [today]: a new day with no batches;
  /// - stored on [today] or [tomorrow] (a clock set back by up to a day):
  ///   kept as it is, so moving the clock back never resets the cap;
  /// - stored on a later day (a clock once set far forward), or unreadable:
  ///   the cap already reached today ([cap], not reported, [invalid]). Fail
  ///   closed for today only; the caller stores a record of [today].
  static KeyBatchDay read(
    Uint8List? stored, {
    required String today,
    required String tomorrow,
    required int cap,
  }) {
    if (stored == null) return KeyBatchDay(today, 0);
    final KeyBatchDay value;
    try {
      value = decode(stored);
    } on FormatException {
      return capped(today, cap);
    }
    // 'YYYY-MM-DD' strings order like the days they name.
    if (value.day.compareTo(today) < 0) return KeyBatchDay(today, 0);
    if (value.day.compareTo(tomorrow) > 0) return capped(today, cap);
    return value;
  }

  /// The cap for [today] from a record that cannot be used.
  static KeyBatchDay capped(String today, int cap) =>
      KeyBatchDay(today, cap, invalid: true);

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({'v': 1, 'day': day, 'n': count, 'reported': reported}),
    ),
  );

  static final RegExp _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static KeyBatchDay decode(Uint8List bytes) {
    if (bytes.length > kMaxKeyBatchDayBytes) throw const FormatException();
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map || value['v'] != 1) throw const FormatException();
    final day = value['day'];
    final n = value['n'];
    final reported = value['reported'];
    if (day is! String ||
        !_day.hasMatch(day) ||
        n is! int ||
        n < 0 ||
        reported is! bool) {
      throw const FormatException();
    }
    return KeyBatchDay(day, n, reported: reported);
  }
}
