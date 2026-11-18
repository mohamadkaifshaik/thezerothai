// A second Web Locks client for integration_test/vault_owner_test.dart: it
// plays "another tab" by requesting the same lock name directly, without
// VaultOwner. Off the web every helper throws UnsupportedError (the web group
// is skipped there).
export 'web_lock_platform_io.dart'
    if (dart.library.js_interop) 'web_lock_platform_web.dart';
