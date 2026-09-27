import 'package:connectrpc/connect.dart' show HttpClient;

/// Fallback for platforms that are neither `dart:io` nor web. Should never
/// be selected in practice; present so the conditional import always
/// resolves to something.
HttpClient createPlatformHttpClient() {
  throw UnsupportedError(
    'No HttpClient implementation for this platform. '
    'Expected dart:io or dart:js_interop (web) to be available.',
  );
}
