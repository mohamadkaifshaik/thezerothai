import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// The port the test fetches the MLS vectors from: 8089, or the
/// MLS_VECTORS_PORT environment variable (pass the same number to the app as
/// `--dart-define=MLS_VECTORS_PORT=n`). The vectors live outside the app's
/// asset list (so release builds do not ship them); the driver serves them for
/// the length of the run.
final _vectorsPort =
    int.tryParse(Platform.environment['MLS_VECTORS_PORT'] ?? '') ?? 8089;

Future<void> main() async {
  // The driver runs on the VM with `app/` as its working directory, so it reads
  // the one committed copy of the vectors, in the repo's testdata/.
  final vectors = File('../testdata/mls/vectors-v1.json');
  if (!vectors.existsSync()) {
    throw StateError('run flutter drive from app/: ${vectors.path} not found');
  }
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    _vectorsPort,
  );
  server.listen((request) {
    request.response
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..headers.contentType = ContentType.json
      ..add(vectors.readAsBytesSync());
    request.response.close();
  });
  try {
    await integrationDriver();
  } finally {
    await server.close(force: true);
  }
}
