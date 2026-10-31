/// Dart port of the server's one-line text rules (`identity.singleLineIssue`,
/// `backend/internal/identity/validate.go`; W5-45, ported by W5-49). Shared by
/// display name, location, list name and list description. Both sides run
/// `testdata/profile_text/single_line_text.json`, so a rule changed on one side
/// fails on the other.
///
/// Input is the NORMALISED value (trimmed, NFC), as the server checks it.
/// `""` is never refused here (a length rule decides whether it may be empty).
library;

/// Why a normalised one-line value is refused.
enum SingleLineIssue {
  /// A control character (a line break included), a line or paragraph
  /// separator or a bidi formatting control.
  forbidden,

  /// An invisible format character (category Cf, but for a joiner between two
  /// real neighbours and a well-formed flag tag sequence), a Hangul or
  /// halfwidth filler, or text with no visible character.
  invisible,
}

/// Category Cf, as an explicit table: Dart has no Unicode category data and the
/// server's table is Go's `unicode.Cf` (identical to Unicode 15 to 17). Each
/// entry is an inclusive [low, high] pair. The poll fold's ignorable set
/// (`pollFoldKey`) is Default_Ignorable_Code_Point, a different set (it holds
/// Mn and Lo members and omits U+0600-0605), so it cannot be reused.
const List<List<int>> _formatRanges = [
  [0x00AD, 0x00AD],
  [0x0600, 0x0605],
  [0x061C, 0x061C],
  [0x06DD, 0x06DD],
  [0x070F, 0x070F],
  [0x0890, 0x0891],
  [0x08E2, 0x08E2],
  [0x180E, 0x180E],
  [0x200B, 0x200F],
  [0x202A, 0x202E],
  [0x2060, 0x2064],
  [0x2066, 0x206F],
  [0xFEFF, 0xFEFF],
  [0xFFF9, 0xFFFB],
  [0x110BD, 0x110BD],
  [0x110CD, 0x110CD],
  [0x13430, 0x1343F],
  [0x1BCA0, 0x1BCA3],
  [0x1D173, 0x1D17A],
  [0xE0001, 0xE0001],
  [0xE0020, 0xE007F],
];

/// Whether [r] is in Unicode category Cf (format character).
bool isFormatCharacter(int r) {
  for (final range in _formatRanges) {
    if (r < range[0]) return false;
    if (r <= range[1]) return true;
  }
  return false;
}

bool _isControl(int r) => r <= 0x1F || (r >= 0x7F && r <= 0x9F);
bool _isLineSeparator(int r) => r == 0x2028 || r == 0x2029;
bool _isBidi(int r) =>
    (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069);

/// The Hangul and halfwidth fillers: letters to Unicode, blank on screen.
bool _isFiller(int r) => r == 0x115F || r == 0x1160 || r == 0x3164 || r == 0xFFA0;

/// White space as the server trims it: Unicode White_Space plus U+FEFF.
bool _isSpace(int r) =>
    (r >= 0x09 && r <= 0x0D) ||
    r == 0x20 ||
    r == 0x85 ||
    r == 0xA0 ||
    r == 0x1680 ||
    (r >= 0x2000 && r <= 0x200A) ||
    r == 0x2028 ||
    r == 0x2029 ||
    r == 0x202F ||
    r == 0x205F ||
    r == 0x3000 ||
    r == 0xFEFF;

/// A rune a ZWJ or ZWNJ may sit next to: not white space, not a format
/// character (so never another joiner), not a control and not a filler.
bool _isJoinerNeighbour(int r) =>
    !_isSpace(r) && !isFormatCharacter(r) && !_isControl(r) && !_isFiller(r);

// Letter, number, punctuation or symbol (emoji are symbols). Unicode property
// escapes are built into the Dart VM and JS regex engines.
final RegExp _visible = RegExp(r'^[\p{L}\p{N}\p{P}\p{S}]$', unicode: true);

/// A rune that draws something on its own, but for the blank-looking U+17B4,
/// U+17B5 and U+2800.
bool _isVisibleRune(int r) {
  if (r == 0x17B4 || r == 0x17B5 || r == 0x2800) return false;
  return _visible.hasMatch(String.fromCharCode(r));
}

/// How many runes after U+1F3F4 form a well-formed subdivision flag: one or
/// more tag characters (U+E0020-E007E) closed by U+E007F, counting the closer.
/// 0 when [rest] does not start with one.
int _tagSequenceLength(List<int> rest, int from) {
  var n = 0;
  while (from + n < rest.length &&
      rest[from + n] >= 0xE0020 &&
      rest[from + n] <= 0xE007E) {
    n++;
  }
  if (n == 0 || from + n >= rest.length || rest[from + n] != 0xE007F) return 0;
  return n + 1;
}

/// Why [normalized] cannot be a one-line field value, or null. Mirrors
/// `singleLineIssue`: refuses control, line separator, bidi control, filler,
/// any Cf character but a joiner with real neighbours and a well-formed flag
/// tag sequence, and non-empty text with no visible rune.
SingleLineIssue? singleLineIssue(String normalized) {
  final rs = normalized.runes.toList(growable: false);
  var visible = false;
  for (var i = 0; i < rs.length; i++) {
    final r = rs[i];
    if (r == 0x1F3F4) {
      visible = true;
      i += _tagSequenceLength(rs, i + 1);
    } else if (_isControl(r) || _isLineSeparator(r) || _isBidi(r)) {
      return SingleLineIssue.forbidden;
    } else if (_isFiller(r)) {
      return SingleLineIssue.invisible;
    } else if (r == 0x200C || r == 0x200D) {
      if (i == 0 ||
          i == rs.length - 1 ||
          !_isJoinerNeighbour(rs[i - 1]) ||
          !_isJoinerNeighbour(rs[i + 1])) {
        return SingleLineIssue.invisible;
      }
    } else if (isFormatCharacter(r)) {
      return SingleLineIssue.invisible;
    } else if (_isVisibleRune(r)) {
      visible = true;
    }
  }
  return normalized.isNotEmpty && !visible ? SingleLineIssue.invisible : null;
}
