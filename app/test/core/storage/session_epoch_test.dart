import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an epoch allows its own value until it ends', () {
    final epoch = SessionEpoch();
    final started = epoch.value;

    expect(epoch.allows(started), isTrue);

    epoch.end();

    expect(epoch.allows(started), isFalse);
    expect(epoch.allows(epoch.value), isTrue);
  });

  test('unguarded is always allowed, even after end()', () {
    final epoch = SessionEpoch();
    expect(epoch.allows(SessionEpoch.unguarded), isTrue);

    epoch.end();
    epoch.end();

    expect(epoch.allows(SessionEpoch.unguarded), isTrue);
    expect(epoch.allows(0), isFalse);
  });

  test('ended fires with the new value, already in force', () async {
    final epoch = SessionEpoch();
    final started = epoch.value;
    final seen = <(int, int, bool)>[];
    final sub = epoch.ended.listen(
      (v) => seen.add((v, epoch.value, epoch.allows(started))),
    );
    addTearDown(sub.cancel);

    epoch.end();
    await Future<void>.delayed(Duration.zero);

    expect(seen, [(started + 1, started + 1, false)]);
  });

  test('a listener changes nothing about allows()', () async {
    final epoch = SessionEpoch();
    final sub = epoch.ended.listen((_) {});
    addTearDown(sub.cancel);

    expect(epoch.allows(0), isTrue);
    epoch.end();
    expect(epoch.value, 1, reason: 'incremented before anyone is told');
    expect(epoch.allows(0), isFalse);
    expect(epoch.allows(1), isTrue);
    expect(epoch.allows(SessionEpoch.unguarded), isTrue);
  });

  test('every end() is told, in order', () async {
    final epoch = SessionEpoch();
    final seen = <int>[];
    final sub = epoch.ended.listen(seen.add);
    addTearDown(sub.cancel);

    epoch
      ..end()
      ..end();
    await Future<void>.delayed(Duration.zero);

    expect(seen, [1, 2]);
  });
}
