import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Android MLS library is built by app/rust_builder/android/build.gradle
/// with `cargo ndk`, from app/rust with every crates.io dependency pinned.
/// These guards keep it that way: the plugin stays Android-only, the Cargokit
/// glue (which ran unpinned pub.dev code during the build) does not come back,
/// for example through `flutter_rust_bridge_codegen integrate`, and no Rust
/// dependency floats.

/// The platform keys under `flutter: plugin: platforms:` in a pubspec.
List<String> pluginPlatforms(String pubspec) {
  final lines = pubspec.replaceAll('\r\n', '\n').split('\n');
  final start = lines.indexWhere((l) => l.trimRight() == '    platforms:');
  if (start < 0) return const [];
  final platforms = <String>[];
  for (final line in lines.skip(start + 1)) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final indent = line.length - line.trimLeft().length;
    if (indent <= 4) break;
    final key = RegExp(r'^ {6}([A-Za-z0-9_]+):').firstMatch(line);
    if (key != null) platforms.add(key.group(1)!);
  }
  return platforms;
}

/// Dependencies in a Cargo.toml whose version is not pinned with `=`, or that
/// come from git. A path-only dependency (a crate of this repo) is fine.
List<String> unpinnedCargoDependencies(String cargoToml) {
  final bad = <String>[];
  var inDependencies = false;
  for (final raw in cargoToml.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('[')) {
      inDependencies = RegExp(r'dependencies\]$').hasMatch(line);
      continue;
    }
    if (!inDependencies) continue;
    final entry = RegExp(r'^([A-Za-z0-9_-]+)\s*=\s*(.*)$').firstMatch(line);
    if (entry == null) continue; // blank, comment or continuation line
    final name = entry.group(1)!;
    final value = entry.group(2)!;
    if (value.startsWith('"')) {
      if (!value.startsWith('"=')) bad.add(name);
    } else if (value.contains('git =') || value.contains('git=')) {
      bad.add(name);
    } else if (RegExp(r'version\s*=').hasMatch(value)) {
      if (!RegExp(r'version\s*=\s*"=').hasMatch(value)) bad.add(name);
    } else if (!RegExp(r'path\s*=').hasMatch(value)) {
      bad.add(name);
    }
  }
  return bad;
}

void main() {
  group('helpers', () {
    test('pluginPlatforms reads the platform keys', () {
      const pubspec = '''
flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
      ios:
        ffiPlugin: true
other: 1
''';
      expect(pluginPlatforms(pubspec), ['android', 'ios']);
    });

    test('unpinnedCargoDependencies flags floating and git versions', () {
      const toml = '''
[package]
name = "x"
version = "0.1.0"

[dependencies]
local = { path = "../local" }
pinned = "=1.0.0"
pinned_table = { version = "=2.0.0", default-features = false, features = [
    "a",
] }
caret = "1.0"
table_caret = { version = "^2.0" }
from_git = { git = "https://example.invalid/x" }

[target.'cfg(unix)'.dependencies]
target_float = "0.3"

[profile.release]
lto = true
''';
      expect(unpinnedCargoDependencies(toml), [
        'caret',
        'table_caret',
        'from_git',
        'target_float',
      ]);
    });
  });

  test('the rust_builder plugin declares only the android platform', () {
    final pubspec = File('rust_builder/pubspec.yaml').readAsStringSync();
    expect(pluginPlatforms(pubspec), ['android']);
    expect(pubspec, contains('ffiPlugin: true'));
  });

  test('no Cargokit file or directory exists under app/', () {
    const skipped = {'build', '.dart_tool', 'target', '.gradle', 'Pods'};
    final found = <String>[];
    void walk(Directory dir) {
      for (final entity in dir.listSync(followLinks: false)) {
        final name = entity.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last
            .toLowerCase();
        if (name.startsWith('cargokit')) found.add(entity.path);
        if (entity is Directory && !skipped.contains(name)) walk(entity);
      }
    }

    walk(Directory('.'));
    expect(found, isEmpty);
  });

  test('app/rust pins every registry dependency with =', () {
    final toml = File('rust/Cargo.toml').readAsStringSync();
    expect(toml, contains('flutter_rust_bridge'), reason: 'sanity: parsed');
    expect(unpinnedCargoDependencies(toml), isEmpty);
  });
}
