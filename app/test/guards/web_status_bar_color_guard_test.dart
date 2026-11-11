import 'dart:convert';
import 'dart:io';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The browser and installed web app paint the phone status bar from
/// `web/manifest.json` and the `theme-color` meta tags. They must match the
/// app background, never Flutter's template blue (#0175C2).
String _hex(Color c) {
  final rgb = c.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

void main() {
  final light = _hex(AppPalette.pearl);
  final dark = _hex(AppPalette.darkSurface);

  test('the manifest colours are the light app background', () {
    final manifest = jsonDecode(
      File('web/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect((manifest['theme_color'] as String).toUpperCase(), light);
    expect((manifest['background_color'] as String).toUpperCase(), light);
  });

  test('index.html sets a theme colour per colour scheme', () {
    final html = File('web/index.html').readAsStringSync();
    final tags = RegExp(r'<meta name="theme-color"[^>]*>')
        .allMatches(html)
        .map((m) => m.group(0)!)
        .toList();
    expect(tags, hasLength(2));
    final byScheme = {
      for (final tag in tags)
        RegExp(r'prefers-color-scheme: (\w+)')
            .firstMatch(tag)!
            .group(1)!: RegExp(r'content="(#[0-9A-Fa-f]{6})"')
            .firstMatch(tag)!
            .group(1)!
            .toUpperCase(),
    };
    expect(byScheme, {'light': light, 'dark': dark});
  });

  test('no web file keeps the template blue', () {
    for (final path in ['web/manifest.json', 'web/index.html']) {
      expect(
        File(path).readAsStringSync().toUpperCase(),
        isNot(contains('#0175C2')),
        reason: path,
      );
    }
  });
}
