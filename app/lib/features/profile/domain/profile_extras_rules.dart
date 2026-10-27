import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../../shared/format/profile_website.dart';

/// Client checks for the profile text fields, mirroring the server
/// (`backend/internal/identity/validate.go`, ADR-0024 D2, W3-22 L-2 / L-3).
/// Both sides run the vectors in `testdata/profile_text/` (see its README.md),
/// so a rule changed here without the server, or the other way round, fails a
/// test. The server stays authoritative: a disagreement comes back as
/// VALIDATION with the field name and is shown inline.
///
/// Common to every field: trim first (Unicode White_Space and U+FEFF, which is
/// what [String.trim] removes), then NFC (not the website), then count code
/// points (runes). Control means category Cc (U+0000-001F, U+007F-009F), bidi
/// formatting controls are U+202A-202E and U+2066-2069, line separators are
/// U+2028 and U+2029.
const kMaxDisplayNameLength = 50;
const kMaxBioLength = 160;
const kMaxLocationLength = 30;
const kMaxWebsiteLength = 100;

enum DisplayNameIssue {
  /// Empty after trim.
  empty,

  /// More than [kMaxDisplayNameLength] code points after trim and NFC.
  tooLong,

  /// A control character (a line break included: the name is one line), a
  /// line or paragraph separator or a bidi formatting control.
  forbiddenCharacter,
}

enum BioIssue {
  /// More than [kMaxBioLength] code points after trim and NFC.
  tooLong,

  /// A control character other than LF (CR is refused, not folded), a line or
  /// paragraph separator or a bidi formatting control.
  forbiddenCharacter,
}

enum LocationIssue {
  /// More than [kMaxLocationLength] code points after trim and NFC.
  tooLong,

  /// A control character (a line break included: the location is one line), a
  /// line or paragraph separator (U+2028, U+2029) or a bidi formatting
  /// control.
  forbiddenCharacter,
}

enum WebsiteIssue {
  /// More than [kMaxWebsiteLength] code points after trim.
  tooLong,

  /// Not an absolute `http`/`https` address with a public-looking host, or it
  /// has user info, whitespace, a control or a bidi character (see
  /// [parseProfileWebsite]).
  invalid,
}

/// What is sent for a display name: trimmed, then NFC (the server's order), so
/// the count the user sees is the count the server checks.
String normalizeDisplayName(String raw) => unorm.nfc(raw.trim());

/// What is sent for a bio: trimmed, then NFC. `""` clears it.
String normalizeBio(String raw) => unorm.nfc(raw.trim());

/// What is sent for a location: trimmed, then NFC (the server's order), so
/// the count the user sees is the count the server checks. `""` clears it.
String normalizeProfileLocation(String raw) => unorm.nfc(raw.trim());

final RegExp _httpScheme = RegExp(r'^https?://', caseSensitive: false);

/// What is sent for a website: the trimmed text with only the scheme
/// lower-cased, as the server stores it (the rest is kept as typed, the host
/// case included). `""` clears it.
String normalizeProfileWebsite(String raw) {
  final text = raw.trim();
  final scheme = _httpScheme.matchAsPrefix(text);
  return scheme == null
      ? text
      : text.substring(0, scheme.end).toLowerCase() +
            text.substring(scheme.end);
}

/// Code points left in the display name (negative once over the limit). Runes,
/// not UTF-16 units, so an emoji counts once.
int profileNameRemaining(String raw) =>
    kMaxDisplayNameLength - normalizeDisplayName(raw).runes.length;

/// Code points left in the bio (negative once over the limit).
int profileBioRemaining(String raw) =>
    kMaxBioLength - normalizeBio(raw).runes.length;

/// Code points left in the location (negative once over the limit). Runes, not
/// UTF-16 units, so an emoji counts once.
int locationRemaining(String raw) =>
    kMaxLocationLength - normalizeProfileLocation(raw).runes.length;

/// Code points left in the website (negative once over the limit).
int websiteRemaining(String raw) =>
    kMaxWebsiteLength - normalizeProfileWebsite(raw).runes.length;

// The server's sets: Cc (U+0000-001F, U+007F-009F), the line and paragraph
// separators Zl and Zp (U+2028, U+2029) and the bidi formatting controls
// U+202A-202E and U+2066-2069 (ADR-0010 D9).
bool _isControl(int r) => r <= 0x1F || (r >= 0x7F && r <= 0x9F);
bool _isLineSeparator(int r) => r == 0x2028 || r == 0x2029;
bool _isBidi(int r) =>
    (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069);

/// Why [raw] cannot be saved as a display name, or null: 1 to
/// [kMaxDisplayNameLength] code points after trim and NFC, on one line.
DisplayNameIssue? displayNameIssue(String raw) {
  final text = normalizeDisplayName(raw);
  final length = text.runes.length;
  if (length < 1) return DisplayNameIssue.empty;
  if (length > kMaxDisplayNameLength) return DisplayNameIssue.tooLong;
  for (final r in text.runes) {
    if (_isControl(r) || _isLineSeparator(r) || _isBidi(r)) {
      return DisplayNameIssue.forbiddenCharacter;
    }
  }
  return null;
}

/// Why [raw] cannot be saved as a bio, or null (empty is a valid clear): up to
/// [kMaxBioLength] code points after trim and NFC; LF is the one control
/// character a bio keeps.
BioIssue? bioIssue(String raw) {
  final text = normalizeBio(raw);
  if (text.runes.length > kMaxBioLength) return BioIssue.tooLong;
  for (final r in text.runes) {
    if (r != 0x0A && (_isControl(r) || _isLineSeparator(r) || _isBidi(r))) {
      return BioIssue.forbiddenCharacter;
    }
  }
  return null;
}

/// Why [raw] cannot be saved as a location, or null (an empty location is a
/// valid clear). Counts after trim and NFC, like the server. NFC is
/// `package:unorm_dart` (pure Dart), the composer's rule.
LocationIssue? locationIssue(String raw) {
  final text = normalizeProfileLocation(raw);
  if (text.runes.length > kMaxLocationLength) return LocationIssue.tooLong;
  for (final r in text.runes) {
    if (_isControl(r) || _isLineSeparator(r) || _isBidi(r)) {
      return LocationIssue.forbiddenCharacter;
    }
  }
  return null;
}

/// Why [raw] cannot be saved as a website, or null (empty is a valid clear).
/// It must be one `parseProfileWebsite` accepts, the same parser the profile
/// header uses before it ever shows or opens a link, so a saved website always
/// renders. The server runs the same rules (W3-22 L-2 / L-3), so the two agree
/// on every row of `testdata/profile_text/website.json`.
WebsiteIssue? websiteIssue(String raw) {
  final text = normalizeProfileWebsite(raw);
  if (text.isEmpty) return null;
  if (text.runes.length > kMaxWebsiteLength) return WebsiteIssue.tooLong;
  return parseProfileWebsite(text) == null ? WebsiteIssue.invalid : null;
}

/// The host a valid website shows as on the profile (punycode for a
/// non-ASCII host), for the "Shows as" hint under the field; null when [raw]
/// is empty or not a valid website.
String? websiteHostPreview(String raw) {
  final text = normalizeProfileWebsite(raw);
  return text.isEmpty ? null : parseProfileWebsite(text)?.host;
}
