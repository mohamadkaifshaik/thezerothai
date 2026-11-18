import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory_io.dart'
    if (dart.library.js_interop) 'package:dzeroth/core/crypto/crypto_engine_factory_web.dart'
    as impl;

/// The real [CryptoEngine] for this platform: the MLS worker on web, the
/// native library (flutter_rust_bridge) on Android. Other platforms, iOS
/// included, throw [UnsupportedError] until their engine lands.
CryptoEngine createCryptoEngine() => impl.createPlatformCryptoEngine();
