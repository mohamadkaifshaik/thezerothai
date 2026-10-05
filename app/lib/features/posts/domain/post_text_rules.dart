import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Client mirror of the server's post-text rules (ADR-0010 D9, with the D21
/// G2/G4 amendments). The server (`backend/internal/posts/text`) stays
/// authoritative; this exists only so the composer's counter and Post button
/// agree with it. Do not restate the server's regexes here; the shared
/// fixture `testdata/post_text_grammar.json` (`normalise` rows) pins both.
const kMaxPostCodePoints = 280;

/// At most 10 lines, i.e. at most 9 `\n` (D9 step 8).
const kMaxPostLines = 10;

/// Why a draft cannot be posted. Only the first failing step is reported, in
/// the server's order.
enum PostDraftProblem {
  /// Nothing visible (D9 step 5, G4 predicate).
  empty,

  /// A control character other than `\n`, or a bidi formatting control (D9
  /// step 6).
  forbiddenCharacter,

  /// More than [kMaxPostCodePoints] code points after NFC (step 7).
  tooLong,

  /// More than [kMaxPostLines] lines (step 8).
  tooManyLines,
}

/// The result of running the D9 steps on what the user typed.
class PostDraft {
  const PostDraft({
    required this.text,
    required this.codePoints,
    required this.lines,
    this.problem,
  });

  /// The text as the server would store it (steps 2-4 applied). Meaningful
  /// even when [problem] is set, so the counter keeps working.
  final String text;

  /// `text.runes.length` after NFC and trim (step 7).
  final int codePoints;

  /// Number of lines in [text] (`\n` count + 1; 0 when empty).
  final int lines;

  /// Null when the draft may be posted.
  final PostDraftProblem? problem;

  bool get canPost => problem == null;

  /// Code points left; negative when over the limit (the counter shows -1 at
  /// 281).
  int get remaining => kMaxPostCodePoints - codePoints;
}

// D9 step 4 / G4: the explicit invisible set trimmed at both ends. Spelled
// out (not `\p{Cf}`) so tag characters, bidi controls and prepended
// concatenation marks are never trimmed.
bool _isTrimInvisible(int r) =>
    r == 0x00AD ||
    r == 0x180E ||
    r == 0x200B ||
    (r >= 0x2060 && r <= 0x2064) ||
    r == 0xFEFF;

// Go's `unicode.IsSpace` (not ECMAScript `\s`: it has U+0085, lacks U+FEFF).
bool _isGoSpace(int r) =>
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
    r == 0x3000;

final _formatChar = RegExp(r'\p{Cf}', unicode: true);

// G4 (L5 amendment, 2026-10-05) blank-looking, non-`Cf` code points: the Hangul
// fillers U+115F/U+1160/U+3164/U+FFA0, Braille blank U+2800, combining grapheme
// joiner U+034F and Khmer inherent vowels U+17B4/U+17B5. Spelled out like the
// Go `isBlankLooking`; used only by the empty check, never to trim.
bool _isBlankLooking(int r) =>
    r == 0x034F ||
    r == 0x115F ||
    r == 0x1160 ||
    r == 0x17B4 ||
    r == 0x17B5 ||
    r == 0x2800 ||
    r == 0x3164 ||
    r == 0xFFA0;

// G4 empty predicate: whitespace, any `Cf`, a variation selector, or a
// blank-looking code point.
bool _isInvisibleForEmptyCheck(int r) =>
    _isGoSpace(r) ||
    _isBlankLooking(r) ||
    (r >= 0xFE00 && r <= 0xFE0F) ||
    (r >= 0xE0100 && r <= 0xE01EF) ||
    _formatChar.hasMatch(String.fromCharCode(r));

bool _isForbidden(int r) =>
    (r < 0x20 && r != 0x0A) ||
    (r >= 0x7F && r <= 0x9F) ||
    (r >= 0x202A && r <= 0x202E) ||
    (r >= 0x2066 && r <= 0x2069);

bool _isTrimmable(int r) => _isGoSpace(r) || _isTrimInvisible(r);

/// Applies D9 steps 2-8 to [raw]. Pure; cheap enough for every keystroke
/// (the composer caps its input length).
PostDraft analyzePostDraft(String raw) {
  // Step 2 (+G2): line endings, U+2028/U+2029 -> \n, TAB -> one space.
  final folded = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u2028', '\n')
      .replaceAll('\u2029', '\n')
      .replaceAll('\t', ' ');
  // Step 3: NFC.
  final runes = unorm.nfc(folded).runes.toList();
  // Step 4 (+G4): trim spaces and the invisible set at both ends.
  var start = 0;
  var end = runes.length;
  while (start < end && _isTrimmable(runes[start])) {
    start++;
  }
  while (end > start && _isTrimmable(runes[end - 1])) {
    end--;
  }
  final kept = runes.sublist(start, end);
  final text = String.fromCharCodes(kept);
  final codePoints = kept.length;
  final lines = kept.isEmpty ? 0 : kept.where((r) => r == 0x0A).length + 1;

  PostDraftProblem? problem;
  // Step 5 (G4): empty when nothing visible remains.
  if (kept.every(_isInvisibleForEmptyCheck)) {
    problem = PostDraftProblem.empty;
  } else if (kept.any(_isForbidden)) {
    problem = PostDraftProblem.forbiddenCharacter;
  } else if (codePoints > kMaxPostCodePoints) {
    problem = PostDraftProblem.tooLong;
  } else if (lines > kMaxPostLines) {
    problem = PostDraftProblem.tooManyLines;
  }
  return PostDraft(
    text: text,
    codePoints: codePoints,
    lines: lines,
    problem: problem,
  );
}
