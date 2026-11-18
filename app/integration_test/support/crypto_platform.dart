// The platform-specific parts of integration_test/crypto_engine_test.dart:
// how the test reaches the vectors the driver serves, how it closes an engine,
// and whether the page is cross-origin isolated (web only).
export 'crypto_platform_io.dart'
    if (dart.library.js_interop) 'crypto_platform_web.dart';
