// The platform-specific parts of integration_test/vault_database_test.dart:
// on the web, what drift's probe lists for a database name, and a way to
// create a second copy of a database in IndexedDB. Off the web the helpers
// report nothing (the web-only cases are skipped there).
export 'vault_db_platform_io.dart'
    if (dart.library.js_interop) 'vault_db_platform_web.dart';
