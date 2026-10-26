// Whether the browser has the Web Share API (false off the web).
export 'native_share_capability_stub.dart'
    if (dart.library.js_interop) 'native_share_capability_web.dart';
