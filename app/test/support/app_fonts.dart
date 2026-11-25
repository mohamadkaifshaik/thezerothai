import 'dart:io';

import 'package:flutter/services.dart';

/// Loads the bundled app fonts (`Inter` and `PlusJakartaSans`, upright and
/// italic: the "D0" monogram is Jakarta italic) into the test engine.
///
/// Call it from `setUpAll` in golden and typography tests only. It is not
/// wired into a global `flutter_test_config.dart` on purpose: loading the
/// real fonts everywhere would change text metrics in every geometry test.
///
/// Paths resolve from `app/`, the working directory of `flutter test`.
Future<void> loadAppFonts() async {
  await _load('Inter', const [
    'assets/fonts/Inter.ttf',
    'assets/fonts/Inter-Italic.ttf',
  ]);
  await _load('PlusJakartaSans', const [
    'assets/fonts/PlusJakartaSans.ttf',
    'assets/fonts/PlusJakartaSans-Italic.ttf',
  ]);
}

Future<void> _load(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    final bytes = await File(path).readAsBytes();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}
