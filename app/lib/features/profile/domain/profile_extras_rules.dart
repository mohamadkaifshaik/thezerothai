import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../../shared/format/profile_website.dart';

/// Client checks for the profile extras, mirroring the server
/// (`backend/internal/identity/validate.go`, ADR-0024 D2). The server stays
/// authoritative: a disagreement comes back as VALIDATION `field=location` or
/// `field=website` and is shown inline.
const kMaxLocationLength = 30;
const kMaxWebsiteLength = 100;

enum LocationIssue {
  /// More than [kMaxLocationLength] code points after trim and NFC.
  tooLong,

  /// A control character (a line break included: the location is one line) or
  /// a bidi formatting control.
  forbiddenCharacter,
}

enum WebsiteIssue {
  /// More than [kMaxWebsiteLength] characters after trim.
  tooLong,

  /// Not an absolute `http`/`https` address with a host, or it has user info,
  /// whitespace, a control or a bidi character.
  invalid,
}

/// What is sent for a location: trimmed, then NFC (the server's order), so
/// the count the user sees is the count the server checks. `""` clears it.
String normalizeProfileLocation(String raw) => unorm.nfc(raw.trim());

/// What is sent for a website: the trimmed text (the server only lower-cases
/// the scheme). `""` clears it.
String normalizeProfileWebsite(String raw) => raw.trim();

/// Code points left in the location (negative once over the limit). Runes, not
/// UTF-16 units, so an emoji counts once.
int locationRemaining(String raw) =>
    kMaxLocationLength - normalizeProfileLocation(raw).runes.length;

/// Characters left in the website (negative once over the limit).
int websiteRemaining(String raw) =>
    kMaxWebsiteLength - normalizeProfileWebsite(raw).runes.length;

// The server's sets: Cc (U+0000-001F, U+007F-009F) and the bidi formatting
// controls U+202A-202E and U+2066-2069 (ADR-0010 D9).
bool _isControl(int r) => r <= 0x1F || (r >= 0x7F && r <= 0x9F);
bool _isBidi(int r) =>
    (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069);

/// Why [raw] cannot be saved as a location, or null (an empty location is a
/// valid clear). Counts after trim and NFC, like the server. NFC is
/// `package:unorm_dart` (pure Dart), the composer's rule.
LocationIssue? locationIssue(String raw) {
  final text = normalizeProfileLocation(raw);
  if (text.runes.length > kMaxLocationLength) return LocationIssue.tooLong;
  for (final r in text.runes) {
    if (_isControl(r) || _isBidi(r)) return LocationIssue.forbiddenCharacter;
  }
  return null;
}

/// Why [raw] cannot be saved as a website, or null (empty is a valid clear).
/// It must be one `parseProfileWebsite` accepts, the same parser the profile
/// header uses before it ever shows or opens a link, so a saved website always
/// renders. (Slightly stricter than the server for exotic hosts such as IPv6
/// literals; the header would not show those anyway.)
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
