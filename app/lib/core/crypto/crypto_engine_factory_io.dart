import 'package:dzeroth/core/crypto/crypto_engine.dart';

/// Platforms without an engine yet.
CryptoEngine createPlatformCryptoEngine() => throw UnsupportedError(
  'No MLS engine for this platform yet; only web has one.',
);
