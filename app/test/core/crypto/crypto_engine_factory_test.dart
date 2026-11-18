import 'dart:io';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_engine_factory.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory_io.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/native_crypto_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the factory throws UnsupportedError off Android and web', () {
    // The VM test host is Linux, macOS or Windows, never Android.
    expect(Platform.isAndroid, isFalse);
    expect(createCryptoEngine, throwsUnsupportedError);
    expect(
      () => createIoCryptoEngine(isAndroid: false),
      throwsUnsupportedError,
    );
  });

  test('on Android the factory returns the native engine', () {
    expect(createIoCryptoEngine(isAndroid: true), isA<NativeCryptoEngine>());
  });

  test('without the native library every call fails with internal', () async {
    // The VM has no libdzmls_flutter, so loading it fails: the engine must turn
    // that into MlsException(internal) on every call, not throw an Error.
    final engine = NativeCryptoEngine();
    final id = Uint8List(16);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        engine.createDevice(id),
        throwsA(
          isA<MlsException>().having(
            (e) => e.code,
            'code',
            MlsErrorCode.internal,
          ),
        ),
      );
    }
    await expectLater(
      engine.wireEpoch(id),
      throwsA(
        isA<MlsException>().having(
          (e) => e.code,
          'code',
          MlsErrorCode.internal,
        ),
      ),
    );
  });
}
