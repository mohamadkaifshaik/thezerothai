import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/build_drift_worker.dart' show lockedVersion, workerSha256;

/// On the web, drift runs sqlite in web/drift_worker.js and web/sqlite3.wasm,
/// two checked-in builds that pubspec.lock does not update. A worker older than
/// the drift the app runs once lost every write made inside a transaction on
/// reload (drift 2.35.0 worker vs 2.35.4 app; drift #3864). These guards fail
/// when either file no longer matches the locked versions.
///
/// The worker embeds no version, so `make drift-worker` records the drift and
/// sqlite3 versions it built against, and both files' SHA-256, in
/// web/drift_worker.version.
const _fix =
    'run `make drift-worker` from the repo root (see app/web/DRIFT_WEB_SETUP.md)';

Map<String, String> _sidecar() {
  final file = File('web/drift_worker.version');
  if (!file.existsSync()) {
    fail('web/drift_worker.version is missing: $_fix');
  }
  return {
    for (final line in file.readAsLinesSync())
      if (line.contains('=') && !line.startsWith('#'))
        line.substring(0, line.indexOf('=')).trim(): line
            .substring(line.indexOf('=') + 1)
            .trim(),
  };
}

void main() {
  final lock = File('pubspec.lock').readAsStringSync();

  test('the drift worker was built for the drift in pubspec.lock', () {
    final drift = lockedVersion(lock, 'drift');
    expect(
      _sidecar()['drift'],
      drift,
      reason: 'web/drift_worker.js is not built for drift $drift: $_fix',
    );
  });

  test('the drift worker is the file that build recorded', () {
    final worker = File('web/drift_worker.js').readAsBytesSync();
    expect(
      workerSha256(worker),
      _sidecar()['drift_worker.js.sha256'],
      reason: 'web/drift_worker.js changed after `make drift-worker`: $_fix',
    );
  });

  test('the drift worker speaks the drift 2.35.1+ protocol', () {
    // Independent of the version file: `client_lock` is a field of the
    // worker's open request that drift 2.35.1 added along with the IndexedDB
    // transaction fix; a 2.35.0 worker (the one that lost writes) lacks it.
    final worker = File('web/drift_worker.js').readAsStringSync();
    expect(
      worker.contains('client_lock'),
      isTrue,
      reason: 'web/drift_worker.js predates drift 2.35.1: $_fix',
    );
  });

  test(
    'sqlite3.wasm is the build recorded for the sqlite3 in pubspec.lock',
    () {
      final sqlite3 = lockedVersion(lock, 'sqlite3');
      final sidecar = _sidecar();
      expect(
        sidecar['sqlite3'],
        sqlite3,
        reason:
            'web/sqlite3.wasm was checked for sqlite3 ${sidecar['sqlite3']}, '
            'pubspec.lock has $sqlite3: replace web/sqlite3.wasm with the '
            'sqlite3-$sqlite3 release asset, then $_fix',
      );
      expect(
        sha256.convert(File('web/sqlite3.wasm').readAsBytesSync()).toString(),
        sidecar['sqlite3.wasm.sha256'],
        reason: 'web/sqlite3.wasm changed after `make drift-worker`: $_fix',
      );
    },
  );

  group('lockedVersion', () {
    const lockText = '''
packages:
  drift:
    dependency: "direct main"
    description:
      name: drift
      sha256: "00"
      url: "https://pub.dev"
    source: hosted
    version: "2.35.4"
  drift_dev:
    dependency: "direct dev"
    source: hosted
    version: "2.35.3"
''';

    test('reads the entry, not a package sharing its prefix', () {
      expect(lockedVersion(lockText, 'drift'), '2.35.4');
      expect(lockedVersion(lockText, 'drift_dev'), '2.35.3');
      expect(
        lockedVersion(lockText.replaceAll('\n', '\r\n'), 'drift'),
        '2.35.4',
      );
    });

    test('throws for a package that is not locked', () {
      expect(() => lockedVersion(lockText, 'sqlite3'), throwsStateError);
    });
  });

  test('workerSha256 reads CRLF as LF', () {
    expect(
      workerSha256('a\r\nb\n'.codeUnits),
      workerSha256('a\nb\n'.codeUnits),
    );
    expect(workerSha256('a\rb'.codeUnits), isNot(workerSha256('ab'.codeUnits)));
  });
}
