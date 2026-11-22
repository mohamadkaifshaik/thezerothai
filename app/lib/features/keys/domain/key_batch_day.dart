import 'dart:convert';
import 'dart:typed_data';

/// The key package batches generated on one IST day (see
/// `kVaultSettingKeyBatchDay` and `kMaxKeyBatchesPerDay`).
class KeyBatchDay {
  const KeyBatchDay(this.day, this.count, {this.reported = false});

  /// `YYYY-MM-DD` at UTC+05:30 (`istDay`).
  final String day;
  final int count;

  /// The cap was reported on [day].
  final bool reported;

  /// The record for [today]: [stored] when it is of that day, else a new
  /// day with no batches. An unreadable [stored] (null bytes are "none")
  /// counts as the cap already reached today ([cap]), not reported: fail
  /// closed, and the next IST day starts over.
  static KeyBatchDay read(Uint8List? stored, String today, int cap) {
    if (stored == null) return KeyBatchDay(today, 0);
    final KeyBatchDay value;
    try {
      value = decode(stored);
    } on FormatException {
      return KeyBatchDay(today, cap);
    }
    return value.day == today ? value : KeyBatchDay(today, 0);
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({'v': 1, 'day': day, 'n': count, 'reported': reported}),
    ),
  );

  static final RegExp _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static KeyBatchDay decode(Uint8List bytes) {
    if (bytes.length > 256) throw const FormatException();
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
