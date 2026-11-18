import 'dart:convert';
import 'dart:io';

import 'package:dzeroth/core/crypto/crypto_engine.dart';

import 'vectors_port.dart';

/// The vectors file the driver serves on the host's 127.0.0.1:[vectorsPort].
/// On an Android device that address is the device itself, so the run first
/// maps the port to the host with `adb reverse tcp:<port> tcp:<port>` (see
/// crypto/README.md). The file is never bundled into the app.
///
/// The app starts its tests as soon as it launches, which can be before the
/// driver (a separate host process) has opened the port, so a refused
/// connection is retried for up to 30 seconds.
Future<String> loadVectorsText() async {
  final client = HttpClient();
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$vectorsPort/vectors-v1.json'),
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw StateError('the driver answered ${response.statusCode}');
        }
        return await response.transform(utf8.decoder).join();
      } on SocketException {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError(
            'no vectors on 127.0.0.1:$vectorsPort: run through flutter drive '
            'with the driver, after adb reverse tcp:$vectorsPort '
            'tcp:$vectorsPort',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  } finally {
    client.close(force: true);
  }
}

/// The native engine holds nothing to close.
void closeEngine(CryptoEngine engine) {}

/// Whether the page is cross-origin isolated; null off the web.
bool? get crossOriginIsolated => null;
