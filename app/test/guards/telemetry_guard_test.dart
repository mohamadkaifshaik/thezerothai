// guards: the rules that keep crash reports and usage
// statistics anonymous, behind the seam and off by default. Each guard fails
// the build when its rule breaks. Every scanner is also proven on synthetic
// input first, so a guard cannot pass because its pattern stopped matching.
//
// Run from app/ (as `flutter test` does). The CSP lives in the repo-root
// firebase.json, i.e. ../firebase.json (app/firebase.json is a different,
// FlutterFire file).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'telemetry_scan.dart';

const _crashAdapter = 'lib/core/telemetry/firebase_crash_reporter.dart';
const _usageAdapter = 'lib/core/telemetry/firebase_usage_analytics.dart';
const _guardFiles = {
  'test/guards/telemetry_guard_test.dart',
  'test/guards/telemetry_scan.dart',
};

Map<String, String> _dartSources() => {
  ...readTree('lib', {'.dart'}),
  ...readTree('test', {'.dart'}),
  if (Directory('integration_test').existsSync())
    ...readTree('integration_test', {'.dart'}),
}..removeWhere((path, _) => _guardFiles.contains(path));

Map<String, String> _nativeSources() => {
  ...readTree('android/app/src', {'.kt', '.java'}),
  ...readTree('ios/Runner', {'.swift', '.m', '.h'}),
};

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) fail('guard cannot find $path (run from app/)');
  return f.readAsStringSync();
}

/// Expected off values.
const _androidOff = <String, String>{
  'firebase_crashlytics_collection_enabled': 'false',
  'firebase_analytics_collection_enabled': 'false',
  'google_analytics_adid_collection_enabled': 'false',
  'google_analytics_ssaid_collection_enabled': 'false',
  'google_analytics_default_allow_analytics_storage': 'false',
  'google_analytics_default_allow_ad_storage': 'false',
  'google_analytics_default_allow_ad_user_data': 'false',
  'google_analytics_default_allow_ad_personalization_signals': 'false',
  'google_analytics_automatic_screen_reporting_enabled': 'false',
};

const _iosOff = <String>[
  'FirebaseCrashlyticsCollectionEnabled',
  'FIREBASE_ANALYTICS_COLLECTION_ENABLED',
  'FirebaseAutomaticScreenReportingEnabled',
  'GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED',
  'GOOGLE_ANALYTICS_DEFAULT_ALLOW_ANALYTICS_STORAGE',
  'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE',
  'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_USER_DATA',
  'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS',
];

/// The permanent switch-off keys: they cannot be undone at runtime, so using
/// one would make Analytics or Crashlytics impossible to turn on (A5).
const _deactivatedKeys = [
  'firebase_analytics_collection_deactivated',
  'firebase_crashlytics_collection_deactivated',
  'FIREBASE_ANALYTICS_COLLECTION_DEACTIVATED',
  'FirebaseCrashlyticsCollectionDeactivated',
];

void main() {
  group('scanners (synthetic mutations)', () {
    test('SDK imports', () {
      expect(findSdkImports("import 'package:firebase_analytics/x.dart';"), [
        'firebase_analytics',
      ]);
      expect(findSdkImports('export "package:firebase_crashlytics/y.dart";'), [
        'firebase_crashlytics',
      ]);
      expect(
        findSdkImports(
          "import 'package:firebase_crashlytics_platform_interface/a.dart';",
        ),
        ['firebase_crashlytics_platform_interface'],
      );
      expect(
        findSdkImports("import 'package:firebase_core/core.dart';"),
        isEmpty,
      );
    });

    test('forbidden identifier calls, any case, any spelling', () {
      for (final s in [
        'c.setUserIdentifier(uid)',
        'a.setUserId(uid)',
        'a.setUserProperty(name: "a", value: "b")',
        'a.setDefaultEventParameters({})',
        'Analytics.setUserID(uid)',
        'Analytics.setUserPropertyString(v, forName: "n")',
      ]) {
        expect(findForbiddenCalls(s), isNotEmpty, reason: s);
      }
      expect(findForbiddenCalls('final userId = 1; setConsent();'), isEmpty);
    });

    test('custom keys: literals in the allow list only', () {
      expect(
        findCustomKeyViolations("x.setCustomKey('platform', p);"),
        isEmpty,
      );
      expect(findCustomKeyViolations('x.setCustomKey("uid", u);'), ['"uid"']);
      expect(findCustomKeyViolations('x.setCustomKey(k, u);'), ['k']);
      // A variable key is allowed only in the two adapter lines.
      expect(
        findCustomKeyViolations(
          'Future<void> setCustomKey(String key, Object value);\n'
          '_c.setCustomKey(key, value);',
          isCrashAdapter: true,
        ),
        isEmpty,
      );
      expect(findCustomKeyViolations('_c.setCustomKey(key, value);'), ['key']);
    });

    test('manifest and plist readers ignore comments and see values', () {
      const manifest =
          '<!-- <meta-data android:name="a" android:value="false" /> -->'
          '<meta-data android:name="b"\n android:value="true" />';
      expect(manifestMetaData(manifest), {'b': 'true'});
      expect(
        plistBooleans('<!-- <key>A</key><false/> --><key>B</key>\n<true/>'),
        {'B': 'true'},
      );
    });

    test('ad permission scanners: removed, commented out, no remove', () {
      String tag(String p, {bool remove = true}) =>
          '<uses-permission android:name="$p"'
          '${remove ? ' tools:node="remove"' : ''}/>';
      final all = adPermissions.map(tag).join();
      expect(removesAdPermissions(all), isTrue);
      for (final p in adPermissions) {
        // Each name on its own: removed, deleted, commented out, no remove.
        expect(removesPermission(tag(p), p), isTrue, reason: p);
        expect(removesPermission('<!-- ${tag(p)} -->', p), isFalse, reason: p);
        expect(removesPermission(tag(p, remove: false), p), isFalse);
        final others = adPermissions.where((o) => o != p).map(tag).join();
        expect(removesAdPermissions(others), isFalse, reason: 'deleted $p');
        expect(
          removesAdPermissions('$others<!-- ${tag(p)} -->'),
          isFalse,
          reason: 'commented $p',
        );
        expect(
          removesAdPermissions('$others${tag(p, remove: false)}'),
          isFalse,
          reason: 'no remove $p',
        );
        // A variant manifest may remove it or not mention it, never add it.
        expect(addsNoAdPermission(tag(p)), isTrue);
        expect(addsNoAdPermission('<!-- ${tag(p, remove: false)} -->'), isTrue);
        expect(addsNoAdPermission(tag(p, remove: false)), isFalse);
      }
      // The AdServices name must not be satisfied by the play-services AD_ID.
      expect(
        removesPermission(tag(adPermissions[0]), adPermissions[1]),
        isFalse,
      );
    });

    test('CSP finder walks maps and lists', () {
      final json = jsonDecode(
        '{"hosting":[{"headers":[{"headers":[{"key":"content-security-policy","value":"a"}]}]}]}',
      );
      expect(cspValues(json), ['a']);
      expect(cspValues(jsonDecode('{"hosting":{}}')), isEmpty);
    });
  });

  group('imports', () {
    test('only the two adapter files import the SDKs, each its own', () {
      final found = <String, List<String>>{};
      _dartSources().forEach((path, src) {
        final hits = findSdkImports(src);
        if (hits.isNotEmpty) found[path] = hits;
      });
      // Both adapters still do (a stale allowlist or broken pattern fails).
      expect(found.keys.toSet(), {_crashAdapter, _usageAdapter});
      expect(found[_crashAdapter]!.toSet(), {'firebase_crashlytics'});
      expect(found[_usageAdapter]!.toSet(), {'firebase_analytics'});
    });

    test('native app code does not call the SDKs', () {
      // The SDKs are reached from Dart only (through the plugins).
      final native = _nativeSources();
      expect(native, isNotEmpty, reason: 'MainActivity.kt must be scanned');
      final hits = {
        for (final e in native.entries)
          if (RegExp(
            r'com\.google\.firebase\.(crashlytics|analytics)|import\s+Firebase(Crashlytics|Analytics)',
          ).hasMatch(e.value))
            e.key,
      };
      expect(hits, isEmpty);
    });
  });

  group('no user identifier (Q10 (f))', () {
    test('the app never reads the installation or app-instance ID', () {
      expect(findIdentifierReads('FirebaseInstallations.instance.getId()'), [
        'FirebaseInstallations',
      ]);
      expect(findIdentifierReads('await a.appInstanceId'), ['appInstanceId']);
      final hits = <String, List<String>>{};
      for (final entry in {..._dartSources(), ..._nativeSources()}.entries) {
        final found = findIdentifierReads(entry.value);
        if (found.isNotEmpty) hits[entry.key] = found;
      }
      expect(hits, isEmpty);
    });

    test('no setUserIdentifier, setUserId, setUserProperty or '
        'setDefaultEventParameters in Dart or native app code', () {
      final native = _nativeSources();
      expect(native, isNotEmpty, reason: 'MainActivity.kt must be scanned');
      final hits = <String, List<String>>{};
      for (final entry in {..._dartSources(), ...native}.entries) {
        final found = findForbiddenCalls(entry.value);
        if (found.isNotEmpty) hits[entry.key] = found;
      }
      expect(hits, isEmpty);
    });

    test('setCustomKey is used only with the three allowed keys', () {
      var calls = 0;
      final bad = <String, List<String>>{};
      _dartSources().forEach((path, src) {
        calls += 'setCustomKey'.allMatches(src).length;
        final v = findCustomKeyViolations(
          src,
          isCrashAdapter: path == _crashAdapter,
        );
        if (v.isNotEmpty) bad[path] = v;
      });
      expect(calls, greaterThan(0), reason: 'the adapter must set the keys');
      expect(bad, isEmpty);
    });
  });

  group('native off switches', () {
    test('every Android meta-data key has the off value', () {
      final meta = manifestMetaData(
        _read('android/app/src/main/AndroidManifest.xml'),
      );
      for (final e in _androidOff.entries) {
        expect(meta[e.key], e.value, reason: e.key);
      }
      for (final k in _deactivatedKeys) {
        expect(meta, isNot(contains(k)));
      }
    });

    test(
      'the three advertising permissions are removed in the source manifest',
      () {
        expect(
          removesAdPermissions(
            _read('android/app/src/main/AndroidManifest.xml'),
          ),
          isTrue,
        );
        // No variant adds it back or turns a key on.
        for (final variant in ['debug', 'profile']) {
          final path = 'android/app/src/$variant/AndroidManifest.xml';
          final xml = _read(path);
          expect(addsNoAdPermission(xml), isTrue, reason: path);
          for (final e in manifestMetaData(xml).entries) {
            if (_androidOff.containsKey(e.key)) {
              expect(e.value, 'false', reason: '$path ${e.key}');
            }
          }
        }
      },
    );

    test('every iOS plist key exists and is NO', () {
      final plist = plistBooleans(_read('ios/Runner/Info.plist'));
      for (final k in _iosOff) {
        expect(plist[k], 'false', reason: k);
      }
      for (final k in _deactivatedKeys) {
        expect(plist, isNot(contains(k)));
      }
    });
  });

  group('web', () {
    test('the CSP exists and names no Google Analytics host', () {
      final json = jsonDecode(_read('../firebase.json'));
      final csp = cspValues(json);
      expect(csp, isNotEmpty, reason: 'firebase.json lost its CSP header');
      for (final value in csp) {
        expect(value, contains('script-src'));
        expect(value, contains('connect-src'));
        for (final host in forbiddenCspHosts) {
          expect(value.toLowerCase(), isNot(contains(host)), reason: host);
        }
      }
    });

    test('the web shell loads no Analytics script', () {
      final html = _read('web/index.html').toLowerCase();
      for (final host in forbiddenCspHosts) {
        expect(html, isNot(contains(host)), reason: host);
      }
    });
  });
}
