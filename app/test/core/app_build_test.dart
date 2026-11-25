import 'package:dzeroth/core/app_build.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the capability level is pinned: a bump is a deliberate edit', () {
    // Raise it by hand only when a later change makes older builds unsafe
    // (plan 6 section 3.1), and change this expectation in the same PR.
    expect(kClientLevel, 1);
    expect(kClientHeader, 'x-dz-client');
  });

  group('clientPlatformName', () {
    test('is web in a browser, whatever the target platform', () {
      expect(
        clientPlatformName(isWeb: true, platform: TargetPlatform.android),
        'web',
      );
      expect(
        clientPlatformName(isWeb: true, platform: TargetPlatform.iOS),
        'web',
      );
    });

    test('is android and ios on those targets', () {
      expect(
        clientPlatformName(isWeb: false, platform: TargetPlatform.android),
        'android',
      );
      expect(
        clientPlatformName(isWeb: false, platform: TargetPlatform.iOS),
        'ios',
      );
    });

    test('is other on every platform that has no E2EE engine and no floor', () {
      for (final p in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(clientPlatformName(isWeb: false, platform: p), 'other');
      }
    });
  });

  group('clientHeaderValue', () {
    test('android and web carry kClientLevel', () {
      expect(clientHeaderValue('android'), 'android/$kClientLevel');
      expect(clientHeaderValue('web'), 'web/$kClientLevel');
      expect(clientHeaderValue('android'), 'android/1');
      expect(clientHeaderValue('web'), 'web/1');
    });

    test('level is 0 wherever createCryptoEngine is unsupported', () {
      expect(clientHeaderValue('ios'), 'ios/0');
      expect(clientHeaderValue('other'), 'other/0');
    });
  });
}
