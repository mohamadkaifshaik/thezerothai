import 'dart:io';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/native_crypto_engine.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// The native engine on Android; other platforms (iOS included) have none yet.
CryptoEngine createPlatformCryptoEngine() =>
    createIoCryptoEngine(isAndroid: Platform.isAndroid);

/// [createPlatformCryptoEngine] with the platform check passed in, for tests.
@visibleForTesting
CryptoEngine createIoCryptoEngine({required bool isAndroid}) {
  if (isAndroid) return NativeCryptoEngine();
  throw UnsupportedError(
    'No MLS engine for this platform yet; only web and Android have one.',
  );
}
