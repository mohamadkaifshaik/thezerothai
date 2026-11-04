/// The one place crash text is made safe. Pure Dart with no
/// SDK or Flutter import, so a future web reporter shares it unchanged.
abstract final class CrashScrubber {
  /// Longest message that may leave the device.
  static const int maxLength = 200;

  static final RegExp _url = RegExp(r'[A-Za-z][A-Za-z0-9+.\-]*://\S*');
  static final RegExp _email = RegExp(r'[^\s@<>]+@[^\s@<>]+');
  static final RegExp _handle = RegExp(r'@\w*');
  // Firebase uids are 28 characters; anything that long and token-like goes.
  static final RegExp _token = RegExp(r'[A-Za-z0-9]{28,}');
  static final RegExp _digits = RegExp(r'\d{6,}');

  /// Replaces URLs, emails, @handles, uid-like tokens and digit runs of 6 or
  /// more, then cuts the result to [maxLength] characters. Total: never
  /// throws, and the output never contains any of those shapes.
  static String scrub(String input) {
    var s = input
        .replaceAll(_url, '<url>')
        .replaceAll(_email, '<email>')
        .replaceAll(_handle, '<handle>')
        .replaceAll(_token, '<token>')
        .replaceAll(_digits, '<n>');
    if (s.length > maxLength) s = s.substring(0, maxLength);
    // A cut can split a surrogate pair; keep the string well formed.
    if (s.isNotEmpty && (s.codeUnitAt(s.length - 1) & 0xFC00) == 0xD800) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
