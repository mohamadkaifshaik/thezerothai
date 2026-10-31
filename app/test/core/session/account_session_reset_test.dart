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
}
