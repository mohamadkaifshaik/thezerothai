import '../../../shared/format/single_line_text.dart';
import '../../lists/domain/list_text_rules.dart' show normalizeListText;
import 'beacons_feature_flag.dart';

/// Why a plan field is refused before sending (docs/beacons-plan.md section
/// 3). The server checks the same limits after trim and NFC and stays
/// authoritative; this only saves a wasted call.
enum BeaconTextIssue {
  /// Empty after trim (title and venue only).
  empty,

  /// More code points than the limit, after trim and NFC.
  tooLong,

  /// Control, line break, bidi control or invisible characters (one line).
  notPlainOneLine,

  /// Details (several lines allowed): a control other than LF, a line
  /// separator, a bidi control, an invisible format character or a filler.
  notPlainText,
}

/// Why a start time is refused before sending.
enum BeaconTimeIssue {
  /// Less than [kBeaconMinLead] from now.
  tooSoon,

  /// More than [kBeaconMaxLead] from now.
  tooFar,
}

/// Code points as the server counts them (trim, then NFC).
int beaconTextLength(String raw) => normalizeListText(raw).runes.length;

BeaconTextIssue? _oneLine(String raw, {required int max}) {
  final text = normalizeListText(raw);
  if (text.isEmpty) return BeaconTextIssue.empty;
  if (text.runes.length > max) return BeaconTextIssue.tooLong;
  return singleLineIssue(text) == null ? null : BeaconTextIssue.notPlainOneLine;
}

/// 1 to [kBeaconTitleMaxLength] code points, one line.
BeaconTextIssue? beaconTitleIssue(String raw) =>
    _oneLine(raw, max: kBeaconTitleMaxLength);

/// 1 to [kBeaconVenueMaxLength] code points, one line: a named meeting point.
BeaconTextIssue? beaconVenueIssue(String raw) =>
    _oneLine(raw, max: kBeaconVenueMaxLength);

/// 0 to [kBeaconNoteMaxLength] code points, one line (empty allowed).
BeaconTextIssue? beaconNoteIssue(String raw) {
  final text = normalizeListText(raw);
  if (text.isEmpty) return null;
  if (text.runes.length > kBeaconNoteMaxLength) return BeaconTextIssue.tooLong;
  return singleLineIssue(text) == null ? null : BeaconTextIssue.notPlainOneLine;
}

/// A beacon id: the 19-digit decimal of the server's Snowflake. Checked before
/// any path is built from one, so a hostile id never adds a segment.
bool isBeaconId(String s) {
  if (s.length != 19) return false;
  for (final c in s.codeUnits) {
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}

/// 0 to [kBeaconDetailsMaxLength] code points, several lines allowed.
BeaconTextIssue? beaconDetailsIssue(String raw) {
  final text = normalizeListText(raw);
  if (text.runes.length > kBeaconDetailsMaxLength) {
    return BeaconTextIssue.tooLong;
  }
  return multiLineTextIssue(text) == null ? null : BeaconTextIssue.notPlainText;
}

/// The inline error under a text field; an empty field shows none (the
/// Create button is disabled instead).
String? beaconFieldError(BeaconTextIssue? issue, {required int max}) =>
    switch (issue) {
      null || BeaconTextIssue.empty => null,
      BeaconTextIssue.tooLong => 'At most $max characters.',
      BeaconTextIssue.notPlainOneLine => 'Use one line of plain text.',
      BeaconTextIssue.notPlainText =>
        'Use plain text, with no invisible characters.',
    };

/// The inline error under the start time.
String? beaconTimeError(BeaconTimeIssue? issue) => switch (issue) {
  null => null,
  BeaconTimeIssue.tooSoon => 'Pick a time at least 5 minutes from now.',
  BeaconTimeIssue.tooFar => 'Pick a time within the next 30 days.',
};

/// [startAt] must be at least [kBeaconMinLead] and at most [kBeaconMaxLead]
/// after [now] (both bounds inclusive).
BeaconTimeIssue? beaconStartIssue(DateTime startAt, DateTime now) {
  if (startAt.isBefore(now.add(kBeaconMinLead))) return BeaconTimeIssue.tooSoon;
  if (startAt.isAfter(now.add(kBeaconMaxLead))) return BeaconTimeIssue.tooFar;
  return null;
}
