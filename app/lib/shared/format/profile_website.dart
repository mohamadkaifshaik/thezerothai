/// A profile website the client may show and open: the ASCII (punycode) host
/// the row displays and the URL that is launched, built from the same host so
/// what the viewer reads is what opens (ADR-0024 D2: `http`/`https` only).
class ProfileWebsite {
  const ProfileWebsite({required this.host, required this.uri});

  /// Lower-case ASCII host, `xn--` labels for non-ASCII ones; no port.
  final String host;

  /// The absolute `http(s)` URL to open, with [host] as its host.
  final Uri uri;
}

final RegExp _website = RegExp(
  r'^(https?)://([^/?#]*)([/?#].*)?$',
  caseSensitive: false,
  dotAll: true,
);

// Whitespace (`\s` also covers no-break and line-separator spaces), C0/C1
// controls and the bidi formatting controls U+061C, U+200E, U+200F,
// U+202A-U+202E and U+2066-U+2069 (ADR-0010 D9). Written as escapes on purpose:
// a raw bidi character in source is itself a Trojan Source risk.
final RegExp _forbidden = RegExp(
  r'[\s\u0000-\u001F\u007F-\u009F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);

final RegExp _asciiLabel = RegExp(r'^[a-z0-9_-]+$');

// The port is ASCII digits only (no sign, no hex: `int.tryParse` would take
// `+80` and `0x50`); leading zeros are fine.
final RegExp _portDigits = RegExp(r'^[0-9]+$');

// A top-level domain: 2 to 63 letters, or an internationalised `xn--` label.
// A label with a digit (the last part of `127.0.0.1`, `0x7f.1` or a decimal
// IPv4) is neither, which is what refuses IPv4 literals in every notation.
final RegExp _tldLabel = RegExp(r'^(?:[a-z]{2,63}|xn--[a-z0-9-]+)$');

// Names that only mean something on the viewer's own machine or network
// (RFC 6761 localhost, RFC 6762 local, the reserved private-use `internal`,
// RFC 8375 home.arpa): a host that is one of them, or a subdomain of one, is
// refused.
const List<String> _internalSuffixes = [
  'localhost',
  'local',
  'internal',
  'home.arpa',
];

/// Parses the server's `Profile.website` for display. Returns null (the row is
/// left out) unless it is an absolute `http`/`https` URL with a non-empty host,
/// no user info and no control, whitespace or bidi character: the client
/// re-checks what the server already validated before it ever launches a URL.
///
/// Non-ASCII host labels are lower-cased and encoded as punycode (RFC 3492),
/// so a look-alike host is shown as the `xn--` name it really resolves to.
/// (No NFKC mapping: a label the server let through that needs one is shown
/// in its encoded form, which is still the honest one.)
ProfileWebsite? parseProfileWebsite(String raw) {
  final text = raw.trim();
  if (text.isEmpty || _forbidden.hasMatch(text)) return null;
  final match = _website.firstMatch(text);
  if (match == null) return null;
  final scheme = match.group(1)!.toLowerCase();
  final authority = match.group(2)!;
  final rest = match.group(3) ?? '';
  if (authority.contains('@') || authority.contains('[')) return null;

  var hostPart = authority;
  int? port;
  final colon = authority.lastIndexOf(':');
  if (colon >= 0) {
    final digits = authority.substring(colon + 1);
    if (digits.isNotEmpty) {
      if (!_portDigits.hasMatch(digits)) return null;
      port = int.tryParse(digits);
      if (port == null || port < 1 || port > 65535) return null;
    }
    hostPart = authority.substring(0, colon);
  }
  final host = _asciiHost(hostPart);
  if (host == null) return null;

  final uri = Uri.tryParse(
    '$scheme://$host${port == null ? '' : ':$port'}$rest',
  );
  if (uri == null || uri.host != host) return null;
  return ProfileWebsite(host: host, uri: uri);
}

String? _asciiHost(String raw) {
  var host = raw.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.isEmpty) return null;
  final labels = <String>[];
  for (final label in host.split('.')) {
    if (label.isEmpty) return null;
    final ascii = label.codeUnits.every((c) => c < 0x80);
    final encoded = ascii ? label : 'xn--${punycodeEncode(label)}';
    if (encoded.length > 63 || !_asciiLabel.hasMatch(encoded)) return null;
    labels.add(encoded);
  }
  if (labels.length < 2 || !_tldLabel.hasMatch(labels.last)) return null;
  final joined = labels.join('.');
  for (final suffix in _internalSuffixes) {
    if (joined == suffix || joined.endsWith('.$suffix')) return null;
  }
  return joined;
}

const int _base = 36;
const int _tMin = 1;
const int _tMax = 26;
const int _skew = 38;
const int _damp = 700;
const int _initialBias = 72;
const int _initialN = 128;

/// RFC 3492 Punycode of one label (without the `xn--` prefix). [input] is a
/// whole label; its basic (ASCII) code points are copied first, then the rest
/// are encoded as deltas.
String punycodeEncode(String input) {
  final cps = input.runes.toList();
  final out = StringBuffer();
  for (final cp in cps) {
    if (cp < 0x80) out.writeCharCode(cp);
  }
  final basic = out.length;
  var handled = basic;
  if (basic > 0) out.write('-');

  var n = _initialN;
  var delta = 0;
  var bias = _initialBias;
  while (handled < cps.length) {
    var m = 0x7fffffff;
    for (final cp in cps) {
      if (cp >= n && cp < m) m = cp;
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final cp in cps) {
      if (cp < n) delta++;
      if (cp == n) {
        var q = delta;
        for (var k = _base; ; k += _base) {
          final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
          if (q < t) break;
          out.writeCharCode(_digit(t + (q - t) % (_base - t)));
          q = (q - t) ~/ (_base - t);
        }
        out.writeCharCode(_digit(q));
        bias = _adapt(delta, handled + 1, handled == basic);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return out.toString();
}

int _digit(int d) => d < 26 ? 0x61 + d : 0x30 + d - 26;

int _adapt(int delta, int points, bool first) {
  var d = first ? delta ~/ _damp : delta ~/ 2;
  d += d ~/ points;
  var k = 0;
  while (d > ((_base - _tMin) * _tMax) ~/ 2) {
    d ~/= _base - _tMin;
    k += _base;
  }
  return k + (_base - _tMin + 1) * d ~/ (d + _skew);
}
