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
}
