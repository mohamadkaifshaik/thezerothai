// The platform-specific parts of integration_test/vault_cipher_test.dart:
// direct access to the web vault's stored key record (IndexedDB), so the test
// can check it is non-extractable, delete it or replace it. Off the web every
// helper throws UnsupportedError (the web group is skipped there).
export 'vault_platform_io.dart'
    if (dart.library.js_interop) 'vault_platform_web.dart';
