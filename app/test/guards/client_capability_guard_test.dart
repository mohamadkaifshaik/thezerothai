// Guard for the client capability header (plan 6, section 3, Task 3.A).
//
// A later server floor tells old builds from new ones by the `x-dz-client`
// header. Two silent regressions would make that floor lie while every unit
// test still passed: the interceptor that stamps the header dropping out of
// the client's interceptor list, and a second definition of the level (so the
// value sent is no longer the one the tests pin).
//
// Limits: text scans with `//` comments removed first, so a commented-out
// line does not count. They prove presence in code, not runtime order.
import 'dart:io';

import 'package:dzeroth/core/app_build.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory_io.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

const _apiClient = 'lib/core/network/api_client.dart';
const _appBuild = 'lib/core/app_build.dart';

/// The stamping interceptor is registered in the transport's list.
final _registered = RegExp(
  r'\bconst\s+RequestMetadataInterceptor\(\s*\)\.call\b',
);

/// A definition of the level (a declaration with an initializer).
final _levelDefinition = RegExp(
  r'\b(?:int|const|final)\s+(?:int\s+)?kClientLevel\s*=',
);

/// A string literal of the header name.
final _headerLiteral = RegExp('[\'"]x-dz-client[\'"]', caseSensitive: false);

String _code(String source) => source
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

/// What is wrong with the registration in [apiClientSource] (empty if fine).
List<String> missingRegistration(String apiClientSource) => [
  if (!_registered.hasMatch(_code(apiClientSource)))
    'const RequestMetadataInterceptor().call in the ApiClient interceptors',
];

/// Files (by path) that define the level or spell the header name, from
/// [sources] (path to content).
Map<String, int> levelDefinitions(Map<String, String> sources) => {
  for (final e in sources.entries)
    if (_levelDefinition.allMatches(_code(e.value)).isNotEmpty)
      e.key: _levelDefinition.allMatches(_code(e.value)).length,
};

Map<String, int> headerLiterals(Map<String, String> sources) => {
  for (final e in sources.entries)
    if (_headerLiteral.allMatches(_code(e.value)).isNotEmpty)
      e.key: _headerLiteral.allMatches(_code(e.value)).length,
};

/// A construction of a Connect transport (`Transport(` not preceded by a word
/// character, so `withTransport(` does not match).
final _transportConstruction = RegExp(r'(?<![\w])Transport\(');

/// Files (by path) that construct a transport, with the count.
Map<String, int> transportConstructions(Map<String, String> sources) => {
  for (final e in sources.entries)
    if (_transportConstruction.allMatches(_code(e.value)).isNotEmpty)
      e.key: _transportConstruction.allMatches(_code(e.value)).length,
};

/// Whether the io engine factory builds an engine for [platform] (it throws
/// UnsupportedError when it has none).
bool _ioEngineExists(TargetPlatform platform) {
  try {
    createIoCryptoEngine(isAndroid: platform == TargetPlatform.android);
    return true;
  } on UnsupportedError {
    return false;
  }
}

Map<String, String> _libSources() => {
  for (final f in Directory('lib').listSync(recursive: true))
    if (f is File &&
        f.path.endsWith('.dart') &&
        !f.path.replaceAll(r'\', '/').startsWith('lib/gen/'))
      f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
};

void main() {
  test('the ApiClient registers the capability header interceptor', () {
    expect(
      missingRegistration(File(_apiClient).readAsStringSync()),
      isEmpty,
      reason:
          '$_apiClient must keep RequestMetadataInterceptor; without it '
          'no request carries x-dz-client and a server floor treats every '
          'build as level 0',
    );
  });

  test('kClientLevel is defined once, in app_build.dart', () {
    expect(levelDefinitions(_libSources()), {_appBuild: 1});
  });

  test('the header name is spelled once, in app_build.dart', () {
    expect(headerLiterals(_libSources()), {_appBuild: 1});
  });

  test('a Connect Transport is constructed only in api_client.dart', () {
    // A second transport would bypass the interceptors, and with them the
    // capability header. `connect.Transport transport)` (a type, in
    // ApiClient.withTransport) is not a construction.
    expect(transportConstructions(_libSources()), {_apiClient: 1});
  });

  test('kClientLevel is 0 wherever createCryptoEngine is unsupported', () {
    // The binding to real engine support lives here, not in lib: when an
    // engine lands for a platform (crypto_engine_factory_io.dart or _web.dart)
    // and clientLevelFor is not updated, or the reverse, this fails.
    for (final isWeb in [true, false]) {
      for (final platform in TargetPlatform.values) {
        final word = clientPlatformName(isWeb: isWeb, platform: platform);
        final level = clientLevelFor(word);
        final hasEngine = isWeb || _ioEngineExists(platform);
        expect(
          level > 0,
          hasEngine,
          reason:
              'isWeb=$isWeb platform=$platform sends "$word/$level" but '
              'the engine is ${hasEngine ? 'supported' : 'unsupported'}',
        );
        if (hasEngine) expect(level, kClientLevel);
      }
    }
  });

  group('the scan itself', () {
    const registered = '''
         interceptors: [
           const RequestMetadataInterceptor().call,
           SessionEndedInterceptor(authTokens, sessionUid).call,
         ],
''';

    test('reports the interceptor removed from the list', () {
      final broken = registered.replaceFirst(
        'const RequestMetadataInterceptor().call,',
        '',
      );
      expect(missingRegistration(broken), hasLength(1));
    });

    test('a commented-out registration does not count', () {
      final broken = registered.replaceFirst(
        'const RequestMetadataInterceptor().call,',
        '// const RequestMetadataInterceptor().call,',
      );
      expect(missingRegistration(broken), hasLength(1));
    });

    test('accepts the registered list', () {
      expect(missingRegistration(registered), isEmpty);
    });

    test('reports a second definition of the level', () {
      final sources = {
        _appBuild: 'const int kClientLevel = 1;',
        'lib/other.dart': 'const kClientLevel = 2;',
      };
      expect(levelDefinitions(sources), {_appBuild: 1, 'lib/other.dart': 1});
    });

    test('reports a second spelling of the header name', () {
      final sources = {
        _appBuild: "const kClientHeader = 'x-dz-client';",
        'lib/other.dart': 'h.set("x-dz-client", ["9"]);',
      };
      expect(headerLiterals(sources), {_appBuild: 1, 'lib/other.dart': 1});
    });

    test('reports a second transport construction', () {
      final sources = {
        _apiClient: 'x = protocol_connect.Transport(baseUrl: b);',
        'lib/other.dart': 'final t = Transport(baseUrl: b);',
      };
      expect(transportConstructions(sources), {
        _apiClient: 1,
        'lib/other.dart': 1,
      });
    });

    test('a type use, withTransport( and a comment are not constructions', () {
      expect(
        transportConstructions({
          'lib/a.dart':
              'ApiClient.withTransport(connect.Transport transport);\n'
              '// Transport(x)',
        }),
        isEmpty,
      );
    });

    test('a commented definition does not count', () {
      expect(
        levelDefinitions({'lib/a.dart': '// const int kClientLevel = 1;'}),
        isEmpty,
      );
    });
  });
}
