import 'dart:io';

import 'package:flutter/services.dart';

/// Loads the bundled app fonts (`Inter`, upright and italic) into the test engine.
///
/// Call it from `setUpAll` in golden and typography tests only. It is not
/// wired into a global `flutter_test_config.dart` on purpose: loading the
/// real fonts everywhere would change text metrics in every geometry test.
///
/// Paths resolve from `app/`, the working directory of `flutter test`.
Future<void> loadAppFonts() async {
  await _load('Inter', 'assets/fonts/Inter.ttf');
}

Future<void> _load(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}
