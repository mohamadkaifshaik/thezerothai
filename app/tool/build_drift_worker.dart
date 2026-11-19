import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Rebuilds web/drift_worker.js from tool/drift_worker.dart with dart2js,
/// against the drift and sqlite3 sources pubspec.lock resolves (the pub cache),
/// and writes web/drift_worker.version, which test/guards/drift_worker_guard_test.dart
/// checks against pubspec.lock. Nothing is downloaded.
///
/// Also checks that the checked-in web/sqlite3.wasm is the file the locked
/// sqlite3 package pins by SHA-256 for its release (its build hook's
/// asset_hashes.dart). It is not rebuilt here: building it needs a wasi
/// toolchain; see web/DRIFT_WEB_SETUP.md.
///
/// Run from app/ after `flutter pub get`: `make drift-worker` (repo root) or
/// `dart run tool/build_drift_worker.dart`.
Future<void> main() async {
  final lock = File('pubspec.lock').readAsStringSync();
  final drift = lockedVersion(lock, 'drift');
  final sqlite3 = lockedVersion(lock, 'sqlite3');

  final packages = _packageRoots();
  _expectPackageVersion(packages, 'drift', drift);
  _expectPackageVersion(packages, 'sqlite3', sqlite3);

  final wasmHash = sha256
      .convert(File('web/sqlite3.wasm').readAsBytesSync())
      .toString();
  _expectPinnedWasm(packages['sqlite3']!, sqlite3, wasmHash);

  final out = Directory.systemTemp.createTempSync('drift_worker_');
  try {
    final compiled = '${out.path}${Platform.pathSeparator}drift_worker.js';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      '-O4',
      '--no-source-maps',
      '-o',
      compiled,
      'tool/drift_worker.dart',
    ]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      throw StateError('dart compile js failed (exit ${result.exitCode})');
    }
    // Only the script: no .js.deps (absolute pub-cache paths) or source map.
    final worker = File(compiled).readAsBytesSync();
    File('web/drift_worker.js').writeAsBytesSync(worker);

    final dart = Platform.version.split(' ').first;
    File('web/drift_worker.version').writeAsStringSync(
      '# Written by `make drift-worker` (app/tool/build_drift_worker.dart). '
      'Do not edit;\n'
      '# test/guards/drift_worker_guard_test.dart checks it against '
      'pubspec.lock.\n'
      'drift=$drift\n'
      'sqlite3=$sqlite3\n'
      'dart=$dart\n'
      'drift_worker.js.sha256=${workerSha256(worker)}\n'
      'sqlite3.wasm.sha256=$wasmHash\n',
    );
    stdout.writeln(
      'web/drift_worker.js: drift $drift, ${worker.length} bytes, '
      'sha256 ${workerSha256(worker)} (Dart $dart)',
    );
  } finally {
    out.deleteSync(recursive: true);
  }
}

/// The `version:` of [package] in a pubspec.lock.
String lockedVersion(String lock, String package) {
  final match = RegExp(
    '^  ${RegExp.escape(package)}:\\r?\\n(?:    .*\\r?\\n)*?    version: "([^"]+)"',
    multiLine: true,
  ).firstMatch(lock);
  if (match == null) throw StateError('$package is not in pubspec.lock');
  return match.group(1)!;
}

/// SHA-256 of the worker with CRLF read as LF: git may check the file out
/// with CRLF on Windows (core.autocrlf), while dart2js writes and git stores LF.
String workerSha256(List<int> bytes) {
  final lf = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 13 && i + 1 < bytes.length && bytes[i + 1] == 10) continue;
    lf.add(bytes[i]);
  }
  return sha256.convert(lf).toString();
}

Map<String, Directory> _packageRoots() {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) {
    throw StateError('run `flutter pub get` in app/ first');
  }
  final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final p in (json['packages'] as List).cast<Map<String, dynamic>>())
      p['name'] as String: Directory.fromUri(
        config.absolute.uri.resolve(p['rootUri'] as String),
      ),
  };
}

void _expectPackageVersion(
  Map<String, Directory> packages,
  String name,
  String locked,
) {
  final root = packages[name];
  if (root == null) throw StateError('$name is not resolved; flutter pub get');
  final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
  final version = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec)?.group(1);
  if (version != locked) {
    throw StateError(
      '$name resolves to $version at ${root.path}, but pubspec.lock has '
      '$locked; run `flutter pub get` in app/',
    );
  }
}

void _expectPinnedWasm(Directory sqlite3Root, String version, String hash) {
  final pins = File('${sqlite3Root.path}/lib/src/hook/asset_hashes.dart');
  if (!pins.existsSync()) {
    throw StateError(
      'sqlite3 $version has no lib/src/hook/asset_hashes.dart; check '
      'web/sqlite3.wasm by hand (web/DRIFT_WEB_SETUP.md)',
    );
  }
  final text = pins.readAsStringSync();
  final tag = RegExp(r"releaseTag\s*=\s*'([^']+)'").firstMatch(text)?.group(1);
  final pinned = RegExp(r"'sqlite3\.wasm':\s*'([0-9a-f]{64})'")
      .firstMatch(text)
      ?.group(1);
  if (tag != 'sqlite3-$version' || pinned != hash) {
    throw StateError(
      'web/sqlite3.wasm (sha256 $hash) is not the sqlite3.wasm sqlite3 '
      '$version pins (release $tag, sha256 $pinned). Replace it with that '
      'release asset and check its hash; see web/DRIFT_WEB_SETUP.md',
    );
  }
}
