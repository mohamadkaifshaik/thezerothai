import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/web_crypto_engine.dart';

/// The engine backed by the MLS Web Worker.
CryptoEngine createPlatformCryptoEngine() => WebCryptoEngine();
