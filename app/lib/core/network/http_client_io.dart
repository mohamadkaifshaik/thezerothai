import 'dart:io' as io;

import 'package:connectrpc/connect.dart' show HttpClient;
import 'package:connectrpc/io.dart' as connect_io;

/// HTTP/1.1 client backed by `dart:io`, used on Android, iOS, desktop.
HttpClient createPlatformHttpClient() {
  return connect_io.createHttpClient(io.HttpClient());
}
