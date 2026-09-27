import 'package:connectrpc/connect.dart' show HttpClient;

import 'http_client_stub.dart'
    if (dart.library.io) 'http_client_io.dart'
    if (dart.library.js_interop) 'http_client_web.dart'
    as impl;

/// Creates the right [HttpClient] transport for the current platform
/// (`dart:io` `HttpClient` on Android/iOS/desktop, `fetch()` on web).
HttpClient createPlatformHttpClient() => impl.createPlatformHttpClient();
