import 'package:dzeroth/core/session/account_session_reset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('run calls every registered step', () {
    final calls = <String>[];
    AccountSessionReset()
      ..register('a', () => calls.add('a'))
      ..register('b', () => calls.add('b'))
      ..run();
    expect(calls, ['a', 'b']);
  });

  test('registering a name twice keeps one step', () {
    var n = 0;
    final reset = AccountSessionReset()
      ..register('a', () => n += 1)
      ..register('a', () => n += 10)
      ..run();
    expect(n, 10);
    expect(reset.names, ['a']);
  });

  test('a failing step is reported and the others still run', () {
    final errors = <Object>[];
    var ran = false;
    AccountSessionReset()
      ..register('bad', () => throw StateError('x'))
      ..register('good', () => ran = true)
      ..run(onError: (e, _) => errors.add(e));
    expect(ran, isTrue);
    expect(errors, hasLength(1));
  });

  test('runIdBearing runs only the id-bearing steps (the account stays '
      'signed in)', () {
    final calls = <String>[];
    AccountSessionReset()
      ..register('push', () => calls.add('push'))
      ..register('graph', () => calls.add('graph'), idBearing: true)
      ..register('lists', () => calls.add('lists'), idBearing: true)
      ..register('snackbars', () => calls.add('snackbars'))
      ..runIdBearing();
    expect(calls, ['graph', 'lists']);
  });

  test('run still runs every step, id-bearing or not', () {
    final calls = <String>[];
    AccountSessionReset()
      ..register('push', () => calls.add('push'))
      ..register('graph', () => calls.add('graph'), idBearing: true)
      ..run();
    expect(calls, ['push', 'graph']);
  });

  test('a failing id-bearing step is reported and the others still run', () {
    final errors = <Object>[];
    var ran = false;
    AccountSessionReset()
      ..register('bad', () => throw StateError('x'), idBearing: true)
      ..register('good', () => ran = true, idBearing: true)
      ..runIdBearing(onError: (e, _) => errors.add(e));
    expect(errors, hasLength(1));
    expect(ran, isTrue);
  });
}
