import 'package:dzeroth/features/notifications/domain/push_opt_in.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the card is offered on Android only: not web, not iOS yet', () {
    bool on(bool web, TargetPlatform p) =>
        PushOptIn.supportedOn(isWeb: web, platform: p);

    expect(on(false, TargetPlatform.android), isTrue);
    expect(on(false, TargetPlatform.iOS), isFalse);
    expect(on(true, TargetPlatform.android), isFalse);
    expect(on(true, TargetPlatform.iOS), isFalse);
    expect(on(false, TargetPlatform.macOS), isFalse);
    expect(on(false, TargetPlatform.windows), isFalse);
  });

  test('"Not now" lasts 30 days', () {
    expect(PushOptIn.notNowWindow, const Duration(days: 30));
  });
}
