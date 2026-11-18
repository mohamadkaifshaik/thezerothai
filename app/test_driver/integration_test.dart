import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// The port the test fetches the MLS vectors from. The vectors live outside
/// the app's asset list (so release builds do not ship them); the driver
/// serves them for the length of the run.
const _vectorsPort = 8089;

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
