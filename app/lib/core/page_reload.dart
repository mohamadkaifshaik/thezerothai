// Reloads the page (web only; a no-op elsewhere). Used by the "A new version is
// available" prompt: Hosting serves only the current build, so a reload brings
// a stale tab up to date. No service worker is involved.
export 'page_reload_stub.dart'
    if (dart.library.js_interop) 'page_reload_web.dart';
