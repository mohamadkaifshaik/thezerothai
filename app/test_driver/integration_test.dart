import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// The port the test fetches the MLS vectors from. The vectors live outside
/// the app's asset list (so release builds do not ship them); the driver
/// serves them for the length of the run.
const _vectorsPort = 8089;

Future<void> main() async {
  final vectors = File('integration_test/assets/mls/vectors-v1.json');
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
