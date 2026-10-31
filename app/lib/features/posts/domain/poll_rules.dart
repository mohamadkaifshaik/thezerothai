import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'composer_draft.dart';
import 'post_text_rules.dart';

/// Client mirror of the server's poll creation rules (ADR-0029 D1/F4,
/// `backend/internal/posts/poll.go`). The server stays authoritative; this
/// exists so the builder and the Post button agree with it. The shared
/// fixture `testdata/poll_rules.json` pins both sides.
const kPollMinChoices = 2;
const kPollMaxChoices = 4;
const kPollChoiceMaxCodePoints = 25;
const kPollMinMinutes = 5;
const kPollMaxMinutes = 7 * 24 * 60;

/// The default length: 1 day.
const kPollDefaultMinutes = 24 * 60;

/// The poll a new builder starts with: two empty choices, one day.
DraftPoll newDraftPoll() =>
    const DraftPoll(choices: ['', ''], durationMinutes: kPollDefaultMinutes);

// Full case folding (Unicode CaseFolding.txt "F" and the common "C" cases the
// plain lower-casing misses). Dart has no case folding; lower-casing covers the
// rest. A miss here only means the server refuses the duplicate instead.
const _foldSpecial = <String, String>{
  '\u00DF': 'ss', // sharp s
  '\u1E9E': 'ss', // capital sharp s
  '\u03C2': '\u03C3', // final sigma
  '\u017F': 's', // long s
  '\uFB00': 'ff',
  '\uFB01': 'fi',
  '\uFB02': 'fl',
  '\uFB03': 'ffi',
  '\uFB04': 'ffl',
  '\uFB05': 'st',
  '\uFB06': 'st',
};

/// The comparison key of the distinctness rule: NFC of the case-folded NFC
/// label (the server's `foldKey`).
String pollFoldKey(String label) {
  var s = unorm.nfc(label).toLowerCase();
  _foldSpecial.forEach((from, to) => s = s.replaceAll(from, to));
  return unorm.nfc(s);
}

/// What is wrong with one choice row. All false: the row is fine.
class PollChoiceCheck {
  const PollChoiceCheck({
    required this.stored,
    required this.codePoints,
    required this.blank,
    required this.forbidden,
    required this.tooLong,
    required this.duplicate,
  });

  /// The normalised label (what would be sent and stored).
  final String stored;

  /// Code points of [stored]: what the "N / 25" counter shows.
  final int codePoints;

  /// Nothing visible. Not an error to show while the user is still typing,
  /// but the poll cannot be posted.
  final bool blank;
  final bool forbidden;
  final bool tooLong;

  /// Equals an earlier choice after NFC + case folding. The earlier row is
  /// not marked, the later one is.
  final bool duplicate;

  bool get ok => !blank && !forbidden && !tooLong && !duplicate;
}

/// The result of running the poll rules on what the user typed. Pure.
class PollAnalysis {
  const PollAnalysis({required this.choices, required this.durationOk});

  final List<PollChoiceCheck> choices;
  final bool durationOk;

  bool get countOk =>
      choices.length >= kPollMinChoices && choices.length <= kPollMaxChoices;

  /// Every rule holds: the poll may be sent.
  bool get valid => countOk && durationOk && choices.every((c) => c.ok);

  /// The normalised labels, in order.
  List<String> get stored => [for (final c in choices) c.stored];
}

/// Runs the server's poll rules (choices, then duration) on [poll].
PollAnalysis analyzePoll(DraftPoll poll) {
  final seen = <String>{};
  final checks = <PollChoiceCheck>[];
  for (final raw in poll.choices) {
    final n = normalizeLabel(raw);
    final blank = n.problem == LabelProblem.blank;
    final forbidden = n.problem == LabelProblem.forbiddenCharacter;
    final tooLong = n.codePoints > kPollChoiceMaxCodePoints;
    var duplicate = false;
    if (!blank && !forbidden) {
      duplicate = !seen.add(pollFoldKey(n.text));
    }
    checks.add(
      PollChoiceCheck(
        stored: n.text,
        codePoints: n.codePoints,
        blank: blank,
        forbidden: forbidden,
        tooLong: tooLong,
        duplicate: duplicate,
      ),
    );
  }
  return PollAnalysis(
    choices: checks,
    durationOk:
        poll.durationMinutes >= kPollMinMinutes &&
        poll.durationMinutes <= kPollMaxMinutes,
  );
}

/// A poll length cut into the builder's three controls.
class PollLength {
  const PollLength(this.days, this.hours, this.minutes);

  factory PollLength.fromMinutes(int total) =>
      PollLength(total ~/ 1440, (total % 1440) ~/ 60, total % 60);

  final int days;
  final int hours;
  final int minutes;

  int get totalMinutes => days * 1440 + hours * 60 + minutes;
}

/// The words for a poll length, for the compact picker row and its label:
/// "1 day, 0 hours, 0 minutes".
String pollLengthText(int totalMinutes) {
  final l = PollLength.fromMinutes(totalMinutes);
  String unit(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  return '${unit(l.days, 'day', 'days')}, '
      '${unit(l.hours, 'hour', 'hours')}, '
      '${unit(l.minutes, 'minute', 'minutes')}';
}
