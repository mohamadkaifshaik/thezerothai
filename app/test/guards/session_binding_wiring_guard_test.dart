// Guard for the one link of the request-session binding no unit test can
// reach: `bootstrap.dart` wiring the production `ApiClient` to the auth bloc.
//
// `ApiClient(sessionUid:)` is required, so the compiler keeps the argument;
// this scan keeps its value. If the reader stopped reading the auth bloc's
// user, or the holder were never assigned, every call would silently go
// unbound (sent under whichever account the auth SDK answers for) while every
// interceptor test still passed.
//
// Limits: a text scan of one file, with `//` comments removed first so a
// commented-out line does not count. It proves the two lines are present in
// code, not that bootstrap runs them in this order at runtime.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _bootstrap = 'lib/app/bootstrap.dart';

/// The ApiClient argument: the session reader reads the auth bloc's user.
final _reader = RegExp(
  r'sessionUid:\s*\(\)\s*=>\s*sessionAuth\?\.state\.user\?\.uid\b',
);

/// The holder is assigned the auth bloc once it is built.
final _assignment = RegExp(r'\bsessionAuth\s*=\s*authBloc\s*;');

/// [source] with every `//` comment removed (line and doc comments).
String _code(String source) => source
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

/// The missing pieces of the wiring in [source] (empty when complete).
List<String> missingWiring(String source) {
  final code = _code(source);
  return [
    if (!_reader.hasMatch(code))
      'ApiClient(sessionUid: () => sessionAuth?.state.user?.uid)',
    if (!_assignment.hasMatch(code)) 'sessionAuth = authBloc;',
  ];
}

void main() {
  test('bootstrap binds the ApiClient to the auth bloc session', () {
    final source = File(_bootstrap).readAsStringSync();
    expect(
      missingWiring(source),
      isEmpty,
      reason:
          '$_bootstrap must wire the request-session binding; without it '
          'every API call goes unbound',
    );
  });

  group('the scan itself', () {
    const wired = '''
  AuthBloc? sessionAuth;
  final apiClient = ApiClient(
    sessionUid: () => sessionAuth?.state.user?.uid,
  );
  final authBloc = AuthBloc()..add(const AuthSubscriptionRequested());
  sessionAuth = authBloc;
''';

    test('accepts the complete wiring', () {
      expect(missingWiring(wired), isEmpty);
    });

    test('reports a reader that does not read the auth bloc', () {
      final broken = wired.replaceFirst(
        'sessionUid: () => sessionAuth?.state.user?.uid,',
        'sessionUid: () => null,',
      );
      expect(missingWiring(broken), [
        'ApiClient(sessionUid: () => sessionAuth?.state.user?.uid)',
      ]);
    });

    test('reports a missing or commented-out assignment', () {
      expect(missingWiring(wired.replaceFirst('sessionAuth = authBloc;', '')), [
        'sessionAuth = authBloc;',
      ]);
      expect(
        missingWiring(
          wired.replaceFirst(
            'sessionAuth = authBloc;',
            '// sessionAuth = authBloc;',
          ),
        ),
        ['sessionAuth = authBloc;'],
      );
    });
  });
}
