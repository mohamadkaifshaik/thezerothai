// Guard for the one link of the request-session binding no unit test can
// reach: `bootstrap.dart` wiring the production `ApiClient` to the auth bloc.
//
// `ApiClient(sessionUid:)` is required, so the compiler keeps the argument;
// this scan keeps its value. If the reader stopped reading the auth bloc's
// user, or the holder were never assigned, every call would silently go
// unbound (sent under whichever account the auth SDK answers for) while every
// interceptor test still passed.
//
// It also pins the SESSION_ENDED path (lane D PR 4): the ApiClient's
// `authTokens` and the AuthBloc's `authRepository` are the one
// AuthRepository instance, so a server-ended session reaches the bloc.
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

/// Lane D PR 4 (fix round ruling 2): the ApiClient's token provider is the
/// one AuthRepository. SessionEndedInterceptor reports a server-ended session
/// through `authTokens.reportSessionEnded`, which reaches the auth bloc only
/// through that repository's `onServerEndedSession` (set by the AuthBloc
/// built on it). A decorator or a second repository here would leave a cut
/// device "signed in" with every call failing, while every unit test passed.
final _apiClientTokens = RegExp(
  r'ApiClient\([^;]*?\bauthTokens:\s*authRepository\s*,',
);

/// The AuthBloc is built on that same repository.
final _authBlocRepository = RegExp(
  r'\bAuthBloc\(\s*authRepository:\s*authRepository\b',
);

/// One AuthRepository instance in bootstrap (so "the same name" is "the
/// same instance").
final _repositoryConstruction = RegExp(r'\bAuthRepository\(');

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
    if (!_apiClientTokens.hasMatch(code))
      'ApiClient(authTokens: authRepository)',
    if (!_authBlocRepository.hasMatch(code))
      'AuthBloc(authRepository: authRepository)',
    if (_repositoryConstruction.allMatches(code).length != 1)
      'exactly one AuthRepository(',
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
  final authRepository = AuthRepository(
    firebaseAuth: auth,
  );
  AuthBloc? sessionAuth;
  final apiClient = ApiClient(
    baseUrl: config.apiBaseUrl,
    authTokens: authRepository,
    sessionUid: () => sessionAuth?.state.user?.uid,
  );
  final authBloc = AuthBloc(
    authRepository: authRepository,
  )..add(const AuthSubscriptionRequested());
  sessionAuth = authBloc;
''';

    test('reports an ApiClient given another token provider (lane D PR 4: '
        'SESSION_ENDED would reach no auth bloc)', () {
      final broken = wired.replaceFirst(
        'authTokens: authRepository,',
        'authTokens: tokenDecorator,',
      );
      expect(missingWiring(broken), ['ApiClient(authTokens: authRepository)']);
    });

    test('reports an AuthBloc built on another repository', () {
      final broken = wired.replaceFirst(
        'authRepository: authRepository,',
        'authRepository: otherRepository,',
      );
      expect(missingWiring(broken), [
        'AuthBloc(authRepository: authRepository)',
      ]);
    });

    test('reports a second AuthRepository (two instances)', () {
      final broken = wired.replaceFirst(
        'sessionAuth = authBloc;',
        'sessionAuth = authBloc;\n  final spare = AuthRepository();',
      );
      expect(missingWiring(broken), ['exactly one AuthRepository(']);
    });

    test('a commented-out authTokens line does not count', () {
      final broken = wired.replaceFirst(
        'authTokens: authRepository,',
        '// authTokens: authRepository,',
      );
      expect(missingWiring(broken), ['ApiClient(authTokens: authRepository)']);
    });

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
