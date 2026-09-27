import 'package:connectrpc/connect.dart' show HttpClient;
import 'package:connectrpc/web.dart' as connect_web;

/// HTTP client backed by `fetch()`, used on Flutter Web.
HttpClient createPlatformHttpClient() {
  return connect_web.createHttpClient();
}
